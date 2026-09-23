<#
.SYNOPSIS
    Bridge the lab to the end state of Module 3 (stateful workloads).

.DESCRIPTION
    This is a STATE-BRIDGING script, not a teaching script. It performs the
    same lab actions a student performs by hand in Module 3, in one run, for
    that module's two workloads only:

      - OnPrem-SQL       (Windows Server + SQL Server Express)
      - OnPrem-Linux-App (Ubuntu + Node.js API)

    It runs three existing scripts in order, each narrowed with -Workload AgentBased:

      1. migrate-step3-replicate.ps1     -- enable replication
      2. migrate-step4-test-migrate.ps1  -- test migrate, validate, clean up
      3. migrate-step5-cutover.ps1       -- cut over to Azure

    The migration logic is NOT duplicated here. This script only sequences
    those three with a consistent workload filter, so there is one command
    per module.

    WHO THIS IS FOR

    - Instructors who need the lab to match the module a student is on, so
      they can troubleshoot from the same state.
    - Students who had to delete a project for time or quota reasons and need
      to return to a known state without redoing every manual step.

    WHEN TO RUN IT

    Modules 2 and 3 are PARALLEL branches off Module 1 -- Module 3's
    prerequisites list Module 1, not Module 2. Run only the branch you need:

    - Did Module 2 by hand, need Module 3's end state?  Run step3b only.
    - Need both branches complete (Module 5 ready)?     Run step3a then step3b.

    PREREQUISITES

    - migrate-step1-setup-project.ps1 and migrate-step2-discover-assess.ps1
      completed: the project exists and all four VMs are discovered.
    - Connected to Azure (Connect-AzAccount). These scripts read the
      subscription from Get-AzContext; there is no -SubscriptionId parameter.

    IMPORTANT -- METHOD DIFFERS FROM THE MODULE

    Module 3 teaches AGENT-BASED migration: deploy a replication appliance,
    install the Mobility Service into each guest, then replicate. This script
    reaches the same END STATE using the AGENTLESS path, because that is what
    migrate-step3-replicate.ps1 implements.

    That difference matters depending on why you are running this:

    - Bypassing Module 3 to reach Module 5? Fine. Module 5 only needs the four
      VMs migrated and running in Azure, which this delivers.
    - Reproducing a student's Mobility Service or replication appliance
      problem? This will NOT reproduce it. No replication appliance is
      deployed and no Mobility Service is installed. Troubleshoot those
      against the student's own environment, following Module 3 sections 5-7.

    WHAT THIS DOES NOT DO

    It does not replace reading Module 3. Cutover shuts the source VMs down on
    the Hyper-V host, so running this forecloses doing Module 3 by hand
    afterwards -- the work is already done.

.PARAMETER SourceResourceGroup
    Resource group holding the Hyper-V host and the nested VMs. Prompted when not supplied.

.PARAMETER TargetResourceGroup
    Resource group the migrated VMs land in.

.PARAMETER MigrateProjectName
    The Azure Migrate project created by step 1.

.PARAMETER Location
    Azure region. Must match the region used in step 1. Prompted when not supplied.

.PARAMETER SkipTestMigration
    Skip the test-migration stage (step 4). Test migration is a safety net and
    is pedagogically important, so it runs by default. Skipping it shortens the
    run and avoids creating temporary test VMs, which can matter on a
    restricted training subscription -- but it also skips the validation that
    would catch a bad replica before cutover.

.EXAMPLE
    .\migrate-step3b-agent-based.ps1

.EXAMPLE
    .\migrate-step3b-agent-based.ps1 -SkipTestMigration

.NOTES
    Reaches Module 3's END STATE. It does so AGENTLESSLY, not agent-based -- see the note above.
#>

param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [string]$MigrateProjectName,

    [string]$Location,

    [Parameter(Mandatory = $false)]
    [switch]$SkipTestMigration
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Every value is entered once here (no silent defaults) and passed to each stage, so the
# stages do not prompt again. The current Azure sign-in is used; only the first five
# characters of the subscription ID are shown.
# region Lab helpers (self-contained: this script needs no other file to run)
# Prompts for every value not passed on the command line, uses the current Azure sign-in,
# checks the step's resources exist in that subscription, and shows only the first five
# characters of the subscription (and tenant) ID in all console output.
$script:LabMaskedValues = @()

