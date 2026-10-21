<#
.SYNOPSIS
    Step 2: Build or verify the Azure Migrate appliance, discover the four workloads and assess them.

.DESCRIPTION
    Follows docs/Module-1-Discovery.md. The appliance is Microsoft's published VHD, kept
    entirely on the ApplianceStore partition that deploy-lab.ps1 created (normally E:\Appliance):
    the download, the extracted VHD and the running VM. Nothing is staged on C:.

    Every environment-specific value is prompted for when it is not passed on the command
    line. The subscription and tenant IDs are truncated in all console output so the script
    can be shown on a shared screen; the project key is never displayed in full.

    What this script does:
    1. Retrieves the Hyper-V host connection info and lists its guest VMs
    2. Generates the project key, or guides you through generating it in the portal (3.1)
    3. Locates the ApplianceStore volume (3.2). Unless the appliance VM already exists, it
       downloads the archive as a background task on the host, verifies its SHA256, extracts
       it to <store>:\Appliance\Extracted and imports it as a VM exactly as section 3.4
       describes. It then checks the VM against the Module 1 checklist.
    4. Guides first boot, registration, credentials and discovery (3.5 and 4)
    5. Waits for the four workloads BY NAME and lists them
    6. Creates an Azure VM assessment for exactly those four workloads (5)
    7. Displays assessment results (readiness, sizing, cost)

    Timing: the archive is roughly 11-12 GB. The download runs on the host independently of
    this console and resumes if interrupted; you choose how long to wait before being asked
    whether to keep waiting, and rerunning the script picks up where it left off.

    Prerequisites:
    - Step 1 (migrate-step1-setup-project.ps1) must be completed
    - The Hyper-V host (HyperVHost) must be running, with the ApplianceStore volume
    - You need RDP or browser access to complete appliance configuration

.PARAMETER SourceResourceGroup
    The on-premises simulation resource group. Prompted when not supplied (example: rg-ces-source-01).

.PARAMETER TargetResourceGroup
    Optional existing landing zone. Derives assessment region from its actual target VNet,
    never from resource-group metadata; checks an explicitly supplied Location matches.

.PARAMETER Location
    Assessment target region chosen in step 1 (alias TargetLocation). If no target group is
    supplied, explicitly prompts/validates against Get-AzLocation; never inherits source region.

.PARAMETER MigrateProjectName
    Name of the Azure Migrate project (from Step 1). Prompted when not supplied (example: ces-migrate-01).

.PARAMETER AssessmentMode
    Classic (default) uses the grouped Azure VM MachineAssessment 2024-01-15 workflow.
    Modern is explicit experimental opt-in, deferred pending further API information.
    Neither mode silently falls back to the other. No application/PaaS retooling is performed.

.PARAMETER AssessmentProjectName
    Optional explicit existing classic assessment backend in the same subscription/resource group.
    Normally resolved from the selected Migrate project's assessment solution, never inferred from
    MigrateProjectName. Required when the solution has no verifiable backend reference.

.PARAMETER AssessmentGroupName
    Defaults to AllServers-Group. Existing groups are reused only with exactly the four workloads;
    different or empty existing groups are preserved. Choose an unused name to create your own group.

.PARAMETER AssessmentName
    Defaults to Workshop-Assessment. Matching existing assessments are reused, never overwritten;
    choose an unused name after reviewing a stale or differently configured assessment.

.PARAMETER HyperVHostVMName
    Name of the Hyper-V host Azure VM. Prompted when not supplied (example: HyperVHost).

.PARAMETER ApplianceVMName
    Name of the appliance VM inside Hyper-V. The Azure registration name is separate and must be alphanumeric, at most 14 characters.
    Prompted when not supplied (example: MigrateAppl).

.PARAMETER ApplianceDownloadUrl
    Needed only when the appliance VM does not exist yet. The VHD download link shown in the project. Prompted when not supplied.

.PARAMETER ApplianceSha256
    Needed only when the appliance VM does not exist yet. The current SHA256 Microsoft publishes for the Hyper-V ZIP. Required before extraction/import; no bypass.

.PARAMETER DownloadTimeoutMinutes
    Needed only when the appliance VM does not exist yet. Minutes to wait for the download before asking whether to keep waiting.

.PARAMETER ApplianceGeneration
    Optional compatibility assertion (1 or 2). The exported configuration determines generation; a mismatching assertion stops import.

.PARAMETER AssessmentCurrency
    Currency for the assessment. Prompted when not supplied (example: USD).

.PARAMETER AzureOfferCode
    Pricing offer for the assessment. Prompted when not supplied (example: MS-AZR-0003P).

.PARAMETER AzureHybridBenefit
    Yes only if Windows Server licence entitlement has been confirmed. Prompted when not supplied.

.EXAMPLE
    .\migrate-step2-discover-assess.ps1

.EXAMPLE
    .\migrate-step2-discover-assess.ps1 -SourceResourceGroup "my-onprem" -MigrateProjectName "MyProject"
MODULE COVERAGE
    The scripts and the modules are run separately. This script completes:

      Module 1, section 3.1 Generate the project key - NOT automated. The script stops and
                            waits: the key is issued interactively in the portal.
      Module 1, section 3.2 Confirm the appliance store.
      Module 1, section 3.3 Download and verify the archive (already staged by deploy-lab.ps1).
      Module 1, section 3.4 Copy-import the published VM configuration; check capacity without resizing.
      Module 1, section 3.5 First boot - printed as manual steps; the console is yours.
      Module 1, section 4   Register and discover - printed as manual steps. Registration is a
                            browser sign-in on the appliance and cannot be driven from here.
      Module 1, section 5   Create the assessment.

    Not covered: Module 1 section 6 (Interpret the dependency view), which is reading, and
    section 2 (host preparation), which deploy-lab.ps1 already applied.
#>

[CmdletBinding()]
param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [Alias('TargetLocation')][string]$Location,

    [string]$MigrateProjectName,

    [ValidateSet('Modern', 'Classic')]
    [string]$AssessmentMode = 'Classic',

    [string]$AssessmentProjectName,

    [string]$AssessmentGroupName = 'AllServers-Group',

    [string]$AssessmentName = 'Workshop-Assessment',

    [string]$HyperVHostVMName,

    [string]$ApplianceVMName,

    [string]$ApplianceDownloadUrl,

    [string]$ApplianceSha256,

    [int]$DownloadTimeoutMinutes,

    [ValidateSet('1', '2')][string]$ApplianceGeneration,

    [string]$AssessmentCurrency,

    [string]$AzureOfferCode,

    [ValidateSet('Yes', 'No')][string]$AzureHybridBenefit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
# Shared helpers, masked console output and parameter entry
# ================================================================
# Every environment-specific value is entered by the learner when it is not passed on
# the command line; no value is taken silently from a default. The script uses the current
# Azure sign-in (Connect-AzAccount), checks that its resources exist in that subscription,
# and shows only the first five characters of the subscription ID. It needs no other file.
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
    # Resolved with Get-Variable rather than read directly. These console proxies shadow the
    # real Write-Host, and a shadowed function can outlive the script that defined it - a
    # dot-sourced run, or an interrupted one. If it is then called from another script that
    # sets Set-StrictMode, reading an unset $script:LabMaskedValues raises a terminating error
    # and kills that script at a Write-Host line, which is not this function's business.
    # Get-Variable with -ErrorAction SilentlyContinue returns nothing instead, so the worst
    # case is text that was never masked rather than a script that stops.
    $secrets = @(Get-Variable -Name 'LabMaskedValues' -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    foreach ($secret in $secrets) {
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
        # A lab-wide setting that is the same for everyone may carry a Default. It is shown in
        # square brackets and Enter accepts it. Names of resources in someone's own subscription
        # never carry one -- those must be typed, so nobody inherits another person's value.
        [string]$Default,
        [ValidateSet('Text', 'ResourceGroup', 'Region', 'ProjectName', 'VMName', 'Cidr', 'Time24h', 'TimeZone', 'Url', 'Sha256', 'Generation', 'Currency', 'OfferCode', 'Workload')]
        [string]$Kind = 'Text'
    )
    $supplied = -not [string]::IsNullOrWhiteSpace($Value)
    while ($true) {
        if ($supplied) {
            $entry = $Value.Trim()
        } else {
            $hint = if ($Default) { " [$Default]" }
                    elseif ($Example) { " (example: $Example)" }
                    else { '' }
            $entry = Read-Host "$Prompt$hint"
            if ($null -ne $entry) { $entry = $entry.Trim() }
            if ([string]::IsNullOrWhiteSpace($entry)) {
                if ($Default) { $entry = $Default }
                else {
                    Microsoft.PowerShell.Utility\Write-Host "  A value for $Name is required." -ForegroundColor Yellow
                    continue
                }
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
            if ($Value -notmatch '^[0-9A-Fa-f]{64}$') { return 'Enter the current official 64-character Hyper-V ZIP SHA256; no bypass.' }
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

function Get-LabResourceGroupNames {
    # Every resource group visible in the signed-in subscription.
    try { return @(Get-AzResourceGroup -ErrorAction Stop | Select-Object -ExpandProperty ResourceGroupName | Sort-Object) }
    catch { return @() }
}

function Get-LabVMNames {
    param([Parameter(Mandatory = $true)][string]$ResourceGroupName)
    try { return @(Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Select-Object -ExpandProperty Name | Sort-Object) }
    catch { return @() }
}

function Get-LabMigrateProjectNames {
    # Azure Migrate exposes the project as one of two resource types depending on how it was
    # created, so both are queried and the results merged.
    param([Parameter(Mandatory = $true)][string]$ResourceGroupName)
    $names = @()
    foreach ($type in @('Microsoft.Migrate/migrateProjects', 'Microsoft.Migrate/assessmentProjects')) {
        try {
            $names += @(Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType $type -ErrorAction Stop |
                        Select-Object -ExpandProperty Name)
        } catch { }
    }
    return @($names | Select-Object -Unique | Sort-Object)
}

function Get-LabSimilarResourceGroupNames {
    # Names in the CURRENT subscription that resemble what was typed, to expose a typo without
    # printing the whole subscription.
    param([Parameter(Mandatory = $true)][string]$Entry)
    $all = @()
    try { $all = @(Get-AzResourceGroup -ErrorAction Stop | Select-Object -ExpandProperty ResourceGroupName) } catch { return @() }
    if ($all.Count -eq 0) { return @() }
    $needle = $Entry.ToLowerInvariant()
    $parts = @($needle -split '[-_.]' | Where-Object { $_.Length -ge 3 })
    $close = @($all | Where-Object {
        $candidate = $_.ToLowerInvariant()
        if ($candidate -like "*$needle*" -or $needle -like "*$candidate*") { return $true }
        foreach ($part in $parts) { if ($candidate -like "*$part*") { return $true } }
        return $false
    })
    return @($close | Select-Object -First 8)
}

function Find-LabResourceGroupSubscription {
    <#
      Looks for a resource group of this name in the account's other enabled subscriptions.
      The Azure portal spans every subscription, so a group that is plainly visible there can
      still be absent from the one this session is pointed at. This names that situation
      instead of leaving it as "not found". The original context is restored either way.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ResourceGroupName,
        [AllowNull()][AllowEmptyString()][string]$CurrentSubscriptionId
    )
    $found = @()
    $subscriptions = @()
    try { $subscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }) }
    catch { return @() }

    $others = @($subscriptions | Where-Object { $_.Id -ne $CurrentSubscriptionId })
    if ($others.Count -eq 0) { return @() }

    Microsoft.PowerShell.Utility\Write-Host "  Checking $($others.Count) other subscription(s) on this account..." -ForegroundColor Cyan
    try {
        foreach ($subscription in $others) {
            try {
                $null = Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop
                if (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue) { $found += $subscription }
            } catch { }
        }
    } finally {
        if (-not [string]::IsNullOrWhiteSpace($CurrentSubscriptionId)) {
            try { $null = Set-AzContext -SubscriptionId $CurrentSubscriptionId -ErrorAction Stop } catch { }
        }
    }
    return @($found)
}

function Read-LabResourceGroupName {
    <#
      Asks for a resource group by name rather than listing every group in the subscription: a
      training subscription can hold a great many, and the learner is expected to know which one
      is theirs. The name is checked against Azure and re-asked when it is not there, so a typo
      is caught at the prompt instead of part way through the run.

      -AllowNew is for a group this script will CREATE. A name that does not exist is then
      offered for creation rather than refused.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][AllowEmptyString()][string]$Value,
        [string]$Example,
        [switch]$AllowNew,
        [string]$MissingHelp = ''
    )

    $supplied = -not [string]::IsNullOrWhiteSpace($Value)
    $entry = $Value

    while ($true) {
        $entry = Read-LabParameter -Name $Name -Prompt $Prompt -Value $entry -Kind ResourceGroup -Example $Example

        $group = $null
        try { $group = Get-AzResourceGroup -Name $entry -ErrorAction Stop } catch { $group = $null }

        if ($group) {
            if ($AllowNew) {
                Microsoft.PowerShell.Utility\Write-Host "  '$entry' exists in this subscription and will be used as it stands." -ForegroundColor Green
            }
            $script:LabResourceGroupCreate = $false
            return $entry
        }

        if ($AllowNew) {
            Microsoft.PowerShell.Utility\Write-Host "  '$entry' does not exist in this subscription." -ForegroundColor Yellow
            if ((Read-LabChoice -Prompt "  Create '$entry'?") -eq 'Yes') {
                $script:LabResourceGroupCreate = $true
                return $entry
            }
            $entry = ''
            continue
        }

        # Not found. Say WHERE it was looked for: the portal spans every subscription, so a group
        # that is obviously there can still be missing from the one this session points at.
        $subscriptionLabel = if ($script:LabSubscriptionName) { "subscription '$script:LabSubscriptionName'" } else { 'the current subscription' }
        $help = if ($MissingHelp) { " $MissingHelp" } else { '' }
        Microsoft.PowerShell.Utility\Write-Host ''
        Microsoft.PowerShell.Utility\Write-Host "  '$entry' was not found in $subscriptionLabel.$help" -ForegroundColor Yellow

        $similar = Get-LabSimilarResourceGroupNames -Entry $entry
        if ($similar.Count -gt 0) {
            Microsoft.PowerShell.Utility\Write-Host '  Similar names in this subscription:' -ForegroundColor White
            foreach ($candidate in $similar) { Microsoft.PowerShell.Utility\Write-Host "    $candidate" -ForegroundColor White }
        }

        if ((Read-LabChoice -Prompt '  Look for this group in your other subscriptions?') -eq 'Yes') {
            $elsewhere = Find-LabResourceGroupSubscription -ResourceGroupName $entry -CurrentSubscriptionId $script:LabSubscriptionId
            if ($elsewhere.Count -gt 0) {
                Microsoft.PowerShell.Utility\Write-Host "  '$entry' exists in: $(@($elsewhere | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Green
                $target = $elsewhere[0]
                if ($elsewhere.Count -gt 1) {
                    $pickedName = Select-LabFromList -Name 'Subscription' -Prompt 'Subscription to switch to' -Options @($elsewhere | ForEach-Object { $_.Name })
                    $target = @($elsewhere | Where-Object { $_.Name -eq $pickedName })[0]
                }
                if ((Read-LabChoice -Prompt "  Switch this session to '$($target.Name)'?") -eq 'Yes') {
                    $switched = Set-AzContext -SubscriptionId $target.Id -ErrorAction Stop
                    $script:LabSubscriptionId = [string]$switched.Subscription.Id
                    $script:LabSubscriptionName = [string]$switched.Subscription.Name
                    $script:LabMaskedValues = @($script:LabSubscriptionId)
                    if ($switched.Tenant -and $switched.Tenant.Id) { $script:LabMaskedValues += [string]$switched.Tenant.Id }
                    Write-Host "  Now working in $script:LabSubscriptionName  $(Format-LabSubscriptionId $script:LabSubscriptionId)" -ForegroundColor Green
                    # $entry is left as it is, so the loop re-checks the same name against the
                    # subscription just switched to without asking for it again.
                    continue
                }
            } else {
                Microsoft.PowerShell.Utility\Write-Host "  '$entry' was not found in any other subscription on this account either." -ForegroundColor Yellow
            }
        }

        if ($supplied) { throw "-$Name '$entry' was not found in $subscriptionLabel.$help" }
        $entry = ''
    }
}

function Select-LabFromList {
    <#
      Picks a value that already exists in the subscription instead of asking the learner to
      recall its name. A value passed on the command line is still honoured; it is only checked
      against what was found. With -AllowNew the list gains a final entry for typing a name that
      does not exist yet, which is how a resource this script is about to CREATE is named.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [AllowNull()][AllowEmptyString()][string]$Value,
        [AllowEmptyCollection()][string[]]$Options = @(),
        [string]$Example,
        [ValidateSet('Text', 'ResourceGroup', 'Region', 'ProjectName', 'VMName', 'Cidr', 'Time24h', 'TimeZone', 'Url', 'Sha256', 'Generation', 'Currency', 'OfferCode', 'Workload')]
        [string]$Kind = 'Text',
        [switch]$AllowNew,
        [string]$NewLabel = 'Enter a different name',
        [string]$EmptyHelp = 'Check that you are signed in to the right subscription (Get-AzContext) and that the earlier steps completed.'
    )

    $choices = @($Options | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $trimmed = $Value.Trim()
        $match = @($choices | Where-Object { $_ -eq $trimmed })
        if ($match.Count -gt 0) { return $match[0] }
        if ($AllowNew -or $choices.Count -eq 0) {
            return Read-LabParameter -Name $Name -Prompt $Prompt -Value $trimmed -Kind $Kind -Example $Example
        }
        throw "-$Name '$trimmed' was not found in this subscription. Found: $($choices -join ', ')"
    }

    if ($choices.Count -eq 0) {
        if (-not $AllowNew) { throw "No candidates for $Name were found in this subscription. $EmptyHelp" }
        return Read-LabParameter -Name $Name -Prompt $Prompt -Kind $Kind -Example $Example
    }

    if ($choices.Count -eq 1 -and -not $AllowNew) {
        Microsoft.PowerShell.Utility\Write-Host "  $Prompt" -ForegroundColor Cyan
        Microsoft.PowerShell.Utility\Write-Host "    $($choices[0])  (only match in this subscription)" -ForegroundColor Green
        return $choices[0]
    }

    $limit = if ($AllowNew) { $choices.Count + 1 } else { $choices.Count }
    while ($true) {
        Microsoft.PowerShell.Utility\Write-Host ''
        Microsoft.PowerShell.Utility\Write-Host "  $Prompt" -ForegroundColor Cyan
        for ($i = 0; $i -lt $choices.Count; $i++) {
            Microsoft.PowerShell.Utility\Write-Host ("    [{0}] {1}" -f ($i + 1), $choices[$i]) -ForegroundColor White
        }
        if ($AllowNew) {
            Microsoft.PowerShell.Utility\Write-Host ("    [{0}] {1}" -f $limit, $NewLabel) -ForegroundColor White
        }
        $entry = Read-Host "  Select 1-$limit"
        $number = 0
        if ([int]::TryParse(([string]$entry).Trim(), [ref]$number)) {
            if ($number -ge 1 -and $number -le $choices.Count) { return $choices[$number - 1] }
            if ($AllowNew -and $number -eq $limit) {
                return Read-LabParameter -Name $Name -Prompt $Prompt -Kind $Kind -Example $Example
            }
        }
        Microsoft.PowerShell.Utility\Write-Host "  Enter one of the numbers listed." -ForegroundColor Yellow
    }
}

