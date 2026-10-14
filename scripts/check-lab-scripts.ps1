<#
.SYNOPSIS
    Parse lab scripts; optionally run offline regressions or package the checkout.

.DESCRIPTION
    A PowerShell script is parsed in full before its first line executes, so a syntax error
    anywhere in the file stops the whole thing -- including the prompts and the error trap that
    would otherwise report the problem. Launched with "Run with PowerShell", that looks like a
    window opening and closing with nothing in it.

    By default this parses each .ps1 beside it, checks encoding and standalone helpers, and
    makes no file changes. It never runs a complete deployment or migration script.
    -RunRegressionChecks additionally executes only whitelisted AST-extracted helpers and
    a restricted literal NSG table with synthetic inputs and local read-only dependency mocks;
    traffic/security/guidance checks are labeled source contracts. No Azure modules, sign-in, prompts or VM actions are used.
    -PackagePath explicitly requests full-checkout ZIP packaging with fresh SHA256SUMS,
    deterministic entry names/timestamps and CRC/SHA256 readback. Packaging automatically
    runs regressions first and does not rebuild the prebuilt application WAR/runtime.
    -UpdateChecksums explicitly refreshes only SHA256SUMS, also after passing regressions.
    No Python or Pester dependency is required. Use Windows PowerShell 5.1 before release.
    Failures return a nonzero exit code; parse/regression failures prevent packaging writes.

.EXAMPLE
    .\check-lab-scripts.ps1

.EXAMPLE
    .\check-lab-scripts.ps1 -Path 'C:\path\to\scripts'

.EXAMPLE
    .\check-lab-scripts.ps1 -RunRegressionChecks

.EXAMPLE
    .\check-lab-scripts.ps1 -PackagePath '..\azure-migrate-workshop-tomcat.zip'
    From the checkout root, package to its parent folder. Existing ZIPs require -OverwritePackage.

.EXAMPLE
    .\check-lab-scripts.ps1 -UpdateChecksums
MODULE COVERAGE
    None. This is a maintenance tool, not part of the workshop. Run it after editing any lab
    script and before a workshop.
#>

param(
    [string]$Path,
    [switch]$RunRegressionChecks,
    [string]$PackagePath,
    [switch]$OverwritePackage,
    [switch]$UpdateChecksums
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

$wantsPackage = $PSBoundParameters.ContainsKey('PackagePath')
$wantsMaintenance = $RunRegressionChecks -or $wantsPackage -or $UpdateChecksums
if ($OverwritePackage -and -not $wantsPackage) { throw '-OverwritePackage requires -PackagePath.' }
if ($wantsMaintenance -and [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') -ine [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/')) {
    throw 'Offline regression/packaging options require this checkout scripts folder; omit -Path.'
}
$checkoutRoot = Split-Path -Parent $PSScriptRoot

Write-Host ''
Write-Host "Parsing every .ps1 under: $Path" -ForegroundColor Cyan
Write-Host ''

$files = @(Get-ChildItem -Path $Path -Filter '*.ps1' -Recurse -File | Sort-Object FullName)
if ($files.Count -eq 0) {
    Write-Host "No .ps1 files found under $Path." -ForegroundColor Red
    exit 1
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
        # The checker alone loads these definitions by AST in its offline child scope.
        if ($Path -eq $PSCommandPath -and (Get-LabOfflineHelperNames) -contains $name) {
            $parent = $command.Parent
            while ($parent -and -not ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $parent.Name -eq 'Invoke-LabOfflineRegression')) { $parent = $parent.Parent }
            if ($parent) { continue }
        }
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
        # Child-scope mocks/helpers are not definitions at script level.
        $parent = $definition.Parent
        $nested = $false
        while ($parent) {
            if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst] -or
                $parent -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $nested = $true; break }
            $parent = $parent.Parent
        }
        if ($nested) { continue }
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

function Get-LabOfflineHelperNames {
    return @('ConvertTo-LabRegionKey', 'Read-LabTargetRegion', 'Resolve-LabTargetNetworkLocation',
        'Get-LabField', 'Get-LabQuotaRow', 'Get-LabSkuPlan', 'Get-LabRunCommandText', 'Assert-LabWorkloadPower',
        'Get-LabKvpReadinessRow', 'Get-LabGuestCommunicationRows', 'ConvertFrom-LabGuestCommunicationPayload', 'Assert-LabGuestCommunication', 'Get-LabAssessmentField', 'Get-LabAssessmentContextStamp', 'Invoke-LabAssessmentRequest', 'Invoke-LabAssessmentCreation', 'ConvertTo-LabAssessmentSegment', 'Test-LabAssessmentPath', 'ConvertTo-LabAssessmentNextPath', 'Assert-LabAssessmentResponse', 'Invoke-LabAssessmentRead', 'Get-LabAssessmentCollection', 'Get-LabAssessmentCatalog', 'Assert-LabAssessmentProvider', 'Resolve-LabAssessmentProject', 'Get-LabAssessmentMachineMap', 'Get-LabAssessmentMembership', 'Get-LabAssessmentSettings', 'Assert-LabAssessmentIdentity', 'Assert-LabAssessmentSettings', 'Wait-LabAssessmentGroup', 'Get-LabAssessmentArray', 'Test-LabAssessmentGroupReady', 'Assert-LabAssessedMachines', 'Get-LabClassicAssessmentState', 'Get-LabAssessmentCompletion', 'Assert-LabAssessmentMachineMapStable', 'ConvertTo-LabAssessmentCanonicalId', 'Get-LabAssessmentProfile', 'Initialize-LabAssessmentGroup', 'Assert-LabModernSettingSubset', 'Assert-LabModernAssessment', 'Assert-LabModernAssessedMachines', 'Show-LabModernRecommendations', 'Get-LabModernAssessmentCompletion', 'Get-LabModernArray')
}

