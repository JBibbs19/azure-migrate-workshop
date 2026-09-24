<#
.SYNOPSIS
    Parse every lab script without running any of them.

.DESCRIPTION
    A PowerShell script is parsed in full before its first line executes, so a syntax error
    anywhere in the file stops the whole thing -- including the prompts and the error trap that
    would otherwise report the problem. Launched with "Run with PowerShell", that looks like a
    window opening and closing with nothing in it.

    This runs the PowerShell parser over each .ps1 beside it and reports what it finds. It
    executes nothing, signs in to nothing and changes nothing, so it is safe to run at any time.

    Run it after editing any lab script, and before a workshop.

.EXAMPLE
    .\check-lab-scripts.ps1

.EXAMPLE
    .\check-lab-scripts.ps1 -Path 'C:\path\to\scripts'
MODULE COVERAGE
    None. This is a maintenance tool, not part of the workshop. Run it after editing any lab
    script and before a workshop.
#>

param(
    [string]$Path
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

Write-Host ''
Write-Host "Parsing every .ps1 under: $Path" -ForegroundColor Cyan
Write-Host ''

$files = @(Get-ChildItem -Path $Path -Filter '*.ps1' -Recurse -File | Sort-Object FullName)
if ($files.Count -eq 0) {
    Write-Host "No .ps1 files found under $Path." -ForegroundColor Yellow
    return
}

function Test-LabEncoding {
    <#
      Windows PowerShell 5.1 reads a file with no byte-order mark using the ANSI code page,
      not UTF-8. A script that contains a box-drawing character, an emoji or a curly quote and
      has no BOM is therefore read as mojibake, and the mangled bytes break string terminators
      and brackets. The failure looks like a syntax error in a line that is perfectly valid.

      Rule applied here:
        - non-ASCII present and a BOM present  -> fine
        - non-ASCII present and no BOM         -> reported
        - pure ASCII                           -> fine either way
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -eq 0) { return $null }
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $nonAscii = 0
    foreach ($byte in $bytes) { if ($byte -gt 127) { $nonAscii++ } }
    if ($nonAscii -gt 0 -and -not $hasBom) {
        return "$nonAscii non-ASCII byte(s) and no UTF-8 byte-order mark. Windows PowerShell 5.1 will misread this file. Save it as 'UTF-8 with BOM', or replace the characters with ASCII."
    }
    return $null
}

function Test-LabMissingHelper {
    <#
      Finds *-Lab* helper functions called in a file but never defined in it. Each migrate-step
      script inlines its own helpers so it can run standalone, so a helper that exists only in
      common.ps1 works during development and fails at run time for a learner.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    if (-not $ast) { return @() }

    $defined = @{}
    foreach ($definition in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $defined[$definition.Name] = $true
    }

    # A helper can legitimately live in another file. Two cases in this lab:
    #   1. deploy-lab.ps1 dot-sources health.ps1, so health.ps1's functions are in scope.
    #   2. host/configure-host.ps1 is a PAYLOAD. It never runs from disk: deploy-lab.ps1
    #      splices health.ps1 into it at the '# LAB_HEALTH_HELPERS' marker and sends the
    #      result to the host. On disk it looks like it is missing those helpers; at run
    #      time it is not.
    # Both are resolved here, otherwise this check reports faults that are not faults -
    # and a checker that cries wolf gets ignored, which is worse than no checker.
    $folder = Split-Path -Parent $Path
    $companions = @()
    foreach ($dotSource in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Dot' }, $true)) {
        $target = $dotSource.CommandElements[0].Extent.Text -replace '["'']', ''
        $leaf = Split-Path -Leaf ($target -replace '\$PSScriptRoot', '')
        if ($leaf) { $companions += $leaf }
    }
    if ((Get-Content -LiteralPath $Path -Raw) -match 'LAB_HEALTH_HELPERS') { $companions += 'health.ps1' }

    foreach ($companion in ($companions | Select-Object -Unique)) {
        $companionPath = Join-Path $folder $companion
        if (-not (Test-Path -LiteralPath $companionPath)) {
            $companionPath = Join-Path (Split-Path -Parent $folder) $companion
            if (-not (Test-Path -LiteralPath $companionPath)) { continue }
        }
        $companionAst = [System.Management.Automation.Language.Parser]::ParseFile($companionPath, [ref]$null, [ref]$null)
        if (-not $companionAst) { continue }
        foreach ($definition in $companionAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $defined[$definition.Name] = $true
        }
    }

    $missing = @{}
    foreach ($command in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if (-not $name -or ($name -notlike '*-Lab*' -and $name -notlike '*-LabProgress')) { continue }
        if ($defined.ContainsKey($name)) { continue }
        if (-not $missing.ContainsKey($name)) { $missing[$name] = $command.Extent.StartLineNumber }
    }
    return @($missing.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Name = $_.Key; Line = $_.Value }
    } | Sort-Object Line)
}