function Resolve-LabLocation {
    # A resource group already carries a region, so the region is read from it rather than asked.
    param(
        [AllowNull()][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$ResourceGroupName
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return Read-LabParameter -Name 'Location' -Prompt 'Azure region' -Value $Value -Kind Region
    }
    $location = $null
    try { $location = (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop).Location } catch { $location = $null }
    if (-not [string]::IsNullOrWhiteSpace($location)) {
        Microsoft.PowerShell.Utility\Write-Host "  Region: $location  (from resource group $ResourceGroupName)" -ForegroundColor Green
        return $location
    }
    return Read-LabParameter -Name 'Location' -Prompt 'Azure region' -Kind Region -Example 'eastus'
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

function Get-LabErrorLogPath {
    # Next to the script when that is writable, otherwise the temp folder.
    param([AllowNull()][AllowEmptyString()][string]$ScriptPath)
    $name = if ([string]::IsNullOrWhiteSpace($ScriptPath)) { 'migrate-step' }
            else { [IO.Path]::GetFileNameWithoutExtension($ScriptPath) }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $folders = @()
    if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) { $folders += (Split-Path -Parent $ScriptPath) }
    $folders += [IO.Path]::GetTempPath()
    foreach ($folder in $folders) {
        if ([string]::IsNullOrWhiteSpace($folder)) { continue }
        try {
            $probe = Join-Path $folder ".lab-write-test-$stamp"
            Set-Content -Path $probe -Value 'x' -ErrorAction Stop
            Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
            return (Join-Path $folder "$name-error-$stamp.log")
        } catch { }
    }
    return (Join-Path ([IO.Path]::GetTempPath()) "$name-error-$stamp.log")
}

function Save-LabErrorReport {
    <#
      Writes the whole failure to a file so it survives a console window that closes on exit.
      Everything written here goes through the same masking as the screen output.
    #>
    param(
        [Parameter(Mandatory = $true)]$ErrorRecord,
        [AllowNull()][AllowEmptyString()][string]$ScriptPath
    )
    try {
        $path = Get-LabErrorLogPath -ScriptPath $ScriptPath
        $invocation = $ErrorRecord.InvocationInfo
        $report = @(
            "Time        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
            "Script      : $ScriptPath"
            "PowerShell  : $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
            "OS          : $([Environment]::OSVersion.VersionString)"
            ''
            "Message     : $([string]$ErrorRecord.Exception.Message)"
            "Type        : $($ErrorRecord.Exception.GetType().FullName)"
            "Category    : $($ErrorRecord.CategoryInfo.Category)"
            "FullyQualifiedErrorId : $($ErrorRecord.FullyQualifiedErrorId)"
            ''
            "Failed at   : line $($invocation.ScriptLineNumber), column $($invocation.OffsetInLine)"
            "Statement   : $(([string]$invocation.Line).Trim())"
            ''
            'Stack trace :'
            ([string]$ErrorRecord.ScriptStackTrace)
            ''
            'Loaded Az modules :'
        )
        $report += @(Get-Module -Name 'Az.*' | ForEach-Object { "  $($_.Name) $($_.Version)" })
        if (-not (Get-Module -Name 'Az.*')) { $report += '  (none loaded)' }

        Set-Content -Path $path -Value (Protect-LabObject $report) -Encoding UTF8 -ErrorAction Stop
        Microsoft.PowerShell.Utility\Write-Host ''
        Microsoft.PowerShell.Utility\Write-Host "A full error report was saved to:" -ForegroundColor Yellow
        Microsoft.PowerShell.Utility\Write-Host "  $path" -ForegroundColor Yellow
    } catch {
        Microsoft.PowerShell.Utility\Write-Host ''
        Microsoft.PowerShell.Utility\Write-Host "  (the error report could not be saved: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

function Wait-LabBeforeExit {
    # A console started by double-click or "Run with PowerShell" closes the instant the script
    # exits, taking the error with it. This holds it open. Set LAB_NO_PAUSE=1 for unattended runs.
    if ($env:LAB_NO_PAUSE -eq '1') { return }
    try {
        if (-not [Environment]::UserInteractive) { return }
        Microsoft.PowerShell.Utility\Write-Host ''
        $null = Read-Host 'Press Enter to close this window'
    } catch { }
}

function Get-LabAssessmentField {
    param([AllowNull()]$Object, [string]$Name, [switch]$PreserveArray)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($PreserveArray) { return ,($Object[$Name]) }
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($PreserveArray) { return ,($property.Value) }
    return $property.Value
}

function Get-LabAssessmentContextStamp {
    param([AllowNull()]$Context)
    $subscription = Get-LabAssessmentField $Context 'Subscription'
    $tenant = Get-LabAssessmentField $Context 'Tenant'
    $account = Get-LabAssessmentField $Context 'Account'
    $environment = Get-LabAssessmentField $Context 'Environment'
    $parts = @((Get-LabAssessmentField $subscription 'Id'), (Get-LabAssessmentField $tenant 'Id'),
        (Get-LabAssessmentField $account 'Id'), (Get-LabAssessmentField $account 'Type'),
        (Get-LabAssessmentField $environment 'Name'), (Get-LabAssessmentField $environment 'ResourceManagerUrl'),
        (Get-LabAssessmentField $environment 'ActiveDirectoryAuthority'))
    foreach ($part in $parts) {
        if ($part -isnot [string] -or [string]::IsNullOrWhiteSpace($part) -or $part.Contains('|')) {
            throw 'Assessment context is incomplete. Verify the original lab sign-in, subscription, tenant and Azure environment, then rerun Step 2.'
        }
    }
    return ($parts -join '|')
}

function Invoke-LabAssessmentRequest {
    param([Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('GET', 'PUT', 'POST')][string]$Method,
        [AllowNull()][string]$Payload, [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$PinnedContext,
        [Parameter(Mandatory = $true)][string]$ResourceGroup)

    $result = [pscustomobject]@{ Success = $false; StatusCode = 0; Data = $null; Pending = $false; RetryAfter = 15;
        FailureKind = 'Context'; ErrorCode = ''; Message = 'Assessment context could not be verified. Restore the original lab context and rerun Step 2.' }
    try {
        if ((Get-LabAssessmentContextStamp $Context) -cne $PinnedContext -or
            (Get-LabAssessmentContextStamp (Get-AzContext -ErrorAction Stop)) -cne $PinnedContext) { return $result }
    } catch { return $result }

    if (-not (Test-LabAssessmentPath -Path $Path -Method $Method -Context $Context -ResourceGroup $ResourceGroup)) {
        $result.FailureKind = 'Path'; $result.Message = 'Assessment request path is outside the selected lab subscription or expected assessment resource. No request sent.'
        return $result
    }
    if (-not (Get-Command -Name 'Invoke-AzRestMethod' -ErrorAction SilentlyContinue)) {
        $result.FailureKind = 'Prerequisite'; $result.Message = 'Invoke-AzRestMethod is unavailable. Update Az.Accounts (Update-Module Az.Accounts), open a new PowerShell session, verify the lab context and rerun Step 2.'
        return $result
    }

    # Az.Accounts owns token acquisition/refresh and the current cloud ARM endpoint. Never unwrap or log tokens.
    $parameters = @{ Path = $Path; Method = $Method; DefaultProfile = $Context; ErrorAction = 'Stop' }
    if ($Method -in @('PUT', 'POST')) { $parameters.Payload = $Payload }
    $data = $null; $requestThrew = $false; $rawFailure = ''
    try {
        $response = Invoke-AzRestMethod @parameters
        $status = Get-LabAssessmentField $response 'StatusCode'
        $numericStatus = 0
        if ($null -eq $status -or -not [int]::TryParse([string]$status, [ref]$numericStatus) -or
            $numericStatus -lt 100 -or $numericStatus -gt 599) {
            $result.FailureKind = 'Response'; $result.Message = 'ARM returned no valid HTTP status. Request outcome is unverified; check the portal before retrying a write.'
            return $result
        }
        $result.StatusCode = $numericStatus
        $headers = Get-LabAssessmentField $response 'Headers'
        $retryAfter = 0
        if ([int]::TryParse([string](Get-LabAssessmentField $headers 'Retry-After'), [ref]$retryAfter) -and $retryAfter -gt 0) {
            $result.RetryAfter = [Math]::Min(60, $retryAfter)
        }
        $content = Get-LabAssessmentField $response 'Content'
        if (-not [string]::IsNullOrWhiteSpace([string]$content)) {
            try { $data = ConvertFrom-Json -InputObject $content -ErrorAction Stop }
            catch {
                if ($numericStatus -ge 200 -and $numericStatus -lt 300) {
                    $result.FailureKind = 'Response'; $result.Message = 'ARM returned unreadable JSON. Request outcome is unverified; check the portal before retrying a write.'
                    return $result
                }
                $data = $null
            }
            if ($null -eq $data -or $data -is [string] -or $data -is [ValueType] -or $data -is [array]) {
                if ($numericStatus -ge 200 -and $numericStatus -lt 300) {
                    $result.FailureKind = 'Response'; $result.Message = 'ARM returned an unexpected JSON shape. Request outcome is unverified; check the portal before retrying a write.'
                    return $result
                }
                $data = $null
            }
        }
    } catch {
        $requestThrew = $true
        $exceptionResponse = Get-LabAssessmentField (Get-LabAssessmentField $_ 'Exception') 'Response'
        $exceptionStatus = 0
        if ([int]::TryParse([string](Get-LabAssessmentField $exceptionResponse 'StatusCode'), [ref]$exceptionStatus) -and
            $exceptionStatus -ge 100 -and $exceptionStatus -le 599) { $result.StatusCode = $exceptionStatus }
        # Parse only a structured service error, never display the exception/request/headers.
        $details = Get-LabAssessmentField $_ 'ErrorDetails'
        $rawFailure = [string](Get-LabAssessmentField $details 'Message')
        try { $data = ConvertFrom-Json -InputObject $rawFailure -ErrorAction Stop } catch { $data = $null }
        $rawFailure += ' ' + [string](Get-LabAssessmentField (Get-LabAssessmentField $_ 'Exception') 'Message')
    }
    $serviceError = Get-LabAssessmentField $data 'error'
    $code = [string](Get-LabAssessmentField $serviceError 'code')
    if ($code -match '^[a-zA-Z][a-zA-Z0-9_.-]{0,79}$' -and $code -notmatch '(?i)^eyJ|bearer|password|secret|credential|[a-zA-Z0-9_+/=-]{64,}') { $result.ErrorCode = $code }
    $authenticationFailed = $result.StatusCode -eq 401 -or $code -match '(?i)Authentication|TokenExpired|ExpiredToken|LoginRequired' -or
        ($requestThrew -and $rawFailure -match '(?i)InvalidAuthenticationToken|ExpiredAuthenticationToken|Connect-AzAccount|authentication|\b401\b')
    if ($requestThrew -or $serviceError -or $result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
        $result.FailureKind = if ($authenticationFailed) { 'Authentication' } elseif ($result.StatusCode -eq 403 -or $code -match '(?i)Authorization|Forbidden') { 'Authorization' }
            elseif ($code -match '^(InvalidApiVersionParameter|NoRegisteredProviderFound|InvalidResourceType|UnsupportedApiVersion)$') { 'ApiVersion' }
            elseif ($code -match '^(ParentResourceNotFound|ResourceGroupNotFound|SubscriptionNotFound)$') { 'ScopeNotFound' }
            elseif ($result.StatusCode -eq 404 -and $Method -eq 'GET' -and
                ($code -in @('ResourceNotFound','NotFound') -or
                 ($code -ieq 'GroupNotFound' -and $Path -match '/assessmentProjects/[^/?]+/groups/[^/?]+\?api-version=2024-01-15$') -or
                 ($code -ieq 'AssessmentNotFound' -and $Path -match '/assessmentProjects/[^/?]+/(?:groups/[^/?]+/)?assessments/[^/?]+\?api-version=(?:2024-01-15|2024-03-03-preview)$'))) { 'NotFound' }
            elseif ($result.StatusCode -eq 409) { 'Conflict' }
            elseif ($result.StatusCode -in @(408, 429) -or $result.StatusCode -ge 500) { 'Transient' } elseif ($requestThrew) { 'Unknown' } else { 'Service' }
        $result.Message = 'ARM request failed. Check the portal and the reported error code; do not assume the write completed or that no assessment exists.'
        $message = [string](Get-LabAssessmentField $serviceError 'message')
        if ($message -and $message.Length -le 400 -and $message -notmatch '(?i)bearer|token|password|secret|authorization|credential|eyJ|[a-zA-Z0-9_+/=-]{64,}|[\x00-\x1f]') {
            $result.Message = $message
        }
        if ($authenticationFailed) { $result.Message = 'Azure authentication was rejected. Stop here; run Connect-AzAccount for the original lab tenant/environment, explicitly select the original lab subscription with Set-AzContext, then rerun Step 2. No automatic sign-in or write retry was attempted.' }
        elseif ($result.FailureKind -eq 'Authorization') { $result.Message = 'Azure denied authorization. Verify assessment/group write permissions in the selected project and subscription; reconnecting alone does not grant RBAC access.' }
        elseif ($result.FailureKind -eq 'ApiVersion') { $result.Message = 'Azure rejected this documented endpoint/API version. Stop and review the provider metadata and service error code for this route; no preview fallback, route conversion or automatic write retry was attempted.' }
        elseif ($result.FailureKind -eq 'ScopeNotFound') { $result.Message = 'Azure reports the parent resource or scope is missing. Stop and reverify the existing assessment backend; no replacement project or child write was attempted.' }
        return $result
    }
    if ($Method -eq 'GET' -and $result.StatusCode -ne 202 -and $null -eq $data) {
        $result.FailureKind = 'Response'; $result.Message = 'ARM returned no JSON data for the read; assessment state is unverified.'
        return $result
    }
    $properties = Get-LabAssessmentField $data 'properties'
    $provisioning = [string](Get-LabAssessmentField $properties 'provisioningState')
    if ($provisioning -match '^(Failed|Canceled|Cancelled)$') {
        $result.FailureKind = 'Service'; $result.Message = 'ARM reports failed/canceled provisioning. Review the project in the portal before retrying Step 2.'
        return $result
    }
    $result.Success = $true; $result.FailureKind = ''; $result.Message = ''; $result.Data = $data
    $result.Pending = $result.StatusCode -eq 202 -or ($provisioning -and $provisioning -ne 'Succeeded')
    return $result
}

function ConvertTo-LabAssessmentCanonicalId {
    param([AllowNull()][string]$Id)
    if ($null -eq $Id) { return '' }
    return $Id.Replace(' ', '%20')
}

function ConvertTo-LabAssessmentSegment {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 260 -or
        $Name -notmatch '^[-a-zA-Z0-9_.() ]+$' -or $Name -in @('.', '..') -or $Name -ne $Name.Trim()) {
        throw 'Assessment resource name is blank or outside the supported safe ARM name characters.'
    }
    return [Uri]::EscapeDataString($Name)
}

function Test-LabAssessmentPath {
    param([string]$Path, [string]$Method, $Context, [string]$ResourceGroup)
    try { $rg = [regex]::Escape((ConvertTo-LabAssessmentSegment $ResourceGroup)) } catch { return $false }
    $sub = [regex]::Escape([string](Get-LabAssessmentField (Get-LabAssessmentField $Context 'Subscription') 'Id'))
    $name = '(?:[-a-zA-Z0-9_.()]|%20)+'
    $root = '/subscriptions/' + $sub
    $scope = $root + '/resourceGroups/' + $rg + '/providers/Microsoft\.Migrate/'
    if ($Path -match '[\x00-\x20#\\]' -or $Path -match '/\.{1,2}(?:/|\?)') { return $false }
    if ($Method -eq 'GET' -and $Path -match ('^' + $root + '/providers/Microsoft\.Migrate\?api-version=2021-04-01$')) { return $true }
    if ($Method -eq 'GET' -and $Path -match ('^' + $scope + 'migrateProjects/' + $name + '/solutions/Servers-Assessment-ServerAssessment\?api-version=2018-09-01-preview$')) { return $true }
    $project = $scope + 'assessmentProjects/' + $name
    $group = $project + '/groups/' + $name
    $assessment = $group + '/assessments/' + $name
    $query = '\?api-version=2024-01-15'
    $modern = $project + '/assessments/' + $name
    $modernQuery = '\?api-version=2024-03-03-preview'
    if ($Method -in @('GET','PUT') -and $Path -match ('^' + $modern + $modernQuery + '$')) { return $true }
    if ($Method -eq 'PUT') { return $Path -match ('^(?:' + $group + '|' + $assessment + ')' + $query + '$') }
    if ($Method -eq 'POST') { return $Path -match ('^' + $group + '/updateMachines' + $query + '$') }
    if ($Method -ne 'GET') { return $false }
    if ($Path -match ('^' + $project + '\?api-version=2023-03-15$')) { return $true }
    if ($Path -match ('^(?:' + $group + '|' + $assessment + ')' + $query + '$')) { return $true }
    # Only list endpoints can carry continuation metadata; never accept a filter or a new resource path.
    $list = '(?:' + $scope + 'assessmentProjects|' + $project + '/machines|' + $assessment + '/assessedMachines|' + $modern + '/assessedMachines)'
    $parts = $Path.Split('?')
    if ($parts.Count -ne 2 -or $parts[0] -notmatch ('^' + $list + '$')) { return $false }
    $listVersion = if ($parts[0] -match ('^' + $scope + 'assessmentProjects$')) { '2023-03-15' }
        elseif ($parts[0] -match ('^' + $modern + '/assessedMachines$')) { '2024-03-03-preview' } else { '2024-01-15' }
    $keys = @{}; $hasContinuation = $false
    foreach ($pair in $parts[1].Split('&')) {
        $entry = $pair.Split([char[]]'=', 2)
        if ($entry.Count -ne 2 -or $keys.ContainsKey($entry[0])) { return $false }
        $keys[$entry[0]] = $true
        switch ($entry[0]) {
            'api-version' { if ($entry[1] -cne $listVersion) { return $false } }
            'pageSize' { if ($entry[1] -notmatch '^[1-9][0-9]{0,3}$') { return $false } }
            'totalRecordCount' { if ($entry[1] -notmatch '^[0-9]{1,9}$') { return $false } }
            { $_ -in @('continuationToken','skipToken','$skipToken') } {
                if ($hasContinuation -or $entry[1] -notmatch '^[-a-zA-Z0-9_.~%+=]+$' -or $entry[1] -match '%(?![0-9a-fA-F]{2})') { return $false }
                $hasContinuation = $true
            }
            default { return $false }
        }
    }
    return $keys.ContainsKey('api-version')
}

function ConvertTo-LabAssessmentNextPath {
    param([string]$Link, [string]$InitialPath, $Context, [string]$ResourceGroup)
    if ([string]::IsNullOrWhiteSpace($Link) -or $Link -match '[\x00-\x20#\\]' -or $Link.StartsWith('//')) {
        throw 'Assessment pagination returned an unsafe link; no linked request sent.'
    }
    $path = $Link
    if (-not $Link.StartsWith('/')) {
        $uri = $null; $arm = $null
        if (-not [Uri]::TryCreate($Link, [UriKind]::Absolute, [ref]$uri) -or
            -not [Uri]::TryCreate([string](Get-LabAssessmentField (Get-LabAssessmentField $Context 'Environment') 'ResourceManagerUrl'), [UriKind]::Absolute, [ref]$arm) -or
            $uri.Scheme -ne 'https' -or $uri.Scheme -ne $arm.Scheme -or $uri.Authority -ine $arm.Authority -or $uri.UserInfo -or $uri.Fragment) {
            throw 'Assessment pagination left the pinned cloud ARM endpoint; no linked request sent.'
        }
        # Keep the raw path to reject traversal that System.Uri would otherwise normalize away.
        $path = $Link.Substring($Link.IndexOf('/', $Link.IndexOf('://') + 3))
    }
    $initialVersion = [regex]::Match($InitialPath, '[?&]api-version=([^&]+)(?:&|$)').Groups[1].Value
    $nextVersion = [regex]::Match($path, '[?&]api-version=([^&]+)(?:&|$)').Groups[1].Value
    if (-not $initialVersion -or $nextVersion -cne $initialVersion -or
        $path.Split('?')[0] -ine $InitialPath.Split('?')[0] -or
        -not (Test-LabAssessmentPath -Path $InitialPath -Method GET -Context $Context -ResourceGroup $ResourceGroup) -or
        -not (Test-LabAssessmentPath -Path $path -Method GET -Context $Context -ResourceGroup $ResourceGroup)) {
        throw 'Assessment pagination changed resource scope or API/query contract; no linked request sent.'
    }
    return $path
}

function Assert-LabAssessmentResponse {
    param($Response, [string]$Stage)
    if (-not $Response.Success) {
        throw "${Stage} failed (HTTP $($Response.StatusCode); code $($Response.ErrorCode); $($Response.FailureKind)): $($Response.Message)"
    }
}

function Invoke-LabAssessmentRead {
    param([string]$Path, [hashtable]$Session)
    $response = Invoke-LabAssessmentRequest -Path $Path -Method GET @Session
    if (-not $response.Success -and $response.FailureKind -eq 'Transient') {
        Write-Host '  Assessment: transient GET failure; one bounded read retry, no write resubmission.' -ForegroundColor Yellow
        Start-Sleep -Seconds $response.RetryAfter
        $response = Invoke-LabAssessmentRequest -Path $Path -Method GET @Session
    }
    return $response
}

function Get-LabAssessmentCollection {
    param([string]$Path, [hashtable]$Session)
    $items = @(); $seen = @{}; $next = $Path
    while ($next) {
        if ($seen.ContainsKey($next) -or $seen.Count -ge 100) { throw 'Assessment pagination repeated or exceeded 100 pages; collection remains unverified.' }
        $seen[$next] = $true
        $response = Invoke-LabAssessmentRead -Path $next -Session $Session
        Assert-LabAssessmentResponse $response 'Assessment collection GET'
        $collection = $response.Data.PSObject.Properties['value']
        $value = $null
        # Read the property directly: a helper pipeline unwraps singleton arrays and loses empty arrays.
        if ($null -ne $collection) { $value = $collection.Value }
        if ($response.Pending -or $null -eq $collection -or $null -eq $value -or $value -isnot [array]) { throw 'Assessment collection GET is pending or returned an invalid collection; no partial collection accepted.' }
        $items += $value
        if ($items.Count -gt 100000) { throw 'Assessment collection exceeded the safe inventory bound.' }
        $link = Get-LabAssessmentField $response.Data 'nextLink'
        $next = if ([string]::IsNullOrWhiteSpace([string]$link)) { '' } else {
            ConvertTo-LabAssessmentNextPath -Link $link -InitialPath $Path -Context $Session.Context -ResourceGroup $Session.ResourceGroup
        }
    }
    return ,$items
}

function Get-LabAssessmentCatalog {
    param($Provider, [ValidateSet('Modern','Classic')][string]$Mode = 'Classic')
    if ((Get-LabAssessmentField $Provider 'namespace') -ine 'Microsoft.Migrate' -or
        (Get-LabAssessmentField $Provider 'registrationState') -ine 'Registered') {
        throw 'Microsoft.Migrate provider is not verified registered. No provider registration or assessment write attempted.'
    }
    $relevant = @{
        'assessmentProjects' = 'assessmentProjects'; 'assessmentProjects/machines' = 'assessmentProjects/machines'
        'assessmentProjects/groups' = 'assessmentProjects/groups'; 'migrateProjects/solutions' = 'migrateProjects/solutions'
    }
    $required = @('assessmentProjects')
    if ($Mode -eq 'Modern') {
        $relevant['assessmentProjects/assessments'] = 'assessmentProjects/assessments'
        $required += 'assessmentProjects/assessments'
    } else {
        $relevant['assessmentProjects/groups/assessments'] = 'assessmentProjects/groups/assessments'
        $relevant['assessmentProjects/groups/assessments/assessedMachines'] = 'assessmentProjects/groups/assessments/assessedMachines'
    }
    $types = $null
    if ($Provider -is [System.Collections.IDictionary]) { $types = $Provider['resourceTypes'] }
    elseif ($null -ne $Provider) {
        $property = $Provider.PSObject.Properties['resourceTypes']
        if ($null -ne $property) { $types = $property.Value }
    }
    if ($types -isnot [array]) { throw 'Microsoft.Migrate provider metadata field resourceTypes must be an array. No write attempted.' }
    $catalog = [System.Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase); $duplicates = 0
    for ($rowIndex = 0; $rowIndex -lt $types.Count; $rowIndex++) {
        $row = $types[$rowIndex]; $rawType = Get-LabAssessmentField $row 'resourceType'
        # Unused provider routes cannot establish or invalidate this assessment contract.
        if ($rawType -isnot [string] -or -not $relevant.ContainsKey($rawType.Trim())) { continue }
        $type = $relevant[$rawType.Trim()]
        $versions = $null
        # Preserve the JSON array shape, including empty/singleton arrays, without pipeline unrolling.
        if ($row -is [System.Collections.IDictionary]) { $versions = $row['apiVersions'] }
        else {
            $property = $row.PSObject.Properties['apiVersions']
            if ($null -ne $property) { $versions = $property.Value }
        }
        $problem = ''
        if ($versions -isnot [array]) { $problem = 'apiVersions must be an array' }
        elseif ($versions.Count -eq 0) { $problem = 'apiVersions must not be empty' }
        $rowVersions = [System.Collections.Hashtable]::new([StringComparer]::OrdinalIgnoreCase)
        if (-not $problem) {
            for ($versionIndex = 0; $versionIndex -lt $versions.Count; $versionIndex++) {
                $version = $versions[$versionIndex]
                if ($version -isnot [string]) { $problem = "apiVersions[$versionIndex] must be a string"; break }
                $version = $version.Trim()
                if ($version.Length -gt 128 -or $version -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]*$') {
                    $problem = "apiVersions[$versionIndex] must be a bounded nonempty metadata token"; break
                }
                if ($rowVersions.ContainsKey($version)) { $duplicates++ }
                else { $rowVersions[$version] = $true }
            }
        }
        if ($problem) {
            $diagnostic = "Microsoft.Migrate provider metadata resourceTypes[$rowIndex] ($type): $problem."
            if ($required -contains $type) { throw "$diagnostic No write attempted." }
            Write-Host "  Assessment: $diagnostic Optional catalog row ignored; validating the fixed documented endpoint read-only before its associated writes; support remains unverified." -ForegroundColor Yellow
            continue
        }
        if ($catalog.ContainsKey($type)) { $duplicates++ }
        else { $catalog[$type] = @() }
        foreach ($version in $rowVersions.Keys) {
            if ($catalog[$type] -contains $version) { $duplicates++ }
            else { $catalog[$type] += $version }
        }
    }
    if ($duplicates -gt 0) {
        Write-Host "  Assessment: normalized $duplicates harmless duplicate relevant catalog rows/API-version entries; endpoint/profile versions remain fixed." -ForegroundColor Gray
    }
    return $catalog
}

function Assert-LabAssessmentProvider {
    param($Provider, [ValidateSet('Modern','Classic')][string]$Mode = 'Classic', [switch]$PassThru)
    $catalog = Get-LabAssessmentCatalog -Provider $Provider -Mode $Mode
    # The provider catalog is not an exhaustive inventory of nested assessment routes.
    $requirements = [ordered]@{
        'assessmentProjects' = '2023-03-15'; 'assessmentProjects/machines' = '2024-01-15'
        'assessmentProjects/groups' = '2024-01-15'; 'assessmentProjects/groups/assessments' = '2024-01-15'
        'assessmentProjects/groups/assessments/assessedMachines' = '2024-01-15'
        'migrateProjects/solutions' = '2018-09-01-preview'
    }
    if (-not $catalog.ContainsKey('assessmentProjects') -or $catalog['assessmentProjects'] -notcontains '2023-03-15') {
        throw 'Microsoft.Migrate provider metadata resourceType assessmentProjects field apiVersions does not advertise selected parent API 2023-03-15. No version fallback or write attempted.'
    }
    foreach ($type in $requirements.Keys) {
        if ($type -eq 'assessmentProjects' -or ($Mode -eq 'Modern' -and $type -like 'assessmentProjects/groups/assessments*')) { continue }
        if (-not $catalog.ContainsKey($type)) {
            Write-Host "  Assessment: $type not advertised in the provider catalog; validating documented endpoint API $($requirements[$type]) read-only before its associated writes. Catalog absence is not proof of unsupported API." -ForegroundColor Yellow
        } elseif ($catalog[$type] -notcontains $requirements[$type]) {
            Write-Host "  Assessment: catalog row $type does not advertise documented API $($requirements[$type]); endpoint support is not verified. Validating the fixed documented endpoint read-only; no preview fallback." -ForegroundColor Yellow
        }
    }
    if ($PassThru) { return $catalog }
}

function Get-LabAssessmentProfile {
    param($Provider, [ValidateSet('Modern','Classic')][string]$Mode)
    $catalog = Assert-LabAssessmentProvider -Provider $Provider -Mode $Mode -PassThru
    if ($Mode -eq 'Classic') { return [pscustomobject]@{ Mode = 'Classic'; Version = '2024-01-15' } }
    # Extend only with separately reviewed public request/response contracts, never date-sort APIs.
    $profiles = @([pscustomobject]@{ Mode = 'Modern'; Version = '2024-03-03-preview' })
    $versions = @()
    if ($catalog.ContainsKey('assessmentProjects/assessments')) { $versions = $catalog['assessmentProjects/assessments'] }
    $unimplemented = @($versions | Where-Object { $_ -notin @($profiles | ForEach-Object { $_.Version }) })
    if ($unimplemented.Count -gt 0) {
        Write-Host "  Assessment: assessmentProjects/assessments field apiVersions contains $($unimplemented.Count) unverified/unimplemented tokens; skipped, not selected by date." -ForegroundColor Yellow
    }
    if ($versions -contains '2025-09-09-preview') {
        Write-Host '  Assessment: skipped advertised 2025-09-09-preview; unverified/unimplemented modern contract, not selected by date.' -ForegroundColor Yellow
    }
    foreach ($profile in $profiles) {
        if ($versions -contains $profile.Version) {
            Write-Host "  Assessment: Modern PREVIEW profile $($profile.Version) selected from actual provider metadata; no feature registration or Classic fallback." -ForegroundColor Yellow
            return $profile
        }
    }
    throw 'Microsoft.Migrate provider metadata resourceType assessmentProjects/assessments field apiVersions does not advertise Modern API 2024-03-03-preview. Stop before group writes; no automatic downgrade. Review service availability or explicitly choose -AssessmentMode Classic.'
}

function Resolve-LabAssessmentProject {
    param([string]$MigrateProjectName, [string]$ExplicitName, [hashtable]$Session)
    $sub = [string](Get-LabAssessmentField (Get-LabAssessmentField $Session.Context 'Subscription') 'Id')
    $base = '/subscriptions/' + $sub + '/resourceGroups/' + (ConvertTo-LabAssessmentSegment $Session.ResourceGroup) + '/providers/Microsoft.Migrate'
    Write-Host "  Assessment: resolving backend linked to Migrate project '$MigrateProjectName' (read-only)." -ForegroundColor Gray
    $solutionId = $base + '/migrateProjects/' + (ConvertTo-LabAssessmentSegment $MigrateProjectName) + '/solutions/Servers-Assessment-ServerAssessment'
    $solution = Invoke-LabAssessmentRead -Path ($solutionId + '?api-version=2018-09-01-preview') -Session $Session
    $reference = ''
    if ($solution.Success) {
        if ($solution.Pending -or (ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $solution.Data 'id')) -ine $solutionId) { throw 'Selected Migrate project solution response identity/state is unverified.' }
        $details = Get-LabAssessmentField (Get-LabAssessmentField $solution.Data 'properties') 'details'
        $reference = ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField (Get-LabAssessmentField $details 'extendedDetails') 'projectId')
    } elseif ($solution.FailureKind -ne 'NotFound') { Assert-LabAssessmentResponse $solution 'Assessment solution GET' }
    $pattern = '^' + [regex]::Escape($base) + '/assessmentProjects/((?:[-a-zA-Z0-9_.()]|%20)+)$'
    $linkedName = ''
    if ($reference -match $pattern -and $reference -notmatch '/\.{1,2}$') { $linkedName = [Uri]::UnescapeDataString($Matches[1]) }
    if ($ExplicitName) { $null = ConvertTo-LabAssessmentSegment $ExplicitName }
    if ($linkedName -and $ExplicitName -and $linkedName -ine $ExplicitName) {
        throw 'Explicit AssessmentProjectName conflicts with the selected Migrate project solution reference. Existing projects are preserved.'
    }
    $name = if ($linkedName) { $linkedName } else { $ExplicitName }
    if (-not $name) {
        Write-Host '  Assessment: no verifiable solution projectId. Existing same-scope assessment backends (not automatically selected):' -ForegroundColor Yellow
        $projects = Get-LabAssessmentCollection -Path ($base + '/assessmentProjects?api-version=2023-03-15') -Session $Session
        foreach ($candidate in $projects) {
            if ((ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $candidate 'id')) -notmatch $pattern -or
                (Get-LabAssessmentField $candidate 'type') -ine 'Microsoft.Migrate/assessmentProjects') { throw 'Assessment-project listing contains a foreign or malformed resource; selection stopped.' }
            $candidateName = [Uri]::UnescapeDataString($Matches[1])
            $props = Get-LabAssessmentField $candidate 'properties'
            Write-Host "    $candidateName | region $(Get-LabAssessmentField $candidate 'location') | type Microsoft.Migrate/assessmentProjects | $(Get-LabAssessmentField $props 'projectStatus') / $(Get-LabAssessmentField $props 'provisioningState')" -ForegroundColor Gray
        }
        if ($projects.Count -eq 0) { Write-Host '    No existing classic assessment backend was returned.' -ForegroundColor Yellow }
        throw 'Backend association is missing or malformed. Review the listed actual names and rerun Step 2 with -AssessmentProjectName <existing-name>; even one candidate is never selected silently. No project is created.'
    }
    if (-not $linkedName) { Write-Host '  Assessment: explicit backend selected without a verified solution link; all four source ARM IDs must match its inventory before any write.' -ForegroundColor Yellow }
    Write-Host "  Assessment: resolved assessment project '$name'; parent GET API 2023-03-15, shared machine/group API 2024-01-15 (read-only verification before writes)." -ForegroundColor Cyan
    $projectId = $base + '/assessmentProjects/' + (ConvertTo-LabAssessmentSegment $name)
    $project = Invoke-LabAssessmentRead -Path ($projectId + '?api-version=2023-03-15') -Session $Session
    Assert-LabAssessmentResponse $project 'Resolved assessment project GET'
    $props = Get-LabAssessmentField $project.Data 'properties'
    if ($project.Pending -or (ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $project.Data 'id')) -ine $projectId -or
        (Get-LabAssessmentField $project.Data 'type') -ine 'Microsoft.Migrate/assessmentProjects' -or
        (Get-LabAssessmentField $props 'provisioningState') -ine 'Succeeded' -or (Get-LabAssessmentField $props 'projectStatus') -ine 'Active') {
        throw 'Resolved assessment backend identity/type or Active/Succeeded state is unverified. No project or VM recreation attempted.'
    }
    return [pscustomobject]@{ Name = $name; Id = $projectId }
}