function Format-LabSubscriptionId {
    param([AllowNull()][AllowEmptyString()][string]$SubscriptionId)
    # Show only the first five characters: enough to tell whether you are signed in to the
    # right subscription, not enough to identify it from a screenshot or recording.
    if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { return '(none)' }
    $value = $SubscriptionId.Trim()
    if ($value.Length -le 5) { return '*****' }
    return ($value.Substring(0, 5) + '***-****-****-****-************')
}

function Protect-LabText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $result = $Text
    foreach ($secret in $script:LabMaskedValues) {
        if (-not [string]::IsNullOrWhiteSpace($secret)) {
            $result = [regex]::Replace($result, [regex]::Escape($secret), (Format-LabSubscriptionId $secret),
                [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }
    # Any other subscription GUID that appears in a resource ID or error message.
    $result = [regex]::Replace($result, '(?i)(/subscriptions/)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})',
        { param($m) $m.Groups[1].Value + (Format-LabSubscriptionId $m.Groups[2].Value) })
    return $result
}

function Protect-LabObject {
    param([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string]) { return Protect-LabText $InputObject }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        return @(foreach ($item in $InputObject) { if ($null -eq $item) { $null } else { Protect-LabText ([string]$item) } })
    }
    return Protect-LabText ([string]$InputObject)
}

# Console proxies. They shadow the built-in cmdlets for the calling script only and pass
# every message through Protect-LabText before it reaches the screen.
function Write-Host {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)]
        [AllowNull()][object]$Object,
        [switch]$NoNewline,
        [object]$Separator,
        [ConsoleColor]$ForegroundColor,
        [ConsoleColor]$BackgroundColor
    )
    process {
        if ($PSBoundParameters.ContainsKey('Object')) { $PSBoundParameters['Object'] = Protect-LabObject $Object }
        Microsoft.PowerShell.Utility\Write-Host @PSBoundParameters
    }
}

function Write-Warning {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)][AllowEmptyString()][string]$Message)
    process { Microsoft.PowerShell.Utility\Write-Warning -Message (Protect-LabText $Message) }
}

function Write-LabTerminatingError {
    # Used by each script's trap so an unhandled Azure error is shown masked, then the script stops.
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    $text = ($ErrorRecord | Out-String).Trim()
    Microsoft.PowerShell.Utility\Write-Host ''
    Microsoft.PowerShell.Utility\Write-Host (Protect-LabText $text) -ForegroundColor Red
}

function Read-LabParameter {
    <#
      Returns $Value when it was supplied; otherwise prompts until a valid entry is typed.
      The example is shown as a hint only -- pressing Enter never accepts it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][AllowEmptyString()][string]$Value,
        [string]$Example,
        [ValidateSet('Text', 'ResourceGroup', 'Region', 'ProjectName', 'VMName', 'Cidr', 'Time24h', 'TimeZone', 'Url', 'Sha256', 'Generation', 'Currency', 'OfferCode', 'Workload')]
        [string]$Kind = 'Text'
    )
    $supplied = -not [string]::IsNullOrWhiteSpace($Value)
    while ($true) {
        if ($supplied) {
            $entry = $Value.Trim()
        } else {
            $hint = if ($Example) { " (example: $Example)" } else { '' }
            $entry = Read-Host "$Prompt$hint"
            if ($null -ne $entry) { $entry = $entry.Trim() }
            if ([string]::IsNullOrWhiteSpace($entry)) {
                Microsoft.PowerShell.Utility\Write-Host "  A value for $Name is required." -ForegroundColor Yellow
                continue
            }
        }
        $problem = Test-LabParameterValue -Kind $Kind -Value $entry
        if (-not $problem) { return $entry }
        if ($supplied) { throw "-$Name '$entry' is not valid: $problem" }
        Microsoft.PowerShell.Utility\Write-Host "  $problem" -ForegroundColor Yellow
    }
}