function Invoke-LabOfflineRegression {
    param([Parameter(Mandatory = $true)][string]$Root)
    # Only whitelisted definitions are loaded; the migration scripts themselves NEVER run.
    & {
        param($Root)
        $step1Path = Join-Path $Root 'scripts/migrate-step1-setup-project.ps1'
        $step1 = [IO.File]::ReadAllText($step1Path)
        $step2Path = Join-Path $Root 'scripts/migrate-step2-discover-assess.ps1'
        $step2 = [IO.File]::ReadAllText($step2Path)
        $traffic = [IO.File]::ReadAllText((Join-Path $Root 'scripts/enable-lab-traffic.ps1'))
        $summary = $step1.Substring($step1.IndexOf('# SUMMARY & NEXT STEPS'))
        $project = $step1.Substring($step1.IndexOf('Write-StepHeader -Step 5'))
        $required = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App')
        $SourceResourceGroup = 'fictional-source'; $HyperVHostVMName = 'fictional-host'
        $fixtureState = @{ HostCode = 'PowerState/running'; Result = $null; Reads = 0; Locations = @(
            [pscustomobject]@{ Location = 'eastus'; DisplayName = 'East US' },
            [pscustomobject]@{ Location = 'westus2'; DisplayName = 'West US 2' }); Network = [pscustomobject]@{ Location = 'westus2' } }

        # These local shadows accept common parameters and cannot contact Azure or prompt.
        function Get-AzLocation { [CmdletBinding()]param(); return $fixtureState.Locations }
        function Get-AzVirtualNetwork { [CmdletBinding()]param($ResourceGroupName, $Name); return $fixtureState.Network }
        function Get-AzVM {
            [CmdletBinding()]param($ResourceGroupName, $Name, [switch]$Status)
            if ($ResourceGroupName -cne 'fictional-source' -or $Name -cne 'fictional-host' -or -not $Status) { throw 'Unexpected host read.' }
            return [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = $fixtureState.HostCode }) }
        }
        function Invoke-AzVMRunCommand {
            [CmdletBinding()]param($ResourceGroupName, $VMName, $CommandId, $ScriptString)
            if ($ResourceGroupName -cne 'fictional-source' -or $VMName -cne 'fictional-host' -or
                $CommandId -cne 'RunPowerShellScript' -or $ScriptString -notmatch 'LAB_(?:GUEST_STATE_JSON|KVP_JSON)') { throw 'Unexpected inventory probe.' }
            $fixtureState.Reads++; return $fixtureState.Result
        }
        function Read-Host { param($Prompt); throw 'Offline regression must never prompt.' }
        function Write-Host { param($Object, $ForegroundColor); $assessmentFixture.Logs += [string]$Object }

        $assessmentFixture = @{ Logs = @(); Available = $true; Context = $null; Current = $null; Stamp = ''; Calls = @(); Responses = @(); Throw = '' }
        function Get-AzContext { [CmdletBinding()]param(); return $assessmentFixture.Current }
        function Start-Sleep { param([int]$Seconds); if ($Seconds -lt 1 -or $Seconds -gt 60) { throw 'Unexpected offline delay.' }; $assessmentFixture.Sleeps += $Seconds }
        function Get-Command {
            [CmdletBinding()]param([string[]]$Name, [System.Management.Automation.CommandTypes]$CommandType = 'All')
            if ($Name.Count -eq 1 -and $Name[0] -ceq 'Invoke-AzRestMethod') {
                if ($assessmentFixture.Available) { return [pscustomobject]@{ Name = 'Invoke-AzRestMethod' } }
                return
            }
            return Microsoft.PowerShell.Core\Get-Command -Name $Name -CommandType $CommandType -ErrorAction SilentlyContinue
        }
        function Invoke-AzRestMethod {
            [CmdletBinding()]param($Path, $Method, $Payload, $DefaultProfile)
            if (-not [object]::ReferenceEquals($DefaultProfile, $assessmentFixture.Context) -or $Method -notin @('GET', 'PUT', 'POST') -or
                $Path -notmatch '^/subscriptions/00000000-0000-0000-0000-000000000001/(?:providers/Microsoft\.Migrate\?|resourceGroups/fictional-source/providers/Microsoft\.Migrate/)' ) { throw 'Unexpected offline ARM request.' }
            $index = $assessmentFixture.Calls.Count
            $assessmentFixture.Calls += [pscustomobject]@{ Path = $Path; Method = $Method; Payload = $Payload }
            if ($assessmentFixture.Throw) { throw $assessmentFixture.Throw }
            if ($index -ge $assessmentFixture.Responses.Count) { throw 'Unexpected extra offline ARM request.' }
            return $assessmentFixture.Responses[$index]
        }

        $ast = [System.Management.Automation.Language.Parser]::ParseFile($step1Path, [ref]$null, [ref]$null)
        $helperNames = Get-LabOfflineHelperNames
        $allowedCommands = @('Where-Object', 'ForEach-Object', 'Write-Host', 'Write-Warning', 'ConvertFrom-Json',
            'Get-AzLocation', 'Get-AzVirtualNetwork', 'Get-AzVM', 'Invoke-AzVMRunCommand', 'Read-Host', 'ConvertTo-Json', 'Start-Sleep',
            'Get-VM', 'Get-CimInstance', 'Get-CimAssociatedInstance', 'Get-Command', 'Get-AzContext', 'Invoke-AzRestMethod') + $helperNames
        foreach ($name in $helperNames) {
            $helperAst = if ($name -in @('Get-LabKvpReadinessRow', 'Get-LabGuestCommunicationRows', 'ConvertFrom-LabGuestCommunicationPayload', 'Assert-LabGuestCommunication', 'Get-LabAssessmentField', 'Get-LabAssessmentContextStamp', 'Invoke-LabAssessmentRequest', 'Invoke-LabAssessmentCreation', 'ConvertTo-LabAssessmentSegment', 'Test-LabAssessmentPath', 'ConvertTo-LabAssessmentNextPath', 'Assert-LabAssessmentResponse', 'Invoke-LabAssessmentRead', 'Get-LabAssessmentCollection', 'Get-LabAssessmentCatalog', 'Assert-LabAssessmentProvider', 'Resolve-LabAssessmentProject', 'Get-LabAssessmentMachineMap', 'Get-LabAssessmentMembership', 'Get-LabAssessmentSettings', 'Assert-LabAssessmentIdentity', 'Assert-LabAssessmentSettings', 'Wait-LabAssessmentGroup', 'Get-LabAssessmentArray', 'Test-LabAssessmentGroupReady', 'Assert-LabAssessedMachines', 'Get-LabClassicAssessmentState', 'Get-LabAssessmentCompletion', 'Assert-LabAssessmentMachineMapStable', 'ConvertTo-LabAssessmentCanonicalId', 'Get-LabAssessmentProfile', 'Initialize-LabAssessmentGroup', 'Assert-LabModernSettingSubset', 'Assert-LabModernAssessment', 'Assert-LabModernAssessedMachines', 'Show-LabModernRecommendations', 'Get-LabModernAssessmentCompletion', 'Get-LabModernArray')) {
                [System.Management.Automation.Language.Parser]::ParseFile($step2Path, [ref]$null, [ref]$null)
            } else { $ast }
            $definitions = @($helperAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
                Where-Object { $_.Name -ceq $name -and $_.Parent -is [System.Management.Automation.Language.NamedBlockAst] -and $_.Parent.Parent -eq $helperAst })
            if ($definitions.Count -ne 1) { throw "Expected one top-level offline helper: $name" }
            foreach ($command in $definitions[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                if ($command.InvocationOperator -ne 'Unknown' -or $allowedCommands -notcontains $command.GetCommandName()) {
                    throw "Offline helper $name contains an unapproved command; review mocks before testing: $($command.Extent.Text)"
                }
            }
            . ([scriptblock]::Create($definitions[0].Extent.Text))
        }

        function Assert-Check { param([bool]$Condition, [string]$Message = 'Assertion failed'); if (-not $Condition) { throw $Message } }
        function Assert-Contains { param([string]$Text, [string[]]$Values); foreach ($value in $Values) { Assert-Check ($Text.Contains($value)) "Missing contract: $value" } }
        function Assert-Absent { param([string]$Text, [string[]]$Values); foreach ($value in $Values) { Assert-Check (-not $Text.Contains($value)) "Unexpected contract: $value" } }
        function Assert-Before {
            param([string]$Text, [string]$First, [string]$Second)
            Assert-Check ($Text.IndexOf($First) -ge 0 -and $Text.IndexOf($Second) -gt $Text.IndexOf($First)) "Expected ordering: $First BEFORE $Second"
        }
        function Assert-Throws {
            param([scriptblock]$Action)
            $threw = $false; try { $null = & $Action } catch { $threw = $true }
            Assert-Check $threw 'Expected rejection, but the helper accepted the fixture.'
        }
        function Get-Section {
            param([string]$Text, [string]$Start, [string]$End)
            $offset = $Text.IndexOf($Start); Assert-Check ($offset -ge 0) "Missing section: $Start"
            $offset += $Start.Length; $stop = $Text.IndexOf($End, $offset)
            Assert-Check ($stop -ge $offset) "Missing section terminator: $End"
            return $Text.Substring($offset, $stop - $offset)
        }
        function Get-StepText { param([int]$Stage); return [IO.File]::ReadAllText(@(Get-ChildItem (Join-Path $Root 'scripts') -Filter "migrate-step$Stage-*.ps1" -File)[0].FullName) }
        function Copy-Fixture { param($Object); return ($Object | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json) }
        function New-QuotaUsage {
            return @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'cores'; LocalizedValue = 'Fictional quota' }; CurrentValue = 3; Limit = 10; Unit = 'Count' },
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardBSFamily' }; CurrentValue = 2; Limit = 10; Unit = 'Count' },
                [pscustomobject]@{ Name = [pscustomobject]@{ Value = 'virtualMachines' }; CurrentValue = 1; Limit = 5; Unit = 'Count' })
        }
        function New-Sku {
            param([string]$Name, [int]$Cores, [string]$Family = 'standardBSFamily', [string]$Location = 'westus2', [object[]]$Restrictions = @())
            return [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Locations = @($Location); Family = $Family;
                Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Cores }, [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = '1' }); Restrictions = $Restrictions }
        }
        $skus = @((New-Sku 'Standard_B2s' 2), (New-Sku 'Standard_B2ms' 2), (New-Sku 'Standard_B1ms' 1))
        $sizes = @('Standard_B2s', 'Standard_B2ms', 'Standard_B1ms', 'Standard_B1ms')
        function New-PowerPayload {
            param([string[]]$States = @('Running', 'Running', 'Running', 'Running'))
            $rows = @(for ($i = 0; $i -lt 4; $i++) { [pscustomobject]@{ Name = $required[$i]; State = $States[$i] } })
            return 'LAB_GUEST_STATE_JSON|' + ([ordered]@{ Schema = 1; Rows = $rows } | ConvertTo-Json -Depth 5 -Compress) + "`nLAB_GUEST_STATE_END"
        }
        function New-StatusRecord { param($Message, $Code = 'ComponentStatus/StdOut/succeeded'); return [pscustomobject]@{ Code = $Code; Message = $Message } }
        function Test-PowerFixture {
            param($Result, $HostCode = 'PowerState/running')
            $fixtureState.Result = $Result; $fixtureState.HostCode = $HostCode
            return (Assert-LabWorkloadPower -Stage 'Offline synthetic inventory')
        }
        $checks = [ordered]@{}
        $checks['regional/region_names_display_names_and_source_are_not_defaults [helper + contract]'] = {
            foreach ($value in @('WESTUS2', ' West US 2 ', 'west us2')) { Assert-Check ((Read-LabTargetRegion $value 'eastus') -ceq 'westus2') }
            foreach ($value in @('', 'moonregion', 'eastus', ' East US ')) { Assert-Throws { Read-LabTargetRegion $value 'eastus' } }
            Assert-Contains $step1 @('Get-AzLocation -ErrorAction Stop', '$matches.Count -ne 1', 'if ($supplied) { throw', '$SourceLocation', "[Alias('TargetLocation')]", 'no default')
            Assert-Absent $step1 @('$Location = Resolve-LabLocation')
        }
        $checks['regional/source_host_actual_region_selection_not_group_metadata [contract]'] = {
            Assert-Contains $step1 @('$sourceHost = Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $HyperVHostVMName', '-SourceLocation $sourceHost.Location', "Where-Object { `$_.Name -eq 'HyperVHost' }).Count -eq 1")
            $selection = Get-Section $step1 '$hostVMs =' 'while ($true)'
            Assert-Absent $selection @('Select-Object -First'); Assert-Contains $selection @('Select-LabFromList'); Assert-Absent $step1 @('Standard_E8s_v7')
        }
        $checks['regional/quota_payload_family_names_units_and_unknown_not_zero [helper + contract]'] = {
            $usage = New-QuotaUsage; $row = Get-LabQuotaRow $usage 'CORES'
            Assert-Check ($row.Current -eq 3 -and $row.Limit -eq 10 -and $row.Remaining -eq 7)
            Assert-Check ((Get-LabQuotaRow $usage 'STANDARDBSFAMILY').Current -eq 2)
            Assert-Check ($null -eq (Get-LabQuotaRow $usage 'absentFamily'))
            foreach ($invalid in @(@{ CurrentValue = $null }, @{ Limit = $null }, @{ Unit = 'Percent' }, @{ CurrentValue = -1 }, @{ CurrentValue = '1.5' }, @{ Limit = -1 })) {
                $rows = New-QuotaUsage; foreach ($key in $invalid.Keys) { $rows[0].$key = $invalid[$key] }
                Assert-Check ($null -eq (Get-LabQuotaRow $rows 'cores'))
            }
            Assert-Check ($null -eq (Get-LabQuotaRow ($usage + $usage[0]) 'cores'))
            Assert-Contains $step1 @("'Name') 'Value'", '$rows.Count -ne 1', "[string]`$unit -ne 'Count'", 'not zero and not proof of headroom')
        }
        $checks['regional/read_failure_provider_and_missing_sku_are_unknown [helper + contract]'] = {
            Assert-Check (-not (Get-LabSkuPlan @() $sizes 'westus2').Known)
            Assert-Check (-not (Get-LabSkuPlan $skus[0..1] $sizes 'westus2').Known)
            Assert-Contains $step1 @('Microsoft.Compute is not registered; quota/SKU reads were not performed.', 'Get-AzVMUsage', 'Get-AzComputeResourceSku', 'Unknown ($($_.Exception.Message))', 'unresolved SKU metadata is not treated as zero', '$familyAdditional = if ($plan.Known)', '$additional = if ($plan.Known)', 'Target Total Regional vCPU quota Unknown.')
            Assert-Absent (Get-Section $step1 'function Get-LabRegionQuotaSnapshot' 'function Show-LabQuotaPreflight') @('Register-AzResourceProvider')
        }
        $checks['regional/sku_vcpus_family_aggregation_and_step3_planning_defaults [helper + contract]'] = {
            $plan = Get-LabSkuPlan $skus $sizes 'westus2'
            Assert-Check ($plan.Known -and $plan.Total -eq 6 -and $plan.Count -eq 4 -and $plan.Families.Count -eq 1 -and $plan.Families['standardbsfamily'] -eq 6)
            Assert-Check ((Get-LabSkuPlan @((New-Sku 'ActualHost' 8 'sourceFamily' 'eastus')) @('ActualHost') 'eastus').Total -eq 8)
            $actual = @([regex]::Matches((Get-StepText 3), 'TargetVMSize\s*=\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
            $declared = Get-Section $step1 '[string[]]$ForecastVmSizes = @(' ')'
            $defaults = @([regex]::Matches($declared, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
            Assert-Check (($actual -join ',') -ceq ($sizes -join ',') -and ($defaults -join ',') -ceq ($actual -join ','))
            Assert-Contains $step1 @("-eq 'vCPUs'", '$families[$family] += $cores')
        }
        $checks['regional/one_set_and_overlap_forecasts_do_not_replace_reported_usage [helper + contract]'] = {
            $plan = Get-LabSkuPlan $skus $sizes 'westus2'; $usage = New-QuotaUsage
            $regional = Get-LabQuotaRow $usage 'cores'; $family = Get-LabQuotaRow $usage 'standardBSFamily'; $vms = Get-LabQuotaRow $usage 'virtualMachines'
            Assert-Check ($regional.Current + $plan.Total -eq 9 -and $regional.Remaining - $plan.Total -eq 1)
            Assert-Check ($regional.Current + $plan.Total * 2 -eq 15 -and $regional.Remaining - $plan.Total * 2 -eq -5)
            Assert-Check ($family.Current + $plan.Families['standardBSFamily'] -eq 8 -and $vms.Current + $plan.Count -eq 5)
            Assert-Check ($plan.Total * 2 -eq 12 -and $plan.Count * 2 -eq 8)
            Assert-Contains $step1 @('already included, NOT added again', 'includes ALL resources', 'VM scale sets', 'allocated AND deallocated cores count', 'NOT separate Azure VMs', 'ONLY if both new sets coexist', 'replication disks do not reserve VM cores', '$plan.Total * 2', '$plan.Families[$family] * 2', '$plan.Count * 2')
        }
        $checks['regional/regional_family_and_vm_count_insufficiency_are_independent [helper arithmetic + contract]'] = {
            $plan = Get-LabSkuPlan $skus $sizes 'westus2'; $usage = New-QuotaUsage
            foreach ($key in @('cores', 'standardBSFamily', 'virtualMachines')) {
                $additional = if ($key -eq 'virtualMachines') { $plan.Count } elseif ($key -eq 'cores') { $plan.Total } else { $plan.Families[$key] }
                Assert-Check ((Get-LabQuotaRow $usage $key).Remaining -ge $additional)
                $rows = New-QuotaUsage; $row = @($rows | Where-Object { $_.Name.Value -eq $key })[0]; $row.Limit = $row.CurrentValue
                Assert-Check ((Get-LabQuotaRow $rows $key).Remaining -lt $additional)
            }
            Assert-Check ($null -eq (Get-LabQuotaRow @($usage | Where-Object { $_.Name.Value -ne 'standardBSFamily' }) 'standardBSFamily'))
            Assert-Contains $step1 @('$regional.Remaining -lt $plan.Total', '$row.Remaining -lt $plan.Families[$family]', '$vmCount.Remaining -lt $plan.Count', "Target family '`$family' quota Unknown.")
        }
        $checks['regional/applicable_sku_location_zone_restrictions_not_capacity_guarantees [helper + contract]'] = {
            $cases = @(@{ Type = 'Location'; Values = @('westus2'); ReasonCode = 'NotAvailableForSubscription' },
                @{ Type = 'Location'; Values = @('eastus') }, @{ Type = 'Zone'; Values = @('1'); RestrictionInfo = [pscustomobject]@{ Locations = @('westus2'); Zones = @('1') } },
                @{ Type = 'Zone'; RestrictionInfo = [pscustomobject]@{ Locations = @('eastus') } }, @{ Type = 'Location' })
            $expected = @($true, $false, $true, $false, $true)
            for ($i = 0; $i -lt $cases.Count; $i++) {
                $altered = Copy-Fixture $skus; $altered[0].Restrictions = @([pscustomobject]$cases[$i])
                Assert-Check (((Get-LabSkuPlan $altered $sizes 'westus2').Issues.Count -gt 0) -eq $expected[$i])
            }
            Assert-Contains $step1 @("'Restrictions'", "'RestrictionInfo'", "'ReasonCode'", "`$type -eq 'Zone'", 'Quota is not physical capacity')
        }
        $checks['regional/existing_network_actual_region_not_group_metadata [mocked helper + contract]'] = {
            Assert-Check ((Resolve-LabTargetNetworkLocation -ResourceGroupName 'fictional-target') -ceq 'westus2')
            Assert-Check ((Resolve-LabTargetNetworkLocation 'West US 2' 'fictional-target') -ceq 'westus2')
            Assert-Throws { Resolve-LabTargetNetworkLocation 'eastus' 'fictional-target' }
            $fixtureState.Network = $null; try { Assert-Throws { Resolve-LabTargetNetworkLocation -ResourceGroupName 'fictional-target' } } finally { $fixtureState.Network = [pscustomobject]@{ Location = 'westus2' } }
            foreach ($stage in 2..6) { $text = Get-StepText $stage; Assert-Contains $text @('Resolve-LabTargetNetworkLocation -Value $Location -ResourceGroupName $TargetResourceGroup'); Assert-Absent $text @('$Location = Resolve-LabLocation') }
            Assert-Contains $step2 @('$Location = Read-LabTargetRegion -Value $Location', '[string]$TargetResourceGroup')
        }
        $checks['regional/network_guards_before_writes_and_wrapper_passthrough [contract]'] = {
            foreach ($write in @('Register-AzResourceProvider -ProviderNamespace', 'New-AzResourceGroup -Name', 'New-AzVirtualNetwork `', 'New-AzNetworkSecurityGroup `')) {
                Assert-Before $step1 '    Assert-LabLandingZoneRegion -ResourceGroupName $TargetResourceGroup -Location $Location' $write
                Assert-Before $step1 '    $quotaPreflight = Show-LabQuotaPreflight' $write
            }
            Assert-Contains $step1 @("`$_.ResourceType -eq 'Microsoft.Network/networkSecurityGroups'", 'Target RG metadata region')
            $four = Get-StepText 4; Assert-Before $four '$preflightTestNetworks =' '$testVNet = New-AzVirtualNetwork'; Assert-Contains $four @('ConvertTo-LabRegionKey $existingVNet.Location')
            $six = Get-StepText 6; foreach ($guard in @('$existingBackupVaults =', 'ConvertTo-LabRegionKey $vm.Location')) { Assert-Before $six $guard '$workspace = New-AzOperationalInsightsWorkspace' }
            foreach ($suffix in @('3a-agentless', '3b-agent-based')) {
                $text = [IO.File]::ReadAllText((Join-Path $Root "scripts/migrate-step$suffix.ps1")); Assert-Absent $text @('$Location = Resolve-LabLocation'); Assert-Contains $text @('Location            = $Location')
            }
        }
        $checks['regional/inline_definitions_decisions_and_project_geography_contracts [contract]'] = {
            foreach ($stage in 1..6) { $text = Get-StepText $stage; foreach ($name in @('ConvertTo-LabRegionKey', 'Read-LabTargetRegion', 'Resolve-LabTargetNetworkLocation')) { Assert-Before $text ('function ' + $name) '$context = Get-LabAzContext' } }
            foreach ($name in @('Get-LabField', 'Get-LabQuotaRow', 'Get-LabSkuPlan', 'Get-LabRegionQuotaSnapshot', 'Show-LabQuotaPreflight', 'Assert-LabLandingZoneRegion')) { Assert-Before $step1 ('function ' + $name) '$context = Get-LabAzContext' }
            Assert-Contains $step1 @('[switch]$AllowQuotaWarning', '[1] Choose another target region', '[2] Continue NETWORK-ONLY', '[3] Cancel', 'if ($locationWasSupplied)', 'if ($script:LabStep1Interactive)', 'SkipSubscriptionPrompt', 'Project migration target lock was NOT verified', 'Create resources / Finalize discovery', 'Project geography is a separate portal decision')
            Assert-Absent $step1 @('$migrateLocationMap'); Assert-Check ($step1 -notmatch '(?m)^\s*New-AzMigrateProject\b'); Assert-Absent $project @('Install-Module')
        }
        $checks['regional/reusable_docs_explain_forecast_unknown_and_locked_region [contract]'] = {
            Assert-Contains ([IO.File]::ReadAllText((Join-Path $Root 'README.md'))) @('-Location $migrationTargetRegion', '-AllowQuotaWarning', '6 vCPUs', '12 vCPUs', 'Unknown')
            Assert-Contains ([IO.File]::ReadAllText((Join-Path $Root 'docs/Module-1-Discovery.md'))) @('migration target region')
            Assert-Contains ([IO.File]::ReadAllText((Join-Path $Root 'docs/Module-2-Agentless-Migration.md'))) @('Create resources', 'different from the actual source Hyper-V host')
            foreach ($file in Get-ChildItem $Root -Filter '*.md' -File -Recurse) { Assert-Check ([IO.File]::ReadAllText($file.FullName) -notmatch '(?i)\b(?:Joseph|azmig1)\b') }
            $zero = [IO.File]::ReadAllText((Join-Path $Root 'docs/Module-0-Setup.md')); Assert-Absent $zero @('deallocate other VMs in that family'); Assert-Contains $zero @('allocated and deallocated')
        }
        $checks['guidance/lookup_state_is_initialized_before_query [contract]'] = {
            Assert-Before $project '$migrateProject = $null' 'Get-AzResource'; Assert-Before $project '$projectLookupSucceeded = $false' 'Get-AzResource'
            Assert-Before $project "throw 'Ambiguous project resource lookup.'" '$projectLookupSucceeded = $true'
        }
        $checks['guidance/next_steps_only_in_verified_project_branch [contract]'] = {
            Assert-Check (([regex]::Matches($step1, [regex]::Escape('Write-NextSteps @('))).Count -eq 1)
            $ready = Get-Section $summary "`nif (`$migrateProject) {`n" '} elseif ($projectLookupSucceeded) {'
            Assert-Contains $ready @('Write-NextSteps @(', 'Run Step 2:')
            $pending = $summary.Substring($summary.IndexOf('} elseif ($projectLookupSucceeded) {')); Assert-Absent $pending @('Write-NextSteps', 'Run Step 2:')
        }
        $checks['guidance/absent_project_cycles_back_to_creation_then_rerun [contract]'] = {
            Assert-Contains $summary @('Create the Azure Migrate project in the portal (Module 1, section 1)', '-Instructions $projectCreationInstructions')
            Assert-Contains (Get-Section $project '$projectCreationInstructions = @(' "`n)") @('Create project', '$SourceResourceGroup', '$MigrateProjectName', 'PROJECT DATA geography', 'wait for the deployment to finish', 'rerun Step 1 with the same settings', '$rerunStep1Command', 'Do not run Step 2 until Step 1 successfully verifies the project.')
            Assert-Absent $step1 @('or continue to Module 1 by hand')
        }
        $checks['guidance/read_failure_is_unknown_not_absent [contract]'] = {
            Assert-Contains (Get-Section $project '} catch {' '# SUMMARY & NEXT STEPS') @('$migrateProject = $null', '$projectLookupSucceeded = $false', 'does not mean the project is absent')
            Assert-Contains $summary @('do not create a duplicate')
        }
        $checks['guidance/pending_summary_and_rerun_preserve_selected_settings [contract]'] = {
            Assert-Before $summary "Assert-LabWorkloadPower -Stage 'Step 1 final readiness'" 'Write-Section "STEP 1 COMPLETE -- Summary"'
            Assert-Contains $summary @('LANDING ZONE READY -- Step 1 requires project verification', 'not found; portal creation required', 'could not verify; retry required')
            $command = Get-Section $project '$rerunStep1Command = ' "`n"
            Assert-Contains $command @('-SourceResourceGroup', '-TargetResourceGroup', '-Location', '-MigrateProjectName', '-HyperVHostVMName'); Assert-Absent $command @('-AllowQuotaWarning')
        }
        $checks['readiness/exact_four_workloads_and_identical_inline_helpers [contract]'] = {
            $one = Get-Section $step1 'function Get-LabRunCommandText {' 'function Test-LabMatchingLocalHost'
            $two = Get-Section $step2 'function Get-LabRunCommandText {' 'function Get-LabKvpReadinessRow'
            Assert-Check ($one -ceq $two); foreach ($name in $required) { Assert-Contains $one @("'$name'") }
            Assert-Contains $one @('MigrateAppl is not a workload prerequisite', '$rows.Count -ne 4', '$row.Name -cne $required[$i]', 'not proof of application or database health')
        }
        $checks['readiness/all_running_and_stdout_not_first [mocked helper + contract]'] = {
            $parts = (New-PowerPayload) -split "`n"
            $result = [pscustomobject]@{ Value = @((New-StatusRecord '' 'ComponentStatus/StdErr/succeeded'), (New-StatusRecord $parts[0]), (New-StatusRecord $parts[1])) }
            $ready = Test-PowerFixture $result; Assert-Check (($ready.Rows.Name -join ',') -ceq ($required -join ','))
            Assert-Contains $step1 @('StdOut', 'StdErr'); Assert-Absent (Get-Section $step1 'function Get-LabRunCommandText' 'function Test-LabMatchingLocalHost') @('$result.Value[0]')
        }
        $checks['readiness/mixed_missing_saved_paused_unknown_states_block [mocked helper + contract]'] = {
            foreach ($state in @('Off', 'Missing', 'Saved', 'Paused', 'Unknown', 'Starting', 'running')) { Assert-Throws { Test-PowerFixture ([pscustomobject]@{ Value = @((New-StatusRecord (New-PowerPayload @('Running', $state, 'Running', 'Running')))) }) } }
            Assert-Contains $step1 @("`$_.State -cne 'Running'", 'Start-VM -Name', 'Resume-VM -Name', 'Start-VM cannot create it', 'No nested VM was automatically started')
        }
        $checks['readiness/host_off_and_localized_status_fail_closed [mocked helper + contract]'] = {
            foreach ($code in @('PowerState/deallocated', 'PowerState/stopped', 'PowerState/starting', '', $null, 'VM running')) {
                $reads = $fixtureState.Reads; Assert-Throws { Test-PowerFixture ([pscustomobject]@{ Value = @((New-StatusRecord (New-PowerPayload))) }) $code }; Assert-Check ($reads -eq $fixtureState.Reads)
            }
            foreach ($text in @($step1, $step2)) { $helper = Get-Section $text 'function Assert-LabWorkloadPower' 'return [pscustomobject]'; Assert-Contains $helper @('$power.Count -ne 1', "-cne 'PowerState/running'"); Assert-Absent $helper @('DisplayStatus') }
        }
        $checks['readiness/unreadable_empty_host_outputs_fail_closed [mocked helper + contract]'] = {
            foreach ($result in @($null, [pscustomobject]@{}, [pscustomobject]@{ Value = @() }, [pscustomobject]@{ Value = @((New-StatusRecord '')) }, [pscustomobject]@{ Value = @((New-StatusRecord '' 'ProvisioningState/succeeded')) }, [pscustomobject]@{ Value = @($null) })) { Assert-Throws { Test-PowerFixture $result } }
            Assert-Contains $step1 @('selected host power/inventory could not be verified', 'no next-stage guidance or traffic is permitted')
        }
        $checks['readiness/stderr_blocks_even_with_valid_stdout [mocked helper + contract]'] = {
            $good = New-StatusRecord (New-PowerPayload); $bad = New-StatusRecord 'failure' 'ComponentStatus/StdErr/succeeded'
            Assert-Throws { Test-PowerFixture ([pscustomobject]@{ Value = @($good, $bad) }) }; Assert-Throws { Test-PowerFixture ([pscustomobject]@{ Value = @($bad, $good) }) }
            Assert-Contains $step1 @('Host read reported stderr')
        }
        $checks['readiness/failed_status_records_cannot_be_masked_by_payload [mocked helper + contract]'] = {
            $badRecords = @((New-StatusRecord (New-PowerPayload) 'ComponentStatus/StdOut/failed'), (New-StatusRecord '' 'ProvisioningState/failed'),
                [pscustomobject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = ''; Level = 'Error' },
                (New-StatusRecord (New-PowerPayload) 'ComponentStatus/StdOut/unknown'), [pscustomobject]@{ Message = (New-PowerPayload) })
            foreach ($bad in $badRecords) { Assert-Throws { Test-PowerFixture ([pscustomobject]@{ Value = @((New-StatusRecord (New-PowerPayload)), $bad) }) } }
            Assert-Contains $step1 @("`$code -match '(?i)(failed|error)'", "`$entry.Level -eq 'Error'")
        }
        $checks['readiness/malformed_truncated_duplicate_protocol_blocks [mocked helper + contract]'] = {
            $valid = New-PowerPayload
            foreach ($text in @($valid.Substring(0, $valid.Length - 4), ($valid -split "`n")[0], ($valid + "`n" + $valid), $valid.Replace('LAB_GUEST_STATE_JSON|', ''), "LAB_GUEST_STATE_JSON|{}`nLAB_GUEST_STATE_END", "LAB_GUEST_STATE_JSON|not-json`nLAB_GUEST_STATE_END", ($valid + "`nLAB_GUEST_STATE_END"))) { Assert-Throws { Test-PowerFixture ([pscustomobject]@{ Value = @((New-StatusRecord $text)) }) } }
            Assert-Contains $step1 @('Missing, duplicate or truncated workload power payload')
        }
        $checks['readiness/row_schema_count_names_and_state_types_blocks [mocked helper]'] = {
            $body = ((New-PowerPayload).Split('|')[1] -split "`n")[0] | ConvertFrom-Json
            foreach ($kind in @('short', 'extra', 'duplicate', 'wrongname', 'null', 'badstate', 'schema', 'norows', 'reorder')) {
                $item = Copy-Fixture $body
                switch ($kind) {
                    'short' { $item.Rows = $item.Rows[0..2] }
                    'extra' { $item.Rows += [pscustomobject]@{ Name = 'MigrateAppl'; State = 'Running' } }
                    'duplicate' { $item.Rows[1] = $item.Rows[0] }
                    'wrongname' { $item.Rows[1].Name = 'OtherLab-SQL' }
                    'null' { $item.Rows[1] = $null }
                    'badstate' { $item.Rows[1].State = @() }
                    'schema' { $item.Schema = 2 }
                    'norows' { $item.PSObject.Properties.Remove('Rows') }
                    'reorder' { [array]::Reverse($item.Rows) }
                }
                $text = 'LAB_GUEST_STATE_JSON|' + ($item | ConvertTo-Json -Depth 6 -Compress) + "`nLAB_GUEST_STATE_END"
                Assert-Throws { Test-PowerFixture ([pscustomobject]@{ Value = @((New-StatusRecord $text)) }) }
            }
        }
        $checks['readiness/step1_gate_and_helpers_before_writes [contract]'] = {
            $gate = "`$guestReadiness = Assert-LabWorkloadPower -Stage 'Step 1 pre-flight'"
            foreach ($name in @('Get-LabRunCommandText', 'Assert-LabWorkloadPower', 'Start-LabTrafficOnSelectedHost', 'Invoke-LabTrafficOffer')) { Assert-Before $step1 ('function ' + $name) $gate }
            foreach ($write in @('Register-AzResourceProvider -ProviderNamespace', 'New-AzResourceGroup -Name', 'New-AzVirtualNetwork `', 'New-AzNetworkSecurityGroup `')) { Assert-Before $step1 $gate $write }
        }
        $checks['readiness/step2_gate_before_appliance_module_and_actions [contract]'] = {
            $gate = "`$guestReadiness = Assert-LabWorkloadPower -Stage 'Step 2 pre-flight'"
            foreach ($name in @('Get-LabRunCommandText', 'Assert-LabWorkloadPower')) { Assert-Before $step2 ('function ' + $name) $gate }
            foreach ($action in @('Install-Module -Name Az.Migrate', 'All prerequisites verified.', 'Write-StepHeader -Step 1', "`$worker = @'", "`$importScript = @'")) { Assert-Before $step2 $gate $action }
            Assert-Absent (Get-Section $step2 '# PRE-FLIGHT: Verify Prerequisites' '# STEP 1:') @('Start-AzVM', 'DisplayStatus'); Assert-Absent $step2 @('$guestVmResult.Value[0]')
        }
        $checks['readiness/final_recheck_and_offer_is_last_ready_action [contract]'] = {
            Assert-Before $summary "Assert-LabWorkloadPower -Stage 'Step 1 final readiness'" 'Write-NextSteps @('; Assert-Before $summary 'Write-NextSteps @(' '    Invoke-LabTrafficOffer'
            $ready = Get-Section $summary "`nif (`$migrateProject) {`n    Write-NextSteps @(" '} elseif ($projectLookupSucceeded)'
            Assert-Check ($ready.TrimEnd().EndsWith('Invoke-LabTrafficOffer')); Assert-Contains $ready @("-HyperVHostVMName '`$HyperVHostVMName'")
            Assert-Contains $step1 @("Assert-LabWorkloadPower -Stage 'Before requested traffic startup'")
        }
        $checks['readiness/no_enter_unrecognized_never_launch [contract + decision expression fixtures]'] = {
            # The exact literal regex is read from the offer; no traffic function is invoked.
            $offer = Get-Section $step1 'function Invoke-LabTrafficOffer {' '# Target networking configuration'
            $pattern = [regex]::Match($offer, '\$answer -notmatch ''([^'']+)''').Groups[1].Value
            Assert-Check ($pattern -ceq '^(?i:y|yes)$')
            foreach ($answer in @('', 'n', 'no', 'maybe', 'true', '1', 'y later', ' yes ')) { Assert-Check ($answer -notmatch $pattern) }
            foreach ($answer in @('y', 'Y', 'yes', 'YES')) { Assert-Check ($answer -match $pattern) }
            Assert-Contains $step1 @('Would you like to initiate lab traffic as part of the immediate continuation of the lab? [y/N]')
        }
        $checks['readiness/supplied_input_safe_default_and_explicit_controls [contract]'] = {
            Assert-Contains $step1 @("[ValidateSet('Prompt', 'Start', 'Skip')]", '[SecureString]$LabTrafficPassword', "`$script:LabTrafficExplicit = `$PSBoundParameters.ContainsKey('LabTraffic')", '-not $script:LabTrafficExplicit')
            $offer = Get-Section $step1 'function Invoke-LabTrafficOffer {' '# Target networking configuration'
            Assert-Contains $offer @("`$LabTraffic -eq 'Skip'", "`$LabTraffic -eq 'Prompt' -and -not `$script:LabStep1Interactive", "if (`$LabTraffic -ne 'Start')")
            Assert-Before $offer 'return' 'Read-Host'; Assert-Before $offer 'Read-Host' 'Start-LabTrafficOnSelectedHost'
            $offerAst = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-LabTrafficOffer' }, $true))[0]
            $conditions = @($offerAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true) |
                ForEach-Object { $_.Clauses[0].Item1 } | Where-Object { $_.Extent.Text.Contains("`$LabTraffic -eq 'Skip'") })
            Assert-Check ($conditions.Count -eq 1)
            Assert-Check (@($conditions[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -or $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)).Count -eq 0)
            # Rename only script-scope bindings so the expression has no persistent state.
            $expression = $conditions[0].Extent.Text.Replace('$script:LabStep1Interactive', '$interactive').Replace('$script:LabTrafficExplicit', '$explicit')
            $skip = [scriptblock]::Create('param($LabTraffic, $interactive, $explicit) return (' + $expression + ')')
            Assert-Check (& $skip 'Prompt' $false $false)
            Assert-Check (-not (& $skip 'Prompt' $false $true))
            Assert-Check (-not (& $skip 'Start' $false $true))
            Assert-Check (& $skip 'Skip' $true $true)
        }
        $checks['readiness/missing_unknown_project_or_guests_block_offer [contract]'] = {
            Assert-Check (([regex]::Matches($summary, [regex]::Escape('    Invoke-LabTrafficOffer'))).Count -eq 1)
            $pending = $summary.Substring($summary.IndexOf('} elseif ($projectLookupSucceeded)')); Assert-Absent $pending @('Invoke-LabTrafficOffer', 'Write-NextSteps')
            $offer = Get-Section $step1 'function Invoke-LabTrafficOffer {' '# Target networking configuration'; Assert-Before $offer 'Assert-LabWorkloadPower' 'Start-LabTrafficOnSelectedHost'
        }
        $checks['readiness/local_invocation_requires_matching_imds_elevation_and_version [contract]'] = {
            $local = Get-Section $step1 'function Test-LabMatchingLocalHost' 'foreach ($command'
            Assert-Contains $local @('169.254.169.254/metadata/instance/compute', '$metadata.vmId -eq $sourceHost.VmId', '$metadata.name -eq $HyperVHostVMName', '$metadata.resourceGroupName -eq $SourceResourceGroup', '$metadata.subscriptionId -eq $context.Subscription.Id', '-TimeoutSec 3', '-not $elevated', "ContainsKey('NonInteractive')", '& $trafficPath -AdminPassword $password', 'LAB_TRAFFIC_FULLY_STARTED')
        }
        $checks['readiness/remote_password_only_protected_and_source_has_no_value [contract]'] = {
            $launch = Get-Section $step1 'function Start-LabTrafficOnSelectedHost' 'function Invoke-LabTrafficOffer'
            $payload = Get-Section $launch "    `$payload = @'`n" ("`n'@")
            Assert-Check ($payload -notmatch '[^\x00-\x7F]'); Assert-Absent $payload @('$passwordPlain', 'FromBase64String', 'Read-Host')
            Assert-Contains $launch @('-ProtectedParameter $protected', '-Location $sourceHost.Location', '-VMName $HyperVHostVMName', '-AsyncExecution -AsJob', "@{ Name = 'AdminPassword'; Value = `$passwordPlain }")
            Assert-Absent $launch @('-Parameter '); Assert-Before $launch "ContainsKey('ProtectedParameter')" '$protected = @('
        }
        $checks['readiness/noninteractive_preflight_before_generator_writes [contract]'] = {
            $execution = $traffic.Substring($traffic.IndexOf('# ---------- Execution ----------'))
            foreach ($prerequisite in @('Initialize-LabSshAskpass', 'LAB_TRAFFIC_SSH_READY', "Name='OnPrem-Linux-Web'", "Name='OnPrem-Linux-App'", 'Assert-TrafficWorkloadPower')) { Assert-Before $execution $prerequisite "Write-Step 'Adding hosts" }
            Assert-Before $traffic 'function Initialize-LabSshAskpass' '$script:LabAskpass = Initialize-LabSshAskpass'
            Assert-Check (([regex]::Matches($traffic, "`nAssert-TrafficWorkloadPower")).Count -eq 1)
            Assert-Contains $execution @('    Assert-TrafficWorkloadPower'); Assert-Contains $traffic @("`$task.State -ne 'Running'", 'if ($appReady -and $nginxReady)')
        }
        $checks['readiness/noninteractive_cannot_prompt_install_or_skip_linux [contract]'] = {
            Assert-Contains $traffic @('$NonInteractive -and ($SkipLinux -or $Disable -or $null -eq $settings)', 'NonInteractive startup requires LinuxUsername', 'NonInteractive startup requires a supplied SecureString password', 'NonInteractive startup requires workload addresses', 'Noninteractive SSH is unavailable; no capability installation', 'sudo -n bash', 'NumberOfPasswordPrompts=1', 'ServerAliveCountMax=2', "SSH_ASKPASS_REQUIRE = 'force'")
            Assert-Contains (Get-Section $traffic 'function Initialize-LabSshAskpass' 'function Invoke-LabLinuxPayload') @("`$ErrorActionPreference = 'Continue'", 'finally { $ErrorActionPreference = $versionPreference }', 'older than 8.4')
        }
        $checks['readiness/managed_provisioning_success_is_not_execution_success [condition fixtures + contract]'] = {
            # Execute only the actual side-effect-free success expression, NOT the launcher.
            $conditions = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true) |
                ForEach-Object { $_.Clauses[0].Item1 } | Where-Object { $_.Extent.Text.Contains('[int]$view.ExitCode -eq 0') })
            Assert-Check ($conditions.Count -eq 1)
            Assert-Check (@($conditions[0].FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -or $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] }, $true)).Count -eq 0)
            $predicate = [scriptblock]::Create('param($view) $state = [string]$view.ExecutionState; $outputText = [string]$view.Output; $errorText = [string]$view.Error; return (' + $conditions[0].Extent.Text + ')')
            $valid = [pscustomobject]@{ ExecutionState = 'Succeeded'; ExitCode = 0; Error = ''; Output = 'LAB_STEP1_TRAFFIC_FULLY_STARTED' }
            Assert-Check (& $predicate $valid); Assert-Check (-not (& $predicate ([pscustomobject]@{ ProvisioningState = 'Succeeded' })))
            foreach ($change in @(@{ ExecutionState = 'Running' }, @{ ExecutionState = 'Failed' }, @{ ExitCode = 1 }, @{ ExitCode = $null }, @{ Error = 'stderr' }, @{ Output = '' },
                @{ Output = 'prefixLAB_STEP1_TRAFFIC_FULLY_STARTED' }, @{ Output = "LAB_STEP1_TRAFFIC_FULLY_STARTED`nLAB_STEP1_TRAFFIC_FULLY_STARTED" },
                @{ Output = "LAB_STEP1_TRAFFIC_FULLY_STARTED`nLAB_STEP1_TRAFFIC_PARTIAL_OR_FAILED" })) {
                $view = Copy-Fixture $valid; foreach ($key in $change.Keys) { $view.$key = $change[$key] }; Assert-Check (-not (& $predicate $view))
            }
            Assert-Contains $step1 @('-Expand InstanceView', "`$state -eq 'Succeeded'", '[int]$view.ExitCode -eq 0', '[string]::IsNullOrWhiteSpace($errorText)', 'LAB_STEP1_TRAFFIC_FULLY_STARTED', 'LAB_STEP1_TRAFFIC_PARTIAL_OR_FAILED')
            Assert-Contains $conditions[0].Extent.Text @('$null -ne $view.ExitCode', ').Count -eq 1', "`$outputText -notmatch 'LAB_STEP1_TRAFFIC_PARTIAL_OR_FAILED'")
        }
        $checks['readiness/unknown_execution_not_false_failure_and_terminal_only_cleanup [contract]'] = {
            $launch = Get-Section $step1 'function Start-LabTrafficOnSelectedHost' 'function Invoke-LabTrafficOffer'
            Assert-Contains $launch @('-TimeoutInSecond 900', 'Wait-Job -Job $job -Timeout 300', 'AddSeconds(960)', 'Traffic outcome UNKNOWN', 'remote execution or partial generators may still be running', 'if ($terminal)', 'Remove-AzVMRunCommand', 'Do not retry blindly')
            Assert-Check (([regex]::Matches($launch, 'Remove-AzVMRunCommand -ResourceGroupName')).Count -eq 1)
            $cleanup = $launch.Substring($launch.LastIndexOf('    } finally {')); Assert-Before $cleanup 'if ($terminal)' 'Remove-AzVMRunCommand -ResourceGroupName'
        }
        $checks['readiness/credentials_cleared_and_error_records_not_printed [contract]'] = {
            $launch = Get-Section $step1 'function Start-LabTrafficOnSelectedHost' 'function Invoke-LabTrafficOffer'
            Assert-Contains $launch @('ZeroFreeBSTR($passwordPointer)', '$passwordPlain = $null', '$parameter.Value = $null', '$secure = $null', '-AsSecureString'); Assert-Check ($launch -notmatch 'Write-(?:Host|Warning|Output).*\$_')
            Assert-Contains $traffic @('Remove-Item Env:LAB_SSH_PASSWORD, Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE', 'no secret-bearing script was written')
        }
        $checks['readiness/encoding_ascii_host_payloads_and_read_only_probes [contract]'] = {
            foreach ($name in @('migrate-step1-setup-project.ps1', 'migrate-step2-discover-assess.ps1', 'enable-lab-traffic.ps1')) {
                $file = Join-Path $Root "scripts/$name"; $bytes = [IO.File]::ReadAllBytes($file); Assert-Check ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
                if ($name.StartsWith('migrate-step')) {
                    $helper = Get-Section ([IO.File]::ReadAllText($file)) 'function Assert-LabWorkloadPower' 'return [pscustomobject]'
                    $probe = Get-Section $helper "`$probe = @'`n" ("`n'@")
                    Assert-Check ($probe -notmatch '[^\x00-\x7F]' -and $probe -notmatch '(?m)^\s*(?:Start|Resume|Stop|Set|New)-VM')
                    Assert-Contains $helper @('-ResourceGroupName $SourceResourceGroup -VMName $HyperVHostVMName')
                }
            }
        }
        $checks['readiness/documented_persistence_and_explicit_stop [contract]'] = {
            Assert-Contains ([IO.File]::ReadAllText((Join-Path $Root 'docs/Lab-Traffic.md'))) @('background sample order creation', 'no automatic lab-completed detector or stop timer', 'enable-lab-traffic.ps1 -Disable', 'Partial/failed startup can leave generators running', 'OpenSSH **8.4+**', '-LabTrafficPassword', 'retaining the deployment')
            Assert-Contains $step1 @('Completing the lab/script alone does not stop traffic')
        }
        $checks['readiness/changed_powershell_lexical_delimiter_balance [real AST parser]'] = {
            foreach ($name in @('migrate-step1-setup-project.ps1', 'migrate-step2-discover-assess.ps1', 'enable-lab-traffic.ps1')) {
                $errors = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Root "scripts/$name"), [ref]$null, [ref]$errors)
                Assert-Check (@($errors).Count -eq 0) "$name failed PowerShell AST parsing."
            }
        }
        $checks['discovery/step2_explicit_hyperv_inventory_and_tomcat_summary [AST + contract]'] = {
            $errors = $null
            $step2Ast = [System.Management.Automation.Language.Parser]::ParseFile($step2Path, [ref]$null, [ref]$errors)
            Assert-Check (@($errors).Count -eq 0) 'Step 2 failed PowerShell AST parsing.'
            $discoveryCalls = @($step2Ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -ieq 'Get-AzMigrateDiscoveredServer'
            }, $true))
            Assert-Check ($discoveryCalls.Count -gt 0) 'Step 2 has no discovered-server command.'
            foreach ($command in $discoveryCalls) {
                $parameters = @($command.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -ieq 'SourceMachineType'
                })
                Assert-Check ($parameters.Count -eq 1) 'Every discovered-server call must explicitly select SourceMachineType.'
                $parameter = $parameters[0]
                $argument = $parameter.Argument
                if ($null -eq $argument) {
                    $index = $command.CommandElements.IndexOf($parameter)
                    Assert-Check ($index + 1 -lt $command.CommandElements.Count) 'SourceMachineType needs a literal value.'
                    $argument = $command.CommandElements[$index + 1]
                }
                Assert-Check ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $argument.Value -ceq 'HyperV') 'Step 2 must query literal HyperV inventory, not VMware.'
            }
            $step2Summary = $step2.Substring($step2.IndexOf('# SUMMARY & NEXT STEPS'))
            Assert-Contains $step2Summary @('OnPrem-Linux-App (192.168.0.13) -- Ubuntu 24.04 + Tomcat 10.1')
            Assert-Absent $step2Summary @('Node.js')
        }
        $checks['discovery/step3_explicit_hyperv_inventory_and_wrapper_routing [AST + contract]'] = {
            $step3Path = Join-Path $Root 'scripts/migrate-step3-replicate.ps1'
            $errors = $null
            $step3Ast = [System.Management.Automation.Language.Parser]::ParseFile($step3Path, [ref]$null, [ref]$errors)
            Assert-Check (@($errors).Count -eq 0) 'Step 3 failed PowerShell AST parsing.'
            $discoveryCalls = @($step3Ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -ieq 'Get-AzMigrateDiscoveredServer'
            }, $true))
            Assert-Check ($discoveryCalls.Count -gt 0) 'Step 3 has no discovered-server command.'
            foreach ($command in $discoveryCalls) {
                $parameters = @($command.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -ieq 'SourceMachineType'
                })
                Assert-Check ($parameters.Count -eq 1) 'Every Step 3 discovered-server call must explicitly select SourceMachineType.'
                $parameter = $parameters[0]
                $argument = $parameter.Argument
                if ($null -eq $argument) {
                    $index = $command.CommandElements.IndexOf($parameter)
                    Assert-Check ($index + 1 -lt $command.CommandElements.Count) 'Step 3 SourceMachineType needs a literal value.'
                    $argument = $command.CommandElements[$index + 1]
                }
                Assert-Check ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                    $argument.Value -ceq 'HyperV') 'Step 3 must query literal HyperV inventory, not VMware.'
            }
            foreach ($route in @(
                @{ Script = 'migrate-step3a-agentless.ps1'; Workload = 'Agentless' },
                @{ Script = 'migrate-step3b-agent-based.ps1'; Workload = 'AgentBased' }
            )) {
                $wrapper = [IO.File]::ReadAllText((Join-Path $Root ('scripts/' + $route.Script)))
                Assert-Contains $wrapper @('Invoke-LabStage -ScriptName "migrate-step3-replicate.ps1"',
                    '-Arguments $common', 'Workload            = $workload', ('$workload = "' + $route.Workload + '"'))
            }
        }
        function New-KvpItem {
            param([string]$Name, [string]$Data)
            $escaped = [Security.SecurityElement]::Escape($Data)
            return '<INSTANCE CLASSNAME="Msvm_KvpExchangeDataItem"><PROPERTY NAME="Name"><VALUE>' + $Name + '</VALUE></PROPERTY><PROPERTY NAME="Data"><VALUE>' + $escaped + '</VALUE></PROPERTY></INSTANCE>'
        }
        function New-KvpComponent {
            param([string]$OSName = 'Microsoft Windows Server', [AllowNull()]$Status = 2)
            return [pscustomobject]@{ EnabledState = 2; OperationalStatus = @($Status); CommunicationStatus = $null;
                GuestIntrinsicExchangeItems = @((New-KvpItem 'OSName' $OSName), (New-KvpItem 'OSVersion' '22.04 fixture')) }
        }
        function New-KvpRows {
            $rows = @(for ($i = 0; $i -lt 4; $i++) {
                $os = if ($i -ge 2) { 'Ubuntu Linux' } else { 'Microsoft Windows Server' }
                Get-LabKvpReadinessRow -Name $required[$i] -VMId ('00000000-0000-0000-0000-{0:000000000000}' -f ($i + 1)) -Component (New-KvpComponent $os)
            })
            return $rows
        }
        function New-KvpPayload {
            param($Rows = (New-KvpRows))
            return 'LAB_KVP_JSON|' + ([ordered]@{ Schema = 1; Rows = @($Rows) } | ConvertTo-Json -Depth 6 -Compress) + "`nLAB_KVP_END"
        }
        function Test-KvpFixture {
            param($Result)
            $fixtureState.Result = $Result
            return Assert-LabGuestCommunication
        }
        function Get-VM {
            [CmdletBinding()]param($Name)
            if ($Name -ceq $fixtureState.MissingKvpVM) { return }
            $index = [array]::IndexOf($required, [string]$Name) + 1
            return [pscustomobject]@{ Id = [guid]('00000000-0000-0000-0000-{0:000000000000}' -f $index); Name = $Name; State = 'Running' }
        }
        function Get-CimInstance {
            [CmdletBinding()]param($Namespace, $ClassName, $Filter, $OperationTimeoutSec)
            if ($fixtureState.KvpCimFailure) { throw 'Fictional denied CIM access' }
            if ($Namespace -cne 'root/virtualization/v2' -or $ClassName -cne 'Msvm_ComputerSystem' -or $Filter -notlike "Name='*'") { throw 'Unexpected CIM query' }
            $os = if ($Filter -match '00000000000[34]') { 'Ubuntu Linux' } else { 'Microsoft Windows Server' }
            return [pscustomobject]@{ Name = 'fictional-VM-id'; OSName = $os }
        }
        function Get-CimAssociatedInstance {
            [CmdletBinding()]param($InputObject, $ResultClassName, $OperationTimeoutSec)
            if ($ResultClassName -cne 'Msvm_KvpExchangeComponent') { throw 'Unexpected CIM association' }
            return New-KvpComponent $InputObject.OSName
        }
        $fixtureState.MissingKvpVM = ''; $fixtureState.KvpCimFailure = $false
        $hostPath = Join-Path $Root 'scripts/host/configure-host.ps1'
        $hostSource = [IO.File]::ReadAllText($hostPath)
        $checks['communication/identical_inline_transport_helpers [AST + contract]'] = {
            $hostAst = [System.Management.Automation.Language.Parser]::ParseFile($hostPath, [ref]$null, [ref]$null)
            $stepAst = [System.Management.Automation.Language.Parser]::ParseFile($step2Path, [ref]$null, [ref]$null)
            foreach ($name in @('Get-LabKvpReadinessRow', 'Get-LabGuestCommunicationRows')) {
                $one = @($hostAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -ceq $name })
                $two = @($stepAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Where-Object { $_.Name -ceq $name })
                Assert-Check ($one.Count -eq 1 -and $two.Count -eq 1 -and $one[0].Extent.Text -ceq $two[0].Extent.Text)
            }
            Assert-Contains $hostSource @('Get-CimAssociatedInstance', 'Msvm_KvpExchangeComponent', 'GuestIntrinsicExchangeItems')
            Assert-Absent (Get-Section $hostSource 'function Get-LabKvpReadinessRow' 'function Assert-LabGuestCommunication') @('HealthState', 'PrimaryStatusDescription', 'HostExchangeItems', 'GuestExchangeItems', 'Get-VMIntegrationService')
        }
        $checks['communication/all_four_healthy_nullable_communication [mocked helper]'] = {
            $rows = @(New-KvpRows); Assert-Check ($rows.Count -eq 4 -and @($rows | Where-Object { -not $_.Ready }).Count -eq 0)
            $liveRows = @(Get-LabGuestCommunicationRows)
            Assert-Check ($liveRows.Count -eq 4 -and @($liveRows | Where-Object { -not $_.Ready }).Count -eq 0)
            $reads = $fixtureState.Reads
            $ready = Test-KvpFixture ([pscustomobject]@{ Value = @((New-StatusRecord (New-KvpPayload $rows))) })
            Assert-Check ($ready.Rows.Count -eq 4 -and $fixtureState.Reads -eq ($reads + 1))
            foreach ($status in @($null, 0, 1, 2)) {
                $component = New-KvpComponent; $component.CommunicationStatus = $status
                Assert-Check (Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' $component).Ready
            }
        }
        $checks['communication/lost_no_contact_protocol_degraded_unknown_block [mocked helper]'] = {
            foreach ($status in @($null, 0, 3, 7, 12, 13, 99, '2')) {
                $row = Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' (New-KvpComponent -Status $status)
                Assert-Check (-not $row.Ready) 'Enabled service with old OS metadata must not hide bad/unknown transport'
            }
            $component = New-KvpComponent; $component.PSObject.Properties.Remove('OperationalStatus')
            Assert-Check (-not (Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' $component).Ready)
        }
        $checks['communication/known_bad_communication_status_blocks [mocked helper]'] = {
            foreach ($status in @(3, 4, 5, '2')) {
                $component = New-KvpComponent; $component.CommunicationStatus = $status
                Assert-Check (-not (Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' $component).Ready)
            }
        }
        $checks['communication/disabled_missing_enabled_state_and_component_block [mocked helper]'] = {
            foreach ($enabled in @($null, 0, 3, '2')) {
                $component = New-KvpComponent; $component.EnabledState = $enabled
                Assert-Check (-not (Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' $component).Ready)
            }
            Assert-Check (-not (Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' $null).Ready)
        }
        $checks['communication/os_name_version_family_required [mocked helper]'] = {
            foreach ($key in @('OSName', 'OSVersion')) {
                $component = New-KvpComponent
                $component.GuestIntrinsicExchangeItems = @($component.GuestIntrinsicExchangeItems | Where-Object { $_ -notlike "*<VALUE>$key</VALUE>*" })
                Assert-Check (-not (Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' $component).Ready)
                $component.GuestIntrinsicExchangeItems += New-KvpItem $key ' '
                Assert-Check (-not (Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' $component).Ready)
            }
            Assert-Check (-not (Get-LabKvpReadinessRow 'OnPrem-Linux-App' 'fixture' (New-KvpComponent)).Ready)
            Assert-Check (-not (Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' (New-KvpComponent 'Ubuntu Linux')).Ready)
            Assert-Check (Get-LabKvpReadinessRow 'OnPrem-Linux-App' 'fixture' (New-KvpComponent 'Ubuntu Linux')).Ready
        }
        $checks['communication/malformed_duplicate_and_dtd_xml_block [mocked helper]'] = {
            foreach ($item in @('<INSTANCE>', '<!DOCTYPE INSTANCE [<!ENTITY fixture "fictional">]><INSTANCE/>', (New-KvpItem 'OSName' 'duplicate'))) {
                $component = New-KvpComponent; $component.GuestIntrinsicExchangeItems += $item
                Assert-Check (-not (Get-LabKvpReadinessRow 'OnPrem-Web' 'fixture' $component).Ready)
            }
            Assert-Contains $hostSource @('DtdProcessing]::Prohibit', '$settings.XmlResolver = $null', '$xml.XmlResolver = $null', "@('OSName', 'OSVersion')")
        }
        $checks['communication/missing_vm_and_cim_failure_block [mocked collector]'] = {
            try {
                $fixtureState.MissingKvpVM = 'OnPrem-Linux-App'
                $rows = @(Get-LabGuestCommunicationRows)
                Assert-Check ($rows.Count -eq 4 -and $rows[2].Ready -and -not $rows[3].Ready -and $rows[3].Reason -eq 'Missing or ambiguous VM')
                $fixtureState.MissingKvpVM = ''; $fixtureState.KvpCimFailure = $true
                $rows = @(Get-LabGuestCommunicationRows)
                Assert-Check ($rows.Count -eq 4 -and @($rows | Where-Object { $_.Ready }).Count -eq 0)
            } finally { $fixtureState.MissingKvpVM = ''; $fixtureState.KvpCimFailure = $false }
        }
        $checks['communication/one_bad_guest_blocks_step2 [mocked helper]'] = {
            for ($i = 0; $i -lt 4; $i++) {
                $rows = @(New-KvpRows); $rows[$i].Ready = $false; $rows[$i].OperationalStatus = 13; $rows[$i].Reason = 'KVP LostCommunication'
                Assert-Throws { Test-KvpFixture ([pscustomobject]@{ Value = @((New-StatusRecord (New-KvpPayload $rows))) }) }
            }
        }
        $checks['communication/payload_missing_duplicate_truncated_schema_rows_block [mocked parser]'] = {
            $good = New-KvpPayload
            foreach ($text in @('', '{}', $good.Replace('LAB_KVP_END', ''), ($good + "`n" + $good), 'LAB_KVP_JSON|{"Schema":1,"Rows":[' + "`nLAB_KVP_END", $good.Replace('"Schema":1', '"Schema":2'))) {
                Assert-Throws { ConvertFrom-LabGuestCommunicationPayload $text }
            }
            foreach ($mode in @('missing', 'duplicate', 'type', 'contradiction', 'metadata', 'identity')) {
                $rows = @(New-KvpRows)
                switch ($mode) {
                    'missing' { $rows = $rows[0..2] }
                    'duplicate' { $rows[3].Name = $rows[2].Name }
                    'type' { $rows[3].Ready = 'true' }
                    'contradiction' { $rows[3].OperationalStatus = 13 }
                    'metadata' { $rows[3].OSVersion = '' }
                    'identity' { $rows[3].VMId = $rows[2].VMId }
                }
                Assert-Throws { ConvertFrom-LabGuestCommunicationPayload (New-KvpPayload $rows) }
            }
        }
        $checks['communication/runcommand_errors_fail_closed [mocked helper]'] = {
            foreach ($result in @($null, [pscustomobject]@{ Value = @() },
                [pscustomobject]@{ Value = @((New-StatusRecord (New-KvpPayload)), (New-StatusRecord 'denied' 'ComponentStatus/StdErr/succeeded')) },
                [pscustomobject]@{ Value = @((New-StatusRecord (New-KvpPayload) 'ComponentStatus/StdOut/failed')) })) {
                Assert-Throws { Test-KvpFixture $result }
            }
        }
        $checks['communication/gates_before_prerequisites_completion_and_discovery [contract]'] = {
            foreach ($later in @('Installing Az.Migrate module', 'All prerequisites verified.', 'STEP 2: Generate the Project Key', 'STEP 3:', 'Get-AzMigrateDiscoveredServer', 'STEP 6: Create Migration Assessment')) {
                Assert-Before $step2 '$guestCommunication = Assert-LabGuestCommunication' $later
            }
            $poll = Get-Section $hostSource '$deadline = (Get-Date).AddMinutes(20)' '# Delete Windows setup password'
            Assert-Contains $poll @('while ((Get-Date) -lt $deadline)', '$guestCommunication = @(Assert-LabGuestCommunication)', 'Assert-LabSourceWorkloads', '$communicationPasses -ge 3', '$communicationPasses = 0', 'Start-Sleep -Seconds 20', 'if (-not $healthy) { throw')
            Assert-Before $hostSource 'if (-not $healthy) { throw' 'LAB_WORKLOADS_READY'
            $end = $hostSource.Substring($hostSource.IndexOf('# PHASE 7'))
            Assert-Before $end "`$hostPrep['GuestCommunication'] = @(Assert-LabGuestCommunication)" 'setup-complete.json'
            Assert-Absent (Get-Section $step2 "`$hostPrepScript = @'" 'Write-Log "Checking host preparation') @('IntegrationServices', 'Get-VMIntegrationService')
        }
        $checks['communication/exact_kernel_binary_install_and_reboot_not_virtual_fallback [contract]'] = {
            $integration = Get-Section $hostSource "`$hyperVIntegration = @'" ("'@")
            Assert-Contains $integration @('kernel="$(uname -r)"', '"linux-tools-$kernel" "linux-cloud-tools-$kernel" || kvp_install_failed', 'test -x "/usr/lib/linux-tools/$kernel/hv_kvp_daemon" || kvp_install_failed', 'LAB_KVP_INSTALL_FAILED', 'systemctl mask hv-kvp-daemon.service', 'systemctl stop hv-kvp-daemon.service || kvp_install_failed')
            Assert-Absent $integration @('linux-tools-virtual', 'linux-cloud-tools-virtual', 'command -v hv_kvp_daemon', 'systemctl start hv-kvp-daemon.service', 'apt-get install -y "linux-cloud-tools-$(uname -r)"')
            Assert-Contains $hostSource @('power_state:', 'mode: reboot', 'condition: true')
        }
        $checks['communication/host_payload_ascii_ps51_composition [AST + encoding]'] = {
            $bytes = [IO.File]::ReadAllBytes($hostPath)
            Assert-Check (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'Host payload must remain ASCII'
            $bytes = [IO.File]::ReadAllBytes($step2Path)
            Assert-Check ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Step 2 keeps its UTF-8 BOM'
            $composed = $hostSource.Replace('# LAB_HEALTH_HELPERS', [IO.File]::ReadAllText((Join-Path $Root 'scripts/health.ps1')))
            $errors = $null; $null = [System.Management.Automation.Language.Parser]::ParseInput($composed, [ref]$null, [ref]$errors)
            Assert-Check (@($errors).Count -eq 0) 'Composed host payload failed PowerShell parsing'
        }
        $checks['ubuntu/noble_exact_image_checksum_cache_and_fresh_host [contract]'] = {
            Assert-Contains $hostSource @('https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img',
                'https://cloud-images.ubuntu.com/noble/current/SHA256SUMS', 'Ubuntu2404-cloudimg.img', 'Ubuntu2404-Base.vhdx',
                '^[0-9a-fA-F]{64}\s+\*?noble-server-cloudimg-amd64\.img$', 'LAB_BUILD|ubuntu2404-tomcat101-v1',
                '$labResuming -and -not $matchingBuild', 'Existing or unmarked lab guests must not be upgraded')
            Assert-Absent $hostSource @('jammy/current', 'Ubuntu2204', 'tomcat9', 'package_upgrade: true')
            Assert-Before $hostSource 'Get-FileHash $ubuntuQcow2 -Algorithm SHA256' '-Stage ''Convert Ubuntu image'''
            Assert-Before $hostSource '$labBuildMarker =' 'Remove-VM -Name $VMName'
        }
        $checks['ubuntu/tomcat101_java17_installer_service_paths [contract]'] = {
            $appRoot = Join-Path $Root 'apps/contoso-orderdesk'
            foreach ($name in @('install-fresh.sh', 'install.sh')) {
                $installer = [IO.File]::ReadAllText((Join-Path $appRoot ('scripts/' + $name)))
                Assert-Contains $installer @('VERSION_ID == 24.04', 'require_tomcat101', '/usr/share/tomcat10/bin/catalina.sh',
                    '/etc/tomcat10/web.xml', 'java-17-openjdk-', 'tomcat10 tomcat10-common libtomcat10-java openjdk-17-jre-headless',
                    'org/apache/tomcat/jdbc/pool/DataSourceFactory.class', 'chmod 0640')
                Assert-Absent $installer @('tomcat9', 'VERSION_ID == 22.04', 'default-jre', 'openjdk-21')
            }
            $common = [IO.File]::ReadAllText((Join-Path $appRoot 'scripts/common.sh'))
            Assert-Contains $common @('require_tomcat101()', 'dpkg-query', '10.1.*')
            $service = [IO.File]::ReadAllText((Join-Path $appRoot 'scripts/contoso-orderdesk.service.in'))
            Assert-Contains $service @('User=contoso-orderdesk', 'CATALINA_HOME=/usr/share/tomcat10', '/usr/share/tomcat10/bin/catalina.sh run', 'JAVA_HOME=__JAVA_HOME__', '-Xmx384m', 'MemoryMax=900M')
        }
        $checks['ubuntu/jakarta_servlet6_javase_jndi_and_war_source [XML + contract]'] = {
            $appRoot = Join-Path $Root 'apps/contoso-orderdesk'
            $webPath = Join-Path $appRoot 'src/main/webapp/WEB-INF/web.xml'
            $descriptor = [xml][IO.File]::ReadAllText($webPath)
            Assert-Check ($descriptor.DocumentElement.NamespaceURI -ceq 'https://jakarta.ee/xml/ns/jakartaee')
            Assert-Check ($descriptor.DocumentElement.GetAttribute('version') -ceq '6.0')
            Assert-Contains ([IO.File]::ReadAllText($webPath)) @('web-app_6_0.xsd', 'javax.sql.DataSource', 'jdbc/ContosoApp')
            $commonPath = Join-Path $appRoot 'src/main/webapp/WEB-INF/jspf/common.jspf'
            $jsp = [IO.File]::ReadAllText($commonPath)
            Assert-Contains $jsp @('jakarta.servlet.http.HttpServletRequest', 'javax.sql.DataSource', 'javax.naming.InitialContext')
            Assert-Absent $jsp @('javax.servlet', 'jakarta.sql', 'jakarta.naming')
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $war = [IO.Compression.ZipFile]::OpenRead((Join-Path $appRoot 'dist/contoso-orderdesk.war'))
            try {
                foreach ($entryName in @('WEB-INF/web.xml', 'WEB-INF/jspf/common.jspf')) {
                    $entry = $war.GetEntry($entryName); Assert-Check ($null -ne $entry)
                    $reader = [IO.StreamReader]::new($entry.Open())
                    try { $entryText = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    Assert-Check ($entryText -ceq [IO.File]::ReadAllText((Join-Path $appRoot ('src/main/webapp/' + $entryName))))
                }
            } finally { $war.Dispose() }
        }
        function New-AssessmentFixture {
            $assessmentFixture.Context = [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000001' };
                Tenant = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000002' };
                Account = [pscustomobject]@{ Id = 'fictional@example.invalid'; Type = 'User' };
                Environment = [pscustomobject]@{ Name = 'AzureCloud'; ResourceManagerUrl = 'https://management.azure.com/'; ActiveDirectoryAuthority = 'https://login.microsoftonline.com/' } }
            $assessmentFixture.Current = Copy-Fixture $assessmentFixture.Context
            $assessmentFixture.Stamp = Get-LabAssessmentContextStamp $assessmentFixture.Context
            $assessmentFixture.Group = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/fictional-source/providers/Microsoft.Migrate/assessmentProjects/fictional-project/groups/AllServers-Group?api-version=2024-01-15'
            $assessmentFixture.Assessment = $assessmentFixture.Group.Replace('?api-version=', '/assessments/Workshop-Assessment?api-version=')
            $assessmentFixture.Logs = @(); $assessmentFixture.Calls = @(); $assessmentFixture.Sleeps = @(); $assessmentFixture.Responses = @(); $assessmentFixture.Throw = ''; $assessmentFixture.Available = $true
        }
        function New-AssessmentResponse {
            param([int]$Status = 200, [string]$Content = '{"properties":{"provisioningState":"Succeeded"}}')
            return [pscustomobject]@{ StatusCode = $Status; Content = $Content }
        }
        function Test-AssessmentRequest {
            param([string]$Method = 'PUT', [string]$Path = $assessmentFixture.Group)
            return Invoke-LabAssessmentRequest -Path $Path -Method $Method -Payload '{}' -Context $assessmentFixture.Context -PinnedContext $assessmentFixture.Stamp -ResourceGroup fictional-source
        }
        $assessmentStages = $step2.Substring($step2.IndexOf("`$assessmentName = `$AssessmentName"))
        $assessmentSummary = $step2.Substring($step2.IndexOf('# SUMMARY & NEXT STEPS'))
        $checks['assessment/arm_context_success_200_201_no_manual_token [mocked helper + contract]'] = {
            foreach ($status in @(200, 201)) {
                New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse $status))
                $result = Test-AssessmentRequest
                Assert-Check ($result.Success -and -not $result.Pending -and $result.StatusCode -eq $status)
                Assert-Check ($assessmentFixture.Calls.Count -eq 1 -and $assessmentFixture.Calls[0].Method -ceq 'PUT' -and $assessmentFixture.Calls[0].Payload -ceq '{}')
            }
            Assert-Absent $step2 @('Get-AzAccessToken', 'Bearer $token', '"Authorization"', 'https://management.azure.com/subscriptions/', 'WaitForCompletion', '-Paginate')
            Assert-Contains $step2 @('DefaultProfile = $Context', 'Invoke-AzRestMethod @parameters', '$assessmentContextStamp = Get-LabAssessmentContextStamp $context')
            Assert-Before $step2 '$assessmentContextStamp = Get-LabAssessmentContextStamp $context' 'Write-StepHeader -Step 1'
        }
        $checks['assessment/202_and_provisioning_pending_not_created [mocked helper]'] = {
            New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 202 ''))
            $result = Test-AssessmentRequest
            Assert-Check ($result.Success -and $result.Pending)
            New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 200 '{"properties":{"provisioningState":"Updating"}}'))
            $result = Test-AssessmentRequest
            Assert-Check ($result.Success -and $result.Pending)
        }
        $checks['assessment/null_bad_status_json_shape_and_empty_get_fail [mocked helper]'] = {
            foreach ($response in @($null, [pscustomobject]@{ Content = '{}' }, [pscustomobject]@{ StatusCode = 'bad'; Content = '{}' },
                (New-AssessmentResponse 0), (New-AssessmentResponse 600), (New-AssessmentResponse 200 'not JSON'),
                (New-AssessmentResponse 200 'null'), (New-AssessmentResponse 200 '[]'), (New-AssessmentResponse 200 '"text"'), (New-AssessmentResponse 200 'true'))) {
                New-AssessmentFixture; $assessmentFixture.Responses = @($response)
                $result = Test-AssessmentRequest
                Assert-Check (-not $result.Success -and $result.FailureKind -eq 'Response')
            }
            New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 200 ''))
            Assert-Check (-not (Test-AssessmentRequest GET).Success)
        }
        $checks['assessment/nonthrowing_401_and_200_error_json_are_auth_failures [mocked helper]'] = {
            foreach ($status in @(401, 200)) {
                New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse $status '{"error":{"code":"InvalidAuthenticationToken","message":"The access token is invalid."}}'))
                $result = Test-AssessmentRequest
                Assert-Check (-not $result.Success -and $result.FailureKind -eq 'Authentication' -and $result.ErrorCode -eq 'InvalidAuthenticationToken')
                Assert-Contains $result.Message @('Connect-AzAccount', 'original lab', 'Set-AzContext', 'rerun Step 2', 'No automatic')
            }
        }
        $checks['assessment/thrown_authentication_and_unknown_are_not_computing [mocked helper]'] = {
            New-AssessmentFixture; $assessmentFixture.Throw = 'InvalidAuthenticationToken: fictional rejected request'
            $result = Test-AssessmentRequest
            Assert-Check (-not $result.Success -and $result.FailureKind -eq 'Authentication' -and $assessmentFixture.Calls.Count -eq 1)
            New-AssessmentFixture; $assessmentFixture.Throw = 'fictional timeout; outcome unverified'
            $result = Test-AssessmentRequest
            Assert-Check (-not $result.Success -and $result.FailureKind -eq 'Unknown')
            Assert-Absent $result.Message @('fictional timeout')
        }
        $checks['assessment/rbac_schema_notfound_conflict_and_transient_are_distinct [mocked helper]'] = {
            foreach ($case in @(@(403, 'Authorization'), @(400, 'Service'), @(404, 'Service'), @(409, 'Conflict'), @(408, 'Transient'), @(429, 'Transient'), @(500, 'Transient'))) {
                New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse $case[0] '{"error":{"code":"FictionalServiceError","message":"Review the machine IDs and project schema."}}'))
                $result = Test-AssessmentRequest
                Assert-Check (-not $result.Success -and $result.FailureKind -ceq $case[1])
                Assert-Absent $result.Message @('Connect-AzAccount')
                if ($case[0] -eq 400) { Assert-Contains $result.Message @('machine IDs', 'project schema') }
            }
            New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 404 '{"error":{"code":"ResourceNotFound"}}'))
            Assert-Check ((Test-AssessmentRequest GET).FailureKind -eq 'NotFound')
        }
        $checks['assessment/identity_subscription_tenant_cloud_drift_prevents_requests [mocked helper]'] = {
            foreach ($case in @(@('Subscription', 'Id'), @('Tenant', 'Id'), @('Account', 'Id'), @('Account', 'Type'), @('Environment', 'Name'), @('Environment', 'ResourceManagerUrl'), @('Environment', 'ActiveDirectoryAuthority'))) {
                New-AssessmentFixture; $assessmentFixture.Current.($case[0]).($case[1]) = 'fictional-drift'
                $result = Test-AssessmentRequest
                Assert-Check (-not $result.Success -and $result.FailureKind -eq 'Context' -and $assessmentFixture.Calls.Count -eq 0)
            }
            New-AssessmentFixture; $assessmentFixture.Context.Subscription.Id = 'fictional-mutated-original'
            Assert-Check (-not (Test-AssessmentRequest).Success -and $assessmentFixture.Calls.Count -eq 0)
        }
        $checks['assessment/missing_context_or_cmdlet_fails_before_request [mocked helper]'] = {
            New-AssessmentFixture; $assessmentFixture.Current = $null
            Assert-Check (-not (Test-AssessmentRequest).Success -and $assessmentFixture.Calls.Count -eq 0)
            Assert-Throws { Get-LabAssessmentContextStamp $null }
            New-AssessmentFixture; $assessmentFixture.Available = $false
            $result = Test-AssessmentRequest
            Assert-Check (-not $result.Success -and $result.FailureKind -eq 'Prerequisite' -and $assessmentFixture.Calls.Count -eq 0)
            Assert-Contains $result.Message @('Update-Module Az.Accounts', 'new PowerShell session')
        }
        $checks['assessment/external_wrong_subscription_or_encoded_paths_denied [mocked helper]'] = {
            New-AssessmentFixture
            foreach ($path in @('https://example.invalid/steal', '//example.invalid/steal', $assessmentFixture.Group.Replace('000000000001', '000000000009'),
                $assessmentFixture.Group.Replace('fictional-source', '..'), $assessmentFixture.Group.Replace('fictional-project', '%2f%2fevil'),
                ($assessmentFixture.Group + '#fragment'), $assessmentFixture.Group.Replace('2024-01-15', 'other-version'))) {
                $result = Test-AssessmentRequest PUT $path
                Assert-Check (-not $result.Success -and $result.FailureKind -eq 'Path' -and $assessmentFixture.Calls.Count -eq 0)
            }
            Assert-Absent $assessmentStages @('-Uri ', '-Headers ', 'nextLink -', 'Invoke-RestMethod')
        }
        $checks['assessment/service_secret_and_raw_exception_never_displayed [mocked helper + contract]'] = {
            $secret = 'fictional-secret-not-real'
            foreach ($message in @(('Bearer ' + $secret), ('password=' + $secret), ('credential: ' + $secret), ('eyJ' + ('a' * 100)))) {
                New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 400 ('{"error":{"code":"BadRequest","message":' + ($message | ConvertTo-Json -Compress) + '}}')))
                $result = Test-AssessmentRequest
                Assert-Absent $result.Message @($secret, 'eyJ', 'Bearer')
            }
            New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 400 '{"error":{"code":"SecretCredentialValue","message":"Review schema."}}'))
            $result = Test-AssessmentRequest
            Assert-Check ($result.ErrorCode -eq '')
            New-AssessmentFixture; $assessmentFixture.Throw = 'Authorization header: Bearer ' + $secret
            $result = Test-AssessmentRequest
            Assert-Absent $result.Message @($secret, 'Bearer', 'Authorization header')
            Assert-Absent $assessmentStages @('Exception.Message', 'Error details: $_', 'Error: $_', 'API: $_')
        }
        $checks['assessment/group_failure_prevents_assessment_put_and_no_write_retry [mocked workflow]'] = {
            foreach ($status in @(401,500)) {
                New-BackendFixture; Set-BackendResponses; $assessmentFixture.Responses[5] = New-AssessmentResponse $status '{}'
                $result = Invoke-BackendCreation
                Assert-Check ($result.State -eq 'Failed' -and $result.Stage -eq 'Server group PUT' -and $assessmentFixture.Calls.Count -eq 6)
            }
        }
        $checks['assessment/pending_group_gates_put_and_pending_assessment_only_submitted [mocked workflow]'] = {
            New-BackendFixture; Set-BackendResponses
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Submitted' -and $assessmentFixture.Calls.Count -eq 13)
            Assert-Check ($assessmentFixture.Calls[12].Method -eq 'PUT' -and $assessmentFixture.Responses[12].StatusCode -eq 202)
        }
        $checks['assessment/assessment_failure_is_not_created [mocked workflow]'] = {
            New-BackendFixture; Set-BackendResponses; $assessmentFixture.Responses[12] = New-AssessmentResponse 400 '{"error":{"code":"InvalidRequest","message":"Review project schema."}}'
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Failed' -and $result.Stage -eq 'Assessment PUT' -and $assessmentFixture.Calls.Count -eq 13)
        }
        $checks['assessment/get_parses_content_value_without_payload [mocked helper]'] = {
            New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 200 '{"value":[{"properties":{"displayName":"OnPrem-Web","suitability":"Suitable"}}]}'))
            $result = Test-AssessmentRequest GET ($assessmentFixture.Assessment.Replace('?api-version=', '/assessedMachines?api-version='))
            Assert-Check ($result.Success -and $result.Data.value.Count -eq 1 -and $result.Data.value[0].properties.displayName -ceq 'OnPrem-Web')
            Assert-Check ($null -eq $assessmentFixture.Calls[0].Payload)
        }
        $checks['assessment/failed_provisioning_is_not_pending_or_created [mocked helper]'] = {
            foreach ($state in @('Failed', 'Canceled', 'Cancelled')) {
                New-AssessmentFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 200 ('{"properties":{"provisioningState":"' + $state + '"}}')))
                $result = Test-AssessmentRequest
                Assert-Check (-not $result.Success -and -not $result.Pending)
            }
        }
        $checks['assessment/poll_only_accepted_requests_and_auth_reads_stop [source contract]'] = {
            Assert-Contains $assessmentStages @("if (`$assessmentState -eq 'Submitted')", 'Get-LabAssessmentCompletion', 'Step 7 not started:')
            Assert-Contains $step2 @("`$resource.FailureKind -eq 'NotFound' -and -not `$outcome.Confirmed", "`$status -eq 'Completed'", "`$outcome.State = 'ReadFailed'", "`$response.FailureKind -eq 'Transient'", 'no write resubmission')
            Assert-Absent $assessmentStages @('Read-Host', 'created successfully')
            New-BackendFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 401 '{"error":{"code":"InvalidAuthenticationToken"}}'))
            $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 1)
        }
        $checks['assessment/final_completion_and_step3_require_confirmed_creation [condition fixtures + contract]'] = {
            $condition = "(`$assessmentConfirmed -and `$assessmentReady -and `$assessmentState -eq 'ResultsReady')"
            Assert-Contains $assessmentSummary @($condition, 'STEP 2 PENDING', 'all four results and current membership verified', 'rerun Step 2', 'before Step 3')
            foreach ($state in @('NotAttempted','Failed','GroupPending','MembershipPending','Submitted','ReadFailed','Created','ResultsReady')) {
                foreach ($confirmed in @($false,$true)) { foreach ($ready in @($false,$true)) {
                    $assessmentState = $state; $assessmentConfirmed = $confirmed; $assessmentReady = $ready
                    Assert-Check ((& ([scriptblock]::Create($condition))) -eq ($confirmed -and $ready -and $state -eq 'ResultsReady'))
                } }
            }
        }
        $checks['assessment/four_ids_and_running_lab_recovery_preserve_scope [source contract]'] = {
            Assert-Contains $assessmentStages @('if ($discoveryComplete -and $workloadServers.Count -eq 4)', 'Existing discovery and VMs are retained', 'Inspect existing', 'not $ApplianceVMName', 'not repaired by reconnecting or rebuilding VMs')
            Assert-Contains $step2 @('api-version=2024-01-15', "sizingCriterion = 'AsOnPremises'", 'azureLocation = $Location', 'Get-LabAssessmentMachineMap', 'discoveryMachineArmId')
            Assert-Absent $assessmentStages @('deploy-lab.ps1', 'New-AzVM', 'New-AzMigrateProject', 'Remove-Az', 'Install-Module', 'Connect-AzAccount -', 'Set-AzContext -')
        }
        function New-BackendFixture {
            New-AssessmentFixture
            $assessmentFixture.Base = '/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/fictional-source/providers/Microsoft.Migrate'
            $assessmentFixture.ProjectId = $assessmentFixture.Base + '/assessmentProjects/fictional-generated-backend'
            $assessmentFixture.Group = $assessmentFixture.ProjectId + '/groups/AllServers-Group?api-version=2024-01-15'
            $assessmentFixture.Assessment = $assessmentFixture.Group.Replace('?api-version=', '/assessments/Workshop-Assessment?api-version=')
            $assessmentFixture.Session = @{ Context = $assessmentFixture.Context; PinnedContext = $assessmentFixture.Stamp; ResourceGroup = 'fictional-source' }
            $assessmentFixture.Settings = Get-LabAssessmentSettings westus2 USD MS-AZR-0003P No
            $assessmentFixture.Workloads = @(for ($i = 0; $i -lt 4; $i++) {
                [pscustomobject]@{ Id = $assessmentFixture.Base.Replace('Microsoft.Migrate', 'Microsoft.OffAzure') + '/HyperVSites/fictional-site/machines/source-' + $i; DisplayName = $required[$i] }
            })
            $assessmentFixture.Inventory = @(for ($i = 0; $i -lt 4; $i++) {
                [pscustomobject]@{ id = $assessmentFixture.ProjectId + '/machines/assessment-' + $i; type = 'Microsoft.Migrate/assessmentProjects/machines';
                    properties = [pscustomobject]@{ discoveryMachineArmId = $assessmentFixture.Workloads[$i].Id; displayName = $required[$i]; groups = @() } }
            })
            $assessmentFixture.Members = Copy-Fixture $assessmentFixture.Inventory
            foreach ($row in $assessmentFixture.Members) { $row.properties.groups = @($assessmentFixture.Group.Split('?')[0]) }
            $assessmentFixture.Provider = [pscustomobject]@{ namespace = 'Microsoft.Migrate'; registrationState = 'Registered'; resourceTypes = @(
                foreach ($type in @('assessmentProjects','assessmentProjects/machines','assessmentProjects/groups','assessmentProjects/groups/assessments','assessmentProjects/groups/assessments/assessedMachines','migrateProjects/solutions')) {
                    [pscustomobject]@{ resourceType = $type; apiVersions = @(if ($type -eq 'migrateProjects/solutions') { '2018-09-01-preview' } elseif ($type -eq 'assessmentProjects') { '2023-03-15' } else { '2024-01-15' }) }
                }) }
            $assessmentFixture.Solution = [pscustomobject]@{ id = $assessmentFixture.Base + '/migrateProjects/fictional-project/solutions/Servers-Assessment-ServerAssessment'; properties = [pscustomobject]@{ details = [pscustomobject]@{ extendedDetails = [pscustomobject]@{ projectId = $assessmentFixture.ProjectId } } } }
            $assessmentFixture.Project = [pscustomobject]@{ id = $assessmentFixture.ProjectId; type = 'Microsoft.Migrate/assessmentProjects'; properties = [pscustomobject]@{ projectStatus = 'Active'; provisioningState = 'Succeeded' } }
            $assessmentFixture.GroupEmpty = [pscustomobject]@{ id = $assessmentFixture.Group.Split('?')[0]; type = 'Microsoft.Migrate/assessmentProjects/groups'; properties = [pscustomobject]@{ groupStatus = 'Completed'; groupType = 'Default'; supportedAssessmentTypes = @('MachineAssessment'); provisioningState = 'Succeeded'; areAssessmentsRunning = $false; assessments = @(); machineCount = 0 } }
            $assessmentFixture.GroupFull = Copy-Fixture $assessmentFixture.GroupEmpty; $assessmentFixture.GroupFull.properties.machineCount = 4
            $props = Copy-Fixture $assessmentFixture.Settings
            foreach ($pair in @(@('assessmentType','MachineAssessment'),@('groupType','Default'),@('provisioningState','Succeeded'),@('status','Completed'),@('numberOfMachines',4),@('updatedTimestamp','2026-10-07T00:00:00Z'))) { $props | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
            $assessmentFixture.AssessmentResource = [pscustomobject]@{ id = $assessmentFixture.Assessment.Split('?')[0]; type = 'Microsoft.Migrate/assessmentProjects/groups/assessments'; properties = $props }
            $assessmentFixture.Results = @(for ($i = 0; $i -lt 4; $i++) { [pscustomobject]@{ id = $assessmentFixture.Assessment.Split('?')[0] + '/assessedMachines/result-' + $i; type = 'Microsoft.Migrate/assessmentProjects/groups/assessments/assessedMachines'; properties = [pscustomobject]@{ datacenterMachineArmId = $assessmentFixture.Workloads[$i].Id; displayName = $required[$i]; type = 'AssessedMachine'; recommendedSize = 'Standard_D2s_v5' } } })
        }
        function New-BackendResponse {
            param($Data, [int]$Status = 200)
            return New-AssessmentResponse $Status ($Data | ConvertTo-Json -Depth 15 -Compress)
        }
        function Set-BackendResponses {
            param([switch]$Existing, [switch]$Reuse)
            $inventory = if ($Existing) { $assessmentFixture.Members } else { $assessmentFixture.Inventory }
            $assessmentFixture.Responses = @((New-BackendResponse $assessmentFixture.Provider), (New-BackendResponse $assessmentFixture.Solution),
                (New-BackendResponse $assessmentFixture.Project), (New-BackendResponse @{ value = @($inventory) }))
            if ($Existing) {
                $assessmentFixture.Responses += @((New-BackendResponse $assessmentFixture.GroupFull), (New-BackendResponse $assessmentFixture.GroupFull), (New-BackendResponse @{ value = @($assessmentFixture.Members) }))
            } else {
                $assessmentFixture.Responses += @((New-AssessmentResponse 404 '{"error":{"code":"GroupNotFound"}}'), (New-BackendResponse $assessmentFixture.GroupEmpty 201),
                    (New-BackendResponse $assessmentFixture.GroupEmpty), (New-BackendResponse @{ value = @($assessmentFixture.Inventory) }),
                    (New-AssessmentResponse 202 ''), (New-BackendResponse $assessmentFixture.GroupFull), (New-BackendResponse @{ value = @($assessmentFixture.Members) }))
            }
            if ($Reuse) { $assessmentFixture.Responses += New-BackendResponse $assessmentFixture.AssessmentResource }
            else { $assessmentFixture.Responses += @((New-AssessmentResponse 404 '{"error":{"code":"AssessmentNotFound"}}'), (New-AssessmentResponse 202 '')) }
        }
        function Invoke-BackendCreation {
            param([string]$ExplicitName = '', [ValidateSet('Modern','Classic')][string]$Mode = 'Classic')
            return Invoke-LabAssessmentCreation -MigrateProjectName fictional-project -ProjectName $ExplicitName -GroupName AllServers-Group -AssessmentName Workshop-Assessment -Workloads $assessmentFixture.Workloads -Settings $assessmentFixture.Settings -Session $assessmentFixture.Session -Mode $Mode
        }
        function New-CompletionCreation {
            return [pscustomobject]@{ AssessmentPath = $assessmentFixture.Assessment; GroupPath = $assessmentFixture.Group;
                MachinePath = $assessmentFixture.ProjectId + '/machines?api-version=2024-01-15'; Settings = $assessmentFixture.Settings;
                Machines = (Get-LabAssessmentMachineMap $assessmentFixture.Workloads $assessmentFixture.Inventory $assessmentFixture.ProjectId) }
        }
        function Set-CompletionResponses {
            param([switch]$Paged)
            $assessmentFixture.Responses = @((New-BackendResponse $assessmentFixture.AssessmentResource))
            if ($Paged) {
                $next = 'https://management.azure.com' + $assessmentFixture.Assessment.Replace('?api-version=', '/assessedMachines?api-version=') + '&continuationToken=fictional%2Bpage'
                $assessmentFixture.Responses += @((New-BackendResponse @{ value = @($assessmentFixture.Results[0], $assessmentFixture.Results[1]); nextLink = $next }), (New-BackendResponse @{ value = @($assessmentFixture.Results[2], $assessmentFixture.Results[3]) }))
            } else { $assessmentFixture.Responses += New-BackendResponse @{ value = @($assessmentFixture.Results) } }
            $assessmentFixture.Responses += @((New-BackendResponse $assessmentFixture.GroupFull), (New-BackendResponse @{ value = @($assessmentFixture.Members) }), (New-BackendResponse $assessmentFixture.AssessmentResource))
        }
        $checks['backend/linked_generated_name_not_migrate_name_and_correct_write_contract [mocked workflow]'] = {
            New-BackendFixture; Set-BackendResponses
            $assessmentFixture.GroupEmpty.properties.groupStatus = 'Created'; Set-BackendResponses
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Submitted' -and $result.ProjectName -eq 'fictional-generated-backend' -and $assessmentFixture.Calls.Count -eq 13)
            $writes = @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }); Assert-Check ($writes.Count -eq 3)
            $groupBody = $writes[0].Payload | ConvertFrom-Json
            Assert-Check ($groupBody.properties.groupType -eq 'Default' -and @($groupBody.properties.PSObject.Properties).Count -eq 1)
            Assert-Check ($null -eq (Get-LabAssessmentField $groupBody.properties 'supportedAssessmentTypes') -and $null -eq (Get-LabAssessmentField $groupBody.properties 'machines'))
            $membershipBody = $writes[1].Payload | ConvertFrom-Json
            Assert-Check ($writes[1].Method -eq 'POST' -and $writes[1].Path.Contains('/updateMachines?') -and $membershipBody.properties.operationType -eq 'Add' -and $membershipBody.properties.machines.Count -eq 4)
            foreach ($id in $membershipBody.properties.machines) { Assert-Check ($id.StartsWith($assessmentFixture.ProjectId + '/machines/') -and -not $id.Contains('OffAzure')) }
            Assert-Check ($null -eq (Get-LabAssessmentField $membershipBody.properties 'eTag'))
            $assessmentBody = $writes[2].Payload | ConvertFrom-Json
            Assert-Check ($assessmentBody.properties.azureOfferCode -eq 'MSAZR0003P' -and $assessmentBody.properties.sizingCriterion -eq 'AsOnPremises')
            Assert-Check ($null -eq (Get-LabAssessmentField $assessmentBody.properties 'stage') -and $null -eq (Get-LabAssessmentField $assessmentBody.properties 'provisioningState'))
        }
        $checks['backend/linked_missing_project_404_no_same_name_fallback [mocked workflow]'] = {
            New-BackendFixture; Set-BackendResponses; $assessmentFixture.Responses[2] = New-AssessmentResponse 404 '{"error":{"code":"ResourceNotFound","message":"Assessment backend does not exist."}}'
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 3)
            Assert-Contains $result.Message @('HTTP 404','ResourceNotFound'); Assert-Absent $result.Message @('Connect-AzAccount')
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
        }
        $checks['backend/no_link_one_multiple_or_empty_projects_never_silently_selected [mocked workflow]'] = {
            foreach ($count in @(0,1,2)) {
                New-BackendFixture
                $projects = @(for ($i = 0; $i -lt $count; $i++) { $p = Copy-Fixture $assessmentFixture.Project; $p.id += $i; $p | Add-Member -NotePropertyName location -NotePropertyValue eastus; $p })
                $assessmentFixture.Responses = @((New-BackendResponse $assessmentFixture.Provider), (New-AssessmentResponse 404 '{"error":{"code":"ResourceNotFound"}}'), (New-BackendResponse @{ value = $projects }))
                $result = Invoke-BackendCreation
                Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 3)
                Assert-Contains $result.Message @('-AssessmentProjectName','never selected silently')
            }
        }
        $checks['backend/malformed_foreign_reference_and_explicit_conflict_preserved [mocked workflow]'] = {
            foreach ($reference in @('/assessmentProjects/fictional', 'https://example.invalid/foreign', $assessmentFixture.ProjectId)) {
                New-BackendFixture; $assessmentFixture.Solution.properties.details.extendedDetails.projectId = if ($reference) { $reference.Replace('fictional-generated-backend','..') } else { '/invalid' }
                $assessmentFixture.Responses = @((New-BackendResponse $assessmentFixture.Provider), (New-BackendResponse $assessmentFixture.Solution), (New-BackendResponse @{ value = @() }))
                Assert-Check ((Invoke-BackendCreation).State -eq 'Failed')
            }
            New-BackendFixture; Set-BackendResponses
            Assert-Check ((Invoke-BackendCreation different-backend).State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 2)
        }
        $checks['backend/explicit_name_without_link_requires_four_exact_source_matches [mocked workflow]'] = {
            New-BackendFixture; Set-BackendResponses -Existing -Reuse
            $assessmentFixture.Responses[1] = New-AssessmentResponse 404 '{"error":{"code":"ResourceNotFound"}}'
            Assert-Check ((Invoke-BackendCreation fictional-generated-backend).State -eq 'Submitted')
            New-BackendFixture; $assessmentFixture.Inventory[0].properties.discoveryMachineArmId += '-foreign'; Set-BackendResponses
            $assessmentFixture.Responses[1] = New-AssessmentResponse 404 '{"error":{"code":"ResourceNotFound"}}'
            $result = Invoke-BackendCreation fictional-generated-backend
            Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 4)
        }
        $checks['backend/provider_unregistered_or_unadvertised_parent_api_stops_writes [mocked helper + workflow]'] = {
            New-BackendFixture; Assert-LabAssessmentProvider $assessmentFixture.Provider
            foreach ($kind in @('missing-parent','unadvertised-parent','unregistered')) {
                New-BackendFixture
                switch ($kind) {
                    'missing-parent' { $assessmentFixture.Provider.resourceTypes = @($assessmentFixture.Provider.resourceTypes | Where-Object { $_.resourceType -ne 'assessmentProjects' }) }
                    'unadvertised-parent' { $assessmentFixture.Provider.resourceTypes[0].apiVersions = @('2025-09-09-preview','2024-01-15') }
                    unregistered { $assessmentFixture.Provider.registrationState = 'NotRegistered' }
                }
                Assert-Throws { Assert-LabAssessmentProvider $assessmentFixture.Provider }
                Set-BackendResponses
                Assert-Check ((Invoke-BackendCreation).State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 1)
            }
        }
        $checks['backend/case_insensitive_map_distinct_four_not_name_only [mocked helper]'] = {
            New-BackendFixture; foreach ($row in $assessmentFixture.Inventory) { $row.properties.discoveryMachineArmId = $row.properties.discoveryMachineArmId.ToUpperInvariant() }
            $map = Get-LabAssessmentMachineMap $assessmentFixture.Workloads $assessmentFixture.Inventory $assessmentFixture.ProjectId
            Assert-Check ($map.Count -eq 4 -and $map[0].AssessmentId -eq $assessmentFixture.ProjectId + '/machines/assessment-0')
            $assessmentFixture.Inventory[0].properties.discoveryMachineArmId += '-wrong'
            Assert-Throws { Get-LabAssessmentMachineMap $assessmentFixture.Workloads $assessmentFixture.Inventory $assessmentFixture.ProjectId }
            $changed = Copy-Fixture $map; $changed[0].AssessmentId += '-changed'
            Assert-Throws { Assert-LabAssessmentMachineMapStable $map $changed }
        }
        $checks['backend/duplicate_missing_foreign_or_malformed_machine_ids_fail_closed [mocked helper]'] = {
            foreach ($kind in @('duplicate','missing','foreign','malformed','name','source-duplicate')) {
                New-BackendFixture
                switch ($kind) {
                    duplicate { $assessmentFixture.Inventory += Copy-Fixture $assessmentFixture.Inventory[0] }
                    missing { $assessmentFixture.Inventory = @($assessmentFixture.Inventory[1..3]) }
                    foreign { $assessmentFixture.Inventory[0].id = $assessmentFixture.Inventory[0].id.Replace('fictional-generated-backend','other-project') }
                    malformed { $assessmentFixture.Inventory[0].id = $assessmentFixture.ProjectId + '/machines/..' }
                    name { $assessmentFixture.Inventory[0].properties.displayName = 'MigrateAppl' }
                    source-duplicate { $assessmentFixture.Workloads[1].Id = $assessmentFixture.Workloads[0].Id }
                }
                Assert-Throws { Get-LabAssessmentMachineMap $assessmentFixture.Workloads $assessmentFixture.Inventory $assessmentFixture.ProjectId }
            }
        }
        $checks['backend/pricing_wire_enums_validated_without_unknown_fallback [mocked helper]'] = {
            foreach ($offer in @('MS-AZR-0003P','MSAZR0003P','ms-azr-0003p')) { Assert-Check ((Get-LabAssessmentSettings westus2 USD $offer No).azureOfferCode -eq 'MSAZR0003P') }
            Assert-Throws { Get-LabAssessmentSettings westus2 USD bogus No }; Assert-Throws { Get-LabAssessmentSettings westus2 Unknown MS-AZR-0003P No }
            Assert-Check ((Get-LabAssessmentSettings eastus EUR EA Yes).currency -eq 'EUR')
        }
        $checks['backend/existing_exact_group_reuse_never_overwrites_membership [mocked workflow]'] = {
            New-BackendFixture; Set-BackendResponses -Existing -Reuse
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Submitted' -and $assessmentFixture.Calls.Count -eq 8 -and @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
        }
        $checks['backend/existing_empty_partial_or_extra_group_preserved [mocked workflow]'] = {
            foreach ($kind in @('empty','partial','extra')) {
                New-BackendFixture
                $rows = Copy-Fixture $assessmentFixture.Members
                if ($kind -eq 'empty') { foreach ($row in $rows) { $row.properties.groups = @() } }
                if ($kind -eq 'partial') { $rows[0].properties.groups = @() }
                if ($kind -eq 'extra') { $extra = Copy-Fixture $rows[0]; $extra.id += '-foreign'; $rows += $extra }
                Set-BackendResponses -Existing; $assessmentFixture.Responses[6] = New-BackendResponse @{ value = @($rows) }
                $result = Invoke-BackendCreation
                Assert-Check ($result.State -eq 'Failed' -and @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
                Assert-Contains $result.Message @('-AssessmentGroupName','preserved')
            }
        }
        $checks['backend/busy_matching_assessment_reused_but_other_busy_group_not_written [mocked workflow]'] = {
            New-BackendFixture; $assessmentFixture.AssessmentResource.properties.status = 'Running'; $assessmentFixture.GroupFull.properties.areAssessmentsRunning = $true; Set-BackendResponses -Existing -Reuse
            Assert-Check ((Invoke-BackendCreation).State -eq 'Submitted' -and @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            New-BackendFixture; $assessmentFixture.GroupFull.properties.areAssessmentsRunning = $true; Set-BackendResponses -Existing
            Assert-Check ((Invoke-BackendCreation).State -eq 'Failed' -and @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
        }
        $checks['backend/stale_invalid_mismatched_type_settings_never_overwritten [mocked workflow]'] = {
            foreach ($case in @(@('status','Invalid'),@('status','OutDated'),@('status','OutOfSync'),@('assessmentType','AvsAssessment'),@('azureLocation','eastus'),@('azureOfferCode','Unknown'))) {
                New-BackendFixture; $assessmentFixture.AssessmentResource.properties.($case[0]) = $case[1]; Set-BackendResponses -Existing -Reuse
                $result = Invoke-BackendCreation
                Assert-Check ($result.State -eq 'Failed' -and @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            }
        }
        $checks['backend/202_group_bounded_wait_no_membership_or_assessment_put [mocked workflow]'] = {
            New-BackendFixture; Set-BackendResponses
            $assessmentFixture.Responses = @($assessmentFixture.Responses[0..5]) + @(for ($i = 0; $i -lt 10; $i++) { New-AssessmentResponse 202 '' })
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'GroupPending' -and $assessmentFixture.Calls.Count -eq 16 -and @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 1)
        }
        $checks['backend/updateMachines_failure_not_retried_and_never_assessment_put [mocked workflow]'] = {
            New-BackendFixture; Set-BackendResponses; $assessmentFixture.Responses[8] = New-AssessmentResponse 500 '{}'
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 9 -and @($assessmentFixture.Calls | Where-Object { $_.Method -eq 'POST' }).Count -eq 1 -and $result.Stage -eq 'Server group updateMachines POST')
        }
        $checks['backend/completion_requires_status_not_review_stage_and_all_four [mocked workflow]'] = {
            New-BackendFixture; $assessmentFixture.AssessmentResource.properties | Add-Member -NotePropertyName stage -NotePropertyValue InProgress
            Set-CompletionResponses
            $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'ResultsReady' -and $result.Ready -and $result.Results.Count -eq 4)
            New-BackendFixture; $assessmentFixture.AssessmentResource.properties.status = 'Running'
            $assessmentFixture.Responses = @(for ($i = 0; $i -lt 10; $i++) { New-BackendResponse $assessmentFixture.AssessmentResource })
            $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'Created' -and $result.Confirmed -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 10)
        }
        $checks['backend/all_results_pages_followed_partial_duplicate_foreign_rejected [mocked workflow + helper]'] = {
            New-BackendFixture; Set-CompletionResponses -Paged
            $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.Ready -and $assessmentFixture.Calls.Count -eq 6 -and $assessmentFixture.Calls[2].Path.Contains('continuationToken='))
            foreach ($kind in @('partial','duplicate','foreign','name','badid')) {
                New-BackendFixture; $rows = Copy-Fixture $assessmentFixture.Results
                switch ($kind) { partial { $rows = @($rows[0..2]) }; duplicate { $rows[1].properties.datacenterMachineArmId = $rows[0].properties.datacenterMachineArmId }; foreign { $rows[0].properties.datacenterMachineArmId += '-other' }; name { $rows[0].properties.displayName = 'MigrateAppl' }; badid { $rows[0].id += '/extra' } }
                Set-CompletionResponses; $assessmentFixture.Responses[1] = New-BackendResponse @{ value = @($rows) }
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready)
            }
        }
        $checks['backend/unsafe_links_duplicate_query_external_scope_traversal_rejected [mocked helper]'] = {
            New-BackendFixture; $path = $assessmentFixture.ProjectId + '/machines?api-version=2024-01-15'
            foreach ($link in @(('https://example.invalid' + $path), ('https://user@management.azure.com' + $path), ('https://management.azure.com' + $path.Replace('/machines','/groups/../machines')), $path.Replace('000000000001','000000000009'), $path.Replace('fictional-generated-backend','other-project'), $path.Replace('/machines','/groups'), ($path + '&api-version=2024-01-15'), ($path + '&continuationToken=x&continuationToken=y'), ($path + '#fragment'), $path.Replace('2024-01-15','2023-03-15'))) {
                Assert-Throws { ConvertTo-LabAssessmentNextPath $link $path $assessmentFixture.Context fictional-source }
            }
            Assert-Check ((ConvertTo-LabAssessmentNextPath ('https://management.azure.com' + $path + '&continuationToken=abc%2Bdef') $path $assessmentFixture.Context fictional-source) -eq $path + '&continuationToken=abc%2Bdef')
        }
        $checks['backend/path_method_and_api_allowlist_cannot_expand_write_scope [mocked helper]'] = {
            New-BackendFixture
            foreach ($case in @(@('POST',$assessmentFixture.Group),@('PUT',$assessmentFixture.ProjectId + '/machines?api-version=2024-01-15'),@('POST',$assessmentFixture.Assessment),@('PUT',$assessmentFixture.Group.Replace('fictional-source','foreign-group')))) {
                Assert-Check (-not (Test-LabAssessmentPath $case[1] $case[0] $assessmentFixture.Context fictional-source))
            }
            Assert-Check (Test-LabAssessmentPath ($assessmentFixture.ProjectId + '/machines?pageSize=2&continuationToken=abc%2Bdef&api-version=2024-01-15&totalRecordCount=4') GET $assessmentFixture.Context fictional-source)
            Assert-Check ((ConvertTo-LabAssessmentCanonicalId ($assessmentFixture.ProjectId.Replace('fictional-generated-backend','safe name'))) -eq $assessmentFixture.ProjectId.Replace('fictional-generated-backend','safe%20name'))
            Assert-Check ((ConvertTo-LabAssessmentSegment 'safe name') -eq 'safe%20name'); Assert-Throws { ConvertTo-LabAssessmentSegment '../bad' }
            Assert-Check (Test-LabAssessmentPath ($assessmentFixture.Group.Replace('AllServers-Group','safe%20name')) PUT $assessmentFixture.Context fictional-source)
        }
        $checks['backend/retry_after_allowlisted_and_safe_get_retry_only [mocked helper]'] = {
            New-BackendFixture; $response = New-AssessmentResponse 429 '{}'; $response | Add-Member -NotePropertyName Headers -NotePropertyValue @{ 'Retry-After' = '999'; Authorization = 'fictional-secret-not-real'; Location = 'https://example.invalid/steal' }
            $assessmentFixture.Responses = @($response, (New-BackendResponse $assessmentFixture.GroupFull))
            $result = Invoke-LabAssessmentRead $assessmentFixture.Group $assessmentFixture.Session
            Assert-Check ($result.Success -and $assessmentFixture.Calls.Count -eq 2 -and $assessmentFixture.Sleeps[0] -eq 60)
            Assert-Absent ($result | ConvertTo-Json -Depth 15) @('fictional-secret-not-real','example.invalid/steal')
        }
        $checks['backend/second_page_error_or_final_group_drift_blocks_handoff [mocked workflow]'] = {
            New-BackendFixture; Set-CompletionResponses -Paged; $assessmentFixture.Responses[2] = New-AssessmentResponse 401 '{"error":{"code":"InvalidAuthenticationToken"}}'
            $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready)
            New-BackendFixture; $assessmentFixture.Members[0].properties.groups = @(); Set-CompletionResponses
            $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready)
        }
        $checks['backend/stage6_reports_failure_before_any_pause_step7_is_automatic [source contract]'] = {
            Assert-Contains $assessmentStages @('Write-Warning "Step 6 $($creation.Stage): $($creation.Message)"','Step 7 not started: Step 6 state','if ($assessmentState -eq ''Submitted'')','Get-LabAssessmentCompletion')
            Assert-Contains $step2 @('Assert-LabAssessmentMachineMapStable', 'ConvertTo-LabAssessmentCanonicalId')
            Assert-Absent $assessmentStages @('Read-Host','Press Enter to continue to Step 7','Get-AzAccessToken')
            Assert-Before $step2 'resolved assessment project' 'submitting classic Azure VM MachineAssessment'
        }
        function Set-SparseProviderFixture {
            $versions = @('2025-09-09-preview','2024-03-03-preview','2024-01-30-preview','2024-01-01-preview','2023-09-09-preview','2023-07-07-preview','2023-05-01-preview','2023-04-01-preview','2023-03-15','2023-03-03','2022-02-02-preview','2020-05-01-preview','2020-01-01','2019-10-01','2019-05-01','2018-06-30-preview')
            $assessmentFixture.Provider.resourceTypes = @(
                [pscustomobject]@{ resourceType = 'assessmentProjects'; apiVersions = $versions },
                [pscustomobject]@{ resourceType = 'assessmentProjects/assessments'; apiVersions = @($versions) + @('2024-01-15') })
        }
        $checks['metadata/sparse_catalog_warns_then_reads_fixed_endpoints_before_writes [mocked workflow]'] = {
            New-BackendFixture; Set-SparseProviderFixture; Set-BackendResponses
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Submitted' -and $assessmentFixture.Calls.Count -eq 13)
            Assert-Check ($assessmentFixture.Calls[2].Path -eq $assessmentFixture.ProjectId + '?api-version=2023-03-15')
            Assert-Check ($assessmentFixture.Calls[3].Path -eq $assessmentFixture.ProjectId + '/machines?api-version=2024-01-15')
            Assert-Check ($assessmentFixture.Calls[4].Path -eq $assessmentFixture.Group -and $assessmentFixture.Calls[4].Method -eq 'GET')
            Assert-Check (@($assessmentFixture.Calls[0..4] | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            Assert-Check ($assessmentFixture.Calls[5].Method -eq 'PUT')
            Assert-Contains ($assessmentFixture.Logs -join "`n") @('assessmentProjects/groups/assessments not advertised','Catalog absence is not proof of unsupported API')
            foreach ($call in $assessmentFixture.Calls) { Assert-Check ($call.Path -notmatch 'preview(?!$)|2025-|2024-03-03|2024-01-30' -and -not $call.Path.Contains('/assessmentProjects/fictional-project')) }
        }
        $checks['metadata/explicit_child_version_omission_probes_not_top_level_alias [mocked workflow]'] = {
            New-BackendFixture; Set-SparseProviderFixture
            $assessmentFixture.Provider.resourceTypes += [pscustomobject]@{ resourceType = 'assessmentProjects/groups/assessments'; apiVersions = @('2023-03-15') }
            Set-BackendResponses -Existing -Reuse
            Assert-Check ((Invoke-BackendCreation).State -eq 'Submitted')
            Assert-Contains ($assessmentFixture.Logs -join "`n") @('catalog row assessmentProjects/groups/assessments does not advertise documented API 2024-01-15','endpoint support is not verified')
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
        }
        $checks['metadata/malformed_required_catalog_fields_fail_before_resolution [mocked workflow]'] = {
            foreach ($kind in @('scalar-types','scalar-versions','empty','null','nonstring','unsafe','wrong-namespace','missing-registration')) {
                New-BackendFixture; Set-SparseProviderFixture
                switch ($kind) {
                    'scalar-types' { $assessmentFixture.Provider.resourceTypes = $assessmentFixture.Provider.resourceTypes[0] }
                    'scalar-versions' { $assessmentFixture.Provider.resourceTypes[0].apiVersions = '2023-03-15' }
                    empty { $assessmentFixture.Provider.resourceTypes[0].apiVersions = @() }
                    null { $assessmentFixture.Provider.resourceTypes[0].apiVersions = $null }
                    nonstring { $assessmentFixture.Provider.resourceTypes[0].apiVersions = @('2023-03-15',42) }
                    unsafe { $assessmentFixture.Provider.resourceTypes[0].apiVersions = @('2023-03-15','https://example.invalid/fictional-secret') }
                    'wrong-namespace' { $assessmentFixture.Provider.namespace = 'Microsoft.Compute' }
                    'missing-registration' { $assessmentFixture.Provider.registrationState = $null }
                }
                Set-BackendResponses
                $result = Invoke-BackendCreation
                Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 1)
                Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
                Assert-Absent $result.Message @('fictional-secret','https://example.invalid')
            }
        }
        $checks['metadata/unused_catalog_rows_never_block_known_profiles [mocked helper]'] = {
            New-ModernFixture
            $assessmentFixture.Provider.resourceTypes += @(
                [pscustomobject]@{ resourceType = 'assessmentProjects/businessCases'; apiVersions = @('2026-06-06-preview','2018-01-01-alpha','opaque-version') },
                [pscustomobject]@{ resourceType = 'unused/routes'; apiVersions = @('opaque','opaque'); locations = @('fixture'); tags = @{ fixture = 'not-selected' } },
                [pscustomobject]@{ resourceType = 'unused/routes'; apiVersions = $null },
                [pscustomobject]@{ resourceType = 'unused/bad'; apiVersions = 42 },
                [pscustomobject]@{ resourceType = ''; apiVersions = $null }, $null)
            Assert-Check ((Get-LabAssessmentProfile $assessmentFixture.Provider Modern).Version -eq '2024-03-03-preview')
            Assert-Check ((Get-LabAssessmentProfile $assessmentFixture.Provider Classic).Version -eq '2024-01-15')
            Assert-Check ((Get-LabAssessmentCatalog $assessmentFixture.Provider Modern).Count -eq 2)
        }
        $checks['metadata/harmless_version_duplicates_trim_and_case_normalize [mocked helper]'] = {
            New-ModernFixture
            $assessmentFixture.Provider.resourceTypes[0].apiVersions = @('2023-03-15',' 2023-03-15 ','future-opaque','FUTURE-OPAQUE')
            $assessmentFixture.Provider.resourceTypes[1].apiVersions = @('2024-03-03-preview','2024-03-03-PREVIEW',' 2024-03-03-preview ')
            $catalog = Get-LabAssessmentCatalog $assessmentFixture.Provider Modern
            Assert-Check ($catalog['assessmentProjects'].Count -eq 2 -and $catalog['assessmentProjects/assessments'].Count -eq 1)
            Assert-Check ((Get-LabAssessmentProfile $assessmentFixture.Provider Modern).Version -ceq '2024-03-03-preview')
            Assert-Contains ($assessmentFixture.Logs -join "`n") @('harmless duplicate','versions remain fixed')
        }
        $checks['metadata/duplicate_relevant_rows_merge_for_same_profile_selection [mocked workflow]'] = {
            New-ModernFixture
            $assessmentFixture.Provider.resourceTypes[1].apiVersions = @('2025-09-09-preview')
            $assessmentFixture.Provider.resourceTypes += @(
                [pscustomobject]@{ resourceType = ' ASSESSMENTPROJECTS '; apiVersions = @('2023-03-15') },
                [pscustomobject]@{ resourceType = ' ASSESSMENTPROJECTS/ASSESSMENTS '; apiVersions = @('2024-03-03-preview','2018-01-01-alpha','future-opaque') },
                [pscustomobject]@{ resourceType = 'assessmentProjects/groups'; apiVersions = @('2024-01-15') },
                [pscustomobject]@{ resourceType = 'ASSESSMENTPROJECTS/GROUPS'; apiVersions = @('2024-01-15','2024-01-15') })
            $profile = Get-LabAssessmentProfile $assessmentFixture.Provider Modern
            Assert-Check ($profile.Version -ceq '2024-03-03-preview')
            Set-BackendResponses -Existing -Reuse
            Assert-Check ((Invoke-BackendCreation -Mode Modern).State -eq 'Submitted')
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
        }
        $checks['metadata/unknown_tokens_never_replace_implemented_versions [mocked helper + workflow]'] = {
            New-ModernFixture
            $assessmentFixture.Provider.resourceTypes[1].apiVersions += @('2018-01-01-alpha','future-opaque','fictional-secret-token')
            Assert-Check ((Get-LabAssessmentProfile $assessmentFixture.Provider Modern).Version -ceq '2024-03-03-preview')
            Assert-Absent ($assessmentFixture.Logs -join "`n") @('fictional-secret-token')
            $assessmentFixture.Provider.resourceTypes[1].apiVersions = @('latest','2025-09-09-preview','future-opaque')
            Set-BackendResponses
            $result = Invoke-BackendCreation -Mode Modern
            Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 1)
            Assert-Contains $result.Message @('assessmentProjects/assessments','apiVersions','2024-03-03-preview','no automatic downgrade')
        }
        $checks['metadata/malformed_optional_rows_warn_and_read_failure_stops_writes [mocked workflow]'] = {
            foreach ($kind in @('scalar','null','empty','nonstring','unsafe')) {
                New-BackendFixture; Set-SparseProviderFixture
                $row = [pscustomobject]@{ resourceType = 'assessmentProjects/machines'; apiVersions = $null }
                switch ($kind) {
                    scalar { $row.apiVersions = '2024-01-15' }
                    null { $row.apiVersions = $null }
                    empty { $row.apiVersions = @() }
                    nonstring { $row.apiVersions = @('2024-01-15',42) }
                    unsafe { $row.apiVersions = @('https://example.invalid/fictional-secret') }
                }
                $assessmentFixture.Provider.resourceTypes += $row
                Set-BackendResponses
                $assessmentFixture.Responses[3] = New-AssessmentResponse 403 '{"error":{"code":"Forbidden"}}'
                $result = Invoke-BackendCreation
                Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 4)
                Assert-Check ($assessmentFixture.Calls[3].Path -eq $assessmentFixture.ProjectId + '/machines?api-version=2024-01-15')
                Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
                Assert-Contains ($assessmentFixture.Logs -join "`n") @('assessmentProjects/machines','apiVersions','Optional catalog row ignored','read-only')
                Assert-Absent ($assessmentFixture.Logs -join "`n") @('fictional-secret')
            }
        }
        $checks['metadata/required_shape_errors_name_type_field_index_without_raw_values [mocked workflow]'] = {
            foreach ($index in @(0,1)) {
                foreach ($kind in @('scalar','empty','null','nonstring','unsafe','oversized')) {
                    New-ModernFixture
                    switch ($kind) {
                        scalar { $assessmentFixture.Provider.resourceTypes[$index].apiVersions = '2024-03-03-preview' }
                        empty { $assessmentFixture.Provider.resourceTypes[$index].apiVersions = @() }
                        null { $assessmentFixture.Provider.resourceTypes[$index].apiVersions = $null }
                        nonstring { $assessmentFixture.Provider.resourceTypes[$index].apiVersions = @(42) }
                        unsafe { $assessmentFixture.Provider.resourceTypes[$index].apiVersions = @('https://example.invalid/fictional-secret') }
                        oversized { $assessmentFixture.Provider.resourceTypes[$index].apiVersions = @(('x' * 129)) }
                    }
                    Set-BackendResponses; $result = Invoke-BackendCreation -Mode Modern
                    Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 1)
                    Assert-Contains $result.Message @("resourceTypes[$index]",$assessmentFixture.Provider.resourceTypes[$index].resourceType,'apiVersions')
                    Assert-Absent $result.Message @('fictional-secret','https://example.invalid',('x' * 129))
                }
            }
        }
        $checks['metadata/dictionary_singleton_arrays_preserved_without_unrolling [mocked helper]'] = {
            $provider = @{ namespace = 'Microsoft.Migrate'; registrationState = 'Registered'; resourceTypes = @(
                @{ resourceType = 'assessmentProjects'; apiVersions = @('2023-03-15') },
                @{ resourceType = 'assessmentProjects/assessments'; apiVersions = @('2024-03-03-preview') }) }
            $catalog = Get-LabAssessmentCatalog $provider Modern
            Assert-Check ($catalog -is [hashtable] -and $catalog.Count -eq 2)
            Assert-Check ($catalog['assessmentProjects'] -is [array] -and $catalog['assessmentProjects'].Count -eq 1)
            Assert-Check ((Get-LabAssessmentProfile $provider Modern).Version -eq '2024-03-03-preview')
            $provider.resourceTypes[0].apiVersions = @(); Assert-Throws { Get-LabAssessmentProfile $provider Modern }
            $provider.resourceTypes = @(); Assert-Throws { Get-LabAssessmentProfile $provider Modern }
        }
        $checks['metadata/inconsistent_duplicate_required_shape_cannot_establish_capability [mocked workflow]'] = {
            foreach ($type in @('assessmentProjects','assessmentProjects/assessments')) {
                New-ModernFixture
                $assessmentFixture.Provider.resourceTypes += [pscustomobject]@{ resourceType = $type.ToUpperInvariant(); apiVersions = '2024-03-03-preview' }
                Set-BackendResponses; $result = Invoke-BackendCreation -Mode Modern
                Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 1)
                Assert-Contains $result.Message @($type,'apiVersions must be an array')
            }
        }
        $checks['metadata/parent_2023_children_2024_methods_and_scope_pinned [mocked helper]'] = {
            New-BackendFixture
            $parent = $assessmentFixture.ProjectId + '?api-version=2023-03-15'
            $list = $assessmentFixture.Base + '/assessmentProjects?api-version=2023-03-15'
            foreach ($path in @($parent,$list,($list + '&continuationToken=abc'))) {
                Assert-Check (Test-LabAssessmentPath $path GET $assessmentFixture.Context fictional-source)
                Assert-Check (-not (Test-LabAssessmentPath ($path.Replace('2023-03-15','2024-01-15')) GET $assessmentFixture.Context fictional-source))
                foreach ($method in @('PUT','POST','DELETE')) { Assert-Check (-not (Test-LabAssessmentPath $path $method $assessmentFixture.Context fictional-source)) }
            }
            foreach ($path in @($assessmentFixture.Group,$assessmentFixture.Assessment,($assessmentFixture.ProjectId + '/machines?api-version=2024-01-15'))) {
                Assert-Check (Test-LabAssessmentPath $path GET $assessmentFixture.Context fictional-source)
                Assert-Check (-not (Test-LabAssessmentPath ($path.Replace('2024-01-15','2023-03-15')) GET $assessmentFixture.Context fictional-source))
            }
        }
        $checks['metadata/parent_pagination_preserves_api_and_collection [mocked helper + collection]'] = {
            New-BackendFixture; $path = $assessmentFixture.Base + '/assessmentProjects?api-version=2023-03-15'
            $next = $path + '&continuationToken=abc%2Bdef'
            Assert-Check ((ConvertTo-LabAssessmentNextPath ('https://management.azure.com' + $next) $path $assessmentFixture.Context fictional-source) -eq $next)
            foreach ($link in @(($next.Replace('2023-03-15','2024-01-15')),($next + '&api-version=2023-03-15'),($next.Replace('fictional-source','other-rg')))) {
                Assert-Throws { ConvertTo-LabAssessmentNextPath $link $path $assessmentFixture.Context fictional-source }
            }
            Assert-Throws { ConvertTo-LabAssessmentNextPath $next ($path.Replace('2023-03-15','2024-01-15')) $assessmentFixture.Context fictional-source }
            $assessmentFixture.Responses = @((New-BackendResponse @{ value = @($assessmentFixture.Project); nextLink = $next }), (New-BackendResponse @{ value = @() }))
            $projects = Get-LabAssessmentCollection $path $assessmentFixture.Session
            Assert-Check ($projects.Count -eq 1 -and $assessmentFixture.Calls.Count -eq 2)
            New-BackendFixture
            $assessmentFixture.Responses = @((New-BackendResponse $assessmentFixture.Provider), (New-AssessmentResponse 404 '{"error":{"code":"ResourceNotFound"}}'), (New-BackendResponse @{ value = @() }))
            Assert-Check ((Invoke-BackendCreation).State -eq 'Failed')
            Assert-Check ($assessmentFixture.Calls[2].Path -eq $path)
        }
        $checks['metadata/parent_read_identity_state_or_http_failure_never_writes [mocked workflow]'] = {
            foreach ($kind in @('404','api','type','id','inactive')) {
                New-BackendFixture; Set-SparseProviderFixture
                switch ($kind) {
                    type { $assessmentFixture.Project.type = 'Microsoft.Migrate/migrateProjects' }
                    id { $assessmentFixture.Project.id += '-foreign' }
                    inactive { $assessmentFixture.Project.properties.projectStatus = 'Inactive' }
                }
                Set-BackendResponses
                if ($kind -eq '404') { $assessmentFixture.Responses[2] = New-AssessmentResponse 404 '{"error":{"code":"ResourceNotFound"}}' }
                if ($kind -eq 'api') { $assessmentFixture.Responses[2] = New-AssessmentResponse 400 '{"error":{"code":"InvalidApiVersionParameter"}}' }
                $result = Invoke-BackendCreation
                Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 3 -and $result.Stage -eq 'Assessment backend resolution')
                Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            }
        }
        $checks['metadata/nested_api_rejection_is_authoritative_no_retry_or_write [mocked workflow]'] = {
            foreach ($code in @('InvalidApiVersionParameter','NoRegisteredProviderFound','InvalidResourceType','UnsupportedApiVersion')) {
                foreach ($index in @(3,4,7)) {
                    New-BackendFixture; Set-SparseProviderFixture; Set-BackendResponses -Existing
                    $assessmentFixture.Responses[$index] = New-AssessmentResponse 404 ('{"error":{"code":"' + $code + '"}}')
                    $result = Invoke-BackendCreation
                    Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq $index + 1)
                    Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0 -and $assessmentFixture.Sleeps.Count -eq 0)
                    Assert-Contains $result.Message @($code,'ApiVersion','no preview fallback')
                }
            }
        }
        $checks['metadata/parent_scope_404_not_treated_as_missing_new_group [mocked workflow]'] = {
            foreach ($code in @('ParentResourceNotFound','ResourceGroupNotFound','SubscriptionNotFound')) {
                New-BackendFixture; Set-SparseProviderFixture; Set-BackendResponses
                $assessmentFixture.Responses[4] = New-AssessmentResponse 404 ('{"error":{"code":"' + $code + '"}}')
                $result = Invoke-BackendCreation
                Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 5)
                Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
                Assert-Contains $result.Message @($code,'ScopeNotFound')
            }
        }
        function New-ModernFixture {
            New-BackendFixture; Set-SparseProviderFixture
            $assessmentFixture.Settings = Get-LabAssessmentSettings westus2 USD MS-AZR-0003P No Modern
            $assessmentFixture.Assessment = $assessmentFixture.ProjectId + '/assessments/Workshop-Assessment?api-version=2024-03-03-preview'
            $assessmentFixture.AssessmentResource = [pscustomobject]@{ id = $assessmentFixture.Assessment.Split('?')[0]; type = 'Microsoft.Migrate/assessmentProjects/assessments';
                properties = [pscustomobject]@{ scope = [pscustomobject]@{ scopeType = 'ServerGroupId'; serverGroupId = $assessmentFixture.Group.Split('?')[0] };
                    settings = (Copy-Fixture $assessmentFixture.Settings); details = [pscustomobject]@{ status = 'Completed'; updatedTimestamp = '2026-10-07T00:00:00Z' } } }
            $assessmentFixture.Results = @(for ($i = 0; $i -lt 4; $i++) {
                [pscustomobject]@{ id = $assessmentFixture.Assessment.Split('?')[0] + '/assessedMachines/result-' + $i; type = 'Microsoft.Migrate/assessmentProjects/assessments/assessedMachines';
                    properties = [pscustomobject]@{ workloadType = 'fixture-returned-workload'; linkages = @([pscustomobject]@{ armId = $assessmentFixture.Workloads[$i].Id; workloadName = 'not-used-for-matching'; kind = 'fixture-returned-kind' });
                        recommendations = @([pscustomobject]@{ configuration = [pscustomobject]@{ azureTarget = 'fixture-returned-target'; sizingCriterion = 'AsOnPremises' };
                            recommendedFor = [pscustomobject]@{ strategies = @('fixture-returned-strategy') }; migrationSuitability = [pscustomobject]@{ readiness = 'fixture-returned-readiness' };
                            skus = @([pscustomobject]@{ details = [pscustomobject]@{ skuName = 'fixture-returned-sku' } }); totalCost = @([pscustomobject]@{ costDetail = @([pscustomobject]@{ name = 'fixture-returned-cost'; value = 12; savingsOptions = 'None' }) }) }) } }
            })
        }
        function New-ModernCreation {
            return [pscustomobject]@{ Mode = 'Modern'; Version = '2024-03-03-preview'; AssessmentPath = $assessmentFixture.Assessment;
                GroupPath = $assessmentFixture.Group; MachinePath = $assessmentFixture.ProjectId + '/machines?api-version=2024-01-15';
                Settings = $assessmentFixture.Settings; Machines = (Get-LabAssessmentMachineMap $assessmentFixture.Workloads $assessmentFixture.Inventory $assessmentFixture.ProjectId) }
        }
        function Test-ModernResource {
            return Assert-LabModernAssessment $assessmentFixture.AssessmentResource $assessmentFixture.Assessment.Split('?')[0] $assessmentFixture.Group.Split('?')[0] $assessmentFixture.Settings
        }
        function Test-ModernResults {
            return Assert-LabModernAssessedMachines $assessmentFixture.Results (New-ModernCreation).Machines $assessmentFixture.Assessment.Split('?')[0]
        }
        $checks['modern/explicit_experimental_mode_with_classic_default_without_fallback [source contract]'] = {
            Assert-Contains $step2 @("[string]`$AssessmentMode = 'Classic'", "[ValidateSet('Modern', 'Classic')]", '-Mode $AssessmentMode', 'no automatic downgrade', 'no fallback/recompute PUT')
            Assert-Absent (Get-Section $step2 'function Get-LabModernAssessmentCompletion' 'function Get-LabAssessmentCompletion') @('Invoke-LabAssessmentCreation','-Method PUT','-Mode Classic')
        }
        $checks['modern/available_verified_profile_skips_2025_not_date_latest [mocked helper]'] = {
            New-ModernFixture; $profile = Get-LabAssessmentProfile $assessmentFixture.Provider Modern
            Assert-Check ($profile.Version -ceq '2024-03-03-preview' -and $profile.Mode -eq 'Modern')
            Assert-Contains ($assessmentFixture.Logs -join '`n') @('skipped advertised 2025-09-09-preview','unverified/unimplemented','PREVIEW')
        }
        $checks['modern/missing_preview_or_top_level_type_stops_before_group_writes [mocked workflow]'] = {
            foreach ($kind in @('missing-version','missing-type','only-2025')) {
                New-ModernFixture
                switch ($kind) {
                    'missing-version' { $assessmentFixture.Provider.resourceTypes[1].apiVersions = @('2024-01-15') }
                    'only-2025' { $assessmentFixture.Provider.resourceTypes[1].apiVersions = @('2025-09-09-preview') }
                    'missing-type' { $assessmentFixture.Provider.resourceTypes = @($assessmentFixture.Provider.resourceTypes[0]) }
                }
                Set-BackendResponses
                $result = Invoke-BackendCreation -Mode Modern
                Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 1)
                Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            }
        }
        $checks['modern/metadata_error_stops_no_group_or_classic_fallback [mocked workflow]'] = {
            New-ModernFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 403 '{"error":{"code":"Forbidden"}}'))
            Assert-Check ((Invoke-BackendCreation -Mode Modern).State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 1)
        }
        $checks['modern/top_level_put_nested_scope_settings_never_classic_assessment_put [mocked workflow]'] = {
            New-ModernFixture; Set-BackendResponses
            $result = Invoke-BackendCreation -Mode Modern
            Assert-Check ($result.State -eq 'Submitted' -and $result.Mode -eq 'Modern' -and $result.Version -eq '2024-03-03-preview')
            $writes = @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }); Assert-Check ($writes.Count -eq 3)
            Assert-Check ($writes[2].Path -eq $assessmentFixture.Assessment -and -not $writes[2].Path.Contains('/groups/'))
            $body = $writes[2].Payload | ConvertFrom-Json
            Assert-Check ($body.properties.scope.scopeType -eq 'ServerGroupId' -and $body.properties.scope.serverGroupId -eq $assessmentFixture.Group.Split('?')[0])
            Assert-Check ($body.properties.settings.savingsSettings.azureOfferCode -eq 'MSAZR0003P' -and $body.properties.settings.savingsSettings.savingsOptions -eq 'None')
            foreach ($field in @('details','azureOfferCode','reservedInstance','sizingCriterion','provisioningState')) { Assert-Check ($null -eq (Get-LabAssessmentField $body.properties $field)) }
        }
        $checks['modern/pricing_integer_settings_and_narrow_offer_enum [mocked helper]'] = {
            New-ModernFixture; $s = $assessmentFixture.Settings
            Assert-Check ($s.scalingFactor -is [int] -and $s.discountPercentage -is [int] -and $s.scalingFactor -eq 1 -and $s.discountPercentage -eq 0)
            Assert-Check ($s.environmentType -eq 'Production' -and $s.azureLocation -eq 'westus2' -and $s.linuxAzureHybridUseBenefit -eq 'No')
            foreach ($offer in @('MSAZR0044P','Unknown','invalid')) { Assert-Throws { Get-LabAssessmentSettings westus2 USD $offer No Modern } }
            Assert-Check ((Get-LabAssessmentSettings westus2 USD MSMCAZR0044P No Modern).savingsSettings.azureOfferCode -eq 'MSMCAZR0044P')
        }
        $checks['modern/get_put_only_profile_paths_other_versions_methods_denied [mocked helper]'] = {
            New-ModernFixture
            foreach ($method in @('GET','PUT')) { Assert-Check (Test-LabAssessmentPath $assessmentFixture.Assessment $method $assessmentFixture.Context fictional-source) }
            foreach ($method in @('POST','DELETE')) { Assert-Check (-not (Test-LabAssessmentPath $assessmentFixture.Assessment $method $assessmentFixture.Context fictional-source)) }
            foreach ($version in @('2025-09-09-preview','2024-01-15','2023-03-15')) { Assert-Check (-not (Test-LabAssessmentPath $assessmentFixture.Assessment.Replace('2024-03-03-preview',$version) PUT $assessmentFixture.Context fictional-source)) }
            $results = $assessmentFixture.Assessment.Replace('?api-version=', '/assessedMachines?api-version=')
            Assert-Check (Test-LabAssessmentPath $results GET $assessmentFixture.Context fictional-source)
            Assert-Check (-not (Test-LabAssessmentPath $results PUT $assessmentFixture.Context fictional-source))
        }
        $checks['modern/pagination_same_authority_scope_collection_and_version [mocked helper]'] = {
            New-ModernFixture; $path = $assessmentFixture.Assessment.Replace('?api-version=', '/assessedMachines?api-version=')
            $next = $path + '&continuationToken=abc%2Bdef'
            Assert-Check ((ConvertTo-LabAssessmentNextPath ('https://management.azure.com' + $next) $path $assessmentFixture.Context fictional-source) -eq $next)
            foreach ($link in @($next.Replace('2024-03-03-preview','2025-09-09-preview'), $next.Replace('fictional-source','foreign-rg'), ('https://example.invalid' + $next), ($next + '&api-version=2024-03-03-preview'))) {
                Assert-Throws { ConvertTo-LabAssessmentNextPath $link $path $assessmentFixture.Context fictional-source }
            }
        }
        $checks['modern/exact_existing_group_and_assessment_reused_read_only [mocked workflow]'] = {
            New-ModernFixture; Set-BackendResponses -Existing -Reuse
            Assert-Check ((Invoke-BackendCreation -Mode Modern).State -eq 'Submitted')
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
        }
        $checks['modern/existing_scope_or_settings_conflict_preserved [mocked workflow]'] = {
            foreach ($kind in @('scope','settings','savings')) {
                New-ModernFixture
                switch ($kind) { scope { $assessmentFixture.AssessmentResource.properties.scope.serverGroupId += '-other' }; settings { $assessmentFixture.AssessmentResource.properties.settings.azureLocation = 'eastus' }; savings { $assessmentFixture.AssessmentResource.properties.settings.savingsSettings.savingsOptions = 'other' } }
                Set-BackendResponses -Existing -Reuse
                Assert-Check ((Invoke-BackendCreation -Mode Modern).State -eq 'Failed')
                Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            }
        }
        $checks['modern/existing_group_extra_member_conflict_preserved [mocked workflow]'] = {
            New-ModernFixture; $assessmentFixture.Members[0].properties.groups = @(); Set-BackendResponses -Existing
            Assert-Check ((Invoke-BackendCreation -Mode Modern).State -eq 'Failed')
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
        }
        $checks['modern/service_scope_rejection_no_classic_fallback_no_retry [mocked workflow]'] = {
            New-ModernFixture; Set-BackendResponses; $assessmentFixture.Responses[12] = New-AssessmentResponse 400 '{"error":{"code":"InvalidRequest","message":"ServerGroupId rejected."}}'
            $result = Invoke-BackendCreation -Mode Modern
            Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 13 -and $result.Stage -eq 'Assessment PUT')
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Path -like '*/groups/*/assessments/*' }).Count -eq 0)
        }
        $checks['modern/accepted_running_created_not_completed_pending_bound [mocked workflow]'] = {
            foreach ($status in @('Created','Updated','Running')) {
                New-ModernFixture; $assessmentFixture.AssessmentResource.properties.details.status = $status
                $assessmentFixture.Responses = @(for ($i = 0; $i -lt 10; $i++) { New-BackendResponse $assessmentFixture.AssessmentResource })
                $result = Get-LabAssessmentCompletion (New-ModernCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.Confirmed -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 10 -and $assessmentFixture.Sleeps.Count -eq 9)
            }
            New-ModernFixture; $assessmentFixture.Responses = @(for ($i = 0; $i -lt 10; $i++) { New-AssessmentResponse 202 '' })
            $result = Get-LabAssessmentCompletion (New-ModernCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check (-not $result.Confirmed -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 10)
        }
        $checks['modern/failed_invalid_stale_unknown_statuses_preserved [mocked helper]'] = {
            foreach ($status in @('Failed','Invalid','OutOfSync','OutDated','Deleted','new-status','')) {
                New-ModernFixture; $assessmentFixture.AssessmentResource.properties.details.status = $status
                Assert-Throws { Test-ModernResource }
            }
        }
        $checks['modern/no_phantom_required_provisioning_field_optional_states_checked [mocked helper]'] = {
            New-ModernFixture; Assert-Check ((Test-ModernResource) -eq 'Completed')
            foreach ($state in @('Succeeded','Accepted','Provisioning','Updating')) {
                New-ModernFixture; $assessmentFixture.AssessmentResource.properties | Add-Member -NotePropertyName provisioningState -NotePropertyValue $state
                Assert-Check ((Test-ModernResource) -eq 'Completed')
            }
            foreach ($state in @('Failed','Canceled','Deleting','unknown')) {
                New-ModernFixture; $assessmentFixture.AssessmentResource.properties | Add-Member -NotePropertyName provisioningState -NotePropertyValue $state
                Assert-Throws { Test-ModernResource }
            }
        }
        $checks['modern/completed_all_pages_source_verified_manual_review_not_auto_handoff [mocked workflow]'] = {
            New-ModernFixture; Set-CompletionResponses -Paged
            $result = Get-LabAssessmentCompletion (New-ModernCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'ManualReview' -and $result.Ready -and $result.Confirmed -and $result.Results.Count -eq 4 -and $assessmentFixture.Calls.Count -eq 6)
            Assert-Contains $result.Message @('Manual IaaS review','not verified','before Step 3')
        }
        $checks['modern/linkages_source_or_assessment_id_not_names [mocked helper]'] = {
            New-ModernFixture; Assert-Check ((Test-ModernResults).Count -eq 4)
            for ($i = 0; $i -lt 4; $i++) { $assessmentFixture.Results[$i].properties.linkages[0].armId = $assessmentFixture.Inventory[$i].id.ToUpperInvariant() }
            Assert-Check ((Test-ModernResults).Count -eq 4)
        }
        $checks['modern/missing_foreign_ambiguous_duplicate_linkages_fail_source_verification [mocked helper]'] = {
            foreach ($kind in @('missing','foreign','ambiguous','duplicate','partial','id','type','linkage-shape','recommendation-shape','cost-shape')) {
                New-ModernFixture
                switch ($kind) {
                    missing { $assessmentFixture.Results[0].properties.linkages = @() }
                    foreign { $assessmentFixture.Results[0].properties.linkages[0].armId += '-foreign' }
                    ambiguous { $assessmentFixture.Results[0].properties.linkages += [pscustomobject]@{ armId = $assessmentFixture.Workloads[1].Id } }
                    duplicate { $assessmentFixture.Results[1].properties.linkages[0].armId = $assessmentFixture.Workloads[0].Id }
                    partial { $assessmentFixture.Results = @($assessmentFixture.Results[0..2]) }
                    id { $assessmentFixture.Results[1].id = $assessmentFixture.Results[0].id }
                    type { $assessmentFixture.Results[0].type = 'Microsoft.Migrate/assessmentProjects/groups/assessments/assessedMachines' }
                    'linkage-shape' { $assessmentFixture.Results[0].properties.linkages = $assessmentFixture.Results[0].properties.linkages[0] }
                    'recommendation-shape' { $assessmentFixture.Results[0].properties.recommendations = $assessmentFixture.Results[0].properties.recommendations[0] }
                    'cost-shape' { $assessmentFixture.Results[0].properties.recommendations[0].totalCost = 'unknown-shape' }
                }
                Assert-Throws { Test-ModernResults }
            }
        }
        $checks['modern/completed_missing_linkage_source_unverified_not_failed_creation [mocked workflow]'] = {
            New-ModernFixture; $assessmentFixture.Results[0].properties.linkages = @(); Set-CompletionResponses
            $result = Get-LabAssessmentCompletion (New-ModernCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'SourceUnverified' -and $result.Confirmed -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 2)
            Assert-Contains $result.Message @('Creation may have completed','do not redo PUT')
        }
        $checks['modern/display_actual_nested_recommendations_no_flat_or_fake_cost [mocked helper + source contract]'] = {
            New-ModernFixture; Show-LabModernRecommendations (Test-ModernResults)
            Assert-Contains ($assessmentFixture.Logs -join '`n') @('fixture-returned-target','fixture-returned-readiness','fixture-returned-sku','fixture-returned-cost = 12','units/period not inferred','Alternatives are not summed')
            $adapter = Get-Section $step2 'function Assert-LabModernAssessedMachines' 'function Assert-LabAssessmentMachineMapStable'
            Assert-Absent $adapter @('datacenterMachineArmId','recommendedSize','monthlyComputeCost','Measure-Object','AzureVM')
        }
        $checks['modern/no_recommendations_or_costs_are_nodata_not_invented [mocked helper]'] = {
            New-ModernFixture; foreach ($row in $assessmentFixture.Results) { $row.properties.recommendations = @() }
            Show-LabModernRecommendations (Test-ModernResults)
            Assert-Contains ($assessmentFixture.Logs -join '`n') @('Recommendations: NoData')
        }
        $checks['modern/final_membership_drift_and_auth_error_stop_handoff [mocked workflow]'] = {
            New-ModernFixture; $assessmentFixture.Members[0].properties.groups = @(); Set-CompletionResponses
            $result = Get-LabAssessmentCompletion (New-ModernCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'Unverified' -and -not $result.Ready)
            New-ModernFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 401 '{"error":{"code":"InvalidAuthenticationToken"}}'))
            $result = Get-LabAssessmentCompletion (New-ModernCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'Unverified' -and $assessmentFixture.Calls.Count -eq 1 -and -not $result.Ready)
        }
        $checks['classic/default_parameter_ast_and_grouped_profile [AST + mocked helper]'] = {
            $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($step2Path, [ref]$null, [ref]$null)
            $parameter = @($scriptAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'AssessmentMode' })
            Assert-Check ($parameter.Count -eq 1 -and $parameter[0].DefaultValue.Value -ceq 'Classic')
            New-BackendFixture; Assert-Check ((Get-LabAssessmentProfile $assessmentFixture.Provider Classic).Version -ceq '2024-01-15')
            Assert-Absent $step2 @("Modern is default", "AssessmentMode = 'Modern'")
        }
        $checks['classic/live_completed_group_without_provisioning_unknown_empty_then_four [mocked workflow]'] = {
            New-BackendFixture
            $assessmentFixture.GroupEmpty.properties.PSObject.Properties.Remove('provisioningState')
            $assessmentFixture.GroupFull.properties.PSObject.Properties.Remove('provisioningState')
            $assessmentFixture.GroupEmpty.properties.supportedAssessmentTypes = @('Unknown')
            Set-BackendResponses; $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Submitted' -and $result.Mode -eq 'Classic' -and $assessmentFixture.Calls.Count -eq 13)
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -eq 'POST' }).Count -eq 1)
            Assert-Contains ($assessmentFixture.Logs -join "`n") @('provisioning <absent/null>','supported types Unknown','machineCount 0','machineCount 4')
        }
        $checks['classic/group_missing_null_provisioning_requires_completed [mocked helper]'] = {
            New-BackendFixture; $g = Copy-Fixture $assessmentFixture.GroupFull; $id = $g.id
            $g.properties.PSObject.Properties.Remove('provisioningState')
            Assert-Check (Test-LabAssessmentGroupReady $g $id -RequireMembership -RequireIdle)
            $g.properties | Add-Member -NotePropertyName provisioningState -NotePropertyValue $null
            Assert-Check (Test-LabAssessmentGroupReady $g $id)
            foreach ($status in @('Created','Updated','Running')) { $g.properties.groupStatus = $status; Assert-Check (-not (Test-LabAssessmentGroupReady $g $id)) }
            foreach ($status in @('Created','Updated','Completed')) { $g.properties.groupStatus = $status; $g.properties.provisioningState = 'Succeeded'; Assert-Check (Test-LabAssessmentGroupReady $g $id) }
            $g.properties.groupStatus = 'Completed'; $g.properties.provisioningState = 'Accepted'
            Assert-Check (-not (Test-LabAssessmentGroupReady $g $id))
            $g.properties.provisioningState = 'Succeeded'; Assert-Check (-not (Test-LabAssessmentGroupReady $g $id -Pending $true))
        }
        $checks['classic/group_completed_never_overrides_failure_or_malformed_state [mocked helper]'] = {
            New-BackendFixture; $g = Copy-Fixture $assessmentFixture.GroupFull
            foreach ($state in @('Failed','Canceled','Cancelled','Deleting','Unknown','',42)) { $g.properties.provisioningState = $state; Assert-Throws { Test-LabAssessmentGroupReady $g $g.id } }
            $g.properties.provisioningState = 'Succeeded'
            foreach ($status in @('Failed','Canceled','Deleting','Unknown',42)) { $g.properties.groupStatus = $status; Assert-Throws { Test-LabAssessmentGroupReady $g $g.id } }
            $g.properties.groupStatus = 'Completed'; $g.properties.groupType = 'Unknown'; Assert-Throws { Test-LabAssessmentGroupReady $g $g.id }
            $g.properties.groupType = 'Default'; $g.properties.machineCount = '4'; Assert-Throws { Test-LabAssessmentGroupReady $g $g.id }
            $g.properties.machineCount = 4; $g.properties.provisioningState = @('Succeeded'); Assert-Throws { Test-LabAssessmentGroupReady $g $g.id }
            $g.properties.provisioningState = 'Succeeded'; $g.properties.groupStatus = @('Completed'); Assert-Throws { Test-LabAssessmentGroupReady $g $g.id }
        }
        $checks['classic/group_running_without_provisioning_is_bounded_not_created [mocked workflow]'] = {
            New-BackendFixture; $assessmentFixture.GroupEmpty.properties.PSObject.Properties.Remove('provisioningState'); $assessmentFixture.GroupEmpty.properties.groupStatus = 'Running'; Set-BackendResponses
            $assessmentFixture.Responses = @($assessmentFixture.Responses[0..5]) + @(for ($i = 0; $i -lt 10; $i++) { New-BackendResponse $assessmentFixture.GroupEmpty })
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'GroupPending' -and $assessmentFixture.Calls.Count -eq 16)
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 1)
        }
        $checks['classic/post_add_updated_zero_then_completed_exact_four [mocked workflow]'] = {
            New-BackendFixture; $assessmentFixture.GroupEmpty.properties.PSObject.Properties.Remove('provisioningState'); $assessmentFixture.GroupEmpty.properties.supportedAssessmentTypes = @('Unknown')
            $assessmentFixture.GroupFull.properties.PSObject.Properties.Remove('provisioningState'); Set-BackendResponses
            $updated = Copy-Fixture $assessmentFixture.GroupEmpty; $updated.properties.groupStatus = 'Updated'
            $assessmentFixture.Responses = @($assessmentFixture.Responses[0..8]) + @((New-BackendResponse $updated)) + @($assessmentFixture.Responses[9..12])
            Assert-Check ((Invoke-BackendCreation).State -eq 'Submitted' -and $assessmentFixture.Calls.Count -eq 14)
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -eq 'POST' }).Count -eq 1)
        }
        $checks['classic/post_member_unknown_capability_stays_pending_no_assessment_put [mocked workflow]'] = {
            New-BackendFixture; $assessmentFixture.GroupFull.properties.supportedAssessmentTypes = @('Unknown'); Set-BackendResponses
            $assessmentFixture.Responses = @($assessmentFixture.Responses[0..8]) + @(for ($i = 0; $i -lt 10; $i++) { New-BackendResponse $assessmentFixture.GroupFull; New-BackendResponse @{ value = @($assessmentFixture.Members) } })
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'MembershipPending' -and $assessmentFixture.Calls.Count -eq 29)
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -eq 'PUT' }).Count -eq 1 -and @($assessmentFixture.Calls | Where-Object { $_.Method -eq 'POST' }).Count -eq 1)
            Assert-Contains $result.Message @('capability','bounded wait','Do not resubmit POST')
        }
        $checks['classic/existing_empty_live_group_preserved_even_if_completed [mocked workflow]'] = {
            New-BackendFixture; $assessmentFixture.GroupEmpty.properties.PSObject.Properties.Remove('provisioningState'); $assessmentFixture.GroupEmpty.properties.supportedAssessmentTypes = @('Unknown'); Set-BackendResponses -Existing
            $assessmentFixture.Responses[4] = New-BackendResponse $assessmentFixture.GroupEmpty
            $assessmentFixture.Responses[5] = New-BackendResponse $assessmentFixture.GroupEmpty
            $assessmentFixture.Responses[6] = New-BackendResponse @{ value = @($assessmentFixture.Inventory) }
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Failed' -and $assessmentFixture.Calls.Count -eq 7 -and @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            Assert-Contains $result.Message @('preserved','unused -AssessmentGroupName')
        }
        $checks['classic/array_empty_singleton_multiple_and_scalar_shape_ps51 [mocked helper]'] = {
            foreach ($objectKind in @('dictionary','psobject')) { foreach ($items in @(@(),@('MachineAssessment'),@('MachineAssessment','Unknown'))) {
                $object = @{ types = $items }; if ($objectKind -eq 'psobject') { $object = [pscustomobject]$object }
                $value = Get-LabAssessmentArray $object types
                $raw = Get-LabAssessmentField $object types -PreserveArray
                Assert-Check ($raw -is [array] -and $raw.Count -eq $items.Count)
                Assert-Check ($value -is [array] -and $value.Count -eq $items.Count)
                if ($items.Count -gt 0) { Assert-Check ($value[0] -ceq $items[0]) }
            } }
            foreach ($bad in @('MachineAssessment',42,$null)) { Assert-Throws { Get-LabAssessmentArray @{ types = $bad } types } }
            Assert-Check ($null -eq (Get-LabAssessmentArray @{} types -AllowMissing))
            New-BackendFixture; $g = Copy-Fixture $assessmentFixture.GroupFull; $g.properties.PSObject.Properties.Remove('supportedAssessmentTypes')
            Assert-Check (Test-LabAssessmentGroupReady $g $g.id -RequireMembership)
            $g.properties | Add-Member -NotePropertyName supportedAssessmentTypes -NotePropertyValue 'MachineAssessment'
            Assert-Throws { Test-LabAssessmentGroupReady $g $g.id -RequireMembership }
        }
        $checks['classic/resource_specific_404_codes_only_on_matching_get [mocked request]'] = {
            New-BackendFixture
            $modern = $assessmentFixture.ProjectId + '/assessments/Workshop-Assessment?api-version=2024-03-03-preview'
            foreach ($case in @(@('GroupNotFound',$assessmentFixture.Group,'GET',$true),@('AssessmentNotFound',$assessmentFixture.Assessment,'GET',$true),@('AssessmentNotFound',$modern,'GET',$true),
                @('GroupNotFound',$assessmentFixture.Assessment,'GET',$false),@('AssessmentNotFound',$assessmentFixture.Group,'GET',$false),@('GroupNotFound',($assessmentFixture.ProjectId + '?api-version=2023-03-15'),'GET',$false),
                @('AssessmentNotFound',($assessmentFixture.ProjectId + '/machines?api-version=2024-01-15'),'GET',$false),@('GroupNotFound',$assessmentFixture.Group,'PUT',$false),@('AssessmentNotFound',$assessmentFixture.Assessment,'PUT',$false),
                @('ParentResourceNotFound',$assessmentFixture.Group,'GET',$false),@('ResourceGroupNotFound',$assessmentFixture.Group,'GET',$false),@('SubscriptionNotFound',$assessmentFixture.Group,'GET',$false),@('Unrecognized404',$assessmentFixture.Group,'GET',$false),@('',$assessmentFixture.Group,'GET',$false))) {
                New-BackendFixture; $assessmentFixture.Responses = @((New-AssessmentResponse 404 ('{"error":{"code":"' + $case[0] + '"}}')))
                $session = $assessmentFixture.Session
                $r = Invoke-LabAssessmentRequest -Path $case[1] -Method $case[2] -Payload '{}' @session
                Assert-Check (($r.FailureKind -eq 'NotFound') -eq $case[3] -and $assessmentFixture.Calls.Count -eq 1)
            }
            foreach ($http in @(401,403,500)) {
                New-BackendFixture; $assessmentFixture.Responses = @((New-AssessmentResponse $http '{"error":{"code":"GroupNotFound"}}'))
                $session = $assessmentFixture.Session
                $r = Invoke-LabAssessmentRequest -Path $assessmentFixture.Group -Method GET @session
                Assert-Check ($r.FailureKind -ne 'NotFound' -and @($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            }
        }
        $checks['classic/completion_uses_shared_group_gate_without_weakening_assessment [mocked workflow]'] = {
            New-BackendFixture; $assessmentFixture.GroupFull.properties.PSObject.Properties.Remove('provisioningState'); Set-CompletionResponses
            $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'ResultsReady' -and $result.Ready -and $result.Results.Count -eq 4)
            New-BackendFixture; $assessmentFixture.AssessmentResource.properties.PSObject.Properties.Remove('provisioningState'); Set-CompletionResponses
            $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'ResultsReady' -and $result.Ready -and $result.Results.Count -eq 4 -and $assessmentFixture.Calls.Count -eq 5)
        }
        function Set-ClassicProvisioningFixture {
            param($Resource, [string]$Kind)
            switch ($Kind) {
                missing { $Resource.properties.PSObject.Properties.Remove('provisioningState') }
                null { $Resource.properties.provisioningState = $null }
                empty { $Resource.properties.provisioningState = '' }
                whitespace { $Resource.properties.provisioningState = " `t " }
                succeeded { $Resource.properties.provisioningState = 'Succeeded' }
                padded { $Resource.properties.provisioningState = ' Succeeded ' }
                default { throw 'Unknown optional provisioning fixture.' }
            }
        }
        function Get-ClassicInvalidProvisioningFixtures {
            return @(
                @{ Value = 'Failed' }, @{ Value = 'Canceled' }, @{ Value = 'Cancelled' }, @{ Value = 'Deleting' }, @{ Value = 'Unknown' },
                @{ Value = ' Failed ' }, @{ Value = ' Deleting ' }, @{ Value = 'Creating' }, @{ Value = 'Running' },
                @{ Value = @() }, @{ Value = @('Succeeded') }, @{ Value = @('Succeeded','Failed') },
                @{ Value = @{ state = 'Succeeded' } }, @{ Value = [pscustomobject]@{} }, @{ Value = 42 }, @{ Value = $false })
        }
        $checks['classic-completion/optional_metadata_completed_exact_four_is_ready [mocked workflow]'] = {
            foreach ($kind in @('missing','null','empty','whitespace','succeeded','padded')) {
                New-BackendFixture; Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource $kind
                $assessmentFixture.AssessmentResource.properties | Add-Member -NotePropertyName stage -NotePropertyValue InProgress
                Set-CompletionResponses -Paged
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.State -eq 'ResultsReady' -and $result.Confirmed -and $result.Ready -and $result.Results.Count -eq 4 -and $assessmentFixture.Calls.Count -eq 6)
                Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
                if ($kind -in @('missing','null')) { Assert-Contains ($assessmentFixture.Logs -join "`n") @('<absent/null; optional>') }
                if ($kind -in @('empty','whitespace')) { Assert-Contains ($assessmentFixture.Logs -join "`n") @('<blank; optional>') }
            }
        }
        $checks['classic-completion/created_updated_running_and_202_never_ready [mocked workflow]'] = {
            foreach ($kind in @('missing','null','empty','whitespace','succeeded')) {
                foreach ($status in @('Created','Updated','Running','Completed')) {
                    New-BackendFixture; Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource $kind
                    $assessmentFixture.AssessmentResource.properties.status = $status
                    $http = if ($status -eq 'Completed') { 202 } else { 200 }
                    $assessmentFixture.Responses = @(for ($i = 0; $i -lt 10; $i++) { New-BackendResponse $assessmentFixture.AssessmentResource $http })
                    $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                    Assert-Check ($result.State -eq 'Created' -and $result.Confirmed -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 10)
                    Assert-Contains $result.Message @("Computation status $status", 'optional provisioning', 'completion gate:')
                    if ($http -eq 202) { Assert-Contains $result.Message @('assessment GET is pending') }
                    else { Assert-Contains $result.Message @('computation status is not Completed') }
                    Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Path.Contains('/assessedMachines') -or $_.Method -ne 'GET' }).Count -eq 0)
                }
            }
        }
        $checks['classic-completion/unknown_malformed_status_and_jsonless_202_fail_closed [mocked helper + workflow]'] = {
            foreach ($case in @(@{ Value = 'Unknown' }, @{ Value = 'Failed' }, @{ Value = '' }, @{ Value = $null },
                @{ Value = @('Completed') }, @{ Value = @{ status = 'Completed' } }, @{ Value = 42 })) {
                New-BackendFixture; Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource missing
                $assessmentFixture.AssessmentResource.properties.status = $case.Value
                $response = [pscustomobject]@{ Data = $assessmentFixture.AssessmentResource; Pending = $false; StatusCode = 200 }
                Assert-Throws { Get-LabClassicAssessmentState $response }
                $assessmentFixture.Responses = @((New-BackendResponse $assessmentFixture.AssessmentResource))
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 1)
            }
            New-BackendFixture; $assessmentFixture.Responses = @(for ($i = 0; $i -lt 10; $i++) { New-AssessmentResponse 202 '' })
            $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'Submitted' -and -not $result.Confirmed -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 10)
            Assert-Contains $result.Message @('pending with no resource JSON', 'unverified')
        }
        $checks['classic-completion/explicit_in_progress_metadata_blocks_completed [mocked workflow]'] = {
            foreach ($provisioning in @('Provisioning','Updating','Accepted')) {
                New-BackendFixture; $assessmentFixture.AssessmentResource.properties.provisioningState = $provisioning
                $assessmentFixture.Responses = @(for ($i = 0; $i -lt 10; $i++) { New-BackendResponse $assessmentFixture.AssessmentResource })
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check (-not $result.Ready -and $result.State -eq 'Created' -and $assessmentFixture.Calls.Count -eq 10)
                Assert-Contains $result.Message @('Computation status Completed', "optional provisioning $provisioning", 'completion gate: assessment GET is pending')
                $response = [pscustomobject]@{ Data = $assessmentFixture.AssessmentResource; Pending = $false; StatusCode = 200 }
                $state = Get-LabClassicAssessmentState $response
                Assert-Check (-not $state.Completed -and $state.Gate -eq 'optional provisioning metadata is in progress')
            }
        }
        $checks['classic-completion/negative_metadata_fails_closed_even_while_running [mocked helper + workflow]'] = {
            foreach ($case in (Get-ClassicInvalidProvisioningFixtures)) { foreach ($status in @('Running','Completed')) {
                New-BackendFixture; $assessmentFixture.AssessmentResource.properties.provisioningState = $case.Value
                $assessmentFixture.AssessmentResource.properties.status = $status
                $response = [pscustomobject]@{ Data = $assessmentFixture.AssessmentResource; Pending = $false; StatusCode = 200 }
                Assert-Throws { Get-LabClassicAssessmentState $response }
                $assessmentFixture.Responses = @((New-BackendResponse $assessmentFixture.AssessmentResource))
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 1 -and $assessmentFixture.Sleeps.Count -eq 0)
            } }
        }
        $checks['classic-completion/final_negative_status_or_pending_prevents_handoff [mocked workflow]'] = {
            $cases = @((Get-ClassicInvalidProvisioningFixtures | ForEach-Object { @{ Field = 'provisioningState'; Value = $_.Value; Http = 200 } }))
            $cases += @(@{ Field = 'status'; Value = 'Created'; Http = 200 }, @{ Field = 'status'; Value = 'Updated'; Http = 200 },
                @{ Field = 'status'; Value = 'Running'; Http = 200 }, @{ Field = 'status'; Value = 'Completed'; Http = 202 })
            foreach ($value in @('Provisioning','Updating','Accepted')) { $cases += @{ Field = 'provisioningState'; Value = $value; Http = 200 } }
            foreach ($case in $cases) {
                New-BackendFixture; Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource missing; Set-CompletionResponses
                $final = Copy-Fixture $assessmentFixture.AssessmentResource
                if ($case.Field -eq 'provisioningState') { $final.properties | Add-Member -NotePropertyName provisioningState -NotePropertyValue $case.Value }
                else { $final.properties.($case.Field) = $case.Value }
                $assessmentFixture.Responses[4] = New-BackendResponse $final $case.Http
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready -and $result.Results.Count -eq 0 -and $assessmentFixture.Calls.Count -eq 5)
            }
            New-BackendFixture
            $response = [pscustomobject]@{ Data = $assessmentFixture.AssessmentResource; Pending = $true; StatusCode = 200 }
            Assert-Check (-not (Get-LabClassicAssessmentState $response).Completed)
            Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource missing
            Assert-Check (-not (Get-LabClassicAssessmentState $response).Completed)
        }
        $checks['classic-completion/initial_and_final_optional_normalization_are_identical [mocked workflow + contract]'] = {
            $kinds = @('missing','null','empty','whitespace','succeeded','padded')
            foreach ($first in $kinds) { foreach ($last in $kinds) {
                New-BackendFixture; $final = Copy-Fixture $assessmentFixture.AssessmentResource
                Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource $first
                Set-ClassicProvisioningFixture $final $last; Set-CompletionResponses
                $assessmentFixture.Responses[4] = New-BackendResponse $final
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.State -eq 'ResultsReady' -and $result.Ready -and $result.Results.Count -eq 4 -and $assessmentFixture.Calls.Count -eq 5)
            } }
            $completion = Get-Section $step2 'function Get-LabAssessmentCompletion {' 'function Get-LabAzContext {'
            Assert-Check ([regex]::Matches($completion, 'Get-LabClassicAssessmentState -Response').Count -eq 2)
            Assert-Contains $completion @('if ($state.Completed)', 'if (-not $finalState.Completed)', 'Assert-LabAssessedMachines', 'Assert-LabAssessmentSettings', 'Assert-LabAssessmentMachineMapStable', 'Get-LabAssessmentMembership')
            Assert-Absent $completion @("'provisioningState') -ieq 'Succeeded'", "'provisioningState') -ine 'Succeeded'")
        }
        $checks['classic-completion/optional_metadata_never_bypasses_exact_result_identity_set [mocked workflow]'] = {
            foreach ($kind in @('missing','extra','duplicate-source','duplicate-result','foreign-source','name','foreign-assessment','malformed-id')) {
                New-BackendFixture; Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource missing
                $rows = Copy-Fixture $assessmentFixture.Results
                switch ($kind) {
                    missing { $rows = @($rows[0..2]) }
                    extra { $extra = Copy-Fixture $rows[0]; $extra.id += '-extra'; $rows += $extra }
                    'duplicate-source' { $rows[1].properties.datacenterMachineArmId = $rows[0].properties.datacenterMachineArmId }
                    'duplicate-result' { $rows[1].id = $rows[0].id }
                    'foreign-source' { $rows[0].properties.datacenterMachineArmId += '-other' }
                    name { $rows[0].properties.displayName = 'MigrateAppl' }
                    'foreign-assessment' { $rows[0].id = $rows[0].id.Replace('/assessments/Workshop-Assessment/','/assessments/Foreign-Assessment/') }
                    'malformed-id' { $rows[0].id += '/extra' }
                }
                Set-CompletionResponses; $assessmentFixture.Responses[1] = New-BackendResponse @{ value = @($rows) }
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready -and $result.Results.Count -eq 0 -and $assessmentFixture.Calls.Count -eq 2)
            }
        }
        $checks['classic-completion/optional_metadata_retains_initial_identity_settings_and_count [mocked workflow]'] = {
            foreach ($kind in @('identity','type','settings','count')) {
                New-BackendFixture; Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource missing
                switch ($kind) {
                    identity { $assessmentFixture.AssessmentResource.id += '-foreign' }
                    type { $assessmentFixture.AssessmentResource.type = 'Microsoft.Migrate/assessmentProjects/assessments' }
                    settings { $assessmentFixture.AssessmentResource.properties.azureLocation = 'eastus' }
                    count { $assessmentFixture.AssessmentResource.properties.numberOfMachines = 3 }
                }
                Set-CompletionResponses
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready -and $assessmentFixture.Calls.Count -eq 1)
            }
        }
        $checks['classic-completion/optional_metadata_retains_final_scope_settings_membership_and_timestamp [mocked workflow]'] = {
            foreach ($kind in @('identity','settings','count','timestamp','group-busy','group-count','membership','mapping','source-conflict')) {
                New-BackendFixture; Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource whitespace
                $final = Copy-Fixture $assessmentFixture.AssessmentResource
                switch ($kind) {
                    identity { $final.id += '-foreign' }
                    settings { $final.properties.azureLocation = 'eastus' }
                    count { $final.properties.numberOfMachines = 3 }
                    timestamp { $final.properties.updatedTimestamp = '2026-10-08T00:00:00Z' }
                    'group-busy' { $assessmentFixture.GroupFull.properties.areAssessmentsRunning = $true }
                    'group-count' { $assessmentFixture.GroupFull.properties.machineCount = 3 }
                    membership { $assessmentFixture.Members[0].properties.groups = @() }
                    mapping { $assessmentFixture.Members[0].id += '-changed' }
                    'source-conflict' { $assessmentFixture.Members[1].properties.discoveryMachineArmId = $assessmentFixture.Members[0].properties.discoveryMachineArmId }
                }
                Set-CompletionResponses; $assessmentFixture.Responses[4] = New-BackendResponse $final
                $result = Get-LabAssessmentCompletion (New-CompletionCreation) $assessmentFixture.Workloads $assessmentFixture.Session
                Assert-Check ($result.State -eq 'ReadFailed' -and -not $result.Ready -and $result.Results.Count -eq 0)
                Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            }
        }
        $checks['classic-completion/rerun_reuses_matching_names_without_put_or_recompute [mocked workflow]'] = {
            New-BackendFixture; Set-ClassicProvisioningFixture $assessmentFixture.AssessmentResource missing
            $groupName = 'Workshop-Servers-Classic-97fd21f6'; $assessmentName = 'Workshop-Assessment-Classic-97fd21f6'
            $oldAssessmentId = $assessmentFixture.Assessment.Split('?')[0]
            $assessmentFixture.Group = $assessmentFixture.Group.Replace('AllServers-Group', $groupName)
            $assessmentFixture.Assessment = $assessmentFixture.Group.Replace('?api-version=', ('/assessments/' + $assessmentName + '?api-version='))
            $assessmentFixture.GroupEmpty.id = $assessmentFixture.Group.Split('?')[0]; $assessmentFixture.GroupFull.id = $assessmentFixture.Group.Split('?')[0]
            foreach ($member in $assessmentFixture.Members) { $member.properties.groups = @($assessmentFixture.Group.Split('?')[0]) }
            $assessmentFixture.AssessmentResource.id = $assessmentFixture.Assessment.Split('?')[0]
            foreach ($row in $assessmentFixture.Results) { $row.id = $row.id.Replace($oldAssessmentId, $assessmentFixture.AssessmentResource.id) }
            Set-BackendResponses -Existing -Reuse
            $creation = Invoke-LabAssessmentCreation -MigrateProjectName fictional-project -ProjectName '' -GroupName $groupName -AssessmentName $assessmentName -Workloads $assessmentFixture.Workloads -Settings $assessmentFixture.Settings -Session $assessmentFixture.Session -Mode Classic
            Assert-Check ($creation.State -eq 'Submitted' -and $assessmentFixture.Calls.Count -eq 8)
            Assert-Check ($creation.GroupPath -ceq $assessmentFixture.Group -and $creation.AssessmentPath -ceq $assessmentFixture.Assessment)
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
            Assert-Contains ($assessmentFixture.Logs -join "`n") @('matching existing', 'No overwrite/recompute PUT')
            $assessmentFixture.Calls = @(); Set-CompletionResponses
            $result = Get-LabAssessmentCompletion $creation $assessmentFixture.Workloads $assessmentFixture.Session
            Assert-Check ($result.State -eq 'ResultsReady' -and $result.Ready -and $result.Results.Count -eq 4 -and $assessmentFixture.Calls.Count -eq 5)
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -ne 'GET' }).Count -eq 0)
        }
        $checks['classic/service_schema_failure_never_falls_back_to_modern [mocked workflow]'] = {
            New-BackendFixture; Set-BackendResponses; $assessmentFixture.Responses[12] = New-AssessmentResponse 400 '{"error":{"code":"MalformedRequestBody"}}'
            $result = Invoke-BackendCreation
            Assert-Check ($result.State -eq 'Failed' -and $result.Mode -eq 'Classic' -and $result.Stage -eq 'Assessment PUT' -and $assessmentFixture.Calls.Count -eq 13)
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Path.Contains('2024-03-03-preview') }).Count -eq 0)
            Assert-Check (@($assessmentFixture.Calls | Where-Object { $_.Method -eq 'PUT' -and $_.Path.Contains('/assessments/') }).Count -eq 1)
        }
        # Step 6 contracts and native AST fixtures stay offline: never run its Azure writes.
        $step6Path = Join-Path $Root 'scripts/migrate-step6-post-migration.ps1'
        $step6Source = [IO.File]::ReadAllText($step6Path)
        $section3Start = $step6Source.IndexOf('# A failed/invalid public-IP lookup')
        $section3End = $step6Source.IndexOf('Wait-ForSection "Section 4: Enable Microsoft Defender for Cloud"')
        Assert-Check ($section3Start -ge 0 -and $section3End -gt $section3Start) 'Missing Step 6 NSG section markers'
        $step6Section = $step6Source.Substring($section3Start, $section3End - $section3Start)
        $preflightStart = $step6Section.IndexOf('# Read-only preflight of ALL four roles')
        $preflightEnd = $step6Section.IndexOf('# Exact inbound application edges')
        Assert-Check ($preflightStart -ge 0 -and $preflightEnd -gt $preflightStart) 'Missing read-only NSG preflight markers'
        $step6Preflight = $step6Section.Substring($preflightStart, $preflightEnd - $preflightStart)
        $step6Errors = $null
        $step6Ast = [System.Management.Automation.Language.Parser]::ParseInput($step6Section, [ref]$null, [ref]$step6Errors)
        Assert-Check (@($step6Errors).Count -eq 0) 'Step 6 hardening failed native AST parsing'
        $step6RuleAssignments = @($step6Ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$nsgRules'
        }, $true))
        Assert-Check ($step6RuleAssignments.Count -eq 1) 'Expected one Step 6 role rule table'
        # This table may contain only literal containers and the two fixture variables.
        $safeRuleAstTypes = @('StatementBlockAst', 'PipelineAst', 'CommandExpressionAst', 'HashtableAst',
            'StringConstantExpressionAst', 'ConstantExpressionAst', 'ArrayExpressionAst', 'ArrayLiteralAst', 'ParenExpressionAst',
            'BinaryExpressionAst', 'IndexExpressionAst', 'VariableExpressionAst')
        foreach ($node in $step6RuleAssignments[0].Right.FindAll({ param($n) $true }, $true)) {
            Assert-Check ($node.GetType().Name -in $safeRuleAstTypes) "Unapproved AST node in offline NSG table: $($node.GetType().Name)"
            if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
                Assert-Check ($node.VariablePath.UserPath -in @('vmIPs', 'myPublicIp')) 'NSG table references a non-fixture variable'
            }
        }
        function Get-Step6RuleFixture {
            $vmIPs = @{ 'OnPrem-Web' = '10.71.4.11'; 'OnPrem-SQL' = '10.71.4.12';
                'OnPrem-Linux-Web' = '10.71.4.13'; 'OnPrem-Linux-App' = '10.71.4.14' }
            $myPublicIp = '203.0.113.10/32'
            . ([scriptblock]::Create($step6RuleAssignments[0].Extent.Text))
            return $nsgRules
        }
        $checks['step6/exact_five_application_edges [native AST rule fixture]'] = {
            $rules = Get-Step6RuleFixture
            $expected = @(
                @('OnPrem-SQL', 'Allow-SQL-From-Web', '1433', '10.71.4.11/32'),
                @('OnPrem-SQL', 'Allow-SQL-From-Linux-App', '1433', '10.71.4.14/32'),
                @('OnPrem-Linux-App', 'Allow-API-From-Web', '3000', '10.71.4.11/32'),
                @('OnPrem-Linux-App', 'Allow-API-From-Nginx', '3000', '10.71.4.13/32'),
                @('OnPrem-Linux-Web', 'Allow-8080-From-Linux-App', '8080', '10.71.4.14/32'))
            $edgeCount = 0
            foreach ($role in $rules.Keys) { $edgeCount += @($rules[$role] | Where-Object { $_.Port -in @('1433', '3000', '8080') }).Count }
            Assert-Check ($rules.Count -eq 4 -and $edgeCount -eq 5) 'Application matrix must contain exactly four roles/five approved edges'
            foreach ($edge in $expected) {
                $actual = @($rules[$edge[0]] | Where-Object { $_.Name -ceq $edge[1] })
                Assert-Check ($actual.Count -eq 1 -and $actual[0].Port -ceq $edge[2] -and $actual[0].Source -ceq $edge[3]) "Incorrect approved edge: $($edge -join ' ')"
            }
        }
        $checks['step6/dynamic_target32_destinations_deny4000_public_http_preserved [AST fixture + source contract]'] = {
            $rules = Get-Step6RuleFixture
            foreach ($role in $required) {
                $deny = @($rules[$role] | Where-Object { $_.Name -ceq 'Deny-All' })
                Assert-Check ($deny.Count -eq 1 -and $deny[0].Access -ceq 'Deny' -and $deny[0].Priority -eq 4000 -and $deny[0].Port -ceq '*')
                Assert-Check (@($rules[$role] | Group-Object Priority | Where-Object { $_.Count -gt 1 }).Count -eq 0) 'Duplicate managed priority'
                foreach ($rule in @($rules[$role] | Where-Object { $_.Port -in @('1433', '3000', '8080') })) {
                    Assert-Check ($rule.Source -match '^10\.71\.4\.(11|13|14)/32$') 'Application source must be a verified peer /32'
                }
            }
            foreach ($role in @('OnPrem-Web', 'OnPrem-Linux-Web')) {
                foreach ($port in @('80', '443')) {
                    $http = @($rules[$role] | Where-Object { $_.Port -ceq $port })
                    Assert-Check ($http.Count -eq 1 -and $http[0].Source -ceq '*') 'Existing public HTTP/HTTPS policy changed'
                }
            }
            Assert-Contains $step6Section @('$destinationAddr = $vmIPs[$vmName] + "/32"', '-DestinationAddressPrefix $destinationAddr', '-SourceAddressPrefix $rule.Source')
            Assert-Absent $step6Section @('-DestinationAddressPrefix "*"', 'Source = "VirtualNetwork"', 'Source = "192.168.0.')
        }
        $checks['step6/missing_ip_fails_closed_public_lookup_never_wildcard [source contract]'] = {
            Assert-Contains $step6Section @('[string]::IsNullOrWhiteSpace($privateIP)', '[Net.IPAddress]::TryParse($privateIP, [ref]$parsedPrivateIp)',
                '$parsedPrivateIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork', '$seenPrivateIPs.ContainsKey($privateIP)',
                'Application allows cannot use a wildcard fallback.', '$myPublicIp = $null',
                '[Net.IPAddress]::TryParse($candidate, [ref]$parsedPublicIp)', '$myPublicIp = $candidate + "/32"',
                'Lab RDP/SSH allows will be omitted', '$_.Name -notin @(''Allow-RDP'', ''Allow-SSH'') -or $myPublicIp',
                '[string]::IsNullOrWhiteSpace([string]$rule.Source)')
            Assert-Absent $step6Section @('$myPublicIp = "*"', '$sourceAddr = if', 'else { "*" }')
            Assert-Before $step6Section 'Application allows cannot use a wildcard fallback.' 'New-AzNetworkSecurityGroup'
        }
        $checks['step6/unique_role_nic_primary_ipv4_same_vnet_before_writes [native AST + source contract]'] = {
            Assert-Contains $step6Preflight @('$vms.Count -ne 1', '$vms[0].Name -ine $vmName', '$seenVmIds.ContainsKey($vm.Id)',
                '$Matches.Subscription -ine $subscriptionId', '$Matches.ResourceGroup -ine $TargetResourceGroup',
                '$vm.StorageProfile.OsDisk.OsType -ine $expectedOS', '$nicRefs.Count -ne 1', '$seenNicIds.ContainsKey($nicId)',
                '$nics.Count -ne 1', '$nics[0].VirtualMachine.Id -ine $vm.Id', '$_.Primary -eq $true',
                '$primaryConfigs.Count -ne 1', '$ipConfig.PrivateIpAddress', '$ipConfig.Subnet.Id', '$commonVNetId -ine $vnetId')
            Assert-Absent $step6Preflight @('IpConfigurations[0].PrivateIpAddress', '-ResourceGroupName $TargetResourceGroup |')
            $preflightErrors = $null
            $preflightAst = [System.Management.Automation.Language.Parser]::ParseInput($step6Preflight, [ref]$null, [ref]$preflightErrors)
            Assert-Check (@($preflightErrors).Count -eq 0)
            foreach ($command in $preflightAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                Assert-Check ($command.InvocationOperator -eq 'Unknown' -and $command.GetCommandName() -in
                    @('Get-AzNetworkInterface', 'Get-AzNetworkSecurityGroup', 'Where-Object', 'ForEach-Object', 'Write-StepInfo')) 'Preflight contains a write/unknown command'
            }
            Assert-Before $step6Section '$commonVNetId -ine $vnetId' 'New-AzNetworkSecurityGroup'
        }
        $checks['step6/shared_nsg_rejected_resource_id_rg_and_dedicated_scope [source contract]'] = {
            Assert-Contains $step6Preflight @('$seenNsgIds.ContainsKey($nsgId)', 'Attach a separate NIC NSG to each lab role',
                '$nsgId = [string]$nic.NetworkSecurityGroup.Id', '$nsgResourceGroup = $Matches.ResourceGroup', '$nsgName = $Matches.Name',
                'Get-AzNetworkSecurityGroup -ResourceGroupName $nsgResourceGroup -Name $nsgName -ErrorAction Stop',
                '$attachedNicIds.Count -ne 1', '$attachedNicIds[0] -ine $nicId', '$attachedSubnets.Count -ne 0',
                'shared/subnet policy is not modified', 'already exists but is not attached')
            Assert-Absent $step6Section @('Get-AzNetworkSecurityGroup -ResourceGroupName $TargetResourceGroup', 'Set-AzVirtualNetwork', 'Set-AzRouteTable')
            Assert-Before $step6Section '$seenNsgIds.ContainsKey($nsgId)' 'Remove-AzNetworkSecurityRuleConfig'
        }
        $checks['step6/unrelated_rules_preserved_conflicts_and_failures_do_not_claim_complete [source contract]'] = {
            Assert-Contains $step6Section @('$managedSpecs[''Allow-SQL-From-VNet'']', '$managedSpecs[''Allow-API-From-VNet'']',
                '$managedSpecs.ContainsKey($existingRule.Name)', '$existingRule.Direction -ine ''Inbound''', '$existingRule.Priority -ne $spec.Priority',
                '$existingRule.DestinationPortRange -ne $spec.Port', 'is not a recognized lab-rule shape; preserved',
                '$existingRule.Priority -in @($nsgRules[$vmName]', 'conflicts with a required inbound priority. Preserved',
                '$_.Name -in $managedRuleNames[$vmName]', 'Remove-AzNetworkSecurityRuleConfig -Name $existingRule.Name -ErrorAction Stop',
                'Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg -ErrorAction Stop',
                'throw "NSG hardening is incomplete;', 'no completion summary will be shown')
            Assert-Absent $step6Section @('$customRules', 'Priority -lt 65000', 'Remove existing custom rules to start clean')
            Assert-Before $step6Section 'conflicts with a required inbound priority. Preserved' 'New-AzNetworkSecurityGroup'
            Assert-Before $step6Section 'Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg -ErrorAction Stop' 'Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction Stop'
        }
        $checks['postmigration/traffic_script_exists_and_parses [native AST]'] = {
            $path = Join-Path $Root 'scripts/post-migration-labtraffic.ps1'
            Assert-Check (Test-Path -LiteralPath $path -PathType Leaf) 'Missing separate post-migration traffic script'
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            Assert-Check ($null -ne $ast -and @($errors).Count -eq 0) 'Post-migration traffic script failed native AST parsing'
            Assert-Check ([string]::IsNullOrEmpty((Test-LabEncoding -Path $path))) 'Post-migration traffic script encoding is unsafe for PS5.1'
        }
        $failures = 0
        foreach ($name in $checks.Keys) {
            try { $null = & $checks[$name]; Microsoft.PowerShell.Utility\Write-Host "  PASS  $name" -ForegroundColor Green }
            catch { $failures++; Microsoft.PowerShell.Utility\Write-Host "  FAIL  $name : $($_.Exception.Message)" -ForegroundColor Red }
        }
        Microsoft.PowerShell.Utility\Write-Host "Offline regression checks: $($checks.Count - $failures)/$($checks.Count) passed (12 regional, 5 guidance, 25 readiness/traffic, 3 Ubuntu/Jakarta, 2 discovery, 14 communication, 18 retained assessment, 22 backend/correct-contract, 16 provider-metadata/endpoint-plan, 22 Modern-profile, 12 Classic-restoration, 11 Classic-completion, 7 Step6/post-migration NSG/AST). No Azure actions executed."
        return $failures
    } $Root
}