function Get-LabAssessmentMachineMap {
    param([object[]]$Workloads, [object[]]$Inventory, [string]$ProjectId)
    $expected = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App')
    $sourceScope = $ProjectId.Substring(0, $ProjectId.IndexOf('/providers/', [StringComparison]::OrdinalIgnoreCase))
    $sourcePattern = '^' + [regex]::Escape($sourceScope) + '/providers/Microsoft\.OffAzure/HyperVSites/(?:[-a-zA-Z0-9_.()]|%20)+/machines/(?:[-a-zA-Z0-9_.()]|%20)+$'
    $machinePattern = '^' + [regex]::Escape($ProjectId) + '/machines/(?:[-a-zA-Z0-9_.()]|%20)+$'
    if ($Workloads.Count -ne 4) { throw 'Assessment requires exactly the four selected workload records.' }
    $seenSources = @{}; $seenAssessment = @{}; $seenNames = @{}; $mapped = @()
    foreach ($workload in $Workloads) {
        $source = ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $workload 'Id'); $name = [string](Get-LabAssessmentField $workload 'DisplayName')
        if ($source -notmatch $sourcePattern -or $source -match '/\.{1,2}(?:/|$)' -or $name -notin $expected -or
            $seenSources.ContainsKey($source) -or $seenNames.ContainsKey($name)) { throw 'Selected workloads have duplicate/foreign/malformed source IDs or unexpected names; no assessment write attempted.' }
        $rows = @($Inventory | Where-Object { (ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField (Get-LabAssessmentField $_ 'properties') 'discoveryMachineArmId')) -ieq $source })
        if ($rows.Count -ne 1) { throw "Assessment inventory must have exactly one source-ID match for '$name'. Discovery may not have synchronized to the backend yet; rerun Step 2 later, not deployment. No IDs are fabricated." }
        $row = $rows[0]; $id = ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $row 'id'); $props = Get-LabAssessmentField $row 'properties'
        $displayName = [string](Get-LabAssessmentField $props 'displayName')
        if ($id -notmatch $machinePattern -or $id -match '/\.{1,2}$' -or (Get-LabAssessmentField $row 'type') -ine 'Microsoft.Migrate/assessmentProjects/machines' -or
            $seenAssessment.ContainsKey($id) -or ($displayName -and $displayName -ine $name)) { throw 'Matched assessment machine has a duplicate/foreign ID, wrong type or mismatching display name; no write attempted.' }
        $seenSources[$source] = $true; $seenAssessment[$id] = $true; $seenNames[$name] = $true
        $mapped += [pscustomobject]@{ Name = $name; SourceId = $source; AssessmentId = $id }
    }
    return ,$mapped
}

function Get-LabAssessmentMembership {
    param([object[]]$Inventory, [string]$GroupId, [object[]]$Machines)
    $members = @{}; $expected = @{}
    foreach ($machine in $Machines) { $expected[$machine.AssessmentId] = $true }
    $projectId = $GroupId.Substring(0, $GroupId.IndexOf('/groups/', [StringComparison]::OrdinalIgnoreCase))
    foreach ($row in $Inventory) {
        $groups = @(Get-LabAssessmentField (Get-LabAssessmentField $row 'properties') 'groups' | ForEach-Object { ConvertTo-LabAssessmentCanonicalId $_ })
        if ($groups -icontains $GroupId) {
            $id = ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $row 'id')
            if ($id -notmatch ('^' + [regex]::Escape($projectId) + '/machines/(?:[-a-zA-Z0-9_.()]|%20)+$') -or $id -match '/\.{1,2}$' -or
                (Get-LabAssessmentField $row 'type') -ine 'Microsoft.Migrate/assessmentProjects/machines' -or $members.ContainsKey($id)) {
                throw 'Group membership inventory contains malformed/foreign/duplicate machine records.'
            }
            $members[$id] = $true
        }
    }
    foreach ($id in $members.Keys) { if (-not $expected.ContainsKey($id)) { return 'Conflict' } }
    if ($members.Count -eq 4 -and $expected.Count -eq 4) { return 'Exact' }
    if ($members.Count -eq 0) { return 'Empty' }
    return 'Partial'
}

function Get-LabAssessmentSettings {
    param([string]$Location, [string]$Currency, [string]$Offer, [string]$HybridBenefit,
        [ValidateSet('Modern','Classic')][string]$Mode = 'Classic')
    $currencies = @('USD','DKK','CAD','IDR','JPY','KRW','NZD','NOK','RUB','SAR','ZAR','SEK','TRY','GBP','MXN','MYR','INR','HKD','BRL','TWD','EUR','CHF','ARS','AUD','CNY')
    $offers = @('MSAZR0003P','MSAZR0044P','MSAZR0059P','MSAZR0060P','MSAZR0062P','MSAZR0063P','MSAZR0064P','MSAZR0029P','MSAZR0022P','MSAZR0023P','MSAZR0148P','MSAZR0025P','MSAZR0036P','MSAZR0120P','MSAZR0121P','MSAZR0122P','MSAZR0123P','MSAZR0124P','MSAZR0125P','MSAZR0126P','MSAZR0127P','MSAZR0128P','MSAZR0129P','MSAZR0130P','MSAZR0111P','MSAZR0144P','MSAZR0149P','MSMCAZR0044P','MSMCAZR0059P','MSMCAZR0060P','MSMCAZR0063P','MSMCAZR0120P','MSMCAZR0121P','MSMCAZR0125P','MSMCAZR0128P','MSAZRDE0003P','MSAZRDE0044P','MSAZRUSGOV0003P','EA','MSAZR0243P','SavingsPlan1Year','SavingsPlan3Year')
    if ($Mode -eq 'Modern') {
        $offers = @('EA','MSAZR0003P','MSAZR0023P','MSAZRUSGOV0003P','MSMCAZR0044P','MSMCAZR0059P','MSMCAZR0060P','MSMCAZR0063P','SavingsPlan1Year','SavingsPlan3Year')
    }
    $normalizedOffer = $Offer.Replace('-', '')
    $wireOffer = @($offers | Where-Object { $_ -ieq $normalizedOffer })
    if ($Currency -notin $currencies -or $wireOffer.Count -ne 1 -or $HybridBenefit -notin @('Yes','No') -or $Location -notmatch '^[a-zA-Z0-9]+$') {
        throw 'Assessment pricing/region input is outside the supported API enum contract. Specify a published currency/offer and Yes/No benefit; Unknown is never substituted.'
    }
    if ($Mode -eq 'Modern') {
        return @{ sizingCriterion = 'AsOnPremises'; azureLocation = $Location; currency = $Currency.ToUpperInvariant()
            azureHybridUseBenefit = $HybridBenefit; linuxAzureHybridUseBenefit = 'No'; azurePricingTier = 'Standard'
            azureStorageRedundancy = 'LocallyRedundant'; scalingFactor = [int]1; discountPercentage = [int]0
            savingsSettings = @{ azureOfferCode = $wireOffer[0]; savingsOptions = 'None' }; environmentType = 'Production' }
    }
    return @{ sizingCriterion = 'AsOnPremises'; azureLocation = $Location; currency = $Currency.ToUpperInvariant()
        azureOfferCode = $wireOffer[0]; azureHybridUseBenefit = $HybridBenefit; linuxAzureHybridUseBenefit = 'No'
        reservedInstance = 'None'; azurePricingTier = 'Standard'; azureStorageRedundancy = 'LocallyRedundant'
        scalingFactor = 1.0; discountPercentage = 0.0 }
}

function Assert-LabAssessmentIdentity {
    param($Resource, [string]$Id, [string]$Type)
    if ((ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $Resource 'id')) -ine $Id -or (Get-LabAssessmentField $Resource 'type') -ine $Type) {
        throw 'Assessment resource GET returned a different identity/type; requested resource remains unverified.'
    }
}

function Assert-LabAssessmentSettings {
    param($Resource, [string]$AssessmentId, [hashtable]$Settings)
    Assert-LabAssessmentIdentity $Resource $AssessmentId 'Microsoft.Migrate/assessmentProjects/groups/assessments'
    $props = Get-LabAssessmentField $Resource 'properties'
    if ((Get-LabAssessmentField $props 'assessmentType') -ine 'MachineAssessment' -or
        (Get-LabAssessmentField $props 'groupType') -ine 'Default') { throw 'Existing assessment is not the requested classic MachineAssessment/Default group type. It is preserved.' }
    foreach ($key in $Settings.Keys) {
        if ($null -eq (Get-LabAssessmentField $props $key) -or (Get-LabAssessmentField $props $key) -ine $Settings[$key]) {
            throw "Assessment settings differ from the requested $key. Existing assessment is preserved; review it or select an unused -AssessmentName."
        }
    }
    $status = [string](Get-LabAssessmentField $props 'status')
    if ($status -notin @('Created','Updated','Running','Completed')) { throw 'Assessment is invalid, stale, out-of-sync, deleted or has an unknown status. Review it or select an unused -AssessmentName; no overwrite attempted.' }
}

function Assert-LabModernSettingSubset {
    param($Actual, [hashtable]$Expected)
    foreach ($key in $Expected.Keys) {
        $value = Get-LabAssessmentField $Actual $key
        if ($Expected[$key] -is [hashtable]) { Assert-LabModernSettingSubset -Actual $value -Expected $Expected[$key] }
        elseif ($null -eq $value -or $value -is [array] -or $value -is [System.Collections.IDictionary] -or
            [string]$value -ine [string]$Expected[$key]) {
            throw "Modern settings differ or are missing at $key. Preserve the assessment; review it or select an unused -AssessmentName."
        }
    }
}

function Assert-LabModernAssessment {
    param($Resource, [string]$AssessmentId, [string]$GroupId, [hashtable]$Settings)
    Assert-LabAssessmentIdentity $Resource $AssessmentId 'Microsoft.Migrate/assessmentProjects/assessments'
    $props = Get-LabAssessmentField $Resource 'properties'
    $scope = Get-LabAssessmentField $props 'scope'
    if ((Get-LabAssessmentField $scope 'scopeType') -ine 'ServerGroupId' -or
        (ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $scope 'serverGroupId')) -ine $GroupId) {
        throw 'Modern assessment scope differs from the verified exact-four ServerGroupId. Existing assessment preserved; no overwrite.'
    }
    Assert-LabModernSettingSubset -Actual (Get-LabAssessmentField $props 'settings') -Expected $Settings
    $status = [string](Get-LabAssessmentField (Get-LabAssessmentField $props 'details') 'status')
    if ($status -notin @('Created','Updated','Running','Completed')) {
        throw 'Modern details.status is terminal, stale or Unverified (unknown/missing response shape). Preserve the assessment; no fallback/recompute PUT.'
    }
    # Public GET example exposes details.status, not a mandatory provisioningState. Never require a phantom field.
    $provisioning = [string](Get-LabAssessmentField $props 'provisioningState')
    if ($provisioning -and $provisioning -notin @('Succeeded','Provisioning','Updating','Accepted')) {
        throw 'Modern optional provisioningState is failed, canceled, deleting or Unverified. No handoff.'
    }
    return $status
}

function Get-LabModernArray {
    param($Object, [string]$Name, [switch]$Required)
    $value = $null
    if ($Object -is [System.Collections.IDictionary]) { $value = $Object[$Name] }
    elseif ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { $value = $property.Value }
    }
    if ($null -eq $value) {
        if ($Required) { throw "SourceUnverified: missing modern $Name array; no result handoff." }
        return ,@()
    }
    if ($value -isnot [array]) { throw "Unverified: modern $Name has an unexpected non-array shape; no result handoff." }
    return ,$value
}

function Assert-LabModernAssessedMachines {
    param([object[]]$Results, [object[]]$Machines, [string]$AssessmentId)
    if ($Results.Count -ne 4 -or $Machines.Count -ne 4) { throw 'SourceUnverified: modern Completed assessment requires exactly four fully paginated results.' }
    $seen = @{}; $seenIds = @{}; $adapted = @()
    foreach ($row in $Results) {
        $id = ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $row 'id')
        $props = Get-LabAssessmentField $row 'properties'
        if ($id -notmatch ('^' + [regex]::Escape($AssessmentId) + '/assessedMachines/(?:[-a-zA-Z0-9_.()]|%20)+$') -or
            $id -match '/\.{1,2}$' -or $seenIds.ContainsKey($id) -or
            (Get-LabAssessmentField $row 'type') -ine 'Microsoft.Migrate/assessmentProjects/assessments/assessedMachines') {
            throw 'SourceUnverified: modern result has a duplicate/foreign/malformed resource identity or type.'
        }
        $matches = @{}
        foreach ($link in (Get-LabModernArray -Object $props -Name linkages -Required)) {
            $armId = ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $link 'armId')
            foreach ($machine in $Machines) {
                if ($armId -ieq $machine.SourceId -or $armId -ieq $machine.AssessmentId) { $matches[$machine.SourceId] = $machine }
            }
        }
        if ($matches.Count -ne 1) {
            $fields = @($props.PSObject.Properties.Name | Where-Object { $_ -match '^[a-zA-Z][a-zA-Z0-9]{0,60}$' }) -join ', '
            Write-Host "  Modern result shape fields: $fields (no IDs or full response logged)." -ForegroundColor Yellow
            $kinds = @(Get-LabAssessmentField $props 'linkages' | ForEach-Object { Get-LabAssessmentField $_ 'kind' } | Where-Object { $_ -is [string] -and $_ -match '^[a-zA-Z][a-zA-Z0-9_.-]{0,40}$' }) -join ', '
            Write-Host "  Modern result linkage-kind labels: $kinds (semantics not assumed)." -ForegroundColor Yellow
            throw 'SourceUnverified: modern Completed result linkages.armId does not match exactly one known source/assessment machine. Creation may have completed; do not redo PUT or use name-only matching. Review linkages in the portal.'
        }
        $machine = @($matches.Values)[0]
        if ($seen.ContainsKey($machine.SourceId)) { throw 'SourceUnverified: duplicate modern machine linkage; no four-result handoff.' }
        $seen[$machine.SourceId] = $true; $seenIds[$id] = $true
        $workloadType = Get-LabAssessmentField $props 'workloadType'
        if (-not $workloadType) { $workloadType = 'NoData' }
        $recommendations = Get-LabModernArray -Object $props -Name recommendations
        foreach ($recommendation in $recommendations) {
            $null = Get-LabModernArray -Object $recommendation -Name skus
            $null = Get-LabModernArray -Object (Get-LabAssessmentField $recommendation 'recommendedFor') -Name strategies
            foreach ($cost in (Get-LabModernArray -Object $recommendation -Name totalCost)) {
                $null = Get-LabModernArray -Object $cost -Name costDetail
            }
        }
        $adapted += [pscustomobject]@{ Name = $machine.Name; WorkloadType = $workloadType; Recommendations = $recommendations }
    }
    return ,$adapted
}

function Show-LabModernRecommendations {
    param([object[]]$Results)
    foreach ($machine in $Results) {
        Write-Host "  VM: $($machine.Name) | returned workloadType: $($machine.WorkloadType)" -ForegroundColor White
        if ($machine.Recommendations.Count -eq 0) { Write-Host '    Recommendations: NoData' -ForegroundColor Yellow }
        foreach ($recommendation in $machine.Recommendations) {
            $configuration = Get-LabAssessmentField $recommendation 'configuration'
            $target = Get-LabAssessmentField $configuration 'azureTarget'
            $sizing = Get-LabAssessmentField $configuration 'sizingCriterion'
            $readiness = Get-LabAssessmentField (Get-LabAssessmentField $recommendation 'migrationSuitability') 'readiness'
            $strategies = @(Get-LabAssessmentField (Get-LabAssessmentField $recommendation 'recommendedFor') 'strategies') -join ', '
            if (-not $target) { $target = 'NoData' }; if (-not $sizing) { $sizing = 'NoData' }
            if (-not $readiness) { $readiness = 'NoData' }; if (-not $strategies) { $strategies = 'NoData' }
            Write-Host "    Returned target: $target | sizing: $sizing | readiness: $readiness | strategies: $strategies" -ForegroundColor Gray
            $skus = @(Get-LabAssessmentField $recommendation 'skus' | Where-Object { $null -ne $_ })
            if ($skus.Count -eq 0) { Write-Host '    SKU: NoData' -ForegroundColor Gray }
            foreach ($sku in $skus) {
                $name = Get-LabAssessmentField (Get-LabAssessmentField $sku 'details') 'skuName'
                if (-not $name) { $name = 'NoData' }
                Write-Host "    Returned SKU: $name" -ForegroundColor Gray
            }
            $costs = @(Get-LabAssessmentField $recommendation 'totalCost' | Where-Object { $null -ne $_ })
            if ($costs.Count -eq 0) { Write-Host '    Cost details: NoData' -ForegroundColor Gray }
            foreach ($cost in $costs) {
                $details = @(Get-LabAssessmentField $cost 'costDetail' | Where-Object { $null -ne $_ })
                if ($details.Count -eq 0) { Write-Host '    Cost details: NoData' -ForegroundColor Gray }
                foreach ($detail in $details) {
                    $name = Get-LabAssessmentField $detail 'name'; $value = Get-LabAssessmentField $detail 'value'
                    $savings = Get-LabAssessmentField $detail 'savingsOptions'
                    if (-not $name) { $name = 'NoData' }; if ($null -eq $value) { $value = 'NoData' }; if (-not $savings) { $savings = 'NoData' }
                    Write-Host "    Returned cost detail: $name = $value | savingsOptions: $savings (units/period not inferred)" -ForegroundColor Gray
                }
            }
        }
    }
    Write-Host '  Alternatives are not summed. Target/strategy codes are not translated without a verified enum contract.' -ForegroundColor Gray
}

function Assert-LabAssessmentMachineMapStable {
    param([object[]]$Expected, [object[]]$Current)
    foreach ($old in $Expected) {
        $mapMatches = @($Current | Where-Object { $_.SourceId -ieq $old.SourceId -and $_.AssessmentId -ieq $old.AssessmentId })
        if ($mapMatches.Count -ne 1) { throw 'Source-to-assessment machine mapping changed during this run. No stale IDs may be written or handed off.' }
    }
}

