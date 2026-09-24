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

.PARAMETER Location
    Target Azure region used by the assessment. Prompted when not supplied (example: eastus).

.PARAMETER MigrateProjectName
    Name of the Azure Migrate project (from Step 1). Prompted when not supplied (example: ces-migrate-01).

.PARAMETER HyperVHostVMName
    Name of the Hyper-V host Azure VM. Prompted when not supplied (example: HyperVHost).

.PARAMETER ApplianceVMName
    Name of the appliance VM inside Hyper-V; must match the name used for the project key.
    Prompted when not supplied (example: MigrateAppl).

.PARAMETER ApplianceDownloadUrl
    Needed only when the appliance VM does not exist yet. The VHD download link shown in the project. Prompted when not supplied.

.PARAMETER ApplianceSha256
    Needed only when the appliance VM does not exist yet. The SHA256 Microsoft publishes for that archive, or SKIP (not recommended).

.PARAMETER DownloadTimeoutMinutes
    Needed only when the appliance VM does not exist yet. Minutes to wait for the download before asking whether to keep waiting.

.PARAMETER ApplianceGeneration
    Only needed for a .vhdx: 1 or 2, per the current Microsoft article.
    A .vhd is always imported as Generation 1.

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
      Module 1, section 3.4 Import the VHD as a VM, including the resize to 80 GB.
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


    [string]$Location,

    [string]$MigrateProjectName,

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

$context = Get-LabAzContext -RequiredModules @('Az.Accounts', 'Az.Resources', 'Az.Compute') -OptionalModules @('Az.Migrate')

Write-Host ""
Write-Host "Enter the values for your lab environment. A value in [brackets] is a lab default and Enter accepts it; an (example: ...) is a hint only and must be typed." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabResourceGroupName -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Prompt 'Source resource group (contains the Hyper-V host)' -Example 'rg-ces-source-01' -MissingHelp 'It is created by deploy-lab.ps1.'
# Discovery and assessment never write to the landing zone, so no target resource group is
# asked for here. The assessment takes an Azure REGION (azureLocation), which is read from the
# source resource group. migrate-step3 onwards, which do deploy into the landing zone, ask for it.
$Location = Resolve-LabLocation -Value $Location -ResourceGroupName $SourceResourceGroup
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