function Test-LabParameterValue {
    param([string]$Kind, [string]$Value)
    switch ($Kind) {
        'ResourceGroup' {
            if ($Value -notmatch '^[\p{L}\p{M}\p{N}_.()-]{1,90}$' -or $Value.EndsWith('.')) {
                return 'Enter one exact resource group name, without wildcards, spaces or a resource ID.'
            }
        }
        'Region' {
            if ($Value -notmatch '^[a-z][a-z0-9]{2,39}$') { return 'Enter an Azure region name in lower case without spaces, such as the one chosen in Module 0.' }
        }
        'ProjectName' {
            if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{1,62}$') { return 'Use 2-63 letters, digits, hyphens or underscores, starting with a letter or digit.' }
        }
        'VMName' {
            if ($Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$') { return 'Use letters, digits, hyphens, periods or underscores (no spaces).' }
        }
        'Cidr' {
            $parts = $Value.Split('/')
            $ip = $null; $prefix = 0
            if ($parts.Count -ne 2 -or -not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
                $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
                -not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 8 -or $prefix -gt 29) {
                return 'Enter an IPv4 range in CIDR form, such as 10.2.0.0/16 (prefix /8 to /29).'
            }
        }
        'Time24h' {
            if ($Value -notmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') { return 'Enter a 24-hour time as HHmm, such as 1900.' }
        }
        'TimeZone' {
            try { $null = [TimeZoneInfo]::FindSystemTimeZoneById($Value) } catch { return "'$Value' is not a recognised Windows time zone ID, such as 'Eastern Standard Time'." }
        }
        'Url' {
            $uri = $null
            if ($Value -match '[\s"''`]' -or -not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { return 'Enter the full https:// download link, without quotes or spaces.' }
        }
        'Sha256' {
            if ($Value -ne 'SKIP' -and $Value -notmatch '^[0-9A-Fa-f]{64}$') { return 'Enter the 64-character SHA256 value Microsoft publishes for this file, or SKIP.' }
        }
        'Generation' {
            if ($Value -notin @('1', '2')) { return 'Enter 1 or 2, matching the generation stated in the current Microsoft article for this VHD.' }
        }
        'Workload' {
            if ($Value -notin @('All', 'Agentless', 'AgentBased')) { return 'Enter All, Agentless or AgentBased.' }
        }
        'Currency' {
            if ($Value -cnotmatch '^[A-Z]{3}$') { return 'Enter a three-letter ISO currency code in capitals, such as USD.' }
        }
        'OfferCode' {
            if ($Value -notmatch '^MS-AZR-[0-9]{4}P$') { return 'Enter an Azure offer code such as MS-AZR-0003P (Pay-As-You-Go).' }
        }
        default {
            if ($Value -match '[\r\n]') { return 'Enter a single line.' }
        }
    }
    return $null
}

function Read-LabNumber {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [int]$Value,
        [switch]$Supplied,
        [Parameter(Mandatory = $true)][int]$Minimum,
        [Parameter(Mandatory = $true)][int]$Maximum,
        [string]$Example
    )
    while ($true) {
        if ($Supplied) { $entry = [string]$Value } else {
            $hint = if ($Example) { " (example: $Example)" } else { '' }
            $entry = Read-Host "$Prompt [$Minimum-$Maximum]$hint"
        }
        $number = 0
        if ([int]::TryParse(([string]$entry).Trim(), [ref]$number) -and $number -ge $Minimum -and $number -le $Maximum) { return $number }
        if ($Supplied) { throw "-$Name must be a whole number from $Minimum to $Maximum." }
        Microsoft.PowerShell.Utility\Write-Host "  Enter a whole number from $Minimum to $Maximum." -ForegroundColor Yellow
    }
}

function Read-LabChoice {
    # Yes/No question with no default: the learner must answer.
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][AllowEmptyString()][string]$Value
    )
    while ($true) {
        $entry = if (-not [string]::IsNullOrWhiteSpace($Value)) { $Value } else { Read-Host "$Prompt [Yes/No]" }
        switch -Regex (([string]$entry).Trim()) {
            '^(?i)(y|yes)$' { return 'Yes' }
            '^(?i)(n|no)$'  { return 'No' }
        }
        if (-not [string]::IsNullOrWhiteSpace($Value)) { throw "Expected Yes or No, got '$Value'." }
        Microsoft.PowerShell.Utility\Write-Host '  Answer Yes or No.' -ForegroundColor Yellow
    }
}