function Get-LabAssessmentArray {
    param([AllowNull()]$Object, [string]$Name, [switch]$AllowMissing)
    $value = $null
    if ($Object -is [System.Collections.IDictionary]) { $value = $Object[$Name] }
    elseif ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { $value = $property.Value }
    }
    if ($null -eq $value -and $AllowMissing) { return $null }
    if ($value -isnot [array]) { throw "Assessment field $Name must be an array; state remains unverified." }
    # Preserve empty/singleton JSON arrays in Windows PowerShell 5.1.
    return ,$value
}

function Test-LabAssessmentGroupReady {
    param($Resource, [string]$GroupId, [bool]$Pending = $false, [switch]$RequireMembership, [switch]$RequireIdle)
    Assert-LabAssessmentIdentity $Resource $GroupId 'Microsoft.Migrate/assessmentProjects/groups'
    $props = Get-LabAssessmentField $Resource 'properties' -PreserveArray
    $type = Get-LabAssessmentField $props 'groupType' -PreserveArray
    $status = Get-LabAssessmentField $props 'groupStatus' -PreserveArray
    $provisioning = Get-LabAssessmentField $props 'provisioningState' -PreserveArray
    if ($type -isnot [string] -or $type -ine 'Default') { throw 'Group type is missing or not Default; existing group preserved.' }
    if ($status -isnot [string] -or $status -notin @('Created','Updated','Running','Completed')) {
        throw 'Group status is failed, canceled, deleting, malformed or unknown; existing group preserved.'
    }
    if ($null -ne $provisioning -and ($provisioning -isnot [string] -or
        $provisioning -notin @('Succeeded','Accepted','Provisioning','Updating','Creating','Running'))) {
        throw 'Group provisioningState is failed, canceled, deleting, malformed or unknown; Completed cannot override it.'
    }
    $capabilities = Get-LabAssessmentArray $props 'supportedAssessmentTypes' -AllowMissing
    $capabilityLabels = @()
    foreach ($capability in $capabilities) {
        if ($capability -isnot [string] -or $capability -notmatch '^[a-zA-Z][a-zA-Z0-9_.-]{0,79}$') {
            throw 'Group supportedAssessmentTypes contains a malformed value; no assessment write or handoff.'
        }
        $capabilityLabels += $capability
    }
    $count = Get-LabAssessmentField $props 'machineCount' -PreserveArray
    if (($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0) { throw 'Group machineCount is missing or malformed; existing group preserved.' }
    $provisioningLabel = if ($null -eq $provisioning) { '<absent/null>' } else { $provisioning }
    $capabilityLabel = if ($null -eq $capabilities) { '<absent/null>' } elseif ($capabilities.Count -eq 0) { '<empty>' } else { $capabilityLabels -join ', ' }
    Write-Host "  Assessment: Default group status $status; provisioning $provisioningLabel; supported types $capabilityLabel; machineCount $count." -ForegroundColor Gray
    if ($Pending -or $status -eq 'Running') { return $false }
    # Live Completed group GETs omit provisioningState. Without it, Created/Updated are still pending.
    if ($null -eq $provisioning) { if ($status -ine 'Completed') { return $false } }
    elseif ($provisioning -ine 'Succeeded') { return $false }
    if ($RequireMembership) {
        if ($count -ne 4) { return $false }
        if ($null -ne $capabilities -and $capabilities -notcontains 'MachineAssessment') { return $false }
        if ($null -eq $capabilities) { Write-Host '  Assessment: capability field absent; exact membership and the assessment service response must establish the requested contract.' -ForegroundColor Yellow }
    }
    if ($RequireIdle) {
        $running = Get-LabAssessmentField $props 'areAssessmentsRunning' -PreserveArray
        if ($running -isnot [bool]) { throw 'Group assessment activity is missing or malformed; state remains unverified.' }
        if ($running) { return $false }
    }
    return $true
}

function Wait-LabAssessmentGroup {
    param([string]$Path, [hashtable]$Session, [ValidateRange(1,10)][int]$MaxAttempts = 10)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $response = Invoke-LabAssessmentRead -Path $Path -Session $Session
        if (-not $response.Success -and $response.FailureKind -eq 'NotFound') {
            Write-Host "  Assessment: group visibility pending (HTTP 404), attempt $attempt/$MaxAttempts." -ForegroundColor Gray
        } else {
            Assert-LabAssessmentResponse $response 'Server group GET'
            if ($null -ne $response.Data -and (Test-LabAssessmentGroupReady -Resource $response.Data -GroupId $Path.Split('?')[0] -Pending $response.Pending)) { return $response.Data }
        }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $response.RetryAfter }
    }
    return $null
}

function Initialize-LabAssessmentGroup {
    param($Outcome, $Project, [string]$GroupName, [object[]]$Workloads, [hashtable]$Session)
    $groupId = $Outcome.GroupPath.Split('?')[0]
    $outcome.Stage = 'Assessment machine mapping'
    Write-Host '  Assessment: reading all inventory pages and mapping exactly four discovery ARM IDs to assessment machine ARM IDs.' -ForegroundColor Gray
    $inventory = Get-LabAssessmentCollection -Path $outcome.MachinePath -Session $Session
    $outcome.Machines = Get-LabAssessmentMachineMap -Workloads $Workloads -Inventory $inventory -ProjectId $project.Id
    foreach ($machine in $outcome.Machines) { Write-Host "    $($machine.Name): unique source/assessment inventory match." -ForegroundColor Green }
    $outcome.Stage = 'Server group preflight GET'
    $groupRead = Invoke-LabAssessmentRead -Path $outcome.GroupPath -Session $Session
    $owned = $false
    if (-not $groupRead.Success -and $groupRead.FailureKind -eq 'NotFound') {
        $outcome.Stage = 'Server group PUT'
        Write-Host "  Assessment: creating new Default group '$GroupName' (no machines in create payload)." -ForegroundColor Gray
        $body = @{ properties = @{ groupType = 'Default' } } | ConvertTo-Json -Depth 5
        $write = Invoke-LabAssessmentRequest -Path $outcome.GroupPath -Method PUT -Payload $body @Session
        Assert-LabAssessmentResponse $write 'Server group PUT'
        if ($null -ne $write.Data) { Assert-LabAssessmentIdentity $write.Data $groupId 'Microsoft.Migrate/assessmentProjects/groups' }
        $owned = $true
    } else { Assert-LabAssessmentResponse $groupRead 'Server group preflight GET' }
    $outcome.Stage = 'Server group provisioning'
    $group = Wait-LabAssessmentGroup -Path $outcome.GroupPath -Session $Session
    if ($null -eq $group) { $outcome.State = 'GroupPending'; $outcome.Message = 'Group provisioning did not complete in ten reads. No assessment PUT sent; review the group before rerunning Step 2.'; return $null }
    $outcome.Stage = 'Server group membership preflight'
    $inventory = Get-LabAssessmentCollection -Path $outcome.MachinePath -Session $Session
    $currentMap = Get-LabAssessmentMachineMap -Workloads $Workloads -Inventory $inventory -ProjectId $project.Id
    Assert-LabAssessmentMachineMapStable -Expected $outcome.Machines -Current $currentMap
    $membership = Get-LabAssessmentMembership -Inventory $inventory -GroupId $groupId -Machines $outcome.Machines
    $groupProps = Get-LabAssessmentField $group 'properties'
    if ($membership -ne 'Exact') {
        $running = Get-LabAssessmentField $groupProps 'areAssessmentsRunning' -PreserveArray
        if (-not $owned -or $membership -ne 'Empty' -or $running -isnot [bool] -or $running -or
            (Get-LabAssessmentArray $groupProps 'assessments').Count -gt 0 -or
            (Get-LabAssessmentField $groupProps 'machineCount') -ne 0) {
            throw 'Existing or concurrently changed group does not contain exactly the four workloads. Empty/different/extra members and active assessments are preserved; select an unused -AssessmentGroupName. No remove, replacement or DELETE attempted.'
        }
        $outcome.Stage = 'Server group updateMachines POST'
        Write-Host '  Assessment: adding four assessment namespace machine IDs to the newly created group.' -ForegroundColor Gray
        $ids = @($outcome.Machines | ForEach-Object { $_.AssessmentId })
        $body = @{ properties = @{ operationType = 'Add'; machines = $ids } } | ConvertTo-Json -Depth 5
        # updateMachines has an optional payload eTag, not a documented Group GET eTag. No wildcard or concurrency claim.
        $update = Invoke-LabAssessmentRequest -Path ($groupId + '/updateMachines?api-version=2024-01-15') -Method POST -Payload $body @Session
        Assert-LabAssessmentResponse $update 'Server group updateMachines POST'
        $outcome.Stage = 'Server group membership confirmation'
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            $group = Wait-LabAssessmentGroup -Path $outcome.GroupPath -Session $Session -MaxAttempts 1
            if ($null -eq $group) {
                if ($attempt -lt 10) { Start-Sleep -Seconds $update.RetryAfter }
                continue
            }
            $inventory = Get-LabAssessmentCollection -Path $outcome.MachinePath -Session $Session
            $currentMap = Get-LabAssessmentMachineMap -Workloads $Workloads -Inventory $inventory -ProjectId $project.Id
            Assert-LabAssessmentMachineMapStable -Expected $outcome.Machines -Current $currentMap
            $membership = Get-LabAssessmentMembership -Inventory $inventory -GroupId $groupId -Machines $outcome.Machines
            Write-Host "  Assessment: group membership $membership, observation $attempt/10 (expected exact four)." -ForegroundColor Gray
            if ($membership -eq 'Exact' -and (Test-LabAssessmentGroupReady -Resource $group -GroupId $groupId -RequireMembership -RequireIdle)) { break }
            if ($membership -eq 'Conflict') { throw 'Group acquired unexpected extra members; existing resources preserved. No assessment PUT sent.' }
            if ($attempt -lt 10) { Start-Sleep -Seconds $update.RetryAfter }
        }
        if ($null -eq $group -or $membership -ne 'Exact' -or
            -not (Test-LabAssessmentGroupReady -Resource $group -GroupId $groupId -RequireMembership -RequireIdle)) {
            $outcome.State = 'MembershipPending'; $outcome.Message = 'Exact four membership, idle state, count or requested MachineAssessment capability did not confirm within the bounded wait. Unknown/empty capabilities may be transient after Add. Do not resubmit POST blindly; review the group or choose an unused group name.'; return $null
        }
    } else {
        Write-Host '  Assessment: existing group has exactly the four matching workload IDs; reused without membership writes.' -ForegroundColor Green
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            if ($null -ne $group -and (Test-LabAssessmentGroupReady -Resource $group -GroupId $groupId -RequireMembership)) { break }
            if ($attempt -lt 10) {
                Start-Sleep -Seconds 15
                $group = Wait-LabAssessmentGroup -Path $outcome.GroupPath -Session $Session -MaxAttempts 1
                if ($null -eq $group) { continue }
                $inventory = Get-LabAssessmentCollection -Path $outcome.MachinePath -Session $Session
                $currentMap = Get-LabAssessmentMachineMap -Workloads $Workloads -Inventory $inventory -ProjectId $project.Id
                Assert-LabAssessmentMachineMapStable -Expected $outcome.Machines -Current $currentMap
                if ((Get-LabAssessmentMembership -Inventory $inventory -GroupId $groupId -Machines $outcome.Machines) -ne 'Exact') { throw 'Existing group membership changed; preserved without assessment writes.' }
            }
        }
        if ($null -eq $group -or -not (Test-LabAssessmentGroupReady -Resource $group -GroupId $groupId -RequireMembership)) {
            $outcome.State = 'MembershipPending'; $outcome.Message = 'Existing exact-four group count/state or explicit MachineAssessment capability remains unverified after bounded reads. Existing group preserved; no assessment PUT sent.'; return $null
        }
    }
    return $group
}

function Invoke-LabAssessmentCreation {
    param([string]$MigrateProjectName, [string]$ProjectName, [string]$GroupName, [string]$AssessmentName,
        [object[]]$Workloads, [hashtable]$Settings, [hashtable]$Session,
        [ValidateSet('Modern','Classic')][string]$Mode = 'Classic')
    $outcome = [pscustomobject]@{ State = 'Failed'; Stage = 'Provider API verification'; Message = ''; ProjectName = '';
        GroupPath = ''; AssessmentPath = ''; MachinePath = ''; Machines = @(); Settings = $Settings; Mode = $Mode; Version = '' }
    try {
        Write-Host '  Assessment: verifying registered provider and endpoint-specific API plan (read-only; nested catalog entries may be absent).' -ForegroundColor Gray
        $sub = [string](Get-LabAssessmentField (Get-LabAssessmentField $Session.Context 'Subscription') 'Id')
        $provider = Invoke-LabAssessmentRead -Path ("/subscriptions/$sub/providers/Microsoft.Migrate?api-version=2021-04-01") -Session $Session
        Assert-LabAssessmentResponse $provider 'Microsoft.Migrate provider GET'
        if ($provider.Pending) { throw 'Microsoft.Migrate provider metadata is pending; no write attempted.' }
        $profile = Get-LabAssessmentProfile -Provider $provider.Data -Mode $Mode
        $outcome.Version = $profile.Version
        $outcome.Stage = 'Assessment backend resolution'
        $project = Resolve-LabAssessmentProject -MigrateProjectName $MigrateProjectName -ExplicitName $ProjectName -Session $Session
        $outcome.ProjectName = $project.Name
        $groupId = $project.Id + '/groups/' + (ConvertTo-LabAssessmentSegment $GroupName)
        $assessmentParent = if ($Mode -eq 'Modern') { $project.Id } else { $groupId }
        $assessmentId = $assessmentParent + '/assessments/' + (ConvertTo-LabAssessmentSegment $AssessmentName)
        $outcome.GroupPath = $groupId + '?api-version=2024-01-15'
        $outcome.AssessmentPath = $assessmentId + '?api-version=' + $profile.Version
        $outcome.MachinePath = $project.Id + '/machines?api-version=2024-01-15'
        $group = Initialize-LabAssessmentGroup -Outcome $outcome -Project $project -GroupName $GroupName -Workloads $Workloads -Session $Session
        if ($null -eq $group) { return $outcome }
        $groupProps = Get-LabAssessmentField $group 'properties'
        $outcome.Stage = 'Assessment preflight GET'
        $existing = Invoke-LabAssessmentRead -Path $outcome.AssessmentPath -Session $Session
        if ($existing.Success) {
            if ($existing.Pending -and $null -eq $existing.Data) { throw 'Existing assessment identity/settings are pending and cannot be verified; preserved without PUT.' }
            if ($Mode -eq 'Modern') {
                $null = Assert-LabModernAssessment -Resource $existing.Data -AssessmentId $assessmentId -GroupId $groupId -Settings $Settings
            } else { Assert-LabAssessmentSettings -Resource $existing.Data -AssessmentId $assessmentId -Settings $Settings }
            Write-Host "  Assessment: matching existing '$AssessmentName' reused. No overwrite/recompute PUT." -ForegroundColor Green
        } elseif ($existing.FailureKind -eq 'NotFound') {
            $running = Get-LabAssessmentField $groupProps 'areAssessmentsRunning' -PreserveArray
            if ($running -isnot [bool] -or $running) { throw 'Group has active or unverified assessments. No new assessment PUT sent; wait for them or choose your own group.' }
            $outcome.Stage = 'Assessment PUT'
            if ($Mode -eq 'Modern') {
                Write-Host "  Assessment: submitting Modern MachineAssessmentV2 PREVIEW '$AssessmentName'; target $($Settings.azureLocation)." -ForegroundColor Yellow
                Write-Host '  ServerGroupId interoperability requires live validation. Service rejection is reported without Classic fallback; no ARG scope is invented.' -ForegroundColor Yellow
                $body = @{ properties = @{ scope = @{ scopeType = 'ServerGroupId'; serverGroupId = $groupId }; settings = $Settings } } | ConvertTo-Json -Depth 10
            } else {
                Write-Host "  Assessment: submitting classic Azure VM MachineAssessment '$AssessmentName'; offer $($Settings.azureOfferCode), target $($Settings.azureLocation)." -ForegroundColor Gray
                $body = @{ properties = $Settings } | ConvertTo-Json -Depth 5
            }
            $write = Invoke-LabAssessmentRequest -Path $outcome.AssessmentPath -Method PUT -Payload $body @Session
            Assert-LabAssessmentResponse $write 'Assessment PUT'
            if ($null -ne $write.Data) {
                if ($Mode -eq 'Modern') { $null = Assert-LabModernAssessment -Resource $write.Data -AssessmentId $assessmentId -GroupId $groupId -Settings $Settings }
                else { Assert-LabAssessmentSettings -Resource $write.Data -AssessmentId $assessmentId -Settings $Settings }
            }
            Write-Host '  Assessment: request accepted; this is not proof of completed computation. Proceeding directly to resource/status verification.' -ForegroundColor Yellow
        } else { Assert-LabAssessmentResponse $existing 'Assessment preflight GET' }
        $outcome.State = 'Submitted'; $outcome.Stage = 'Assessment computation'
    } catch {
        $outcome.State = 'Failed'
        $message = [string](Get-LabAssessmentField (Get-LabAssessmentField $_ 'Exception') 'Message')
        $outcome.Message = if ($message.Length -le 800 -and $message -notmatch '(?i)bearer|password|secret|credential|eyJ|[a-zA-Z0-9_+/=-]{64,}|[\x00-\x1f]') { $message } else { 'Assessment operation failed safely. Review the selected backend, inventory and API contract in the portal; request outcome is unverified.' }
    }
    return $outcome
}

function Assert-LabAssessedMachines {
    param([object[]]$Results, [object[]]$Machines, [string]$AssessmentId)
    if ($Results.Count -ne 4 -or $Machines.Count -ne 4) { throw 'Completed assessment must return exactly four fully paginated machine results; partial results are not ready.' }
    $seen = @{}; $seenIds = @{}
    foreach ($row in $Results) {
        $id = ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $row 'id'); $props = Get-LabAssessmentField $row 'properties'
        $sourceId = ConvertTo-LabAssessmentCanonicalId (Get-LabAssessmentField $props 'datacenterMachineArmId')
        $sourceMatches = @($Machines | Where-Object { $_.SourceId -ieq $sourceId })
        if ($id -notmatch ('^' + [regex]::Escape($AssessmentId) + '/assessedMachines/(?:[-a-zA-Z0-9_.()]|%20)+$') -or $id -match '/\.{1,2}$' -or
            (Get-LabAssessmentField $row 'type') -ine 'Microsoft.Migrate/assessmentProjects/groups/assessments/assessedMachines' -or
            (Get-LabAssessmentField $props 'type') -ine 'AssessedMachine' -or $sourceMatches.Count -ne 1 -or $seen.ContainsKey($sourceId) -or $seenIds.ContainsKey($id)) {
            throw 'Assessed-machine collection has duplicate, foreign or malformed result/source identity; no ResultsReady claim.'
        }
        if ((Get-LabAssessmentField $props 'displayName') -ine $sourceMatches[0].Name) { throw 'Assessed-machine result name does not match its validated source ID.' }
        $seen[$sourceId] = $true; $seenIds[$id] = $true
    }
}

function Get-LabModernAssessmentCompletion {
    param($Creation, [object[]]$Workloads, [hashtable]$Session)
    $outcome = [pscustomobject]@{ State = 'Submitted'; Confirmed = $false; Ready = $false; Stage = 'Modern assessment resource GET'; Message = ''; Results = @() }
    try {
        if ($Creation.Version -cne '2024-03-03-preview') { throw 'Unverified modern profile; no results request sent.' }
        $assessmentId = $Creation.AssessmentPath.Split('?')[0]; $groupId = $Creation.GroupPath.Split('?')[0]
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            $resource = Invoke-LabAssessmentRead -Path $Creation.AssessmentPath -Session $Session
            if (-not $resource.Success -and $resource.FailureKind -eq 'NotFound' -and -not $outcome.Confirmed) {
                Write-Host "  Modern: accepted resource not visible (404), observation $attempt/10; not confirmed complete." -ForegroundColor Gray
            } else {
                Assert-LabAssessmentResponse $resource 'Modern assessment GET'
                if ($null -ne $resource.Data) {
                    $status = Assert-LabModernAssessment -Resource $resource.Data -AssessmentId $assessmentId -GroupId $groupId -Settings $Creation.Settings
                    $outcome.Confirmed = $true; $outcome.State = 'Created'
                    Write-Host "  Modern: resource confirmed; details.status $status, observation $attempt/10." -ForegroundColor Gray
                    if (-not $resource.Pending -and $status -eq 'Completed') {
                        $outcome.Stage = 'Modern assessedMachines source verification'
                        $results = Get-LabAssessmentCollection -Path ($assessmentId + '/assessedMachines?api-version=' + $Creation.Version) -Session $Session
                        $adapted = Assert-LabModernAssessedMachines -Results $results -Machines $Creation.Machines -AssessmentId $assessmentId
                        $outcome.Stage = 'Final modern scope/membership/status verification'
                        $group = Invoke-LabAssessmentRead -Path $Creation.GroupPath -Session $Session
                        Assert-LabAssessmentResponse $group 'Final server group GET'
                        if (-not (Test-LabAssessmentGroupReady -Resource $group.Data -GroupId $groupId -Pending $group.Pending -RequireMembership -RequireIdle)) { throw 'Final modern server group is busy or unverified; no handoff.' }
                        $inventory = Get-LabAssessmentCollection -Path $Creation.MachinePath -Session $Session
                        $projectId = $Creation.MachinePath.Split('?')[0].Substring(0, $Creation.MachinePath.Split('?')[0].Length - '/machines'.Length)
                        $currentMap = Get-LabAssessmentMachineMap -Workloads $Workloads -Inventory $inventory -ProjectId $projectId
                        Assert-LabAssessmentMachineMapStable -Expected $Creation.Machines -Current $currentMap
                        if ((Get-LabAssessmentMembership -Inventory $inventory -GroupId $groupId -Machines $currentMap) -ne 'Exact') { throw 'Final modern membership changed; no partial or stale handoff.' }
                        $final = Invoke-LabAssessmentRead -Path $Creation.AssessmentPath -Session $Session
                        Assert-LabAssessmentResponse $final 'Final modern assessment GET'
                        $finalStatus = Assert-LabModernAssessment -Resource $final.Data -AssessmentId $assessmentId -GroupId $groupId -Settings $Creation.Settings
                        $details = Get-LabAssessmentField (Get-LabAssessmentField $resource.Data 'properties') 'details'
                        $finalDetails = Get-LabAssessmentField (Get-LabAssessmentField $final.Data 'properties') 'details'
                        if ($final.Pending -or $finalStatus -ine 'Completed' -or
                            (Get-LabAssessmentField $details 'updatedTimestamp') -ine (Get-LabAssessmentField $finalDetails 'updatedTimestamp')) {
                            throw 'Modern assessment changed or is not Completed after reading results. No handoff.'
                        }
                        $outcome.Results = $adapted; $outcome.Ready = $true; $outcome.State = 'ManualReview'
                        $outcome.Message = 'Modern assessment Completed; four source-linked results and current scope verified. Manual IaaS review required: Azure target/strategy enum selection is not verified by this profile. Review a suitable Azure VM recommendation for each VM before Step 3; no automatic handoff or assumed SKU/cost units.'
                        return $outcome
                    }
                }
            }
            if ($attempt -lt 10) { Start-Sleep -Seconds $resource.RetryAfter }
        }
        $outcome.Message = 'Bounded Modern wait expired; Accepted/Running is not Completed. Preserve the assessment and review in the portal; no fallback/recompute PUT or Step 3 handoff.'
    } catch {
        $message = [string](Get-LabAssessmentField (Get-LabAssessmentField $_ 'Exception') 'Message')
        $outcome.State = if ($message -like 'SourceUnverified:*') { 'SourceUnverified' } else { 'Unverified' }
        $outcome.Message = if ($message.Length -le 800 -and $message -notmatch '(?i)bearer|password|secret|credential|eyJ|[a-zA-Z0-9_+/=-]{64,}|[\x00-\x1f]') { $message } else { 'Modern verification failed safely; preserve the resource and review the portal. No fallback or handoff.' }
    }
    return $outcome
}