# Verify the Hyper-V host VM is running
$hostVM = Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $HyperVHostVMName -Status -ErrorAction SilentlyContinue
if (-not $hostVM) {
    throw "Hyper-V host VM '$HyperVHostVMName' not found in '$SourceResourceGroup'."
}
$vmStatus = ($hostVM.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
Write-Log "Hyper-V host VM status: $vmStatus"
if ($vmStatus -ne "VM running") {
    Write-Host "WARNING: Hyper-V host is not running. Starting it now..." -ForegroundColor Yellow
    Start-AzVM -ResourceGroupName $SourceResourceGroup -Name $HyperVHostVMName -ErrorAction Stop
    Write-Log "Hyper-V host started."
}

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

    # List the guest VMs currently running on the Hyper-V host
    # This confirms the on-premises environment is healthy before we start discovery
    Write-Log "Checking guest VMs on the Hyper-V host..."
    $guestVmResult = Invoke-AzVMRunCommand `
        -ResourceGroupName $SourceResourceGroup `
        -VMName $HyperVHostVMName `
        -CommandId "RunPowerShellScript" `
        -ScriptString "Get-VM | Select-Object Name, State, MemoryAssigned, ProcessorCount | Format-Table -AutoSize" `
        -ErrorAction Stop

    Write-Host "  Guest VMs on Hyper-V host:" -ForegroundColor White
    Write-Host $guestVmResult.Value[0].Message -ForegroundColor Gray

} catch {
    throw "Failed to get Hyper-V host information: $_"
}

Read-Host "Press Enter to continue to Step 2..."

# The appliance VM is named from what is actually on the Hyper-V host. Microsoft's documented
# route -- Hyper-V Manager > Import Virtual Machine -- keeps the name held in Microsoft's
# exported configuration and offers no rename step, while Module 1 creates the VM with
# New-VM -Name. Rather than assume either, the host is asked what it has.
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
$missing = @()
foreach ($vm in @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App')) {
    if (-not (Get-VM -Name $vm -ErrorAction SilentlyContinue)) { continue }
    $svcs = Get-VMIntegrationService -VMName $vm -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('Heartbeat','Key-Value Pair Exchange') -and -not $_.Enabled }
    if ($svcs) { $missing += $vm }
}
$report['IntegrationServices'] = if ($missing.Count) { "Incomplete on $($missing -join ', ')" } else { 'Enabled on all present guests' }
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
if ($prepState['IntegrationServices'] -like 'Incomplete*') { $prepProblems += $prepState['IntegrationServices'] }

foreach ($key in @('RecordedByDeployment','HyperVRole','WinRmService','PSRemoting','IntegrationServices')) {
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
# Timing: the archive is roughly 11-12 GB and expands to a ~40 GB VHD. A single VM Run
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
    $ApplianceDownloadUrl = Read-LabParameter -Name 'ApplianceDownloadUrl' -Value $ApplianceDownloadUrl -Kind Url -Prompt 'VHD download link shown in the project (Discover > Hyper-V > VHD)' -Example 'https://aka.ms/migrate/appliance/hyperv'
    $ApplianceSha256 = Read-LabParameter -Name 'ApplianceSha256' -Value $ApplianceSha256 -Kind Sha256 -Prompt "SHA256 Microsoft publishes for this archive (Hyper-V appliance article, 'Verify security'), or SKIP"
    $DownloadTimeoutMinutes = Read-LabNumber -Name 'DownloadTimeoutMinutes' -Prompt 'Minutes to wait for the download before asking whether to keep waiting' -Value $DownloadTimeoutMinutes -Supplied:($PSBoundParameters.ContainsKey('DownloadTimeoutMinutes')) -Minimum 15 -Maximum 480 -Example '90'
}

if ($doImport) {
    # --- 3.3: Download, verify and extract on the host --------------------------------
    $worker = @'
param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Sha256)
$ErrorActionPreference = 'Stop'
$statusPath = Join-Path $Root 'appliance-download.status'
$archive = Join-Path $Root 'AzureMigrateAppliance.zip'
$partial = "$archive.partial"
$extracted = Join-Path $Root 'Extracted'
function Set-Status([string]$State, [string]$Detail) {
    $line = '{0}|{1}|{2}' -f $State, (Get-Date).ToUniversalTime().ToString('o'), ($Detail -replace '[\r\n|]+', ' ')
    Set-Content -LiteralPath $statusPath -Value $line -Encoding UTF8
}
function Find-ApplianceVhd {
    if (-not (Test-Path -LiteralPath $extracted)) { return $null }
    return (Get-ChildItem -LiteralPath $extracted -Recurse -File | Where-Object { $_.Extension -in @('.vhd', '.vhdx') } | Select-Object -First 1)
}
try {
    $vhd = Find-ApplianceVhd
    if ($vhd) { Set-Status 'Ready' $vhd.FullName; exit 0 }
    if (-not (Test-Path -LiteralPath $archive)) {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        $attempt = 0
        while ($true) {
            $attempt++
            Set-Status 'Downloading' "Attempt $attempt"
            # --continue-at - resumes a partial file after a network drop or a host restart.
            & $curl --location --fail --silent --show-error --retry 5 --retry-delay 20 --continue-at - --output $partial $Url
            if ($LASTEXITCODE -eq 0) { break }
            if ($attempt -ge 5) { throw "curl.exe exited with code $LASTEXITCODE after $attempt attempts." }
            Start-Sleep -Seconds 30
        }
        Move-Item -LiteralPath $partial -Destination $archive -Force
    }
    if ($Sha256 -ne 'SKIP') {
        Set-Status 'Verifying' 'Computing SHA256'
        $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        if ($actual -ne $Sha256.ToUpperInvariant()) {
            Remove-Item -LiteralPath $archive -Force
            throw "SHA256 mismatch (expected $Sha256, got $actual). The archive was deleted; do not import it."
        }
    }
    Set-Status 'Extracting' "Extracting to $extracted"
    if (Test-Path -LiteralPath $extracted) { Remove-Item -LiteralPath $extracted -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($archive, $extracted)
    $vhd = Find-ApplianceVhd
    if (-not $vhd) { throw 'The archive did not contain a .vhd or .vhdx file.' }
    Set-Status 'Ready' $vhd.FullName
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
    $alreadyReady = $existingOutput -match '(?m)^DOWNLOAD_STATUS\|[^|]*\|[^|]*\|Ready\|'
    $partialGB = 0.0
    $partialMatch = [regex]::Match($existingOutput, '(?m)^DOWNLOAD_STATUS\|[^|]*\|([0-9.]+)\|')
    if ($partialMatch.Success) { $partialGB = [double]::Parse($partialMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) }
    if (-not $alreadyReady -and ($storeFreeGB + $partialGB) -lt 55) {
        throw "The appliance store has $storeFreeGB GB free; the archive plus the extracted VHD need about 55 GB. Free space on $storeDrive (do not stage on C:) and rerun."
    }

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
    if ($ApplianceSha256 -eq 'SKIP') {
        Write-Warning "Hash verification was skipped. Module 1 requires checking the archive against Microsoft's published SHA256 before import."
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

    # --- 3.4: Import the VHD as a VM, grow the disk to 80 GB before first boot ------------
    $importScript = @'
$ErrorActionPreference = 'Stop'
$root = '__ROOT__'; $vmName = '__VMNAME__'; $vhdPath = '__VHD__'; $generationToken = '__GEN__'
$drive = $root.Substring(0, 2)
if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Write-Output 'APPLIANCE_EXISTS'; return }
if (-not $vhdPath.StartsWith($drive, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $vhdPath)) {
    throw "The extracted VHD '$vhdPath' is not on the appliance store $drive."
}
$extension = [IO.Path]::GetExtension($vhdPath).ToLowerInvariant()
if ($extension -eq '.vhd') {
    if ($generationToken -eq '2') { throw 'A .vhd disk can only boot as a Generation 1 VM.' }
    $generation = 1
} elseif ($generationToken -in @('1', '2')) {
    $generation = [int]$generationToken
} else {
    Write-Output 'APPLIANCE_NEEDS_GENERATION'; return
}
# The VM runs from the extracted VHD in place on the store. The disk stays dynamic.
$disk = Get-VHD -Path $vhdPath
if ($disk.Size -lt 80GB) { Resize-VHD -Path $vhdPath -SizeBytes 80GB }
$vmPath = Join-Path $root 'VMs'
New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
New-VM -Name $vmName -MemoryStartupBytes 16GB -VHDPath $vhdPath -SwitchName 'intSwitch' -Path $vmPath -Generation $generation | Out-Null
Set-VMProcessor -VMName $vmName -Count 8
Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false
Set-VM -Name $vmName -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
Set-VMNetworkAdapter -VMName $vmName -StaticMacAddress '00155D000014'
Enable-VMIntegrationService -VMName $vmName -Name 'Time Synchronization'
$reservation = @(Get-DhcpServerv4Reservation -ScopeId 192.168.0.0 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress.IPAddressToString -eq '192.168.0.20' })
if (-not $reservation.Count) {
    Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress 192.168.0.20 -ClientId '00-15-5D-00-00-14' -Name $vmName
} elseif ($reservation[0].ClientId -ne '00-15-5d-00-00-14') {
    throw "192.168.0.20 is already reserved for another client ($($reservation[0].ClientId))."
}
Start-VM -Name $vmName
# Module 1, section 3.3: keep the archive until the import succeeds, then delete it.
Remove-Item -LiteralPath (Join-Path $root 'AzureMigrateAppliance.zip') -Force -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'AzMigrateApplianceDownload' -Confirm:$false -ErrorAction SilentlyContinue
Write-Output ('APPLIANCE_IMPORTED|{0}' -f $generation)
'@

    $generationChoice = $ApplianceGeneration
    while ($true) {
        $importBody = $importScript.Replace('__ROOT__', (& $quote $storeRoot)).Replace('__VMNAME__', (& $quote $ApplianceVMName))
        $importBody = $importBody.Replace('__VHD__', (& $quote $extractedVhd)).Replace('__GEN__', [string]$generationChoice)
        Write-Log "Importing '$ApplianceVMName' from $extractedVhd (16 GB static memory, 8 vCPUs, intSwitch, 80 GB disk)..."
        $importOutput = Invoke-HostScript -Script $importBody -Stage 'Import appliance VM'
        if ($importOutput -match '(?m)^APPLIANCE_NEEDS_GENERATION') {
            Write-Log "The extracted disk is a .vhdx, which can be Generation 1 or 2."
            $generationChoice = Read-LabParameter -Name 'ApplianceGeneration' -Value '' -Kind Generation `
                -Prompt 'VM generation stated in the current Microsoft article for this VHD (1 or 2)'
            continue
        }
        break
    }
    if ($importOutput -match '(?m)^APPLIANCE_EXISTS') {
        Write-Log "VM '$ApplianceVMName' already exists on the host; it was not recreated."
    } elseif ($importOutput -match '(?m)^APPLIANCE_IMPORTED\|(\d)') {
        Write-Log "Appliance imported as a Generation $($Matches[1]) VM and started. The archive was deleted to reclaim space."
    } else {
        throw 'The host did not confirm the appliance import.'
    }
} else {
    Write-Log "VM '$ApplianceVMName' already exists on the host; the download and import are skipped."
    Write-Log "This script checks it against Module 1 below."
}