function Test-LabCidrContains {
    # True when $Inner (for example a subnet) lies entirely inside $Outer (for example its VNet).
    param([Parameter(Mandatory = $true)][string]$Outer, [Parameter(Mandatory = $true)][string]$Inner)
    $toRange = {
        param([string]$Cidr)
        $parts = $Cidr.Split('/')
        $bytes = ([System.Net.IPAddress]::Parse($parts[0])).GetAddressBytes()
        [Array]::Reverse($bytes)
        $address = [BitConverter]::ToUInt32($bytes, 0)
        $prefix = [int]$parts[1]
        $mask = if ($prefix -eq 0) { [uint32]0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix)) }
        $start = $address -band $mask
        $end = [uint32]($start + [math]::Pow(2, 32 - $prefix) - 1)
        return @($start, $end)
    }
    $o = & $toRange $Outer
    $i = & $toRange $Inner
    return ($i[0] -ge $o[0] -and $i[1] -le $o[1])
}

function Get-LabAzContext {
    # Uses the Azure account you are already signed in with (Connect-AzAccount). Only the first
    # five characters of the subscription ID are shown, so you can confirm it is the workshop
    # subscription without exposing the full ID.
    if (-not (Get-Command -Name Get-AzContext -ErrorAction SilentlyContinue)) {
        throw 'The Az PowerShell modules are required: Install-Module Az -Scope CurrentUser'
    }
    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context -or -not $context.Account -or -not $context.Subscription -or [string]::IsNullOrWhiteSpace($context.Subscription.Id)) {
        throw 'No Azure sign-in found. Run Connect-AzAccount, select the workshop subscription with Set-AzContext -Subscription <name or ID>, then rerun this script.'
    }
    $script:LabSubscriptionId = [string]$context.Subscription.Id
    $script:LabAccountId = [string]$context.Account.Id
    $script:LabMaskedValues = @($script:LabSubscriptionId)
    if ($context.Tenant -and $context.Tenant.Id) { $script:LabMaskedValues += [string]$context.Tenant.Id }
    Write-Host "Azure account : $script:LabAccountId" -ForegroundColor Cyan
    Write-Host "Subscription  : $(Format-LabSubscriptionId $script:LabSubscriptionId)" -ForegroundColor Cyan
    return $context
}

function Get-LabNotFoundMessage {
    param([Parameter(Mandatory = $true)][string]$What, [string]$Hint)
    $text = "$What was not found in subscription $(Format-LabSubscriptionId $script:LabSubscriptionId) (signed in as $script:LabAccountId). " +
            "If this is the wrong subscription, switch with Set-AzContext -Subscription <workshop subscription> (or Connect-AzAccount with the right account) and rerun."
    if ($Hint) { $text += " $Hint" }
    return $text
}

function Assert-LabResources {
    # Confirms the resources this step depends on exist in the signed-in subscription before any
    # change is made. Every missing item is listed, each against the truncated subscription ID.
    param(
        [string]$SourceResourceGroup,
        [string]$TargetResourceGroup,
        [string]$HyperVHostVMName,
        [string]$MigrateProjectName
    )
    $problems = @()
    if ($SourceResourceGroup) {
        if (-not (Get-AzResourceGroup -Name $SourceResourceGroup -ErrorAction SilentlyContinue)) {
            $problems += Get-LabNotFoundMessage "Source resource group '$SourceResourceGroup'" 'It is created by deploy-lab.ps1.'
        } else {
            if ($HyperVHostVMName -and -not (Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $HyperVHostVMName -ErrorAction SilentlyContinue)) {
                $problems += Get-LabNotFoundMessage "Hyper-V host VM '$HyperVHostVMName' in '$SourceResourceGroup'" 'It is created by deploy-lab.ps1.'
            }
            if ($MigrateProjectName) {
                $project = @(Get-AzResource -ResourceGroupName $SourceResourceGroup -Name $MigrateProjectName -ErrorAction SilentlyContinue |
                    Where-Object { $_.ResourceType -in @('Microsoft.Migrate/migrateProjects', 'Microsoft.Migrate/assessmentProjects') })
                if (-not $project.Count) {
                    $problems += Get-LabNotFoundMessage "Azure Migrate project '$MigrateProjectName' in '$SourceResourceGroup'" 'It is created by migrate-step1-setup-project.ps1 (or in the portal, Module 1 section 1).'
                }
            }
        }
    }
    if ($TargetResourceGroup -and -not (Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction SilentlyContinue)) {
        $problems += Get-LabNotFoundMessage "Target resource group '$TargetResourceGroup'" 'It is created by migrate-step1-setup-project.ps1.'
    }
    if ($problems.Count) {
        Write-Host ''
        foreach ($p in $problems) { Write-Host "  NOT FOUND: $p" -ForegroundColor Red }
        throw "$($problems.Count) required resource(s) not found in subscription $(Format-LabSubscriptionId $script:LabSubscriptionId). No changes were made."
    }
    Write-Host "Required resources found in subscription $(Format-LabSubscriptionId $script:LabSubscriptionId)." -ForegroundColor Green
}