function Get-LabClassicAssessmentState {
    param($Response)
    $props = Get-LabAssessmentField $Response.Data 'properties' -PreserveArray
    $provisioning = Get-LabAssessmentField $props 'provisioningState' -PreserveArray
    if ($null -ne $provisioning -and $provisioning -isnot [string]) {
        throw 'Classic optional provisioningState is malformed (expected a scalar string or null); no handoff.'
    }
    $normalized = if ($null -eq $provisioning) { '' } else { $provisioning.Trim() }
    if ($normalized -and $normalized -notin @('Succeeded','Provisioning','Updating','Accepted')) {
        throw 'Classic optional provisioningState is failed, canceled, deleting or unknown; computation status cannot override it. No handoff.'
    }
    $status = Get-LabAssessmentField $props 'status' -PreserveArray
    if ($status -isnot [string] -or $status -notin @('Created','Updated','Running','Completed')) {
        throw 'Classic computation status is missing, malformed or unknown; no handoff.'
    }
    $label = if ($null -eq $provisioning) { '<absent/null; optional>' } elseif (-not $normalized) { '<blank; optional>' } else { $normalized }
    $pending = $Response.Pending -or $Response.StatusCode -eq 202
    # The shared adapter uses the untrimmed string to mark Pending. Normalize only that
    # metadata-derived flag on a successful HTTP 200 GET; never clear HTTP 202 or in-progress metadata.
    if ($Response.StatusCode -eq 200 -and $provisioning -is [string] -and $provisioning -cne $normalized -and
        ($normalized -eq '' -or $normalized -ieq 'Succeeded')) { $pending = $false }
    $gate = if ($pending) { 'assessment GET is pending' }
        elseif ($normalized -and $normalized -ine 'Succeeded') { 'optional provisioning metadata is in progress' }
        elseif ($status -ine 'Completed') { 'computation status is not Completed' }
        else { 'Completed; exact-four results and final verification still required' }
    return [pscustomobject]@{ Status = $status; ProvisioningLabel = $label; Gate = $gate
        Completed = (-not $pending -and ($normalized -eq '' -or $normalized -ieq 'Succeeded') -and $status -ieq 'Completed') }
}

function Get-LabAssessmentCompletion {
    param($Creation, [object[]]$Workloads, [hashtable]$Session)
    if ((Get-LabAssessmentField $Creation 'Mode') -eq 'Modern') { return Get-LabModernAssessmentCompletion -Creation $Creation -Workloads $Workloads -Session $Session }
    $outcome = [pscustomobject]@{ State = 'Submitted'; Confirmed = $false; Ready = $false; Stage = 'Assessment resource GET'; Message = ''; Results = @() }
    try {
        $assessmentId = $Creation.AssessmentPath.Split('?')[0]
        $lastObservation = 'Assessment resource/state has not been verified.'
        for ($attempt = 1; $attempt -le 10; $attempt++) {
            $resource = Invoke-LabAssessmentRead -Path $Creation.AssessmentPath -Session $Session
            if (-not $resource.Success -and $resource.FailureKind -eq 'NotFound' -and -not $outcome.Confirmed) {
                $lastObservation = 'Assessment GET returned HTTP 404; creation remains unconfirmed.'
                Write-Host "  Assessment: accepted resource not visible yet (HTTP 404), attempt $attempt/10; creation remains unconfirmed." -ForegroundColor Gray
            } else {
                Assert-LabAssessmentResponse $resource 'Assessment resource GET'
                if ($null -ne $resource.Data) {
                    Assert-LabAssessmentSettings -Resource $resource.Data -AssessmentId $assessmentId -Settings $Creation.Settings
                    $props = Get-LabAssessmentField $resource.Data 'properties'
                    $state = Get-LabClassicAssessmentState -Response $resource
                    $lastObservation = "Computation status $($state.Status); optional provisioning $($state.ProvisioningLabel); completion gate: $($state.Gate)."
                    $outcome.Confirmed = $true; $outcome.State = 'Created'
                    Write-Host "  Assessment: creation confirmed; $lastObservation Attempt $attempt/10." -ForegroundColor Gray
                    # stage is the user review workflow, not the computation status.
                    if ($state.Completed) {
                        if ((Get-LabAssessmentField $props 'numberOfMachines') -ne 4) { throw 'Completed assessment numberOfMachines is not four; existing assessment preserved, no handoff.' }
                        $outcome.Stage = 'Assessed machines GET'
                        $results = Get-LabAssessmentCollection -Path ($assessmentId + '/assessedMachines?api-version=2024-01-15') -Session $Session
                        Assert-LabAssessedMachines -Results $results -Machines $Creation.Machines -AssessmentId $assessmentId
                        $outcome.Stage = 'Final membership/status verification'
                        $group = Invoke-LabAssessmentRead -Path $Creation.GroupPath -Session $Session
                        Assert-LabAssessmentResponse $group 'Final server group GET'
                        if (-not (Test-LabAssessmentGroupReady -Resource $group.Data -GroupId $Creation.GroupPath.Split('?')[0] -Pending $group.Pending -RequireMembership -RequireIdle)) { throw 'Final group state/count is busy or unverified; no handoff.' }
                        $inventory = Get-LabAssessmentCollection -Path $Creation.MachinePath -Session $Session
                        $projectId = $Creation.MachinePath.Split('?')[0].Substring(0, $Creation.MachinePath.Split('?')[0].Length - '/machines'.Length)
                        $currentMap = Get-LabAssessmentMachineMap -Workloads $Workloads -Inventory $inventory -ProjectId $projectId
                        Assert-LabAssessmentMachineMapStable -Expected $Creation.Machines -Current $currentMap
                        if ((Get-LabAssessmentMembership -Inventory $inventory -GroupId $Creation.GroupPath.Split('?')[0] -Machines $currentMap) -ne 'Exact') { throw 'Final group membership changed; no stale or partial result handoff.' }
                        $final = Invoke-LabAssessmentRead -Path $Creation.AssessmentPath -Session $Session
                        Assert-LabAssessmentResponse $final 'Final assessment GET'
                        Assert-LabAssessmentSettings -Resource $final.Data -AssessmentId $assessmentId -Settings $Creation.Settings
                        $finalProps = Get-LabAssessmentField $final.Data 'properties'
                        $finalState = Get-LabClassicAssessmentState -Response $final
                        if (-not $finalState.Completed) { throw "Final assessment completion gate: $($finalState.Gate); computation status $($finalState.Status), optional provisioning $($finalState.ProvisioningLabel). No handoff." }
                        if ((Get-LabAssessmentField $finalProps 'numberOfMachines') -ne 4 -or
                            (Get-LabAssessmentField $finalProps 'updatedTimestamp') -ine (Get-LabAssessmentField $props 'updatedTimestamp')) { throw 'Assessment count or update timestamp changed after reading results; no handoff.' }
                        $outcome.Results = $results; $outcome.Ready = $true; $outcome.State = 'ResultsReady'
                        return $outcome
                    }
                } else { $lastObservation = 'Assessment GET is pending with no resource JSON; computation status and optional provisioning metadata are unverified.' }
            }
            if ($attempt -lt 10) { Start-Sleep -Seconds $resource.RetryAfter }
        }
        $outcome.Message = "Bounded assessment verification wait expired. Last observation: $lastObservation Preserve the assessment and rerun Step 2 with the same names/settings. No automatic replication handoff."
    } catch {
        $outcome.State = 'ReadFailed'
        $message = [string](Get-LabAssessmentField (Get-LabAssessmentField $_ 'Exception') 'Message')
        $outcome.Message = if ($message.Length -le 800 -and $message -notmatch '(?i)bearer|password|secret|credential|eyJ|[a-zA-Z0-9_+/=-]{64,}|[\x00-\x1f]') { $message } else { 'Assessment verification failed safely; state/results remain unverified. Review the portal before Step 3.' }
    }
    return $outcome
}

function Get-LabAzContext {
    <#
      Makes this script runnable on its own from the scripts folder, the same way deploy-lab.ps1
      is. It loads the Az modules it needs, signs in when the session has no sign-in, and picks a
      subscription when none is current. A subscription already selected with Set-AzContext is
      used as it stands, so an existing session is never second-guessed.
    #>
    param(
        [string[]]$RequiredModules = @('Az.Accounts', 'Az.Resources'),
        [AllowEmptyCollection()][string[]]$OptionalModules = @()
    )

    # Modules are loaded best-effort. A module that will not import is reported but is not fatal
    # on its own: what matters is whether the cmdlets are callable, and PowerShell also
    # auto-loads them on first use. Only a genuinely missing cmdlet stops the run.
    $failed = @()
    foreach ($module in @($RequiredModules + $OptionalModules)) {
        if ([string]::IsNullOrWhiteSpace($module)) { continue }
        if (Get-Module -Name $module) { continue }
        try { Import-Module $module -ErrorAction Stop } catch { $failed += $module }
    }

    $absent = @()
    foreach ($command in @('Get-AzContext', 'Get-AzResourceGroup')) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) { $absent += $command }
    }
    if ($absent.Count -gt 0) {
        throw "The Az PowerShell modules are not available in this session: $($absent -join ', ') could not be found. Install them with: Install-Module Az -Scope CurrentUser -Repository PSGallery"
    }
    if ($failed.Count -gt 0) {
        Write-Warning "These modules did not import: $($failed -join ', '). Continuing, because the Azure cmdlets this script needs are present. A step that needs a missing module will say so."
    }

    $context = $null
    try { $context = Get-AzContext -ErrorAction Stop } catch { $context = $null }

    if (-not $context -or -not $context.Account) {
        Microsoft.PowerShell.Utility\Write-Host ''
        Microsoft.PowerShell.Utility\Write-Host 'This session is not signed in to Azure. Starting sign-in...' -ForegroundColor Cyan
        try { $null = Connect-AzAccount -ErrorAction Stop }
        catch { throw "Azure sign-in did not complete: $($_.Exception.Message)" }
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $context -or -not $context.Account) {
            throw 'Azure sign-in did not complete. Run Connect-AzAccount, then rerun this script.'
        }
    }

    if (-not $context.Subscription -or [string]::IsNullOrWhiteSpace($context.Subscription.Id)) {
        $subscriptions = @()
        try { $subscriptions = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }) }
        catch { $subscriptions = @() }
        if ($subscriptions.Count -eq 0) {
            throw "The signed-in account $($context.Account.Id) has no enabled subscriptions. Sign in with the account that holds the workshop subscription."
        }
        $chosen = $null
        if ($subscriptions.Count -eq 1) {
            $chosen = $subscriptions[0]
            Microsoft.PowerShell.Utility\Write-Host "  Subscription: $($chosen.Name)  (the only enabled one on this account)" -ForegroundColor Green
        } else {
            $picked = Select-LabFromList -Name 'Subscription' -Prompt 'Azure subscription to work in' -Options @($subscriptions | ForEach-Object { $_.Name })
            $chosen = @($subscriptions | Where-Object { $_.Name -eq $picked })[0]
        }
        $context = Set-AzContext -SubscriptionId $chosen.Id -ErrorAction Stop
    }

    $script:LabSubscriptionId = [string]$context.Subscription.Id
    $script:LabSubscriptionName = [string]$context.Subscription.Name
    $script:LabAccountId = [string]$context.Account.Id
    $script:LabMaskedValues = @($script:LabSubscriptionId)
    if ($context.Tenant -and $context.Tenant.Id) { $script:LabMaskedValues += [string]$context.Tenant.Id }
    Write-Host "Azure account : $script:LabAccountId" -ForegroundColor Cyan
    Write-Host "Subscription  : $($context.Subscription.Name)  $(Format-LabSubscriptionId $script:LabSubscriptionId)" -ForegroundColor Cyan

    # An account with more than one subscription can easily be pointed at the wrong one: the
    # portal shows every subscription, so a resource group that is plainly there can be absent
    # from this session. The chance to switch is offered here rather than after a failed lookup.
    $available = @()
    try { $available = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' }) } catch { $available = @() }
    if ($available.Count -gt 1) {
        if ((Read-LabChoice -Prompt "Work in '$script:LabSubscriptionName'?") -eq 'No') {
            $pickedName = Select-LabFromList -Name 'Subscription' -Prompt 'Azure subscription to work in' -Options @($available | ForEach-Object { $_.Name })
            $target = @($available | Where-Object { $_.Name -eq $pickedName })[0]
            $context = Set-AzContext -SubscriptionId $target.Id -ErrorAction Stop
            $script:LabSubscriptionId = [string]$context.Subscription.Id
            $script:LabSubscriptionName = [string]$context.Subscription.Name
            $script:LabMaskedValues = @($script:LabSubscriptionId)
            if ($context.Tenant -and $context.Tenant.Id) { $script:LabMaskedValues += [string]$context.Tenant.Id }
            Write-Host "Subscription  : $script:LabSubscriptionName  $(Format-LabSubscriptionId $script:LabSubscriptionId)" -ForegroundColor Cyan
        }
    }
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
    if ($problems.Count) {
        Write-Host ''
        foreach ($p in $problems) { Write-Host "  NOT FOUND: $p" -ForegroundColor Red }
        throw "$($problems.Count) required resource(s) not found in subscription $(Format-LabSubscriptionId $script:LabSubscriptionId). No changes were made."
    }
    Write-Host "Required resources found in subscription $(Format-LabSubscriptionId $script:LabSubscriptionId)." -ForegroundColor Green
}

function ConvertTo-LabRegionKey {
    param([string]$Value)
    return (($Value -replace '\s', '').ToLowerInvariant())
}

function Read-LabTargetRegion {
    param([string]$Value, [string]$SourceLocation)
    $locations = @(Get-AzLocation -ErrorAction Stop)
    if ($locations.Count -eq 0) { throw 'Get-AzLocation returned no subscription regions. No changes were made.' }
    $supplied = -not [string]::IsNullOrWhiteSpace($Value)
    while ($true) {
        $constraint = if ($SourceLocation) { 'different from source host' } else { 'match the chosen step 1 target' }
        $entry = if ($supplied) { $Value } else { Read-Host "Migration target region (name or display name; $constraint; no default)" }
        $key = ConvertTo-LabRegionKey ([string]$entry)
        $matches = @($locations | Where-Object {
            (ConvertTo-LabRegionKey ([string]$_.Location)) -eq $key -or
            (ConvertTo-LabRegionKey ([string]$_.DisplayName)) -eq $key
        })
        $problem = $null
        if ($matches.Count -ne 1) { $problem = "Region '$entry' is not an unambiguous Get-AzLocation entry for this subscription." }
        elseif ($SourceLocation -and (ConvertTo-LabRegionKey ([string]$matches[0].Location)) -eq (ConvertTo-LabRegionKey $SourceLocation)) {
            $problem = "Migration target must differ from the actual source Hyper-V host region '$SourceLocation'. Choose another region yourself."
        }
        if (-not $problem) { return [string]$matches[0].Location }
        if ($supplied) { throw "$problem No changes were made." }
        Write-Warning $problem
        Write-Host "Subscription region names: $(@($locations | ForEach-Object { $_.Location }) -join ', ')"
    }
}

function Resolve-LabTargetNetworkLocation {
    param([string]$Value, [Parameter(Mandatory = $true)][string]$ResourceGroupName)
    $name = "$ResourceGroupName-vnet"
    $network = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $name -ErrorAction Stop
    if (-not $network -or [string]::IsNullOrWhiteSpace($network.Location)) {
        throw "Target VNet '$name' is missing or its actual region is unknown. Run step 1. No changes were made."
    }
    $actual = [string]$network.Location
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        $selected = Read-LabTargetRegion -Value $Value
        if ((ConvertTo-LabRegionKey $selected) -ne (ConvertTo-LabRegionKey $actual)) {
            throw "-Location '$selected' conflicts with target VNet '$name' in '$actual'. Existing networks cannot be moved; choose a fresh landing zone. No changes were made."
        }
    }
    Write-Host "Migration target region: $actual (actual target VNet; resource-group metadata is not used)" -ForegroundColor Green
    return $actual
}

# endregion Lab helpers
# $PSCommandPath is the full path of this script; it is captured so the error report can be
# written beside it. The trap records the failure and holds the window open, because a console
# launched by double-click closes the moment the script exits.
$script:LabScriptPath = $PSCommandPath
trap {
    Write-LabTerminatingError $_
    Save-LabErrorReport -ErrorRecord $_ -ScriptPath $script:LabScriptPath
    Wait-LabBeforeExit
    exit 1
}

$context = Get-LabAzContext -RequiredModules @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network') -OptionalModules @('Az.Migrate')
$assessmentContextStamp = Get-LabAssessmentContextStamp $context

Write-Host ""
Write-Host "Enter the values for your lab environment. A value in [brackets] is a lab default and Enter accepts it; an (example: ...) is a hint only and must be typed." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabResourceGroupName -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Prompt 'Source resource group (contains the Hyper-V host)' -Example 'rg-ces-source-01' -MissingHelp 'It is created by deploy-lab.ps1.'
# Assessment targets the chosen migration region, not source/project/RG metadata.
if (-not [string]::IsNullOrWhiteSpace($TargetResourceGroup)) {
    $Location = Resolve-LabTargetNetworkLocation -Value $Location -ResourceGroupName $TargetResourceGroup
} else {
    $Location = Read-LabTargetRegion -Value $Location
}
$MigrateProjectName = Select-LabFromList -Name 'MigrateProjectName' -Value $MigrateProjectName -Options (Get-LabMigrateProjectNames -ResourceGroupName $SourceResourceGroup) -Kind ProjectName -Prompt 'Azure Migrate project' -EmptyHelp 'Run migrate-step1-setup-project.ps1 first, or create the project in the portal (Module 1 section 1).'
$HyperVHostVMName = Select-LabFromList -Name 'HyperVHostVMName' -Value $HyperVHostVMName -Options (Get-LabVMNames -ResourceGroupName $SourceResourceGroup) -Kind VMName -Prompt 'Hyper-V host VM' -EmptyHelp 'Run deploy-lab.ps1 first: it creates the Hyper-V host in the source resource group.'

$AssessmentCurrency = Read-LabParameter -Name 'AssessmentCurrency' -Value $AssessmentCurrency -Kind Currency -Prompt 'Assessment currency' -Default 'USD'
$AzureOfferCode = Read-LabParameter -Name 'AzureOfferCode' -Value $AzureOfferCode -Kind OfferCode -Prompt 'Azure offer (pricing agreement) for the assessment' -Default 'MS-AZR-0003P'
$AzureHybridBenefit = Read-LabChoice -Prompt 'Apply Azure Hybrid Benefit? Answer Yes only if licence entitlement is confirmed' -Value $AzureHybridBenefit


# Confirm this step's resources exist in the signed-in subscription before changing anything.
Assert-LabResources -SourceResourceGroup $SourceResourceGroup -HyperVHostVMName $HyperVHostVMName -MigrateProjectName $MigrateProjectName

# ================================================================
# Helper Functions
# ================================================================

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host "  $Title" -ForegroundColor Yellow
    Write-Host ("=" * 70) -ForegroundColor Yellow
    Write-Host ""
}

function Write-StepHeader {
    param([int]$Step, [string]$Title)
    Write-Host ""
    Write-Host "--- Step $Step`: $Title ---" -ForegroundColor Green
    Write-Host ""
}

function Write-ManualAction {
    param([string]$Title, [string[]]$Instructions)
    Write-Host ""
    Write-Host ("*" * 70) -ForegroundColor Red
    Write-Host "  MANUAL ACTION REQUIRED: $Title" -ForegroundColor Red
    Write-Host ("*" * 70) -ForegroundColor Red
    foreach ($instruction in $Instructions) {
        Write-Host "  $instruction" -ForegroundColor White
    }
    Write-Host ("*" * 70) -ForegroundColor Red
    Write-Host ""
}

function Write-NextSteps {
    param([string[]]$Steps)
    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host "  WHAT TO DO NEXT" -ForegroundColor Magenta
    Write-Host ("=" * 70) -ForegroundColor Magenta
    foreach ($s in $Steps) {
        Write-Host "  -> $s" -ForegroundColor White
    }
    Write-Host ("=" * 70) -ForegroundColor Magenta
    Write-Host ""
}

function Get-LabRunCommandText {
    param([Parameter(Mandatory = $true)]$Result)
    $results = @($Result)
    if ($results.Count -ne 1 -or $null -eq $results[0] -or
        $null -eq $results[0].PSObject.Properties['Value']) { throw 'Host read returned no valid Run Command result.' }
    $entries = @($results[0].Value)
    if ($entries.Count -eq 0) { throw 'Host read returned no status records.' }
    $stdout = @()
    foreach ($entry in $entries) {
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['Code'] -or
            $null -eq $entry.PSObject.Properties['Message']) { throw 'Malformed host status record.' }
        $code = [string]$entry.Code
        if ($code -match '(?i)(failed|error)' -or
            ($null -ne $entry.PSObject.Properties['Level'] -and [string]$entry.Level -eq 'Error')) {
            throw 'Host Run Command reported failure.'
        }
        if ($code -match '(?i)StdErr') {
            if (-not [string]::IsNullOrWhiteSpace([string]$entry.Message)) { throw 'Host read reported stderr.' }
        } elseif ($code -match '(?i)StdOut') {
            if ($code -notmatch '(?i)/succeeded$') { throw 'Host stdout status is not successful.' }
            $stdout += [string]$entry.Message
        }
    }
    $text = $stdout -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Host read returned empty stdout.' }
    return $text
}