# --- Confirm the appliance VM matches Module 1 (section 3.5 checklist) -------------------
$verifyScript = @'
$vmName = '__VMNAME__'; $drive = '__DRIVE__'
$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) { Write-Output 'APPLIANCE_CHECK|Missing'; return }
$paths = @(Get-VMHardDiskDrive -VMName $vmName | ForEach-Object { $_.Path })
$onStore = ($paths.Count -gt 0 -and @($paths | Where-Object { $_ -like "$drive*" }).Count -eq $paths.Count)
$maxGB = 0
if ($paths.Count) { $maxGB = [math]::Round((Get-VHD -Path $paths[0]).Size / 1GB) }
$memory = Get-VMMemory -VMName $vmName
$nic = Get-VMNetworkAdapter -VMName $vmName | Select-Object -First 1
$ips = @($nic.IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ' '
Write-Output ('APPLIANCE_CHECK|{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $vm.State, $vm.ProcessorCount, [math]::Round($memory.Startup / 1GB), $memory.DynamicMemoryEnabled, $onStore, $maxGB, $nic.SwitchName, $ips)
'@

Write-Log "Checking '$ApplianceVMName' against Module 1..."
$checkBody = $verifyScript.Replace('__VMNAME__', $ApplianceVMName.Replace("'", "''")).Replace('__DRIVE__', $storeDrive)
$checkOutput = Invoke-HostScript -Script $checkBody -Stage 'Check appliance VM'
$checkLine = @($checkOutput -split "`r?`n" | Where-Object { $_ -like 'APPLIANCE_CHECK|*' }) | Select-Object -Last 1
if (-not $checkLine -or $checkLine -eq 'APPLIANCE_CHECK|Missing') {
    Write-Warning "VM '$ApplianceVMName' was not found on $HyperVHostVMName. Rerun this script, or complete Module 1 sections 3.3-3.4 by hand, before continuing."
    Read-Host "Press Enter once the appliance VM exists and is running..."
} else {
    $c = $checkLine.Split([char[]]'|')
    $checks = @(
        @{ Item = 'State';                  Actual = $c[1]; Expected = 'Running' }
        @{ Item = 'vCPUs';                  Actual = $c[2]; Expected = '8' }
        @{ Item = 'Memory (GB)';            Actual = $c[3]; Expected = '16' }
        @{ Item = 'Dynamic memory';         Actual = $c[4]; Expected = 'False' }
        @{ Item = "Disk on $storeDrive";    Actual = $c[5]; Expected = 'True' }
        @{ Item = 'Virtual disk size (GB)'; Actual = $c[6]; Expected = '80' }
        @{ Item = 'Switch';                 Actual = $c[7]; Expected = 'intSwitch' }
    )
    foreach ($check in $checks) {
        $ok = [string]$check.Actual -eq [string]$check.Expected
        $colour = if ($ok) { 'Green' } else { 'Yellow' }
        $mark = if ($ok) { '[OK]  ' } else { '[CHECK]' }
        Write-Host ("  {0} {1,-24} {2}  (expected {3})" -f $mark, $check.Item, $check.Actual, $check.Expected) -ForegroundColor $colour
    }
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
    "3. Inside $ApplianceVMName (elevated PowerShell), extend C: into the space added to the disk:"
    "     `$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax; Resize-Partition -DriveLetter C -Size `$max"
    "4. Check the clock inside ${ApplianceVMName}: [DateTime]::UtcNow and Get-TimeZone (expect UTC)."
    "     If wrong: Set-TimeZone -Id 'UTC'; w32tm /resync /force"
    "5. Open https://192.168.0.20:44368 (HTTPS only) and confirm it is your own appliance."
    "6. Complete the connectivity, time and update checks."
    "7. Paste the project key; sign in to the correct tenant and subscription."
    "8. Hyper-V host credentials: HyperVHost\<lab user>; discovery source address 192.168.0.1."
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
        $discoveredServers = @(Get-AzMigrateDiscoveredServer `
            -ProjectName $MigrateProjectName `
            -ResourceGroupName $SourceResourceGroup `
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

$assessmentName = "Workshop-Assessment"

try {
    Write-Log "Creating assessment '$assessmentName'..."
    Write-Log "Assessment type: Azure VM (IaaS) -- for lift-and-shift migration"

    # The assessment needs a group of servers to evaluate.
    # Module 1: a group containing exactly the four workload VMs.
    $groupName = "AllServers-Group"

    # Attempt to create assessment via REST API since the PowerShell cmdlet
    # may not be available in all Az.Migrate module versions
    $subscriptionId = $context.Subscription.Id
    $apiVersion = "2023-03-15"

    # Build the assessment group with all discovered machines
    if ($workloadServers.Count) {
        $machineIds = @()
        foreach ($server in $workloadServers) {
            if ($server.Id) {
                $machineIds += $server.Id
            }
        }

        Write-Log "Creating server group '$groupName' with $($machineIds.Count) machines..."

        # Create the group via REST API
        $groupUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$SourceResourceGroup/providers/Microsoft.Migrate/assessmentProjects/$MigrateProjectName/groups/${groupName}?api-version=$apiVersion"

        $groupBody = @{
            properties = @{
                machines = $machineIds
            }
        } | ConvertTo-Json -Depth 5

        try {
            $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type"  = "application/json"
            }
            $groupResponse = Invoke-RestMethod -Uri $groupUri -Method Put -Body $groupBody -Headers $headers -ErrorAction Stop
            Write-Log "Server group '$groupName' created."
        } catch {
            Write-Warning "Could not create group via REST API: $_"
        }

        # Create the assessment
        Write-Log "Creating assessment '$assessmentName'..."

        $assessmentUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$SourceResourceGroup/providers/Microsoft.Migrate/assessmentProjects/$MigrateProjectName/groups/$groupName/assessments/${assessmentName}?api-version=$apiVersion"

        $assessmentBody = @{
            properties = @{
                # "AsOnPremises" uses the current VM sizes to find equivalent Azure sizes
                # "PerformanceBased" would use actual utilization data for right-sizing
                sizingCriterion     = "AsOnPremises"
                azureLocation       = $Location
                currency            = $AssessmentCurrency
                # Reserved instances can reduce costs by 30-72% for 1-3 year commitments
                reservedInstance    = "None"
                azureOfferCode      = $AzureOfferCode
                azureHybridUseBenefit = $AzureHybridBenefit
            }
        } | ConvertTo-Json -Depth 5

        try {
            $assessmentResponse = Invoke-RestMethod -Uri $assessmentUri -Method Put -Body $assessmentBody -Headers $headers -ErrorAction Stop
            Write-Log "Assessment '$assessmentName' created successfully."
        } catch {
            Write-Warning "Could not create assessment via REST API: $_"
        }
    }

} catch {
    Write-Host ""
    Write-Host "NOTE: Assessment creation requires discovered servers." -ForegroundColor Yellow
    Write-Host "If discovery hasn't completed, create the assessment manually:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "MANUAL ALTERNATIVE:" -ForegroundColor Yellow
    Write-Host "  1. Go to Azure portal > Azure Migrate > $MigrateProjectName" -ForegroundColor White
    Write-Host "  2. Under 'Assessment tools', click 'Assess' > 'Azure VM'" -ForegroundColor White
    Write-Host "  3. Assessment settings:" -ForegroundColor White
    Write-Host "     - Target location: $Location" -ForegroundColor White
    Write-Host "     - Sizing criterion: As on-premises" -ForegroundColor White
    Write-Host "     - VM series: Include all" -ForegroundColor White
    Write-Host "     - Currency: $AssessmentCurrency; offer: $AzureOfferCode; Azure Hybrid Benefit: $AzureHybridBenefit" -ForegroundColor White
    Write-Host "  4. Select exactly the 4 workload servers (not $ApplianceVMName)" -ForegroundColor White
    Write-Host "  5. Create the assessment and wait for it to complete" -ForegroundColor White
    Write-Host ""
    Write-Warning "Error details: $_"
}

Read-Host "Press Enter to continue to Step 7..."

# ================================================================
# STEP 7: Display Assessment Results
# ================================================================
# The assessment takes a few minutes to compute. Once complete, it
# provides detailed information about each VM's readiness for Azure.
# This is critical decision-making data for a real migration:
# - Are there any blockers? (e.g., unsupported OS, incompatible boot type)
# - What Azure VM size should each VM use?
# - What will it cost monthly?

Write-StepHeader -Step 7 -Title "Display Assessment Results"

try {
    Write-Log "Retrieving assessment results..."
    Write-Log "(Assessment computation may take 2-5 minutes after creation)"

    # Poll for assessment status
    $assessmentReady = $false
    $assessAttempts = 0
    $maxAssessAttempts = 10

    while (-not $assessmentReady -and $assessAttempts -lt $maxAssessAttempts) {
        $assessAttempts++
        try {
            $token = (Get-AzAccessToken -ResourceUrl "https://management.azure.com").Token
            $headers = @{
                "Authorization" = "Bearer $token"
                "Content-Type"  = "application/json"
            }

            $assessResultUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$SourceResourceGroup/providers/Microsoft.Migrate/assessmentProjects/$MigrateProjectName/groups/$groupName/assessments/${assessmentName}/assessedMachines?api-version=$apiVersion"

            $assessedMachines = Invoke-RestMethod -Uri $assessResultUri -Method Get -Headers $headers -ErrorAction Stop

            if ($assessedMachines.value -and $assessedMachines.value.Count -gt 0) {
                $assessmentReady = $true

                Write-Host ""
                Write-Host "  Assessment Results: $assessmentName" -ForegroundColor White
                Write-Host "  ========================================" -ForegroundColor White
                Write-Host ""

                foreach ($machine in $assessedMachines.value) {
                    $props = $machine.properties
                    $readiness = if ($props.suitability) { $props.suitability } else { "Unknown" }
                    $readinessColor = if ($readiness -eq "Suitable") { "Green" } elseif ($readiness -eq "ConditionallySuitable") { "Yellow" } else { "Red" }

                    Write-Host "  VM: $($props.displayName)" -ForegroundColor White
                    Write-Host "    Readiness       : $readiness" -ForegroundColor $readinessColor
                    Write-Host "    Recommended Size: $($props.recommendedSize)" -ForegroundColor Gray
                    Write-Host "    Monthly Cost    : `$$($props.monthlyComputeCostForRecommendedSize) `(compute`)" -ForegroundColor Gray
                    Write-Host "    OS              : $($props.operatingSystemName)" -ForegroundColor Gray
                    Write-Host "    Boot Type       : $($props.bootType)" -ForegroundColor Gray
                    Write-Host ""
                }
            } else {
                Write-Log "  Attempt $assessAttempts/$maxAssessAttempts -- Assessment still computing..."
                Start-Sleep -Seconds 30
            }
        } catch {
            Write-Log "  Attempt $assessAttempts -- Waiting for assessment results..."
            Start-Sleep -Seconds 30
        }
    }

    if (-not $assessmentReady) {
        Write-Host ""
        Write-Host "Assessment results are not yet available." -ForegroundColor Yellow
        Write-Host "Check results in the Azure portal:" -ForegroundColor Yellow
        Write-Host "  Azure Migrate > $MigrateProjectName > Assessments > $assessmentName" -ForegroundColor White
    }

} catch {
    Write-Host ""
    Write-Host "Could not retrieve assessment results programmatically." -ForegroundColor Yellow
    Write-Host "Check results in the Azure portal:" -ForegroundColor Yellow
    Write-Host "  Azure Migrate > $MigrateProjectName > Assessments" -ForegroundColor White
    Write-Warning "Error: $_"
}