# endregion Lab helpers
trap { Write-LabTerminatingError $_; exit 1 }

$context = Get-LabAzContext

Write-Host ""
Write-Host "Enter the values for your lab environment (examples are hints only; Enter does not accept them)." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabParameter -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Kind ResourceGroup -Prompt 'Source resource group (contains HyperVHost)' -Example 'rg-ces-source-01'
$TargetResourceGroup = Read-LabParameter -Name 'TargetResourceGroup' -Value $TargetResourceGroup -Kind ResourceGroup -Prompt 'Target resource group (landing zone for migrated VMs)' -Example 'rg-ces-target-01'
$MigrateProjectName = Read-LabParameter -Name 'MigrateProjectName' -Value $MigrateProjectName -Kind ProjectName -Prompt 'Azure Migrate project name' -Example 'ces-migrate-01'
$Location = Read-LabParameter -Name 'Location' -Value $Location -Kind Region -Prompt 'Azure target region used in step 1' -Example 'eastus'

# Confirm this step's resources exist in the signed-in subscription before changing anything.
Assert-LabResources -SourceResourceGroup $SourceResourceGroup -TargetResourceGroup $TargetResourceGroup -MigrateProjectName $MigrateProjectName

$workload = "AgentBased"
$targetModule = "Module 3"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Bridging lab state to the end of $targetModule" -ForegroundColor Cyan
Write-Host "  Workload group: $workload" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This runs replicate -> test -> cutover for:" -ForegroundColor White
Write-Host "    - OnPrem-SQL       (Windows Server + SQL Server Express)" -ForegroundColor White
Write-Host "    - OnPrem-Linux-App (Ubuntu + Node.js API)" -ForegroundColor White
Write-Host ""
Write-Host "  Cutover SHUTS DOWN the matching source VMs on the Hyper-V host." -ForegroundColor Yellow
Write-Host ""

# Confirm before doing anything destructive.
$confirm = Read-Host "Continue? (yes/no)"
if ($confirm -ne "yes") {
    Write-Host "Aborted. No changes made." -ForegroundColor Yellow
    return
}

# Common arguments passed to each stage.
$common = @{
    SourceResourceGroup = $SourceResourceGroup
    TargetResourceGroup = $TargetResourceGroup
    MigrateProjectName  = $MigrateProjectName
    Location            = $Location
    Workload            = $workload
}

function Invoke-LabStage {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][hashtable]$Arguments
    )

    $path = Join-Path $scriptRoot $ScriptName
    if (-not (Test-Path $path)) {
        throw "Required script not found: $path"
    }

    Write-Host ""
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  $Description" -ForegroundColor White
    Write-Host "  ($ScriptName)" -ForegroundColor DarkGray
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray

    $global:LASTEXITCODE = 0   # strict mode: make sure it is defined before the check below
    & $path @Arguments

    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "$ScriptName exited with code $LASTEXITCODE. Stopping before the next stage."
    }
}

Invoke-LabStage -ScriptName "migrate-step3-replicate.ps1" `
                -Description "Stage 1 of 3 - Enable replication" `
                -Arguments $common

if ($SkipTestMigration) {
    Write-Host ""
    Write-Host "  Skipping test migration (-SkipTestMigration)." -ForegroundColor Yellow
    Write-Host "  Cutover will proceed without a validated test failover." -ForegroundColor Yellow
} else {
    Invoke-LabStage -ScriptName "migrate-step4-test-migrate.ps1" `
                    -Description "Stage 2 of 3 - Test migration and cleanup" `
                    -Arguments $common
}

$cutoverArgs = $common.Clone()
$cutoverArgs["TurnOffSourceVMs"] = "Yes"
Invoke-LabStage -ScriptName "migrate-step5-cutover.ps1" `
                -Description "Stage 3 of 3 - Cutover to Azure" `
                -Arguments $cutoverArgs

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Lab state now matches the end of $targetModule." -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Next: Module 5 (post-migration operations), or migrate-step6-post-migration.ps1." -ForegroundColor White
Write-Host ""