function Assert-LabWorkloadPower {
    param([Parameter(Mandatory = $true)][string]$Stage)
    $required = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App')
    Write-Host "${Stage}: read-only workload power check on $SourceResourceGroup/$HyperVHostVMName" -ForegroundColor Cyan
    $rows = @()
    try {
        $hostStatus = Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $HyperVHostVMName -Status -ErrorAction Stop
        if ($null -eq $hostStatus -or $null -eq $hostStatus.PSObject.Properties['Statuses']) { throw 'Azure host power state is unreadable.' }
        $power = @($hostStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' })
        if ($power.Count -ne 1 -or [string]$power[0].Code -cne 'PowerState/running') {
            throw 'Azure host must be running before its nested workload states can be verified.'
        }
        $probe = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$required = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App')
$inventory = @(Get-VM -ErrorAction Stop)
$rows = @(foreach ($name in $required) {
    $match = @($inventory | Where-Object { $_.Name -ceq $name })
    if ($match.Count -gt 1) { throw 'Ambiguous workload inventory.' }
    $state = if ($match.Count -eq 1) { [string]$match[0].State } else { 'Missing' }
    [pscustomobject]@{ Name = $name; State = $state }
})
Write-Output ('LAB_GUEST_STATE_JSON|' + ([ordered]@{ Schema = 1; Rows = $rows } | ConvertTo-Json -Depth 4 -Compress))
Write-Output 'LAB_GUEST_STATE_END'
'@
        $result = Invoke-AzVMRunCommand -ResourceGroupName $SourceResourceGroup -VMName $HyperVHostVMName `
            -CommandId RunPowerShellScript -ScriptString $probe -ErrorAction Stop
        $text = Get-LabRunCommandText -Result $result
        $matches = [regex]::Matches($text, '(?m)^LAB_GUEST_STATE_JSON\|([^\r\n]+)\r?\nLAB_GUEST_STATE_END\r?$')
        if ($matches.Count -ne 1 -or ([regex]::Matches($text, 'LAB_GUEST_STATE_JSON\|')).Count -ne 1 -or
            ([regex]::Matches($text, '(?m)^LAB_GUEST_STATE_END\r?$')).Count -ne 1) {
            throw 'Missing, duplicate or truncated workload power payload.'
        }
        $payload = $matches[0].Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $payload -or $null -eq $payload.PSObject.Properties['Schema'] -or
            [string]$payload.Schema -cne '1' -or $null -eq $payload.PSObject.Properties['Rows']) { throw 'Invalid workload payload schema.' }
        $rows = @($payload.Rows)
        if ($rows.Count -ne 4) { throw 'Expected exactly four workload rows.' }
        for ($i = 0; $i -lt $required.Count; $i++) {
            $row = $rows[$i]
            if ($null -eq $row -or $null -eq $row.PSObject.Properties['Name'] -or
                $null -eq $row.PSObject.Properties['State'] -or $row.Name -isnot [string] -or
                $row.State -isnot [string] -or $row.Name -cne $required[$i] -or
                $row.State -cnotmatch '^[A-Za-z]+$') { throw 'Malformed, duplicate or unexpected workload row.' }
        }
    } catch {
        foreach ($name in $required) { Write-Host "  ${name}: Unknown (selected host power/inventory could not be verified)" -ForegroundColor Yellow }
        Write-Host "Verify Azure host '$HyperVHostVMName' is running and Run Command/Hyper-V access works. Then rerun this step." -ForegroundColor Yellow
        Write-Host 'No nested VM was started; do not continue to discovery or traffic with unknown workload states.' -ForegroundColor Yellow
        throw 'Workload power verification failed closed; no next-stage guidance or traffic is permitted.'
    }
    $notRunning = @($rows | Where-Object { $_.State -cne 'Running' })
    foreach ($row in $rows) {
        $color = if ($row.State -ceq 'Running') { 'Green' } else { 'Yellow' }
        Write-Host "  $($row.Name): $($row.State)" -ForegroundColor $color
    }
    Write-Host 'Running is a VM power state, not proof of application or database health. MigrateAppl is not a workload prerequisite.' -ForegroundColor Gray
    if ($notRunning.Count -gt 0) {
        Write-Host "Repair manually in elevated PowerShell ON the selected host '$HyperVHostVMName', then rerun this step:" -ForegroundColor Yellow
        foreach ($row in $notRunning) {
            if ($row.State -ceq 'Missing') {
                Write-Host "  $($row.Name) is missing: restore the expected workload/deployment; Start-VM cannot create it." -ForegroundColor Yellow
            } else {
                if ($row.State -ceq 'Paused') { Write-Host "  Resume-VM -Name '$($row.Name)' # Paused VM" -ForegroundColor White }
                Write-Host "  Start-VM -Name '$($row.Name)' # Review its reported state before repair" -ForegroundColor White
            }
        }
        throw 'All four workload VMs must be Running. No nested VM was automatically started; stop and retry after repair.'
    }
    return [pscustomobject]@{ Rows = $rows; CheckedUtc = [DateTime]::UtcNow.ToString('u') }
}

function Get-LabKvpReadinessRow {
    param([string]$Name, [string]$VMId, [AllowNull()]$Component, [string]$Failure = '')
    $row = [ordered]@{ Name = $Name; VMId = $VMId; EnabledState = $null; OperationalStatus = $null;
        CommunicationStatus = $null; OSName = ''; OSVersion = ''; Ready = $false; Reason = '' }
    try {
        if ($Failure) { throw $Failure }
        if ($null -eq $Component) { throw 'Missing KVP component' }
        foreach ($field in @('EnabledState', 'OperationalStatus', 'CommunicationStatus')) {
            $property = $Component.PSObject.Properties[$field]
            if ($null -eq $property -or $null -eq $property.Value) { continue }
            $values = @($property.Value)
            if ($values.Count -eq 0) { continue }
            if ($field -ne 'OperationalStatus' -and $values.Count -ne 1) { throw 'Invalid numeric KVP status' }
            $value = $values[0]
            if ($value -isnot [byte] -and $value -isnot [uint16] -and $value -isnot [int] -and
                $value -isnot [uint32] -and $value -isnot [long]) { throw 'Invalid numeric KVP status' }
            if ($value -lt 0 -or $value -gt 65535) { throw 'Invalid numeric KVP status' }
            $row[$field] = [int]$value
        }
        if ($row.EnabledState -ne 2) { throw 'KVP disabled or enabled state unknown' }
        # OperationalStatus is authoritative. CommunicationStatus is inherited and may be unimplemented.
        if ($null -eq $row.OperationalStatus) { throw 'KVP operational status missing or not OK' }
        if ($row.OperationalStatus -ne 2) {
            switch ($row.OperationalStatus) {
                3 { throw 'KVP Degraded (lab requires normal communication)' }
                7 { throw 'KVP incompatible protocol' }
                12 { throw 'KVP NoContact' }
                13 { throw 'KVP LostCommunication' }
                default { throw 'KVP operational status missing or not OK' }
            }
        }
        if ($null -ne $row.CommunicationStatus -and $row.CommunicationStatus -notin @(0, 1, 2)) {
            throw 'KVP CommunicationStatus reports lost/no contact or unknown failure'
        }
        $property = $Component.PSObject.Properties['GuestIntrinsicExchangeItems']
        if ($null -eq $property) { throw 'Missing guest OS metadata' }
        $metadata = @{}
        foreach ($item in @($property.Value)) {
            if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) { throw 'Malformed guest OS metadata XML' }
            $settings = [Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $reader = [Xml.XmlReader]::Create([IO.StringReader]::new($item), $settings)
            try { $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver = $null; $xml.Load($reader) }
            catch { throw 'Malformed guest OS metadata XML' }
            finally { $reader.Dispose() }
            $names = $xml.SelectNodes('/INSTANCE/PROPERTY[@NAME="Name"]/VALUE')
            $data = $xml.SelectNodes('/INSTANCE/PROPERTY[@NAME="Data"]/VALUE')
            if ($names.Count -ne 1 -or $data.Count -ne 1) { throw 'Malformed guest OS metadata XML' }
            $key = $names[0].InnerText
            if ($key -notin @('OSName', 'OSVersion')) { continue }
            if ($metadata.ContainsKey($key)) { throw 'Duplicate guest OS metadata' }
            $metadata[$key] = $data[0].InnerText.Trim()
        }
        foreach ($key in @('OSName', 'OSVersion')) {
            if (-not $metadata.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($metadata[$key])) { throw 'Missing guest OS name/version' }
            if ($metadata[$key].Length -gt 256 -or $metadata[$key] -match '[\x00-\x1f\x7f]') { throw 'Invalid guest OS metadata text' }
            $row[$key] = $metadata[$key]
        }
        if ($Name -like 'OnPrem-Linux-*') {
            if ($row.OSName -notmatch '(?i)\b(?:Linux|Ubuntu)\b') { throw 'Guest OS family is not recognized as Linux/Ubuntu' }
        } elseif ($row.OSName -notmatch '(?i)\bWindows\b') { throw 'Guest OS family is not recognized as Windows' }
        $row.Ready = $true
        $row.Reason = 'KVP communication OK and guest OS metadata present'
    } catch { $row.Reason = $_.Exception.Message }
    return [pscustomobject]$row
}

function Get-LabGuestCommunicationRows {
    $required = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App')
    foreach ($name in $required) {
        $id = ''; $component = $null; $failure = ''
        try {
            $vms = @(Get-VM -Name $name -ErrorAction Stop)
            if ($vms.Count -ne 1) { $failure = 'Missing or ambiguous VM'; throw $failure }
            $vm = $vms[0]; $id = [string]$vm.Id
            if ([string]$vm.State -cne 'Running') { $failure = 'VM not Running'; throw $failure }
            $systems = @(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem -Filter "Name='$id'" -OperationTimeoutSec 15 -ErrorAction Stop)
            if ($systems.Count -ne 1) { $failure = 'Missing or ambiguous VM CIM record'; throw $failure }
            $components = @(Get-CimAssociatedInstance -InputObject $systems[0] -ResultClassName Msvm_KvpExchangeComponent -OperationTimeoutSec 15 -ErrorAction Stop)
            if ($components.Count -ne 1) { $failure = 'Missing or ambiguous KVP component'; throw $failure }
            $component = $components[0]
        } catch { if (-not $failure) { $failure = 'VM/KVP read unavailable; check VM state and host CIM access' } }
        Get-LabKvpReadinessRow -Name $name -VMId $id -Component $component -Failure $failure
    }
}

function ConvertFrom-LabGuestCommunicationPayload {
    param([string]$Text)
    $matches = [regex]::Matches($Text, '(?m)^LAB_KVP_JSON\|([^\r\n]+)\r?\nLAB_KVP_END\r?$')
    if ($matches.Count -ne 1 -or ([regex]::Matches($Text, 'LAB_KVP_JSON\|')).Count -ne 1 -or
        ([regex]::Matches($Text, '(?m)^LAB_KVP_END\r?$')).Count -ne 1) { throw 'Missing, duplicate or truncated KVP payload' }
    $payload = $matches[0].Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $payload -or $null -eq $payload.PSObject.Properties['Schema'] -or
        [string]$payload.Schema -cne '1' -or $null -eq $payload.PSObject.Properties['Rows']) { throw 'Invalid KVP payload schema' }
    $required = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App')
    $rows = @($payload.Rows)
    if ($rows.Count -ne 4) { throw 'Expected exactly four KVP rows' }
    $ids = @{}
    for ($i = 0; $i -lt 4; $i++) {
        $row = $rows[$i]
        foreach ($field in @('Name', 'VMId', 'EnabledState', 'OperationalStatus', 'CommunicationStatus', 'OSName', 'OSVersion', 'Ready', 'Reason')) {
            if ($null -eq $row -or $null -eq $row.PSObject.Properties[$field]) { throw 'Malformed KVP row' }
        }
        if ($row.Name -isnot [string] -or $row.Name -cne $required[$i] -or $row.VMId -isnot [string] -or
            $row.Ready -isnot [bool] -or $row.Reason -isnot [string] -or $row.Reason.Length -gt 256 -or
            $row.Reason -match '[\x00-\x1f\x7f]') { throw 'Malformed or duplicate KVP row' }
        foreach ($field in @('EnabledState', 'OperationalStatus', 'CommunicationStatus')) {
            $value = $row.$field
            if ($null -ne $value -and (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 65535)) { throw 'Invalid numeric KVP payload status' }
        }
        if ($row.OSName -isnot [string] -or $row.OSVersion -isnot [string]) { throw 'Invalid OS metadata payload' }
        if ($row.Ready) {
            $id = [guid]::Empty
            if (-not [guid]::TryParse($row.VMId, [ref]$id) -or $id -eq [guid]::Empty -or $ids.ContainsKey($row.VMId)) { throw 'Missing or duplicate VM identity' }
            $ids[$row.VMId] = $true
            if ($row.EnabledState -ne 2 -or $row.OperationalStatus -ne 2 -or
                ($null -ne $row.CommunicationStatus -and $row.CommunicationStatus -notin @(0, 1, 2))) { throw 'KVP readiness contradicts numeric status' }
            foreach ($field in @('OSName', 'OSVersion')) {
                if ([string]::IsNullOrWhiteSpace($row.$field) -or $row.$field.Length -gt 256 -or $row.$field -match '[\x00-\x1f\x7f]') { throw 'Missing or invalid guest OS metadata' }
            }
            $family = if ($row.Name -like 'OnPrem-Linux-*') { '(?i)\b(?:Linux|Ubuntu)\b' } else { '(?i)\bWindows\b' }
            if ($row.OSName -notmatch $family) { throw 'Unrecognized guest OS family' }
        }
    }
    return $rows
}

function Assert-LabGuestCommunication {
    Write-Host "Read-only guest KVP communication/OS metadata check on $SourceResourceGroup/$HyperVHostVMName" -ForegroundColor Cyan
    # Inline the same read-only functions into the selected Azure host, never the workstation.
    $probe = "`$ErrorActionPreference = 'Stop'`n`$ProgressPreference = 'SilentlyContinue'`n"
    foreach ($name in @('Get-LabKvpReadinessRow', 'Get-LabGuestCommunicationRows')) {
        $probe += "function $name {`n" + (Get-Command $name -CommandType Function).Definition + "`n}`n"
    }
    $probe += @'
$rows = @(Get-LabGuestCommunicationRows)
Write-Output ('LAB_KVP_JSON|' + ([ordered]@{ Schema = 1; Rows = $rows } | ConvertTo-Json -Depth 4 -Compress))
Write-Output 'LAB_KVP_END'
'@
    try {
        $result = Invoke-AzVMRunCommand -ResourceGroupName $SourceResourceGroup -VMName $HyperVHostVMName `
            -CommandId RunPowerShellScript -ScriptString $probe -ErrorAction Stop
        $rows = @(ConvertFrom-LabGuestCommunicationPayload -Text (Get-LabRunCommandText -Result $result))
    } catch {
        Write-Warning "KVP communication Unknown: $($_.Exception.Message)"
        throw 'Guest communication verification failed closed. Check selected host Run Command/CIM access, then rerun Step 2.'
    }
    foreach ($row in $rows) {
        $color = if ($row.Ready) { 'Green' } else { 'Yellow' }
        Write-Host "  $($row.Name): $($row.Reason) [EnabledState=$($row.EnabledState); OperationalStatus=$($row.OperationalStatus); CommunicationStatus=$($row.CommunicationStatus)]" -ForegroundColor $color
    }
    if (@($rows | Where-Object { -not $_.Ready }).Count) {
        Write-Warning 'Repair only the named guest(s) manually. In Linux check uname -r, systemctl status hv-kvp-daemon.service and journalctl -u hv-kvp-daemon.service.'
        Write-Warning 'A unit can be enabled yet lack its current-kernel daemon. Module 1 section 2 explains matching tools, service and retry checks. WinRM does not fix guest KVP.'
        throw 'All four guests require normal KVP communication and recognized OS name/version. No guest was started or modified; rerun Step 2 after repair.'
    }
    Write-Host 'Local host transport/OS metadata verified only; appliance credentials, OS classification and fresh software/web discovery still require validation.' -ForegroundColor Gray
    return [pscustomobject]@{ Rows = $rows; CheckedUtc = [DateTime]::UtcNow.ToString('o') }
}

function Invoke-HostScript {
    # Runs a short script on the Hyper-V host through VM Run Command and returns its output.
    param([Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string]$Stage)
    # Progress and warning records would arrive as StdErr and be mistaken for failure.
    $Script = "`$ProgressPreference = 'SilentlyContinue'`n`$WarningPreference = 'SilentlyContinue'`n" + $Script
    $result = Invoke-AzVMRunCommand `
        -ResourceGroupName $SourceResourceGroup `
        -VMName $HyperVHostVMName `
        -CommandId "RunPowerShellScript" `
        -ScriptString $Script `
        -ErrorAction Stop
    $stdout = @($result.Value | Where-Object { $_.Code -match 'StdOut' } | ForEach-Object { $_.Message }) -join "`n"
    $stderr = @($result.Value | Where-Object { $_.Code -match 'StdErr' } | ForEach-Object { $_.Message }) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { throw "$Stage failed on ${HyperVHostVMName}: $stderr" }
    return $stdout
}

# ================================================================
Write-Section "Step 2: Discover & Assess On-Premises VMs"
# ================================================================

# ================================================================
# PRE-FLIGHT: Verify Prerequisites
# ================================================================

Write-StepHeader -Step 0 -Title "Pre-flight: Verify Prerequisites"

# Check Azure authentication
try {
    $context = Get-AzContext
    if (-not $context) { throw "Not logged in." }
    Write-Log "Authenticated as: $($context.Account.Id)"
    Write-Log "Subscription    : $(Format-LabSubscriptionId $context.Subscription.Id)"
} catch {
    throw "Azure authentication required. Run Connect-AzAccount first."
}

# Verify source resource group and Hyper-V host exist
$sourceRg = Get-AzResourceGroup -Name $SourceResourceGroup -ErrorAction SilentlyContinue
if (-not $sourceRg) {
    throw "Source resource group '$SourceResourceGroup' not found. Run deploy-lab.ps1 first."
}

# Fail closed before appliance/download/registration/assessment actions. No nested VM is started.
$guestReadiness = Assert-LabWorkloadPower -Stage 'Step 2 pre-flight'
$guestCommunication = Assert-LabGuestCommunication

# Ensure Az.Migrate module is loaded
$migrateModule = Get-Module -ListAvailable -Name Az.Migrate
if (-not $migrateModule) {
    Write-Log "Installing Az.Migrate module..."
    Install-Module -Name Az.Migrate -Force -AllowClobber -Scope CurrentUser
}
Import-Module Az.Migrate -ErrorAction SilentlyContinue

Write-Log "All prerequisites verified."

Read-Host "Press Enter to continue..."

# ================================================================
# STEP 1: Get Hyper-V Host Information
# ================================================================
# We need the Hyper-V host's public IP to:
# 1. Access the Azure Migrate appliance web UI (after deployment)
# 2. Run commands on the host via Invoke-AzVMRunCommand
#
# The public IP was assigned during lab deployment (deploy-lab.ps1).
# The Hyper-V host runs Windows Server 2022 with the Hyper-V role and
# contains 4 nested VMs simulating on-premises workloads.

Write-StepHeader -Step 1 -Title "Get Hyper-V Host Information"

try {
    # Find the public IP associated with the Hyper-V host
    # The PIP name follows the convention set in deploy-lab.ps1
    $pipName = "$HyperVHostVMName-pip"
    $pip = Get-AzPublicIpAddress -Name $pipName -ResourceGroupName $SourceResourceGroup -ErrorAction Stop

    Write-Log "Hyper-V Host Details:"
    Write-Host "  VM Name     : $HyperVHostVMName" -ForegroundColor White
    Write-Host "  Public IP   : $($pip.IpAddress)" -ForegroundColor White
    Write-Host "  RDP Access  : mstsc /v:$($pip.IpAddress)" -ForegroundColor White
    Write-Host ""

    # Store the IP for later use
    $hyperVHostIP = $pip.IpAddress

    Write-Host "  Four workload VMs were verified Running at $($guestReadiness.CheckedUtc) UTC (power state only)." -ForegroundColor Gray

} catch {
    throw "Failed to get Hyper-V host information: $_"
}

Read-Host "Press Enter to continue to Step 2..."

# Select from the host inventory or choose a name for a new configuration copy-import.
# Module 1 renames the imported VM before boot; its Azure registration name is separate.
$workloadVMNames = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App')
$hostVMText = Invoke-HostScript -Script 'Get-VM | Select-Object -ExpandProperty Name' -Stage 'List VMs on the Hyper-V host'
$hostVMNames = @($hostVMText -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$applianceCandidates = @($hostVMNames | Where-Object { $workloadVMNames -notcontains $_ })

$ApplianceVMName = Select-LabFromList -Name 'ApplianceVMName' -Value $ApplianceVMName `
    -Options $applianceCandidates -Kind VMName -AllowNew `
    -NewLabel 'Not there yet -- name it and this script will download and import it' `
    -Prompt 'Azure Migrate appliance VM on the Hyper-V host' -Example 'MigrateAppl'

# Azure Migrate applies its own rule to the name entered under "Generate project key":
# alphanumeric, 14 characters or fewer. A Hyper-V VM name may be longer or contain hyphens,
# so it is checked here and a separate registration name is asked for only when it has to be.
$ApplianceRegistrationName = $ApplianceVMName
if ($ApplianceVMName -notmatch '^[A-Za-z0-9]{1,14}$') {
    Write-Warning "Azure Migrate will not accept '$ApplianceVMName' as an appliance name: it allows letters and digits only, 14 characters or fewer."
    $ApplianceRegistrationName = Read-LabParameter -Name 'ApplianceRegistrationName' -Kind Text `
        -Prompt 'Name to register the appliance under in Azure Migrate (letters and digits, 14 max)' -Example 'MigrateAppl'
}



# --- Confirm the host is prepared for discovery (Module 1, section 2) --------------------
# deploy-lab.ps1 applies this in PHASE 7 and records the result, but the scripts and the
# modules are run separately: this host may have been built another way, or that phase may
# have failed. Checked here rather than at discovery time, so a problem surfaces before the
# appliance download rather than after it.
$hostPrepScript = @'
$report = [ordered]@{}
$prepFile = 'C:\AzMigrateLab\hyperv-prep.json'
$report['RecordedByDeployment'] = if (Test-Path $prepFile) { 'Yes' } else { 'No' }
try { $report['HyperVRole'] = (Get-WindowsFeature -Name Hyper-V).InstallState } catch { $report['HyperVRole'] = 'Unknown' }
try {
    $svc = Get-Service WinRM
    $report['WinRmService'] = "$($svc.Status)/$($svc.StartType)"
} catch { $report['WinRmService'] = 'Unknown' }
try {
    $listeners = @(Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop)
    $report['PSRemoting'] = if ($listeners.Count) { 'Enabled' } else { 'No listener' }
} catch { $report['PSRemoting'] = 'Not enabled' }
foreach ($k in $report.Keys) { Write-Output ("HOSTPREP|{0}|{1}" -f $k, $report[$k]) }
'@

Write-Log "Checking host preparation (Module 1, section 2)..."
$prepLines = @((Invoke-HostScript -Script $hostPrepScript -Stage 'Check host preparation') -split "`r?`n" |
               Where-Object { $_ -like 'HOSTPREP|*' })
$prepState = @{}
foreach ($line in $prepLines) {
    $parts = $line.Split([char[]]'|')
    if ($parts.Count -ge 3) { $prepState[$parts[1]] = ($parts[2..($parts.Count - 1)] -join '|') }
}

$prepProblems = @()
if ($prepState['HyperVRole'] -ne 'Installed') { $prepProblems += "Hyper-V role: $($prepState['HyperVRole'])" }
if ($prepState['WinRmService'] -notlike 'Running*') { $prepProblems += "WinRM service: $($prepState['WinRmService'])" }
if ($prepState['PSRemoting'] -ne 'Enabled') { $prepProblems += "PowerShell remoting: $($prepState['PSRemoting'])" }
# Guest communication was gated separately before module/appliance work; WinRM cannot waive it.
Write-Log "  GuestCommunication : verified live in pre-flight at $($guestCommunication.CheckedUtc)"

foreach ($key in @('RecordedByDeployment','HyperVRole','WinRmService','PSRemoting')) {
    Write-Log "  $key : $($prepState[$key])"
}

if ($prepProblems.Count -eq 0) {
    Write-Log "Host preparation is in place; Module 1 section 2 needs nothing further."
} else {
    Write-Host ''
    Write-Warning 'This host is not fully prepared for discovery. Without these, the appliance finds nothing:'
    foreach ($problem in $prepProblems) { Write-Host "    $problem" -ForegroundColor Yellow }
    if ($prepState['HyperVRole'] -ne 'Installed') {
        Write-Host '  The Hyper-V role is missing. That cannot be fixed from here and needs a restart.' -ForegroundColor Yellow
        Write-Host '  Install it by hand, restart the host, and rerun this script.' -ForegroundColor Yellow
    }
    if ((Read-LabChoice -Prompt '  Apply WinRM and PowerShell remoting now?') -eq 'Yes') {
        $fixScript = @'
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }
Set-Service -Name WinRM -StartupType Automatic
Write-Output 'HOSTPREP_FIXED'
'@
        try {
            $fixOutput = Invoke-HostScript -Script $fixScript -Stage 'Apply host preparation'
            if ($fixOutput -match 'HOSTPREP_FIXED') { Write-Log 'WinRM and PowerShell remoting applied.' }
        } catch {
            Write-Warning "Could not apply host preparation: $($_.Exception.Message)"
            Write-Warning 'Complete Module 1 section 2 on the host by hand before starting discovery.'
        }
    } else {
        Write-Warning 'Continuing without applying it. Complete Module 1 section 2 before starting discovery.'
    }
}

# ================================================================
# STEP 2: Generate the Project Key (Module 1, section 3.1)
# ================================================================
# The appliance registers with the project using a project key. Module 1 generates it in
# the portal (Discover > Hyper-V > VHD download option) for the appliance name you entered.
# The key is a credential: it is never written to the console in full, and it must stay
# out of Git, screenshots and chat.

Write-StepHeader -Step 2 -Title "Generate the Project Key (Module 1, section 3.1)"

$applianceKeyReady = $false
$keyCommand = Get-Command -Name 'New-AzMigrateHyperVSiteApplianceKey' -ErrorAction SilentlyContinue
if ($keyCommand) {
    try {
        Write-Log "Generating the project key for appliance '$ApplianceRegistrationName'..."
        $keyResult = New-AzMigrateHyperVSiteApplianceKey `
            -SiteName "${MigrateProjectName}HyperVSite" `
            -ResourceGroupName $SourceResourceGroup `
            -ProjectName $MigrateProjectName `
            -KeyName 'HyperVKey1' `
            -ErrorAction Stop
        $applianceKey = [string]$keyResult.Key
        if (-not [string]::IsNullOrWhiteSpace($applianceKey)) {
            $maskedKey = if ($applianceKey.Length -gt 8) { $applianceKey.Substring(0, 4) + ('*' * 16) } else { '****' }
            Write-Log "Project key generated ($maskedKey). It is not displayed in full."
            if (Get-Command -Name Set-Clipboard -ErrorAction SilentlyContinue) {
                $applianceKey | Set-Clipboard
                Write-Log "The key is on your clipboard. Store it somewhere safe now; it is needed at registration."
            }
            $applianceKeyReady = $true
        }
        $applianceKey = $null
        $keyResult = $null
    } catch {
        Write-Warning "Could not generate the key from PowerShell: $($_.Exception.Message)"
    }
}

if (-not $applianceKeyReady) {
    Write-ManualAction -Title "Generate the project key in the portal (Module 1, section 3.1)" -Instructions @(
        "1. Azure portal > Azure Migrate > $MigrateProjectName > discovery, source: Hyper-V."
        "2. Choose the VHD download option rather than the installer script."
        "3. Enter the appliance name '$ApplianceRegistrationName' and generate the project key."
        "4. Copy the key and keep it somewhere safe -- out of Git, screenshots and chat."
        "5. Copy the VHD download link shown on the same page if this script imports the appliance."
    )
}

Read-Host "Press Enter once the project key is generated and stored safely..."

# ================================================================
# STEP 3: Appliance store, VHD download and import (Module 1, sections 3.2-3.4)
# ================================================================
# deploy-lab.ps1 created a dedicated partition labelled 'ApplianceStore' (normally E:)
# with an \Appliance folder. The download, the extracted VHD and the running VM all stay
# on it -- never on C:, which holds the four fixed workload disks.
#
# Timing: the archive is roughly 11-12 GB; extracted physical size depends on the current package. A single VM Run
# Command cannot be relied on for that (it has a hard time limit and gives no progress),
# so the download runs as a scheduled task on the host and this script polls it with
# short Run Commands. The task survives a closed console; rerunning this script with the
# same answers resumes where it left off.

Write-StepHeader -Step 3 -Title "Appliance Store, VHD Download and Import (Module 1, sections 3.2-3.4)"

$storeScript = @'
$ErrorActionPreference = 'Stop'
$volumes = @(Get-Volume -FileSystemLabel 'ApplianceStore' -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
if ($volumes.Count -ne 1) { throw 'The ApplianceStore volume created by deploy-lab.ps1 was not found on this host. Redeploy the lab or recreate the store as described in Module 0.' }
$root = '{0}:\Appliance' -f $volumes[0].DriveLetter
if (-not (Test-Path -LiteralPath $root)) { throw "The appliance folder $root is missing. deploy-lab.ps1 creates it; recreate it before continuing." }
$inv = [Globalization.CultureInfo]::InvariantCulture
Write-Output ('APPLIANCE_STORE|{0}|{1}|{2}' -f $root, [string]::Format($inv, '{0:0.0}', $volumes[0].Size / 1GB), [string]::Format($inv, '{0:0.0}', $volumes[0].SizeRemaining / 1GB))
'@

Write-Log "Locating the appliance store on $HyperVHostVMName (volume label 'ApplianceStore')..."
$storeOutput = Invoke-HostScript -Script $storeScript -Stage 'Locate appliance store'
$storeMatch = [regex]::Match($storeOutput, '(?m)^APPLIANCE_STORE\|([A-Z]:\\Appliance)\|([0-9.]+)\|([0-9.]+)\r?$')
if (-not $storeMatch.Success) { throw "The host did not report the appliance store location." }
$storeRoot = $storeMatch.Groups[1].Value
$storeDrive = $storeRoot.Substring(0, 2)
$storeFreeGB = [double]::Parse($storeMatch.Groups[3].Value, [Globalization.CultureInfo]::InvariantCulture)
Write-Log "Appliance store: $storeRoot ($($storeMatch.Groups[2].Value) GB volume, $($storeMatch.Groups[3].Value) GB free)"
if ($storeDrive -ne 'E:') {
    Write-Log "Note: the store is on $storeDrive rather than E:. Substitute $storeDrive wherever Module 1 writes E:."
}

# The appliance is downloaded and imported unless a VM with that name is already on the host
# (for example, imported by hand following Module 1). The download values are asked for here,
# only when they are needed.
# The appliance VM was chosen from the host's own VM list earlier in this script, so the
# import is needed only when the name picked is not yet on the host.
$doImport = ($hostVMNames -notcontains $ApplianceVMName)
if ($doImport) {
    Write-Log "No VM named '$ApplianceVMName' on the host yet: the VHD will be downloaded and imported into $storeRoot."
    $ApplianceDownloadUrl = Read-LabParameter -Name 'ApplianceDownloadUrl' -Value $ApplianceDownloadUrl -Kind Url -Prompt 'VHD download link shown in the project (Discover > Hyper-V > VHD)' -Example 'https://go.microsoft.com/fwlink/?linkid=2191848'
    $ApplianceSha256 = Read-LabParameter -Name 'ApplianceSha256' -Value $ApplianceSha256 -Kind Sha256 -Prompt "Current official Hyper-V ZIP SHA256 (appliance article, 'Verify security')"
    $DownloadTimeoutMinutes = Read-LabNumber -Name 'DownloadTimeoutMinutes' -Prompt 'Minutes to wait for the download before asking whether to keep waiting' -Value $DownloadTimeoutMinutes -Supplied:($PSBoundParameters.ContainsKey('DownloadTimeoutMinutes')) -Minimum 15 -Maximum 480 -Example '90'
}

if ($doImport) {
    # --- 3.3: Download, verify and extract on the host --------------------------------
    $worker = @'
param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Sha256)
$ErrorActionPreference = 'Stop'
$statusPath = Join-Path $Root 'appliance-download.status'
$recordPath = Join-Path $Root 'download-complete.json'
$extracted = Join-Path $Root 'Extracted'
$prefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
function Set-Status([string]$State, [string]$Detail) {
    $line = '{0}|{1}|{2}' -f $State, (Get-Date).ToUniversalTime().ToString('o'), ($Detail -replace '[\r\n|]+', ' ')
    Set-Content -LiteralPath $statusPath -Value $line -Encoding UTF8
}
function Get-StoreFile([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Recorded file is outside ApplianceStore.' }
    $item = Get-Item -LiteralPath $full -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Expected a regular file inside ApplianceStore.' }
    return $item
}
try {
    if ($Sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw 'A current official Hyper-V ZIP SHA256 is required; bypass is not supported.' }
    $record = $null
    if (Test-Path -LiteralPath $recordPath) { $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json }
    if ($record -and $record.Archive) {
        $archive = (Get-StoreFile ([string]$record.Archive)).FullName
        if ([IO.Path]::GetExtension($archive) -ne '.zip') { throw 'Completion record does not identify a ZIP.' }
    } else {
        $candidates = @(Get-ChildItem -LiteralPath $Root -Filter *.zip -File)
        if ($candidates.Count -gt 1) { throw 'Multiple ZIPs are present. Select and verify one explicit file using Module 1; no first-ZIP guess was made.' }
        $archive = if ($candidates.Count -eq 1) { (Get-StoreFile $candidates[0].FullName).FullName } else { Join-Path $Root 'AzureMigrateAppliance.zip' }
    }
    $partial = "$archive.partial"
    if (-not (Test-Path -LiteralPath $archive)) {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $attempt = 0
        while ($true) {
            $attempt++
            Set-Status 'Downloading' "Attempt $attempt"
            & $curl --location --fail --silent --show-error --retry 5 --retry-delay 20 --continue-at - --output $partial $Url
            if ($LASTEXITCODE -eq 0) { break }
            if ($attempt -ge 5) { throw "curl.exe exited with code $LASTEXITCODE after $attempt attempts." }
            Start-Sleep -Seconds 30
        }
        Move-Item -LiteralPath $partial -Destination $archive -Force
    }
    Set-Status 'Verifying' 'Hashing the exact source ZIP against the supplied official value'
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($actual -ne $Sha256.ToUpperInvariant()) {
        throw "ZIP SHA256 mismatch: expected $Sha256, actual $actual, file $archive. Retained for inspection; do not extract or import."
    }
    if (Test-Path -LiteralPath $extracted) {
        # A matching ZIP does not prove an existing extracted/booted disk is unchanged.
        if (-not $record -or $record.ArchiveSha256 -ne $actual -or -not $record.ExtractionFiles) {
            throw 'Existing extraction has no matching content record. Instructor must review it and any attached disks; no files were deleted. Follow the fresh-extraction route in Module 1.'
        }
        $files = @(Get-ChildItem -LiteralPath $extracted -Recurse -File)
        if ($files.Count -ne @($record.ExtractionFiles).Count) { throw 'Extracted file inventory changed. Do not import; no files were deleted.' }
        foreach ($entry in $record.ExtractionFiles) {
            $item = Get-StoreFile ([string]$entry.Path)
            if (-not $item.FullName.StartsWith($extracted.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
                (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash -ne $entry.Sha256) {
                throw 'Extracted content changed or is outside the recorded extraction folder. Source ZIP verification does not verify this disk.'
            }
        }
    } else {
        Set-Status 'Extracting' "Checking space and extracting to $extracted"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $sourceZip = [IO.Compression.ZipFile]::OpenRead($archive)
        try { $expandedBytes = ($sourceZip.Entries | Measure-Object Length -Sum).Sum }
        finally { $sourceZip.Dispose() }
        $free = (Get-Volume -DriveLetter $Root.Substring(0,1)).SizeRemaining
        if ($free -lt ($expandedBytes + 10GB)) { throw 'Insufficient store space for extracted bytes plus 10 GB headroom. Stop for instructor capacity review.' }
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extracted)
        $extractionFiles = @(Get-ChildItem -LiteralPath $extracted -Recurse -File | ForEach-Object {
            [ordered]@{ Path=$_.FullName; Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
        })
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $actual) { throw 'ZIP changed during extraction. Do not use the extracted files.' }
        [ordered]@{ CompletedUtc=(Get-Date).ToUniversalTime().ToString('o'); Archive=$archive; ArchiveSha256=$actual;
            ExtractionFiles=$extractionFiles; Verified=$true; Note='Extraction content recorded; rehash before import.' } |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    }
    $vhds = @(Get-ChildItem -LiteralPath $extracted -Recurse -File | Where-Object { $_.Extension -in @('.vhd', '.vhdx') })
    if ($vhds.Count -ne 1) { throw 'Expected exactly one appliance disk in the exported configuration; check the current Microsoft package.' }
    $attached = @(Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -and $_.Path.StartsWith($extracted.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
    if ($attached.Count) { throw 'An existing VM uses a disk in the extraction folder. No active disk will be overwritten or treated as a pristine template.' }
    Set-Status 'Ready' $vhds[0].FullName
} catch {
    Set-Status 'Failed' $_.Exception.Message
    exit 1
}
'@

    $startScript = @'
$ErrorActionPreference = 'Stop'
$root = '__ROOT__'
$taskName = 'AzMigrateApplianceDownload'
$workerPath = Join-Path $root 'appliance-download.ps1'
$statusPath = Join-Path $root 'appliance-download.status'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and [string]$task.State -eq 'Running') { Write-Output 'DOWNLOAD_ALREADY_RUNNING'; return }
[IO.File]::WriteAllText($workerPath, [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__WORKER__')), (New-Object Text.UTF8Encoding($false)))
Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
$arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Root "{1}" -Url "{2}" -Sha256 "{3}"' -f $workerPath, $root, '__URL__', '__SHA__'
$action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $arguments
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 8) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Output 'DOWNLOAD_STARTED'
'@

    $pollScript = @'
$root = '__ROOT__'
$statusPath = Join-Path $root 'appliance-download.status'
$archive = Join-Path $root 'AzureMigrateAppliance.zip'
$bytes = [long]0
foreach ($p in @("$archive.partial", $archive)) { if (Test-Path -LiteralPath $p) { $bytes = [math]::Max($bytes, (Get-Item -LiteralPath $p).Length) } }
$status = if (Test-Path -LiteralPath $statusPath) { (Get-Content -LiteralPath $statusPath -Raw).Trim() } else { 'Pending||Waiting for the download task to start' }
$task = Get-ScheduledTask -TaskName 'AzMigrateApplianceDownload' -ErrorAction SilentlyContinue
$taskState = if ($task) { [string]$task.State } else { 'Missing' }
Write-Output ('DOWNLOAD_STATUS|{0}|{1}|{2}' -f $taskState, [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.00}', $bytes / 1GB), $status)
'@

    $existingOutput = Invoke-HostScript -Script ($pollScript.Replace('__ROOT__', $storeRoot)) -Stage 'Check existing download'
    # The worker checks extraction/copy requirements using actual package/file bytes.

    $quote = { param([string]$Text) $Text.Replace("'", "''") }
    $workerB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($worker))
    $startBody = $startScript.Replace('__ROOT__', (& $quote $storeRoot)).Replace('__WORKER__', $workerB64)
    $startBody = $startBody.Replace('__URL__', (& $quote $ApplianceDownloadUrl)).Replace('__SHA__', (& $quote $ApplianceSha256))
    $startOutput = Invoke-HostScript -Script $startBody -Stage 'Start appliance download'
    if ($startOutput -match '(?m)^DOWNLOAD_ALREADY_RUNNING') {
        Write-Log "A download is already running on the host; following its progress."
    } else {
        Write-Log "Download task started on $HyperVHostVMName. Files go to $storeRoot."
    }

    Write-Log "Polling every 60 seconds. The archive is roughly 11-12 GB; allow $DownloadTimeoutMinutes minutes before you are asked whether to keep waiting."
    $deadline = (Get-Date).AddMinutes($DownloadTimeoutMinutes)
    $pollBody = $pollScript.Replace('__ROOT__', (& $quote $storeRoot))
    $downloadState = 'Pending'
    $extractedVhd = $null
    $stalledChecks = 0
    while ($true) {
        $pollOutput = Invoke-HostScript -Script $pollBody -Stage 'Check appliance download'
        $line = @($pollOutput -split "`r?`n" | Where-Object { $_ -like 'DOWNLOAD_STATUS|*' }) | Select-Object -Last 1
        if (-not $line) { throw 'The host did not report download progress.' }
        $fields = $line.Split([char[]]'|', 6)
        $taskState = $fields[1]; $sizeGB = $fields[2]; $downloadState = $fields[3]
        $detail = if ($fields.Count -ge 6) { $fields[5] } else { '' }
        Write-Log ("  {0,-11} {1,6} GB   {2}" -f $downloadState, $sizeGB, $detail)

        if ($downloadState -eq 'Ready') { $extractedVhd = $detail; break }
        if ($downloadState -eq 'Failed') { throw "The appliance download failed on the host: $detail" }
        if ($taskState -ne 'Running' -and $downloadState -ne 'Pending') {
            $stalledChecks++
            if ($stalledChecks -ge 3) { throw "The host download task stopped while '$downloadState'. Rerun this script to resume." }
        } else { $stalledChecks = 0 }

        if ((Get-Date) -ge $deadline) {
            $keepWaiting = Read-LabChoice -Prompt "The download has not finished within $DownloadTimeoutMinutes minutes. It continues on the host either way. Keep waiting another $DownloadTimeoutMinutes minutes"
            if ($keepWaiting -eq 'No') { $downloadState = 'Waiting'; break }
            $deadline = (Get-Date).AddMinutes($DownloadTimeoutMinutes)
        }
        Start-Sleep -Seconds 60
    }

    if ($downloadState -ne 'Ready') {
        Write-NextSteps @(
            "The download is still running on $HyperVHostVMName into $storeRoot."
            "Rerun this script with the same answers; it resumes and imports once the VHD is ready."
        )
        return
    }
    Write-Log "Extracted VHD: $extractedVhd"

    # --- 3.4: Copy-import the exported configuration; preserve generation and disk -------
    $importScript = @'
$ErrorActionPreference = 'Stop'
$root = '__ROOT__'; $vmName = '__VMNAME__'; $vhdPath = '__VHD__'; $expected = '__SHA__'; $requestedGeneration = '__GEN__'
if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Write-Output 'APPLIANCE_EXISTS'; return }
$prefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
$vhdPath = [IO.Path]::GetFullPath($vhdPath)
if (-not $vhdPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $vhdPath -PathType Leaf)) {
    throw 'The extracted disk is not inside the appliance store.'
}
$extracted = Join-Path $root 'Extracted'
$record = Get-Content -LiteralPath (Join-Path $root 'download-complete.json') -Raw | ConvertFrom-Json
$archive = [IO.Path]::GetFullPath([string]$record.Archive)
if (-not $archive.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($archive) -ne '.zip') { throw 'Recorded archive is not a ZIP inside ApplianceStore.' }
$fresh = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
if ($fresh -ne $expected -or $fresh -ne $record.ArchiveSha256 -or -not $record.ExtractionFiles) { throw 'ZIP or extraction record is no longer verified; stop before import.' }
$files = @(Get-ChildItem -LiteralPath $extracted -Recurse -File)
if ($files.Count -ne @($record.ExtractionFiles).Count) { throw 'Extraction inventory changed before import.' }
foreach ($entry in $record.ExtractionFiles) {
    $full = [IO.Path]::GetFullPath([string]$entry.Path)
    if (-not $full.StartsWith($extracted.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash -ne $entry.Sha256) { throw 'Extracted content changed before import; no VM was created.' }
}
$vhds = @($files | Where-Object { $_.Extension -in @('.vhd', '.vhdx') })
if ($vhds.Count -ne 1 -or $vhds[0].FullName -ne $vhdPath) { throw 'Ambiguous or changed appliance disk selection.' }
$attached = @(Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -and $_.Path.StartsWith($extracted.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) })
if ($attached.Count) { throw 'An existing VM uses this extracted disk; do not import or overwrite it.' }
$configs = @($files | Where-Object { $_.Extension -eq '.vmcx' })
if (-not $configs.Count) { $configs = @($files | Where-Object { $_.Extension -eq '.xml' }) }
if ($configs.Count -ne 1) { throw 'Expected exactly one exported VM configuration. Check the current official import route; generation will not be guessed.' }
$disks = @(Get-VHD -Path $vhdPath -ErrorAction Stop)
if ($disks.Count -ne 1) { throw 'Expected one readable appliance VHD; stop before import.' }
$disk = $disks[0]
$capacityBytes = [UInt64]0; $diskFileBytes = [UInt64]0
$inv = [Globalization.CultureInfo]::InvariantCulture
if (-not [UInt64]::TryParse([string]$disk.Size, [Globalization.NumberStyles]::None, $inv, [ref]$capacityBytes) -or $capacityBytes -eq 0 -or
    -not [UInt64]::TryParse([string]$disk.FileSize, [Globalization.NumberStyles]::None, $inv, [ref]$diskFileBytes) -or $diskFileBytes -eq 0) {
    throw 'Appliance VHD capacity or file size is missing, invalid or nonpositive; stop before import.'
}
# Preserve the verified export. Approximate host-storage guidance is not an exact VHD-capacity gate.
Write-Output ('TEMPLATE_CAPACITY_BYTES|{0}|FILE_BYTES|{1}' -f $capacityBytes.ToString($inv), $diskFileBytes.ToString($inv))
$copyBytes = ($files | Measure-Object Length -Sum).Sum
$free = (Get-Volume -DriveLetter $root.Substring(0,1)).SizeRemaining
if ($free -lt ($copyBytes + 10GB)) { throw 'Insufficient ApplianceStore space for the physical source-file copy plus 10 GB headroom. Nothing was deleted.' }
$reservations = @(Get-DhcpServerv4Reservation -ScopeId 192.168.0.0)
$client = '00155D000014'
$conflicts = @($reservations | Where-Object {
    ($_.IPAddress.ToString() -eq '192.168.0.20' -and ($_.ClientId -replace '[-:]','') -ne $client) -or
    (($_.ClientId -replace '[-:]','') -eq $client -and $_.IPAddress.ToString() -ne '192.168.0.20')
})
if ($conflicts.Count) { throw 'DHCP reservation conflict: do not overwrite another client.' }
$leases = @(Get-DhcpServerv4Lease -ScopeId 192.168.0.0 | Where-Object { $_.IPAddress.ToString() -eq '192.168.0.20' -and ($_.ClientId -replace '[-:]','') -ne $client })
if ($leases.Count) { throw '192.168.0.20 is leased to another client.' }
$usedMac = @(Get-VM | Get-VMNetworkAdapter | Where-Object { $_.MacAddress -eq $client })
if ($usedMac.Count) { throw 'Appliance MAC is already in use by another VM.' }
$vmPath = Join-Path $root 'VMs'
$diskPath = Join-Path $vmPath 'Virtual Hard Disks'
$checkpointPath = Join-Path $vmPath 'Snapshots'
$pagingPath = Join-Path $vmPath 'Paging'
if (Test-Path -LiteralPath (Join-Path $diskPath $vhds[0].Name)) { throw 'Destination disk file already exists. No file will be overwritten; instructor review required.' }
New-Item -ItemType Directory -Path $vmPath,$diskPath,$checkpointPath,$pagingPath -Force | Out-Null
$report = Compare-VM -Path $configs[0].FullName -Copy -GenerateNewId -VirtualMachinePath $vmPath `
    -SnapshotFilePath $checkpointPath -SmartPagingFilePath $pagingPath -VhdDestinationPath $diskPath -VhdSourcePath $vhds[0].DirectoryName
if ($requestedGeneration -and [int]$requestedGeneration -ne $report.VM.Generation) { throw 'Requested generation differs from the export. Preserve the published configuration; do not infer from disk extension.' }
foreach ($issue in $report.Incompatibilities) {
    if ($issue.MessageId -eq 33012 -and $issue.Source -is [Microsoft.HyperV.PowerShell.VMNetworkAdapter]) {
        Disconnect-VMNetworkAdapter -VMNetworkAdapter $issue.Source
    } else { throw 'Export compatibility issue requires instructor review using Hyper-V Manager; generation/hardware will not be guessed.' }
}
$report = Compare-VM -CompatibilityReport $report
if ($report.Incompatibilities.Count) { throw 'Export remains incompatible after switch disconnection. Stop for instructor review.' }
if (@(Get-VMNetworkAdapter -VM $report.VM).Count -ne 1) { throw 'Unexpected exported NIC count; stop for instructor review.' }
$vm = Import-VM -CompatibilityReport $report
Rename-VM -VM $vm -NewName $vmName
Set-VMProcessor -VMName $vmName -Count 8
Set-VMMemory -VMName $vmName -StartupBytes 16GB -DynamicMemoryEnabled $false
Set-VM -Name $vmName -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
Connect-VMNetworkAdapter -VMName $vmName -SwitchName 'intSwitch'
Set-VMNetworkAdapter -VMName $vmName -StaticMacAddress $client
Enable-VMIntegrationService -VMName $vmName -Name 'Time Synchronization'
if (-not @($reservations | Where-Object { $_.IPAddress.ToString() -eq '192.168.0.20' }).Count) {
    Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress 192.168.0.20 -ClientId '00-15-5D-00-00-14' -Name $vmName
}
$imported = Get-VM -Name $vmName
$paths = @(Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { $_.Path }) + @($imported.Path, $imported.SnapshotFileLocation, $imported.SmartPagingFilePath)
if (@($paths | Where-Object { -not $_ -or -not ([IO.Path]::GetFullPath($_)).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) }).Count) { throw 'Imported VM has a disk/configuration destination outside ApplianceStore; it was not started.' }
Start-VM -Name $vmName
Unregister-ScheduledTask -TaskName 'AzMigrateApplianceDownload' -Confirm:$false -ErrorAction SilentlyContinue
Write-Output ('APPLIANCE_IMPORTED|{0}' -f $imported.Generation)
'@

    $importBody = $importScript.Replace('__ROOT__', (& $quote $storeRoot)).Replace('__VMNAME__', (& $quote $ApplianceVMName))
    $importBody = $importBody.Replace('__VHD__', (& $quote $extractedVhd)).Replace('__GEN__', [string]$ApplianceGeneration).Replace('__SHA__', $ApplianceSha256.ToUpperInvariant())
    Write-Log "Copy-importing '$ApplianceVMName' from the exported configuration (16 GB static memory, 8 vCPUs, intSwitch; template disk unchanged)..."
    $importOutput = Invoke-HostScript -Script $importBody -Stage 'Import appliance VM'
    if ($importOutput -match '(?m)^APPLIANCE_EXISTS') {
        Write-Warning "VM '$ApplianceVMName' appeared before import; it was not recreated or source-hash verified. Confirm it belongs to this project."
    } elseif ($importOutput -match '(?m)^APPLIANCE_IMPORTED\|(\d)') {
        Write-Log "Appliance copy-imported as the export's Generation $($Matches[1]) VM and started. Source ZIP and extracted files retained."
    } else {
        throw 'The host did not confirm the appliance import.'
    }
} else {
    Write-Log "VM '$ApplianceVMName' already exists on the host; the download and import are skipped."
    Write-Warning "Existing appliance: source ZIP/extracted bytes are NOT verified by this path. Confirm this VM is not registered to another project; only read-only VM checks follow."
}

# --- Confirm the appliance VM matches Module 1 (section 3.5 checklist) -------------------
$verifyScript = @'
$ErrorActionPreference = 'Stop'
$vmName = '__VMNAME__'; $drive = '__DRIVE__'
$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) { Write-Output 'APPLIANCE_CHECK|Missing'; return }
$paths = @(Get-VMHardDiskDrive -VMName $vmName -ErrorAction Stop | ForEach-Object { $_.Path })
if ($paths.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$paths[0])) { throw 'Expected exactly one attached appliance VHD; missing or ambiguous disk requires instructor review.' }
$onStore = @($paths | Where-Object { $_ -like "$drive*" }).Count -eq $paths.Count
$disks = @(Get-VHD -Path $paths[0] -ErrorAction Stop)
if ($disks.Count -ne 1) { throw 'Expected one readable appliance VHD; read-only check failed.' }
$disk = $disks[0]
$capacityBytes = [UInt64]0; $diskFileBytes = [UInt64]0
$inv = [Globalization.CultureInfo]::InvariantCulture
if (-not [UInt64]::TryParse([string]$disk.Size, [Globalization.NumberStyles]::None, $inv, [ref]$capacityBytes) -or $capacityBytes -eq 0 -or
    -not [UInt64]::TryParse([string]$disk.FileSize, [Globalization.NumberStyles]::None, $inv, [ref]$diskFileBytes) -or $diskFileBytes -eq 0) {
    throw 'Appliance VHD capacity or file size is missing, invalid or nonpositive; read-only check failed.'
}
$memory = Get-VMMemory -VMName $vmName
$nic = Get-VMNetworkAdapter -VMName $vmName | Select-Object -First 1
$ips = @($nic.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ' '
# Field 6 is exact logical capacity bytes; append file bytes without moving switch/IP fields.
Write-Output ('APPLIANCE_CHECK|{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f $vm.State, $vm.ProcessorCount, [math]::Round($memory.Startup / 1GB), $memory.DynamicMemoryEnabled, $onStore, $capacityBytes.ToString($inv), $nic.SwitchName, $ips, $diskFileBytes.ToString($inv))
'@

Write-Log "Checking '$ApplianceVMName' against Module 1..."
$checkBody = $verifyScript.Replace('__VMNAME__', $ApplianceVMName.Replace("'", "''")).Replace('__DRIVE__', $storeDrive)
$checkOutput = Invoke-HostScript -Script $checkBody -Stage 'Check appliance VM'
$checkLine = @($checkOutput -split "`r?`n" | Where-Object { $_ -like 'APPLIANCE_CHECK|*' }) | Select-Object -Last 1
if (-not $checkLine -or $checkLine -eq 'APPLIANCE_CHECK|Missing') {
    throw "VM '$ApplianceVMName' was not found or its read-only check was not reported on $HyperVHostVMName. Complete Module 1 sections 3.3-3.4 and rerun Step 2 before discovery."
} else {
    $c = $checkLine.Split([char[]]'|')
    $capacityBytes = [UInt64]0; $diskFileBytes = [UInt64]0
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($c.Count -ne 10 -or
        -not [UInt64]::TryParse($c[6], [Globalization.NumberStyles]::None, $inv, [ref]$capacityBytes) -or $capacityBytes -eq 0 -or
        -not [UInt64]::TryParse($c[9], [Globalization.NumberStyles]::None, $inv, [ref]$diskFileBytes) -or $diskFileBytes -eq 0) {
        throw 'Appliance check has missing, invalid or nonpositive disk byte values; stop before discovery.'
    }
    $checks = @(
        @{ Item = 'State';                  Actual = $c[1]; Expected = 'Running' }
        @{ Item = 'vCPUs';                  Actual = $c[2]; Expected = '8' }
        @{ Item = 'Memory (GB)';            Actual = $c[3]; Expected = '16' }
        @{ Item = 'Dynamic memory';         Actual = $c[4]; Expected = 'False' }
        @{ Item = "Disk on $storeDrive";    Actual = $c[5]; Expected = 'True' }
        @{ Item = 'Switch';                 Actual = $c[7]; Expected = 'intSwitch' }
    )
    foreach ($check in $checks) {
        $ok = [string]$check.Actual -eq [string]$check.Expected
        $colour = if ($ok) { 'Green' } else { 'Yellow' }
        $mark = if ($ok) { '[OK]  ' } else { '[CHECK]' }
        Write-Host ("  {0} {1,-24} {2}  (expected {3})" -f $mark, $check.Item, $check.Actual, $check.Expected) -ForegroundColor $colour
    }
    Write-Host ([string]::Format($inv, '         VHD logical capacity: {0} bytes ({1:0.000} GiB).', $capacityBytes, ($capacityBytes / 1GB)))
    Write-Host ([string]::Format($inv, '         VHD file size: {0} bytes ({1:0.000} GB decimal); not logical capacity or guest free space.', $diskFileBytes, ($diskFileBytes / 1000000000)))
    Write-Host '         GiB = 1,073,741,824 bytes (PowerShell 1GB); decimal GB = 1,000,000,000 bytes. No resize was performed.'
    if ($capacityBytes -lt 80GB) {
        Write-Warning "Capacity is below the former 80 GiB script gate. Microsoft lists 'around 80 GB disk storage' as approximate host-resource guidance, not an exact 80 GiB VHD gate. Preserve the verified published export; capacity alone neither rejects it nor proves an existing VM's provenance or support."
    }
    Write-Host '         Guest C: partition capacity/free space are separate: inspect them read-only inside the appliance. All appliance prerequisites must PASS before discovery; this is not a waiver of Microsoft requirements.'
    Write-Host '         If guest storage is insufficient or a storage prerequisite fails, STOP for instructor/support review. Do not resize automatically, require learner expansion, or bypass the failure.'
    $ipText = if ($c.Count -ge 9 -and $c[8]) { $c[8] } else { '(not reported yet)' }
    Write-Host ("         {0,-24} {1}  (expected 192.168.0.20)" -f 'Address', $ipText) -ForegroundColor Gray
}

Read-Host "Press Enter to continue to Step 4..."

# ================================================================
# STEP 4: First boot, registration and discovery (Module 1, sections 3.5 and 4)
# ================================================================
# The configuration manager steps involve interactive sign-in, so they stay manual.
# The order below follows Module 1.

Write-StepHeader -Step 4 -Title "First Boot, Register and Discover (Manual, Module 1 sections 3.5 and 4)"

Write-ManualAction -Title "Complete first boot and register the appliance" -Instructions @(
    "1. RDP to the Hyper-V host: mstsc /v:$hyperVHostIP"
    "2. Hyper-V Manager > $ApplianceVMName > Connect. Accept the first-boot prompts and set its password."
    "3. Inside $ApplianceVMName, check guest OS, Get-Disk and Get-Volume C read-only; do not expand partitions."
    "4. Compare [DateTime]::UtcNow with a trusted source; any display time zone is valid."
    "     Check w32tm /query /status and /source; repair the time source if needed, resync, then recheck."
    "5. Open https://192.168.0.20:44368 (HTTPS only) and confirm it is your own appliance."
    "6. Confirm .20/gateway .1, DNS, required Azure HTTPS access, accurate UTC and updates."
    "   Verify Windows Server 2022/2025 inside the guest, not from its filename; do not run AzureMigrateInstaller on the host or workloads."
    "   Do not reuse an appliance registered to another project or force WinRM HTTPS without a proper listener/certificate."
    "7. Paste the project key; sign in to the correct tenant and subscription."
    "8. Hyper-V host credentials: HyperVHost\<actual AdminUsername>; discovery source address 192.168.0.1."
    "9. Validate the source, resolve every failed prerequisite, then start discovery."
    "10. Guest credentials (Manage credentials and discovery sources, step 3):"
    "     - Windows (non-domain): Administrator -> OnPrem-Web, OnPrem-SQL"
    "     - Linux (non-domain):   <lab user>    -> OnPrem-Linux-Web, OnPrem-Linux-App"
    "     - SQL: Windows authentication with Administrator (not the labapp login)"
    "   All use the lab password. The Linux user name is in C:\AzMigrateLab\lab-traffic.settings.json."
)

Read-Host "Press Enter AFTER host validation succeeded and discovery has started..."

# ================================================================
# STEP 5: Wait for Discovery and List Discovered Servers
# ================================================================
# Module 1 checks the four workload NAMES, not a count: the appliance itself can appear in
# inventory, so four machines is not proof. Discovery runs continuously; the wait can be
# extended as often as needed.

Write-StepHeader -Step 5 -Title "Wait for Discovery to Complete"

$expectedVMs = @("OnPrem-Web", "OnPrem-SQL", "OnPrem-Linux-Web", "OnPrem-Linux-App")
$discoveryComplete = $false
$discoveredServers = @()
$workloadServers = @()
$discoveryWaitMinutes = 15
$discoveryDeadline = (Get-Date).AddMinutes($discoveryWaitMinutes)
$attempt = 0

Write-Log "Polling Azure Migrate every 30 seconds for: $($expectedVMs -join ', ')"
Write-Host ""

while (-not $discoveryComplete) {
    $attempt++
    try {
        # This lab uses Hyper-V; select its inventory explicitly, not VMware inventory.
        $discoveredServers = @(Get-AzMigrateDiscoveredServer `
            -ProjectName $MigrateProjectName `
            -ResourceGroupName $SourceResourceGroup `
            -SourceMachineType 'HyperV' `
            -ErrorAction Stop)
        $workloadServers = @($discoveredServers | Where-Object { $_.DisplayName -in $expectedVMs })
        $foundNames = @($workloadServers | ForEach-Object { $_.DisplayName } | Select-Object -Unique)
        $missing = @($expectedVMs | Where-Object { $_ -notin $foundNames })
        Write-Log "  Attempt $attempt -- $($foundNames.Count)/$($expectedVMs.Count) workloads found$(if ($missing.Count) { '; waiting for ' + ($missing -join ', ') })"
        if (-not $missing.Count) {
            $discoveryComplete = $true
            Write-Log "All four workloads discovered."
            break
        }
    } catch {
        Write-Log "  Attempt $attempt -- waiting for discovery data ($($_.Exception.Message))"
    }
    if ((Get-Date) -ge $discoveryDeadline) {
        Write-Host ""
        Write-Host "  Not all workloads have appeared yet. If host validation is failing, waiting will not fix it:" -ForegroundColor Yellow
        Write-Host "  check the appliance clock (UTC), Test-NetConnection 192.168.0.1 -Port 5985 and the validation panel." -ForegroundColor Yellow
        $keepWaiting = Read-LabChoice -Prompt "Keep polling for another $discoveryWaitMinutes minutes"
        if ($keepWaiting -eq 'No') { break }
        $discoveryDeadline = (Get-Date).AddMinutes($discoveryWaitMinutes)
    }
    Start-Sleep -Seconds 30
}

if ($workloadServers.Count) {
    Write-Host ""
    Write-Host "  Discovered workloads (check names, OS, CPU and memory):" -ForegroundColor White
    Write-Host "  =======================================================" -ForegroundColor White
    foreach ($server in $workloadServers) {
        $osType = if ($server.OperatingSystemDetailOSType) { $server.OperatingSystemDetailOSType } else { "Unknown" }
        $osName = if ($server.OperatingSystemDetailOSName) { $server.OperatingSystemDetailOSName } else { "Unknown" }
        $cores  = if ($server.NumberOfProcessorCore) { $server.NumberOfProcessorCore } else { "?" }
        $memMB  = if ($server.AllocatedMemoryInMb) { $server.AllocatedMemoryInMb } else { "?" }
        Write-Host "  Name    : $($server.DisplayName)" -ForegroundColor Green
        Write-Host "  OS      : $osName `($osType`)" -ForegroundColor Gray
        Write-Host "  Cores   : $cores" -ForegroundColor Gray
        Write-Host "  Memory  : ${memMB} MB" -ForegroundColor Gray
        Write-Host "  ---" -ForegroundColor Gray
    }
    $others = @($discoveredServers | Where-Object { $_.DisplayName -notin $expectedVMs } | ForEach-Object { $_.DisplayName })
    if ($others.Count) { Write-Log "Also in inventory (excluded from assessment and migration): $($others -join ', ')" }
}
if (-not $discoveryComplete) {
    Write-Host ""
    Write-Host "Discovery has not found all four workloads yet." -ForegroundColor Yellow
    Write-Host "  Azure Migrate > $MigrateProjectName > Discovered servers" -ForegroundColor White
    Write-Host "Rerun this script later, or create the assessment in the portal once discovery completes." -ForegroundColor Yellow
    Read-Host "Press Enter to continue anyway..."
}

Read-Host "Press Enter to continue to Step 6..."

# ================================================================
# STEP 6: Create Migration Assessment
# ================================================================
# An assessment evaluates your discovered VMs and provides:
# - **Azure readiness**: Can this VM run in Azure as-is, or are there
#   compatibility issues (unsupported OS, boot type, disk config)?
# - **VM sizing**: Recommended Azure VM size based on current CPU/memory
#   utilization (right-sizing to avoid over-provisioning)
# - **Cost estimation**: Monthly cost estimate for running the VMs in Azure
#   including compute, storage, and networking costs
# - **Risk identification**: Potential migration blockers or warnings
#
# Assessments use the performance data collected by the appliance. For
# the most accurate sizing, let the appliance collect data for at least
# 24 hours. Module 1 starts with "as on-premises" sizing on a fresh lab, then a second,
# performance-based assessment once data has accumulated. The group contains exactly the
# four workloads -- never the appliance, which is lab infrastructure.

Write-StepHeader -Step 6 -Title "Create Migration Assessment"

$assessmentName = $AssessmentName
$groupName = $AssessmentGroupName
$assessmentState = 'NotAttempted'
$assessmentConfirmed = $false
$assessmentReady = $false
$assessmentSession = @{ Context = $context; PinnedContext = $assessmentContextStamp; ResourceGroup = $SourceResourceGroup }
$creation = $null

if ($discoveryComplete -and $workloadServers.Count -eq 4) {
    try {
        $settings = Get-LabAssessmentSettings -Location $Location -Currency $AssessmentCurrency -Offer $AzureOfferCode -HybridBenefit $AzureHybridBenefit -Mode $AssessmentMode
        $creation = Invoke-LabAssessmentCreation -MigrateProjectName $MigrateProjectName -ProjectName $AssessmentProjectName -GroupName $groupName -AssessmentName $assessmentName -Workloads $workloadServers -Settings $settings -Session $assessmentSession -Mode $AssessmentMode
        $assessmentState = $creation.State
        if ($assessmentState -ne 'Submitted') {
            Write-Warning "Step 6 $($creation.Stage): $($creation.Message)"
            Write-Warning 'No Step 7 continuation prompt: resolve the reported backend/mapping/group error or pending state first. HTTP 404 is not a login timeout; these errors are not repaired by reconnecting or rebuilding VMs.'
        }
    } catch {
        $assessmentState = 'Failed'
        Write-Warning 'Step 6 input validation failed: use a supported pricing currency/offer, target region and benefit. No assessment write was attempted.'
    }
} else {
    Write-Warning 'Step 6 not attempted: discovery must contain exactly the four workloads, excluding the appliance. Complete discovery and rerun Step 2.'
}

# ================================================================
# STEP 7: Display Assessment Results
# ================================================================
# No second manual pause: only verified/accepted assessments enter bounded completion checks.
if ($assessmentState -eq 'Submitted') {
    Write-StepHeader -Step 7 -Title 'Verify Completed Assessment and Display Results'
    $completion = Get-LabAssessmentCompletion -Creation $creation -Workloads $workloadServers -Session $assessmentSession
    $assessmentState = $completion.State
    $assessmentConfirmed = $completion.Confirmed
    $assessmentReady = $completion.Ready
    if ($completion.Message) { Write-Warning "Step 7 $($completion.Stage): $($completion.Message)" }
    if ($assessmentReady -and $AssessmentMode -eq 'Modern') {
        Write-Host "  Completed Modern MachineAssessmentV2 PREVIEW: $assessmentName (exactly four source-linked results; manual review required)" -ForegroundColor White
        Show-LabModernRecommendations -Results $completion.Results
    } elseif ($assessmentReady) {
        Write-Host "  Completed classic Azure VM assessment: $assessmentName (exactly four verified results)" -ForegroundColor White
        foreach ($machine in $completion.Results) {
            $props = Get-LabAssessmentField $machine 'properties'
            $suitability = [string](Get-LabAssessmentField $props 'suitability')
            $readiness = if ($suitability) { $suitability } else { 'Unknown' }
            $readinessColor = if ($readiness -eq 'Suitable') { 'Green' } elseif ($readiness -eq 'ConditionallySuitable') { 'Yellow' } else { 'Red' }
            Write-Host "  VM: $(Get-LabAssessmentField $props 'displayName')" -ForegroundColor White
            Write-Host "    Readiness       : $readiness" -ForegroundColor $readinessColor
            Write-Host "    Recommended Size: $(Get-LabAssessmentField $props 'recommendedSize')" -ForegroundColor Gray
            Write-Host "    Monthly Cost    : $AssessmentCurrency $((Get-LabAssessmentField $props 'monthlyComputeCostForRecommendedSize')) (compute)" -ForegroundColor Gray
            Write-Host "    OS              : $(Get-LabAssessmentField $props 'operatingSystemName')" -ForegroundColor Gray
            Write-Host "    Boot Type       : $(Get-LabAssessmentField $props 'bootType')" -ForegroundColor Gray
        }
    }
} else {
    Write-Log "Step 7 not started: Step 6 state is $assessmentState. The failure/pending reason was reported above before any continuation."
}

if (-not $assessmentReady) {
    Write-Host ''
    Write-Host 'Assessment is not verified complete. Existing discovery and VMs are retained; inspect the portal before rerunning Step 2, not deployment.' -ForegroundColor Yellow
    Write-Host 'MANUAL ALTERNATIVE (after resolving the reported error and completing discovery):' -ForegroundColor Yellow
    Write-Host "  1. Azure portal > Azure Migrate > $MigrateProjectName" -ForegroundColor White
    Write-Host "  2. Inspect existing '$groupName' / '$assessmentName' first; use classic Assessment tools > Assess > Azure VM if needed" -ForegroundColor White
    Write-Host "  3. Target location: $Location; sizing: As on-premises; VM series: Include all" -ForegroundColor White
    Write-Host "     Currency: $AssessmentCurrency; offer: $AzureOfferCode; Azure Hybrid Benefit: $AzureHybridBenefit" -ForegroundColor White
    Write-Host "  4. Select exactly the four workloads (not $ApplianceVMName); wait for Completed and review all four results" -ForegroundColor White
    Write-Host '  Missing solution association: review actual listed backend names and use -AssessmentProjectName.' -ForegroundColor White
    Write-Host '  Group/assessment name conflict: preserve it and choose unused -AssessmentGroupName / -AssessmentName.' -ForegroundColor White
    Write-Host '  Classic Azure VM assessment is default. Modern requires explicit -AssessmentMode Modern and remains experimental/deferred. No automatic fallback between modes.' -ForegroundColor Gray
    Write-Host '  MachineAssessmentV2 is a server assessment, not full mixed application assessment. Portal application assessment is a separate optional exercise.' -ForegroundColor Gray
}
Write-Host "  Azure Migrate > $MigrateProjectName > Assessments > $assessmentName" -ForegroundColor White

# ================================================================
# SUMMARY & NEXT STEPS
# ================================================================

$assessmentCanProceed = ($assessmentConfirmed -and $assessmentReady -and $assessmentState -eq 'ResultsReady')
if ($assessmentCanProceed) { Write-Section 'STEP 2 COMPLETE -- Four-machine assessment completed and results verified' }
elseif ($assessmentConfirmed -and $assessmentReady -and $assessmentState -eq 'ManualReview') {
    Write-Section 'STEP 2 ASSESSMENT COMPLETED -- Modern results require manual IaaS review before Step 3'
    Write-Host '  Review each returned Azure VM target, readiness and recommended SKU in the portal; planning defaults in Step 3 are not derived from Modern alternatives.' -ForegroundColor Yellow
}
else { Write-Section 'STEP 2 PENDING -- Assessment requires review' }

Write-Host "  What was accomplished:" -ForegroundColor White
Write-Host "  [+] Hyper-V host connection verified" -ForegroundColor Green
Write-Host "  [+] Project key generated (never displayed in full)" -ForegroundColor Green
Write-Host "  [+] Appliance '$ApplianceVMName' checked on $storeRoot$(if ($doImport -and $importOutput -match 'APPLIANCE_IMPORTED\|') { ' (fresh ZIP and extraction hashes checked, configuration copy-imported)' } else { ' (existing VM; source archive not verified)' })" -ForegroundColor Green
Write-Host "  [+] Appliance configured and discovery initiated" -ForegroundColor Green
Write-Host "  [+] Discovered servers listed" -ForegroundColor Green
if ($assessmentCanProceed) {
    Write-Host '  [+] Migration assessment Completed; all four results and current membership verified' -ForegroundColor Green
} elseif ($assessmentConfirmed -and $assessmentReady -and $assessmentState -eq 'ManualReview') {
    Write-Host '  [+] Modern assessment Completed; four source-linked results verified; manual IaaS review still required' -ForegroundColor Yellow
} elseif ($assessmentState -eq 'Submitted') {
    Write-Host '  [!] Assessment request accepted; creation not yet confirmed' -ForegroundColor Yellow
} else {
    Write-Host "  [!] Assessment state: $assessmentState; completion is not verified" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  VMs Discovered:" -ForegroundColor White
Write-Host "  - OnPrem-Web       (192.168.0.10) -- Windows + IIS" -ForegroundColor Cyan
Write-Host "  - OnPrem-SQL       (192.168.0.11) -- Windows + SQL Server 2022 Express" -ForegroundColor Cyan
Write-Host "  - OnPrem-Linux-Web (192.168.0.12) -- Ubuntu 24.04 + Nginx" -ForegroundColor Cyan
Write-Host "  - OnPrem-Linux-App (192.168.0.13) -- Ubuntu 24.04 + Tomcat 10.1" -ForegroundColor Cyan

if ($assessmentCanProceed) {
    Write-NextSteps @(
        'Review the assessment results in the Azure portal before Step 3'
        'Record the collection period and confidence rating; this is idle-lab telemetry'
        'Create a second, performance-based assessment once data has accumulated'
        'Note any readiness issues or warnings for each VM'
        'After reviewing the assessment, run Step 3: .\migrate-step3-replicate.ps1'
        'Step 3 will enable replication for all 4 VMs and begin migration'
    )
} elseif ($assessmentConfirmed -and $assessmentReady -and $assessmentState -eq 'ManualReview') {
    Write-NextSteps @(
        'Modern server assessment is Completed with four source-linked results; do not recompute it merely to remove this manual-review gate'
        'Review a suitable Azure VM target, readiness and actual recommended SKU for each workload in the portal'
        'Resolve missing/unknown/unsuitable recommendations; record evidence and recheck regional/family quotas'
        'Step 3 planning sizes are unchanged and are not automatically populated from Modern recommendations'
        'Full application assessment is a separate optional portal activity in Module 1, not this server-assessment API'
    )
} else {
    Write-NextSteps @(
        'Resolve the reported assessment error or pending state; review the existing group/assessment in the portal'
        'For authentication rejection, reconnect to the original lab tenant/environment and explicitly select the original subscription'
        'For authorization/schema/project errors, fix the specific reported cause, not the VMs'
        'Keep the running lab and appliance; rerun Step 2 with the same lab settings, not deployment/provisioning'
        'Confirm assessment creation and review the results before Step 3'
    )
}

Write-Log "Step 2 finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