# ================================================================
# SUMMARY & NEXT STEPS
# ================================================================

Write-Section "STEP 2 COMPLETE -- Summary"

Write-Host "  What was accomplished:" -ForegroundColor White
Write-Host "  [+] Hyper-V host connection verified" -ForegroundColor Green
Write-Host "  [+] Project key generated (never displayed in full)" -ForegroundColor Green
Write-Host "  [+] Appliance '$ApplianceVMName' checked on $storeRoot$(if ($doImport) { ' (downloaded, verified and imported by this script)' })" -ForegroundColor Green
Write-Host "  [+] Appliance configured and discovery initiated" -ForegroundColor Green
Write-Host "  [+] Discovered servers listed" -ForegroundColor Green
Write-Host "  [+] Migration assessment created" -ForegroundColor Green
Write-Host ""
Write-Host "  VMs Discovered:" -ForegroundColor White
Write-Host "  - OnPrem-Web       (192.168.0.10) -- Windows + IIS" -ForegroundColor Cyan
Write-Host "  - OnPrem-SQL       (192.168.0.11) -- Windows + SQL Server 2022 Express" -ForegroundColor Cyan
Write-Host "  - OnPrem-Linux-Web (192.168.0.12) -- Ubuntu 22.04 + Nginx" -ForegroundColor Cyan
Write-Host "  - OnPrem-Linux-App (192.168.0.13) -- Ubuntu 22.04 + Node.js" -ForegroundColor Cyan

Write-NextSteps @(
    "Review the assessment results in the Azure portal"
    "Record the collection period and confidence rating; this is idle-lab telemetry"
    "Create a second, performance-based assessment once data has accumulated"
    "Note any readiness issues or warnings for each VM"
    "Run Step 3: .\migrate-step3-replicate.ps1"
    "Step 3 will enable replication for all 4 VMs and begin migration"
)

Write-Log "Step 2 finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