function Get-LabPackageFiles {
    param([string]$Root)
    $prefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $map = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $name = $file.FullName.Substring($prefix.Length).Replace('\', '/')
        if ($name -eq 'SHA256SUMS' -or $name -match '(^|/)(?:__pycache__|\.static-work|\.git)(/|$)' -or $name.EndsWith('.pyc')) { continue }
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Package inputs must not be links: $name" }
        $parent = $file.Directory
        while ($parent -and $parent.FullName -ne $Root) {
            if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Package inputs must not traverse links: $name" }
            $parent = $parent.Parent
        }
        $map[$name] = $file.FullName
    }
    [string[]]$names = @($map.Keys); [array]::Sort($names, [StringComparer]::Ordinal)
    foreach ($name in $names) { [pscustomobject]@{ Name = $name; FullName = $map[$name] } }
}

function Get-LabStreamSha256 {
    param([IO.Stream]$Stream)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-LabZipCrcMap {
    param([string]$ArchivePath)
    $stream = [IO.File]::OpenRead($ArchivePath); $reader = [IO.BinaryReader]::new($stream)
    try {
        $length = [int][Math]::Min(65557, $stream.Length)
        $stream.Position = $stream.Length - $length; $tail = $reader.ReadBytes($length); $end = -1
        for ($i = $tail.Length - 22; $i -ge 0; $i--) {
            if ([BitConverter]::ToUInt32($tail, $i) -eq 101010256 -and
                $i + 22 + [BitConverter]::ToUInt16($tail, $i + 20) -eq $tail.Length) { $end = $i; break }
        }
        if ($end -lt 0) { throw 'ZIP end-of-central-directory record is missing.' }
        $count = [BitConverter]::ToUInt16($tail, $end + 10)
        $offset = [BitConverter]::ToUInt32($tail, $end + 16)
        if ($count -eq 65535 -or $offset -eq [uint32]::MaxValue -or
            [BitConverter]::ToUInt16($tail, $end + 4) -ne 0 -or [BitConverter]::ToUInt16($tail, $end + 6) -ne 0) {
            throw 'ZIP64 or split archives are not supported by this lab packager.'
        }
        $stream.Position = $offset; $map = @{}
        for ($i = 0; $i -lt $count; $i++) {
            $header = $reader.ReadBytes(46)
            if ($header.Length -ne 46 -or [BitConverter]::ToUInt32($header, 0) -ne 33639248 -or $header[5] -ne 3) { throw 'Invalid ZIP central directory or UNIX creator mode.' }
            $nameLength = [BitConverter]::ToUInt16($header, 28); $extraLength = [BitConverter]::ToUInt16($header, 30); $commentLength = [BitConverter]::ToUInt16($header, 32)
            $name = [Text.Encoding]::UTF8.GetString($reader.ReadBytes($nameLength))
            if ($map.ContainsKey($name)) { throw "Duplicate ZIP entry: $name" }
            $map[$name] = [BitConverter]::ToUInt32($header, 16)
            $stream.Position += $extraLength + $commentLength
        }
        return $map
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Set-LabZipUnixPlatform {
    param([string]$ArchivePath)
    # ZipArchive on Windows stamps DOS as creator; retain the original UNIX mode semantics.
    $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $reader = [IO.BinaryReader]::new($stream, [Text.Encoding]::UTF8, $true)
    try {
        $stream.Position = $stream.Length - 22; $end = $reader.ReadBytes(22)
        if ([BitConverter]::ToUInt32($end, 0) -ne 101010256 -or [BitConverter]::ToUInt16($end, 20) -ne 0) { throw 'Unexpected ZIP footer while setting UNIX modes.' }
        $count = [BitConverter]::ToUInt16($end, 10); $stream.Position = [BitConverter]::ToUInt32($end, 16)
        for ($i = 0; $i -lt $count; $i++) {
            $position = $stream.Position; $header = $reader.ReadBytes(46)
            if ($header.Length -ne 46 -or [BitConverter]::ToUInt32($header, 0) -ne 33639248) { throw 'Invalid ZIP central directory while setting UNIX modes.' }
            $next = $position + 46 + [BitConverter]::ToUInt16($header, 28) + [BitConverter]::ToUInt16($header, 30) + [BitConverter]::ToUInt16($header, 32)
            $stream.Position = $position + 5; $stream.WriteByte(3); $stream.Position = $next
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Test-LabPackageArchive {
    param([string]$ArchivePath, [object[]]$Inputs, [hashtable]$Digests, [string]$Manifest)
    $crcMap = Get-LabZipCrcMap $ArchivePath
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -ne $Inputs.Count + 1 -or $crcMap.Count -ne $archive.Entries.Count) { throw 'ZIP inventory mismatch.' }
        $table = New-Object 'long[]' 256
        for ($i = 0; $i -lt 256; $i++) {
            $value = [long]$i
            for ($bit = 0; $bit -lt 8; $bit++) {
                if (($value -band 1) -ne 0) { $value = ($value -shr 1) -bxor 3988292384L } else { $value = $value -shr 1 }
            }
            $table[$i] = $value
        }
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            if (-not $Digests.ContainsKey($name)) { throw "Unexpected ZIP entry: $name" }
            if ($entry.LastWriteTime.DateTime -ne [datetime]'1980-01-01T00:00:00') { throw "ZIP timestamp mismatch: $name" }
            $expectedMode = if ($name.EndsWith('.sh')) { 33261 } else { 33188 }
            if ($entry.ExternalAttributes -ne ($expectedMode -shl 16)) { throw "ZIP UNIX mode mismatch: $name" }
            $stream = $entry.Open()
            try { $actual = Get-LabStreamSha256 $stream } finally { $stream.Dispose() }
            if ($actual -cne $Digests[$name]) { throw "ZIP SHA256 mismatch: $name" }
            $stream = $entry.Open(); $crc = 4294967295L; $buffer = New-Object byte[] 65536
            try {
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    for ($i = 0; $i -lt $read; $i++) { $crc = ($crc -shr 8) -bxor $table[($crc -bxor [long]$buffer[$i]) -band 255] }
                }
            } finally { $stream.Dispose() }
            $crc = $crc -bxor 4294967295L
            if ($crc -ne $crcMap[$name]) { throw "ZIP CRC mismatch: $name" }
        }
        $reader = [IO.StreamReader]::new($archive.GetEntry('SHA256SUMS').Open(), [Text.Encoding]::UTF8)
        try { if ($reader.ReadToEnd() -cne $Manifest) { throw 'ZIP checksum manifest mismatch.' } } finally { $reader.Dispose() }
    } finally { $archive.Dispose() }
}

function Publish-LabPackage {
    param([string]$Root, [string]$Destination, [switch]$Overwrite, [switch]$ChecksumsOnly)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $prefix = $rootPath + [IO.Path]::DirectorySeparatorChar
    $target = $null; $pending = $null
    if (-not $ChecksumsOnly) {
        if ([string]::IsNullOrWhiteSpace($Destination)) { throw 'PackagePath must name an external .zip destination.' }
        $target = [IO.Path]::GetFullPath($Destination)
        if ($target.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Place the delivery ZIP outside the checkout.' }
        if ([IO.Path]::GetExtension($target) -ine '.zip') { throw 'PackagePath must end in .zip.' }
        if (Test-Path -LiteralPath $target) {
            if (-not $Overwrite -or -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'Destination exists; use -OverwritePackage only for an intended existing ZIP file.' }
        }
        $parent = [IO.Path]::GetDirectoryName($target)
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Create the external destination folder before packaging.' }
        $directory = Get-Item -LiteralPath $parent
        while ($directory) {
            if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Package destination must not traverse directory links.' }
            $directory = $directory.Parent
        }
        $pending = Join-Path $parent ('.lab-package-' + [guid]::NewGuid().ToString('N') + '.zip')
    }
    $inputs = @(Get-LabPackageFiles $rootPath)
    if ($inputs.Count -ge 65534) { throw 'Too many files for the lab packager.' }
    $runtime = Join-Path $rootPath 'apps/contoso-orderdesk/dist/runtime.zip'
    $expectedRuntime = [IO.File]::ReadAllText((Join-Path $rootPath 'apps/contoso-orderdesk/dist/runtime.sha256')).Trim()
    if ($expectedRuntime -notmatch '^[0-9a-fA-F]{64}$' -or (Get-FileHash -LiteralPath $runtime -Algorithm SHA256).Hash -ine $expectedRuntime) { throw 'Prebuilt runtime SHA256 mismatch; packaging does not rebuild application assets.' }
    $digests = @{}; $lines = New-Object Text.StringBuilder
    foreach ($inputFile in $inputs) {
        $digest = (Get-FileHash -LiteralPath $inputFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $digests[$inputFile.Name] = $digest; $null = $lines.Append($digest + '  ' + $inputFile.Name + "`n")
    }
    $manifest = $lines.ToString(); $utf8 = [Text.UTF8Encoding]::new($false)
    $manifestBytes = $utf8.GetBytes($manifest); $memory = [IO.MemoryStream]::new([byte[]]$manifestBytes, $false)
    try { $digests['SHA256SUMS'] = Get-LabStreamSha256 $memory } finally { $memory.Dispose() }
    $manifestPath = Join-Path $rootPath 'SHA256SUMS'
    if ($ChecksumsOnly) {
        [IO.File]::WriteAllText($manifestPath, $manifest, $utf8)
        Write-Host "Updated SHA256SUMS for $($inputs.Count) files (application assets not rebuilt)."
        return
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $stream = [IO.File]::Open($pending, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            [string[]]$names = @($digests.Keys); [array]::Sort($names, [StringComparer]::Ordinal)
            $paths = @{}; foreach ($inputFile in $inputs) { $paths[$inputFile.Name] = $inputFile.FullName }
            foreach ($name in $names) {
                $entry = $archive.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $mode = if ($name.EndsWith('.sh')) { 33261 } else { 33188 }
                $entry.ExternalAttributes = [int]($mode -shl 16)
                $output = $entry.Open()
                try {
                    if ($name -eq 'SHA256SUMS') { $output.Write($manifestBytes, 0, $manifestBytes.Length) }
                    else { $source = [IO.File]::OpenRead($paths[$name]); try { $source.CopyTo($output) } finally { $source.Dispose() } }
                } finally { $output.Dispose() }
            }
        } finally { $archive.Dispose(); $stream.Dispose() }
        if ((Get-Item -LiteralPath $pending).Length -ge [uint32]::MaxValue) { throw 'The lab packager does not support ZIP64 archives.' }
        Set-LabZipUnixPlatform $pending
        Test-LabPackageArchive $pending $inputs $digests $manifest
        # Do not touch the selected destination until archive readback succeeds.
        if (Test-Path -LiteralPath $target) {
            if (-not $Overwrite) { throw 'Destination appeared during packaging; no overwrite was requested.' }
            [IO.File]::Replace($pending, $target, $null)
        } else { [IO.File]::Move($pending, $target) }
        [IO.File]::WriteAllText($manifestPath, $manifest, $utf8)
        Write-Host "Complete checkout ZIP CRC/per-file SHA256 verified: $target ($($inputs.Count + 1) files)"
        Write-Host ('ZIP SHA256: ' + (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant())
    } finally { if ($pending -and (Test-Path -LiteralPath $pending)) { Remove-Item -LiteralPath $pending -Force } }
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

if ($totalErrors -eq 0 -and $wantsMaintenance) {
    try {
        $totalErrors += Invoke-LabOfflineRegression -Root $checkoutRoot
        if ($totalErrors -eq 0 -and ($wantsPackage -or $UpdateChecksums)) {
            Publish-LabPackage -Root $checkoutRoot -Destination $PackagePath -Overwrite:$OverwritePackage -ChecksumsOnly:(-not $wantsPackage)
        }
    } catch {
        $totalErrors++
        Write-Host ('Maintenance failed: ' + $_.Exception.Message) -ForegroundColor Red
    }
}
if ($totalErrors -gt 0) { Write-Host 'Validation/maintenance failed; review the reported error. Parser/regression failures block packaging writes.' -ForegroundColor Red }
if (-not $wantsMaintenance -and $env:LAB_NO_PAUSE -ne '1' -and [Environment]::UserInteractive) {
    $null = Read-Host 'Press Enter to close this window'
}
if ($totalErrors -gt 0) { exit 1 }
exit 0