function Test-LabFunctionUsedBeforeDefined {
    <#
      Finds functions that are CALLED at script level before the line that DEFINES them.
      Calls inside another function body are ignored: those run later, by which time every
      definition in the file has been processed.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    if (-not $ast) { return @() }

    $definitions = @{}
    foreach ($definition in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $name = $definition.Name
        $line = $definition.Extent.StartLineNumber
        if (-not $definitions.ContainsKey($name) -or $line -lt $definitions[$name]) {
            $definitions[$name] = $line
        }
    }
    if ($definitions.Count -eq 0) { return @() }

    $findings = @()
    foreach ($command in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if (-not $name -or -not $definitions.ContainsKey($name)) { continue }

        # Skip calls that sit inside a function body.
        $parent = $command.Parent
        $insideFunction = $false
        while ($parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $insideFunction = $true; break }
            $parent = $parent.Parent
        }
        if ($insideFunction) { continue }

        $callLine = $command.Extent.StartLineNumber
        if ($callLine -lt $definitions[$name]) {
            $findings += [pscustomobject]@{
                Name           = $name
                CallLine       = $callLine
                DefinitionLine = $definitions[$name]
            }
        }
    }
    return @($findings | Sort-Object CallLine)
}

$totalErrors = 0
foreach ($file in $files) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$null, [ref]$parseErrors)

    $count = @($parseErrors).Count
    if ($count -eq 0) {
        # A script runs top to bottom, so a function called at script level before the line that
        # defines it fails at run time with "is not recognized as the name of a cmdlet". The
        # parser accepts it happily, so it is checked separately here.
        $earlyCalls = Test-LabFunctionUsedBeforeDefined -Path $file.FullName
        $missingHelpers = Test-LabMissingHelper -Path $file.FullName
        $encodingProblem = Test-LabEncoding -Path $file.FullName
        if ($encodingProblem) {
            $totalErrors++
            Write-Host ("  FAIL  {0}" -f $file.Name) -ForegroundColor Red
            Write-Host ("        encoding: {0}" -f $encodingProblem) -ForegroundColor Red
            continue
        }
        if ($earlyCalls.Count -eq 0 -and $missingHelpers.Count -eq 0) {
            Write-Host ("  OK    {0}" -f $file.Name) -ForegroundColor Green
            continue
        }
        $totalErrors += ($earlyCalls.Count + $missingHelpers.Count)
        Write-Host ("  FAIL  {0}" -f $file.Name) -ForegroundColor Red
        foreach ($call in $earlyCalls) {
            Write-Host ("        line {0}: '{1}' is called here but not defined until line {2}" -f `
                $call.CallLine, $call.Name, $call.DefinitionLine) -ForegroundColor Red
        }
        foreach ($helper in $missingHelpers) {
            Write-Host ("        line {0}: '{1}' is called but never defined in this file" -f `
                $helper.Line, $helper.Name) -ForegroundColor Red
        }
        continue
    }

    $totalErrors += $count
    Write-Host ("  FAIL  {0}  ({1} error(s))" -f $file.Name, $count) -ForegroundColor Red
    foreach ($parseError in $parseErrors) {
        $line = $parseError.Extent.StartLineNumber
        $col = $parseError.Extent.StartColumnNumber
        Write-Host ("        line {0}, column {1}: {2}" -f $line, $col, $parseError.Message) -ForegroundColor Red
        Write-Host ("        {0}" -f $parseError.Extent.Text.Trim()) -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($totalErrors -eq 0) {
    Write-Host ("All {0} script(s) parsed cleanly." -f $files.Count) -ForegroundColor Green
} else {
    Write-Host ("{0} parse error(s) across {1} script(s). Each one stops its script before the first line runs." -f $totalErrors, $files.Count) -ForegroundColor Red
}
Write-Host ''

if ($env:LAB_NO_PAUSE -ne '1' -and [Environment]::UserInteractive) {
    $null = Read-Host 'Press Enter to close this window'
}
