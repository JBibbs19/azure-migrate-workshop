<#
.SYNOPSIS
    Step 1: Create Azure Migrate project and prepare the target landing zone.

.DESCRIPTION
    This script sets up the Azure Migrate project and creates the target
    resource group (rg-ces-target-01) with networking infrastructure for migrated VMs.

    Run this script before starting discovery. If the project is absent, create it
    in the portal, then rerun this step to verify it before continuing to Step 2.

    What this script does:
    1. Registers required Azure resource providers
    2. Creates the target resource group (landing zone)
    3. Creates a target VNet and subnet for migrated VMs
    4. Creates a Network Security Group with appropriate rules
    5. Checks an existing Azure Migrate project or prints manual portal creation steps
    6. Outputs project details and next steps

    Why each step matters:
    - Resource providers must be registered before you can create Azure Migrate
      resources. Without them, API calls will fail with "resource type not found."
    - The target resource group is the "landing zone" -- the destination where
      migrated VMs will live. Keeping it separate from the source RG provides
      clear isolation between on-premises (simulated) and cloud environments.
    - The target VNet provides network connectivity for migrated VMs. We use a
      different address space (10.1.0.0/16) than the source (10.0.0.0/16) to
      avoid conflicts and simulate a real migration scenario.
    - The NSG controls inbound/outbound traffic to migrated VMs, following the
      principle of least privilege.
    - The Azure Migrate project is the central hub for discovery, assessment,
      and migration. It tracks all servers and their migration status.

.PARAMETER SourceResourceGroup
    The on-premises simulation resource group. Prompted when not supplied (example: rg-ces-source-01).

.PARAMETER TargetResourceGroup
    The target cloud resource group. Prompted when not supplied (example: rg-ces-target-01).

.PARAMETER Location
    Migration target VM/network region, different from the actual source host region.
    Validated against Get-AzLocation; no source default. Alias: TargetLocation.

.PARAMETER HyperVHostVMName
    Optional source Azure host name. Uses HyperVHost when present, otherwise an unambiguous
    existing VM or a selection prompt; never takes an arbitrary first VM.

.PARAMETER ForecastVmSizes
    Planning list with duplicates representing VM counts. Defaults match step 3:
    Standard_B2s, Standard_B2ms, Standard_B1ms, Standard_B1ms. Not binding migration sizes.

.PARAMETER AllowQuotaWarning
    Explicitly acknowledge unknown/insufficient quota or SKU restrictions and create only
    the network landing zone. Does not bypass Azure quota or region-conflict validation.

.PARAMETER LabTraffic
    Prompt (default) offers traffic only after a verified project and four Running workloads.
    Fully supplied environment inputs default to no traffic prompt; explicit Prompt requests it.
    Start explicitly opts in, Skip makes no generator changes. No option bypasses readiness.
.PARAMETER LabTrafficPassword
    Optional SecureString deployment password for an explicitly opted-in launch. Otherwise
    privately prompted. Never pass plaintext credentials on command lines.

.PARAMETER MigrateProjectName
    Name for the Azure Migrate project. Prompted when not supplied (example: ces-migrate-01).

.EXAMPLE
    .\migrate-step1-setup-project.ps1

.EXAMPLE
    .\migrate-step1-setup-project.ps1 -TargetResourceGroup "mycloud-rg" -Location "westus2"
MODULE COVERAGE
    The scripts and the modules are run separately. This script completes:

      Module 1, section 1   Create the project - NOT created here. This script checks for the
                            project and prints the portal steps when it is absent. A project
                            made with New-AzMigrateProject has no tool solutions registered and
                            cannot generate an appliance key. See CHANGES.md section 26.

      Module 2, section 4.1 Build the target landing zone - resource group, VNet (10.1.0.0/16),
                            subnet (default, 10.1.0.0/24) and NSG with five inbound rules, plus
                            registration of the Microsoft.OffAzure, Microsoft.Migrate and
                            Microsoft.KeyVault providers. Identical names, ranges and rules to
                            the portal steps in that section.

    Running this is OPTIONAL and is the instructor's shortcut when time is short. Module 2
    section 4.1 has the student build the same landing zone in the portal, which is where the
    address-planning and NSG-scoping decisions are actually taught. Skip this script if you want
    the student to do that.
#>

[CmdletBinding()]
param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [Alias('TargetLocation')][string]$Location,

    [string]$MigrateProjectName,

    [string]$HyperVHostVMName,

    [ValidateNotNullOrEmpty()][string[]]$ForecastVmSizes = @('Standard_B2s', 'Standard_B2ms', 'Standard_B1ms', 'Standard_B1ms'),

    [switch]$AllowQuotaWarning,

    [ValidateSet('Prompt', 'Start', 'Skip')][string]$LabTraffic = 'Prompt',

    [SecureString]$LabTrafficPassword
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
        [AllowEmptyCollection()][string[]]$OptionalModules = @(),
        [switch]$SkipSubscriptionPrompt
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
    if ($available.Count -gt 1 -and -not $SkipSubscriptionPrompt) {
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

function Get-LabField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Get-LabQuotaRow {
    param([object[]]$Usage, [string]$Key)
    $rows = @($Usage | Where-Object { (Get-LabField (Get-LabField $_ 'Name') 'Value') -eq $Key })
    if ($rows.Count -ne 1) { return $null }
    $current = Get-LabField $rows[0] 'CurrentValue'
    $limit = Get-LabField $rows[0] 'Limit'
    $unit = Get-LabField $rows[0] 'Unit'
    $currentNumber = 0L; $limitNumber = 0L
    if ($null -eq $current -or $null -eq $limit -or [string]$unit -ne 'Count' -or
        -not [long]::TryParse([string]$current, [ref]$currentNumber) -or
        -not [long]::TryParse([string]$limit, [ref]$limitNumber) -or $currentNumber -lt 0 -or $limitNumber -lt 0) { return $null }
    return [pscustomobject]@{ Current = $currentNumber; Limit = $limitNumber; Remaining = ($limitNumber - $currentNumber) }
}

function Write-LabQuotaRow {
    param([string]$Label, $Row, [Nullable[long]]$Additional)
    if ($null -eq $Row) {
        Write-Warning "$Label : Unknown (quota row missing, unreadable or unsupported unit; not zero and not proof of headroom)."
        return
    }
    Write-Host "$Label : current=$($Row.Current) limit=$($Row.Limit) remaining=$($Row.Remaining)"
    if ($null -ne $Additional) {
        Write-Host "  Hypothetical new allocations: +$Additional; projected=$($Row.Current + $Additional); remaining-after=$($Row.Remaining - $Additional)"
    }
}

function Get-LabSkuPlan {
    param([object[]]$Skus, [string[]]$Sizes, [string]$Location)
    $families = @{}; $total = 0L; $issues = @(); $known = $true
    foreach ($size in $Sizes) {
        $matches = @($Skus | Where-Object { $_.Name -eq $size -and $_.ResourceType -eq 'virtualMachines' -and @($_.Locations) -contains $Location })
        if ($matches.Count -ne 1) { $known = $false; $issues += "SKU '$size' metadata unavailable in '$Location'; forecast Unknown."; continue }
        $sku = $matches[0]
        # Quota uses the SKU vCPUs capability, not constrained vCPUsAvailable.
        $capabilities = @(Get-LabField $sku 'Capabilities' | Where-Object { (Get-LabField $_ 'Name') -eq 'vCPUs' })
        $cores = 0L
        $family = [string](Get-LabField $sku 'Family')
        if ($capabilities.Count -ne 1 -or -not [long]::TryParse([string](Get-LabField $capabilities[0] 'Value'), [ref]$cores) -or $cores -le 0 -or -not $family) {
            $known = $false; $issues += "SKU '$size' vCPUs/family metadata missing; forecast Unknown."; continue
        }
        $total += $cores
        if (-not $families.ContainsKey($family)) { $families[$family] = 0L }
        $families[$family] += $cores
        foreach ($restriction in @(Get-LabField $sku 'Restrictions')) {
            if ($null -eq $restriction) { continue }
            $type = [string](Get-LabField $restriction 'Type')
            $values = @(Get-LabField $restriction 'Values' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $info = Get-LabField $restriction 'RestrictionInfo'
            $restrictedLocations = @(Get-LabField $info 'Locations' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $applies = ($values -contains $Location -or $restrictedLocations -contains $Location)
            if ($type -eq 'Location' -and $values.Count -eq 0 -and $restrictedLocations.Count -eq 0) { $applies = $true }
            if ($applies -or ($type -eq 'Zone' -and $restrictedLocations.Count -eq 0)) {
                $issues += "SKU '$size' has a $type restriction in '$Location' (reason: $(Get-LabField $restriction 'ReasonCode')); review region/zone eligibility."
            }
        }
    }
    return [pscustomobject]@{ Known = $known; Total = $total; Families = $families; Count = $Sizes.Count; Issues = $issues }
}

function Get-LabRegionQuotaSnapshot {
    param([string]$Location)
    $usage = @(); $skus = @(); $issues = @()
    try {
        $providers = @(Get-AzResourceProvider -ProviderNamespace 'Microsoft.Compute' -ErrorAction Stop)
        if (-not @($providers | Where-Object { $_.RegistrationState -eq 'Registered' }).Count) {
            throw 'Microsoft.Compute is not registered; quota/SKU reads were not performed.'
        }
        try { $usage = @(Get-AzVMUsage -Location $Location -ErrorAction Stop) }
        catch { $issues += "Get-AzVMUsage '$Location': Unknown ($($_.Exception.Message))." }
        try { $skus = @(Get-AzComputeResourceSku -Location $Location -ErrorAction Stop | Where-Object { $_.ResourceType -eq 'virtualMachines' }) }
        catch { $issues += "Get-AzComputeResourceSku '$Location': Unknown ($($_.Exception.Message))." }
    } catch { $issues += "Read-only Compute preflight '$Location': Unknown ($($_.Exception.Message))." }
    return [pscustomobject]@{ Usage = $usage; Skus = $skus; Issues = $issues }
}

function Show-LabQuotaPreflight {
    param($SourceHost, [string]$TargetLocation, [string[]]$PlannedSizes)
    Write-Host ''
    Write-Host "READ-ONLY SUBSCRIPTION QUOTA HEADS-UP | UTC $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))" -ForegroundColor Cyan
    Write-Host "Subscription: $script:LabSubscriptionName $(Format-LabSubscriptionId $script:LabSubscriptionId) (same signed-in subscription for source and target)"
    Write-Host 'Reported usage includes ALL resources, including other labs and VM scale sets; allocated AND deallocated cores count. Nothing is subtracted.'
    $source = Get-LabRegionQuotaSnapshot -Location $SourceHost.Location
    $target = Get-LabRegionQuotaSnapshot -Location $TargetLocation
    foreach ($issue in @($source.Issues + $target.Issues)) { Write-Warning $issue }
    $sourcePlan = Get-LabSkuPlan -Skus $source.Skus -Sizes @($SourceHost.HardwareProfile.VmSize) -Location $SourceHost.Location
    Write-Host "SOURCE HOST REGION: $($SourceHost.Location) | VM $($SourceHost.Name) | actual size $($SourceHost.HardwareProfile.VmSize)"
    Write-LabQuotaRow -Label 'Total Regional vCPUs' -Row (Get-LabQuotaRow -Usage $source.Usage -Key 'cores')
    Write-LabQuotaRow -Label 'Regional VM count' -Row (Get-LabQuotaRow -Usage $source.Usage -Key 'virtualMachines')
    foreach ($family in @($sourcePlan.Families.Keys | Sort-Object)) {
        Write-LabQuotaRow -Label "Source host family $family (host SKU vCPUs=$($sourcePlan.Total); already included, NOT added again)" -Row (Get-LabQuotaRow -Usage $source.Usage -Key $family)
    }
    foreach ($issue in $sourcePlan.Issues) { Write-Warning $issue }
    if (-not $sourcePlan.Known) { Write-Warning 'Source host family quota: Unknown (actual SKU family/vCPUs metadata unresolved; no hard-coded host sizing used).' }
    Write-Host 'Four nested workload VMs and MigrateAppl are NOT separate Azure VMs; source quota counts the Azure host only, plus other Azure allocations.'
    Write-Host "TARGET MIGRATION REGION: $TargetLocation"
    $plan = Get-LabSkuPlan -Skus $target.Skus -Sizes $PlannedSizes -Location $TargetLocation
    $regional = Get-LabQuotaRow -Usage $target.Usage -Key 'cores'
    $vmCount = Get-LabQuotaRow -Usage $target.Usage -Key 'virtualMachines'
    $additional = if ($plan.Known) { $plan.Total } else { $null }
    Write-LabQuotaRow -Label 'Total Regional vCPUs' -Row $regional -Additional $additional
    Write-LabQuotaRow -Label 'Regional VM count' -Row $vmCount -Additional $plan.Count
    $issues = @($target.Issues + $plan.Issues)
    if ($null -eq $regional) { $issues += 'Target Total Regional vCPU quota Unknown.' }
    elseif ($plan.Known -and $regional.Remaining -lt $plan.Total) { $issues += 'Insufficient target Total Regional vCPU quota for the planning baseline.' }
    if ($null -eq $vmCount) { $issues += 'Target regional VM-count quota Unknown.' }
    elseif ($vmCount.Remaining -lt $plan.Count) { $issues += 'Insufficient target regional VM-count quota for the planning baseline.' }
    foreach ($family in @($plan.Families.Keys | Sort-Object)) {
        $row = Get-LabQuotaRow -Usage $target.Usage -Key $family
        $familyAdditional = if ($plan.Known) { $plan.Families[$family] } else { $null }
        Write-LabQuotaRow -Label "Target VM family $family" -Row $row -Additional $familyAdditional
        if ($null -eq $row) { $issues += "Target family '$family' quota Unknown." }
        elseif ($row.Remaining -lt $plan.Families[$family]) { $issues += "Insufficient target family '$family' quota for the planning baseline." }
    }
    Write-Host "Planning sizes (not binding migration choices): $($PlannedSizes -join ', ')"
    if ($plan.Known) {
        Write-Host "ONE FULL TARGET OR TEST SET: +$($plan.Total) vCPUs / +$($plan.Count) Azure VMs (hypothetical new allocations)."
        Write-Host "FULL TARGET + FULL TEST OVERLAP: +$($plan.Total * 2) vCPUs / +$($plan.Count * 2) Azure VMs ONLY if both new sets coexist in this target region."
        Write-LabQuotaRow -Label 'Overlap Total Regional vCPUs (optional scenario)' -Row $regional -Additional ($plan.Total * 2)
        Write-LabQuotaRow -Label 'Overlap regional VM count (optional scenario)' -Row $vmCount -Additional ($plan.Count * 2)
        if (($null -ne $regional -and $regional.Remaining -lt ($plan.Total * 2)) -or ($null -ne $vmCount -and $vmCount.Remaining -lt ($plan.Count * 2))) {
            Write-Warning 'Optional FULL TARGET + FULL TEST overlap exceeds reported regional vCPU or VM-count headroom. Clean up tests before cutover; the single-set baseline is checked separately.'
        }
        foreach ($family in @($plan.Families.Keys | Sort-Object)) {
            $overlapFamilyRow = Get-LabQuotaRow -Usage $target.Usage -Key $family
            Write-LabQuotaRow -Label "Overlap target VM family $family (optional scenario)" -Row $overlapFamilyRow -Additional ($plan.Families[$family] * 2)
            if ($null -ne $overlapFamilyRow -and $overlapFamilyRow.Remaining -lt ($plan.Families[$family] * 2)) {
                Write-Warning "Optional full-target/full-test overlap exceeds '$family' headroom; the single-set baseline is checked separately."
            }
        }
    } else { Write-Warning 'vCPU forecast: Unknown; unresolved SKU metadata is not treated as zero.' }
    Write-Host 'Step 4 normally cleans up test VMs before step 5; replication disks do not reserve VM cores. Existing target VMs are already in reported usage: do not add them again as actual usage.'
    Write-Host 'Forecasts are NOT reservations. Rerun with actual planned sizes/counts before VM/test allocation. Quota is not physical capacity; SKU restrictions, subscription policy and region access can still block allocation.'
    foreach ($issue in $issues) { Write-Warning $issue }
    return [pscustomobject]@{ NeedsAcknowledgement = ($issues.Count -gt 0); Issues = $issues }
}

function Assert-LabLandingZoneRegion {
    param([string]$ResourceGroupName, [string]$Location)
    # Enumerate read-only so a permission failure is not mistaken for a missing resource.
    $groups = @(Get-AzResourceGroup -ErrorAction Stop | Where-Object { $_.ResourceGroupName -eq $ResourceGroupName })
    if ($groups.Count -eq 0) { return }
    $resources = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Where-Object {
        ($_.ResourceType -eq 'Microsoft.Network/virtualNetworks' -and $_.Name -eq "$ResourceGroupName-vnet") -or
        ($_.ResourceType -eq 'Microsoft.Network/networkSecurityGroups' -and $_.Name -eq "$ResourceGroupName-nsg")
    })
    foreach ($resource in $resources) {
        if (-not $resource.Location -or (ConvertTo-LabRegionKey $resource.Location) -ne (ConvertTo-LabRegionKey $Location)) {
            throw "Existing $($resource.Name) is in '$($resource.Location)', not migration target '$Location'. It cannot be moved. Choose a fresh target RG/VNet. No changes were made."
        }
    }
    Write-Host "Target RG metadata region '$($groups[0].Location)' does NOT bind child resource regions."
}

# endregion Lab helpers
# $PSCommandPath is the full path of this script; it is captured so the error report can be
# written beside it. The trap records the failure and holds the window open, because a console
# launched by double-click closes the moment the script exits.
$script:LabScriptPath = $PSCommandPath
trap {
    Write-LabTerminatingError $_
    Save-LabErrorReport -ErrorRecord $_ -ScriptPath $script:LabScriptPath
    if ($script:LabStep1Interactive) { Wait-LabBeforeExit }
    exit 1
}

$script:LabTrafficExplicit = $PSBoundParameters.ContainsKey('LabTraffic')
$script:LabStep1Interactive = [string]::IsNullOrWhiteSpace($SourceResourceGroup) -or [string]::IsNullOrWhiteSpace($TargetResourceGroup) -or [string]::IsNullOrWhiteSpace($Location) -or [string]::IsNullOrWhiteSpace($MigrateProjectName)
$locationWasSupplied = -not [string]::IsNullOrWhiteSpace($Location)
$context = Get-LabAzContext -RequiredModules @('Az.Accounts', 'Az.Resources', 'Az.Network', 'Az.Compute') -OptionalModules @('Az.Migrate') -SkipSubscriptionPrompt:(-not $script:LabStep1Interactive)
foreach ($command in @('Get-AzVM', 'Get-AzLocation', 'Get-AzVirtualNetwork', 'Get-AzNetworkSecurityGroup')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required read command '$command' is unavailable. No changes were made." }
}

Write-Host ""
Write-Host "Enter the values for your lab environment. A value in [brackets] is a lab default and Enter accepts it; an (example: ...) is a hint only and must be typed." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabResourceGroupName -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Prompt 'Source resource group (contains the Hyper-V host)' -Example 'rg-ces-source-01' -MissingHelp 'It is created by deploy-lab.ps1.'
$TargetResourceGroup = Read-LabResourceGroupName -Name 'TargetResourceGroup' -Value $TargetResourceGroup -Prompt 'Target resource group to use as the landing zone' -Example 'rg-ces-target-01' -AllowNew
$MigrateProjectName = Select-LabFromList -Name 'MigrateProjectName' -Value $MigrateProjectName -Options (Get-LabMigrateProjectNames -ResourceGroupName $SourceResourceGroup) -Kind ProjectName -AllowNew -NewLabel 'Create a new Azure Migrate project -- you name it' -Prompt 'Azure Migrate project to create or reuse' -Example 'ces-migrate-01'


# Confirm this step's resources exist in the signed-in subscription before changing anything.
Assert-LabResources -SourceResourceGroup $SourceResourceGroup

$hostVMs = @(Get-AzVM -ResourceGroupName $SourceResourceGroup -ErrorAction Stop)
if (-not $HyperVHostVMName -and @($hostVMs | Where-Object { $_.Name -eq 'HyperVHost' }).Count -eq 1) { $HyperVHostVMName = 'HyperVHost' }
$HyperVHostVMName = Select-LabFromList -Name 'HyperVHostVMName' -Value $HyperVHostVMName -Options @($hostVMs | ForEach-Object { $_.Name }) -Kind VMName -Prompt 'Actual source Hyper-V host Azure VM' -EmptyHelp 'Deploy the source lab first.'
$sourceHost = Get-AzVM -ResourceGroupName $SourceResourceGroup -Name $HyperVHostVMName -ErrorAction Stop
if (-not $sourceHost -or -not $sourceHost.Location) { throw 'Actual source host region is unknown. No changes were made.' }
Write-Host "Source Hyper-V host actual region: $($sourceHost.Location) (NOT source RG metadata)" -ForegroundColor Cyan
Write-Warning 'CHOOSE THE MIGRATION TARGET BEFORE portal Create resources / Finalize discovery locks the project migration target. All subsequent migrations and test VNets must match that target. Project data geography is separate; an existing project is not remapped.'
Write-Warning 'Project migration target lock was NOT verified by this preflight. Inspect the existing project migration/recovery resources in the portal before continuing; do not change an already locked target.'
while ($true) {
    $Location = Read-LabTargetRegion -Value $Location -SourceLocation $sourceHost.Location
    Assert-LabLandingZoneRegion -ResourceGroupName $TargetResourceGroup -Location $Location
    $quotaPreflight = Show-LabQuotaPreflight -SourceHost $sourceHost -TargetLocation $Location -PlannedSizes $ForecastVmSizes
    if (-not $quotaPreflight.NeedsAcknowledgement) { break }
    if ($AllowQuotaWarning) {
        Write-Warning 'Explicit -AllowQuotaWarning: NETWORK-ONLY landing zone may proceed; quota/SKU eligibility remains unresolved. No VM allocation is approved or guaranteed.'
        break
    }
    if ($locationWasSupplied) {
        throw 'Quota/SKU heads-up requires acknowledgement before any writes. Choose another -Location or rerun with -AllowQuotaWarning for NETWORK-ONLY setup; review actual VM choices before migration.'
    }
    Write-Host '[1] Choose another target region (recommended)  [2] Continue NETWORK-ONLY despite warnings  [3] Cancel'
    $choice = Read-Host 'Quota preflight decision'
    if ($choice -eq '1') { $Location = ''; continue }
    if ($choice -eq '2') { Write-Warning 'NETWORK-ONLY acknowledgement; not a quota bypass or VM allocation guarantee.'; break }
    if ($choice -eq '3') { throw 'Cancelled before resource/provider writes.' }
    Write-Warning 'Enter 1, 2 or 3.'
}

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

# ================================================================
# Configuration
# ================================================================

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

function Test-LabMatchingLocalHost {
    try {
        $metadata = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' `
            -Headers @{ Metadata = 'true' } -TimeoutSec 3 -ErrorAction Stop
        return ($metadata.vmId -eq $sourceHost.VmId -and $metadata.name -eq $HyperVHostVMName -and
            $metadata.resourceGroupName -eq $SourceResourceGroup -and $metadata.subscriptionId -eq $context.Subscription.Id)
    } catch { return $false }
}

function Start-LabTrafficOnSelectedHost {
    $trafficPath = 'C:\AzMigrateLab\enable-lab-traffic.ps1'
    $manual = "Run $trafficPath in elevated PowerShell ON '$HyperVHostVMName' (not on a workstation)."
    $local = Test-LabMatchingLocalHost
    if ($local) {
        $localCommand = Get-Command $trafficPath -ErrorAction SilentlyContinue
        $elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $elevated -or -not (Test-Path -LiteralPath $trafficPath) -or
            $null -eq $localCommand -or -not $localCommand.Parameters.ContainsKey('NonInteractive')) {
            Write-Warning "Traffic NOT initiated by this offer. Use the refreshed traffic script on the host. $manual"
            return
        }
        $password = $LabTrafficPassword
        if (-not $password) { $password = Read-Host 'Lab deployment password (private)' -AsSecureString }
        try {
            $result = @(& $trafficPath -AdminPassword $password -ErrorAction Stop)
            if (@($result | Where-Object { [string]$_ -ceq 'LAB_TRAFFIC_FULLY_STARTED' }).Count -eq 1) {
                Write-Host 'Lab traffic fully started on the selected host; background sample order creation remains enabled until explicitly stopped or VMs are stopped/removed.' -ForegroundColor Green
            } else {
                Write-Warning "Full traffic startup was NOT confirmed; generators may be partially running. Inspect or stop them on the host. $manual"
            }
        } catch {
            Write-Warning "Traffic launch failed or is partial; generators may already be running. Inspect or stop them on the host. $manual"
        } finally { $password = $null; $result = $null }
        return
    }

    foreach ($command in @('Set-AzVMRunCommand', 'Get-AzVMRunCommand', 'Remove-AzVMRunCommand')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            Write-Warning "Traffic NOT initiated by this offer: managed Run Command is unavailable. $manual"
            return
        }
    }
    if (-not (Get-Command Set-AzVMRunCommand).Parameters.ContainsKey('ProtectedParameter')) {
        Write-Warning "Traffic NOT initiated by this offer: Az.Compute needs managed Run Command ProtectedParameter support. $manual"
        return
    }
    # Read-only remote capability checks happen before any credential is requested or generator changed.
    $preflight = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    $path = 'C:\AzMigrateLab\enable-lab-traffic.ps1'
    if (-not (Test-Path -LiteralPath $path) -or -not (Get-Command $path).Parameters.ContainsKey('NonInteractive')) { throw 'Refresh the staged traffic script.' }
    $settings = Get-Content 'C:\AzMigrateLab\lab-traffic.settings.json' -Raw | ConvertFrom-Json
    if ($settings.LinuxUsername -notmatch '^[a-z][a-z0-9]{2,18}$') { throw 'Valid deployment settings are required.' }
    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { throw 'SSH must already be installed.' }
    $ErrorActionPreference = 'Continue'
    $version = (& ssh.exe -V 2>&1 | Out-String)
    $ErrorActionPreference = 'Stop'
    if ($version -notmatch 'OpenSSH[_a-zA-Z]*(\d+)\.(\d+)' -or [int]$Matches[1] -lt 8 -or
        ([int]$Matches[1] -eq 8 -and [int]$Matches[2] -lt 4)) { throw 'OpenSSH 8.4+ is required.' }
    Write-Output 'LAB_TRAFFIC_REMOTE_CAPABLE'
} catch { Write-Output 'LAB_TRAFFIC_REMOTE_UNSUPPORTED' }
'@
    try {
        $probeResult = Invoke-AzVMRunCommand -ResourceGroupName $SourceResourceGroup -VMName $HyperVHostVMName `
            -CommandId RunPowerShellScript -ScriptString $preflight -ErrorAction Stop
        $probeText = Get-LabRunCommandText -Result $probeResult
        if (([regex]::Matches($probeText, '(?m)^LAB_TRAFFIC_REMOTE_CAPABLE\r?$')).Count -ne 1 -or
            $probeText -match 'LAB_TRAFFIC_REMOTE_UNSUPPORTED') { throw 'Remote preflight failed.' }
    } catch {
        Write-Warning "Traffic NOT initiated by this offer: remote prerequisites were not verified (refreshed staged script/settings and OpenSSH 8.4+ required). $manual"
        return
    }

    $payload = @'
param([Parameter(Mandatory = $true)][string]$AdminPassword)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$secure = $null
try {
    $secure = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    $result = @(& 'C:\AzMigrateLab\enable-lab-traffic.ps1' -AdminPassword $secure -NonInteractive -ErrorAction Stop 6>$null)
    if (@($result | Where-Object { [string]$_ -ceq 'LAB_TRAFFIC_FULLY_STARTED' }).Count -ne 1) { throw 'Full startup not confirmed.' }
    Write-Output 'LAB_STEP1_TRAFFIC_FULLY_STARTED'
} catch {
    Write-Output 'LAB_STEP1_TRAFFIC_PARTIAL_OR_FAILED'
    exit 1
} finally { $AdminPassword = $null; $secure = $null; $result = $null }
'@
    if ($payload -match '[^\x00-\x7F]') { throw 'Traffic host payload must be ASCII.' }
    $password = $LabTrafficPassword
    if (-not $password) { $password = Read-Host 'Lab deployment password (private)' -AsSecureString }
    $passwordPlain = $null
    $passwordPointer = [IntPtr]::Zero
    $protected = $null
    $job = $null
    $terminal = $false
    $attempted = $false
    $runName = 'lab-traffic-' + [guid]::NewGuid().ToString('N')
    try {
        $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
        $passwordPlain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        if ([string]::IsNullOrWhiteSpace($passwordPlain)) { Write-Warning 'Traffic NOT initiated: an empty password was supplied.'; return }
        $protected = @(@{ Name = 'AdminPassword'; Value = $passwordPlain })
        $attempted = $true
        $job = Set-AzVMRunCommand -ResourceGroupName $SourceResourceGroup -VMName $HyperVHostVMName `
            -Location $sourceHost.Location -RunCommandName $runName -SourceScript $payload `
            -ProtectedParameter $protected -TimeoutInSecond 900 -AsyncExecution -AsJob -ErrorAction Stop
        $submitted = Wait-Job -Job $job -Timeout 300
        if (-not $submitted -or $job.State -ne 'Completed') { throw 'Submission not confirmed.' }
        $null = Receive-Job -Job $job -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddSeconds(960)
        while ([DateTime]::UtcNow -lt $deadline) {
            $run = Get-AzVMRunCommand -ResourceGroupName $SourceResourceGroup -VMName $HyperVHostVMName `
                -RunCommandName $runName -Expand InstanceView -ErrorAction Stop
            if ($null -ne $run -and $null -ne $run.PSObject.Properties['InstanceView'] -and $null -ne $run.InstanceView) {
                $view = $run.InstanceView
                $state = [string](Get-LabField $view 'ExecutionState')
                $outputText = [string](Get-LabField $view 'Output')
                $errorText = [string](Get-LabField $view 'Error')
                if ($state -in @('Succeeded', 'Failed', 'TimedOut', 'Canceled', 'Cancelled')) {
                    $terminal = $true
                    if ($state -eq 'Succeeded' -and $null -ne $view.PSObject.Properties['ExitCode'] -and
                        $null -ne $view.ExitCode -and [int]$view.ExitCode -eq 0 -and
                        [string]::IsNullOrWhiteSpace($errorText) -and
                        ([regex]::Matches($outputText, '(?m)^LAB_STEP1_TRAFFIC_FULLY_STARTED\r?$')).Count -eq 1 -and
                        $outputText -notmatch 'LAB_STEP1_TRAFFIC_PARTIAL_OR_FAILED') {
                        Write-Host 'Lab traffic fully started on the selected host; background sample order creation remains enabled until explicitly stopped or VMs are stopped/removed.' -ForegroundColor Green
                    } else {
                        Write-Warning "Full traffic startup was NOT confirmed; generators may be partially running. Inspect/stop them ON '$HyperVHostVMName'. Do not retry blindly."
                    }
                    return
                }
            }
            Start-Sleep -Seconds 10
        }
        throw 'Traffic execution observation timed out.'
    } catch {
        # Never print Azure/guest error records: they can contain protected parameter values.
        if ($attempted) {
            Write-Warning "Traffic outcome UNKNOWN; remote execution or partial generators may still be running. Inspect managed Run Command '$runName' and stop traffic ON '$HyperVHostVMName' before retrying."
        } else { Write-Warning "Traffic NOT initiated by this offer. $manual" }
    } finally {
        if ($terminal) {
            try { Remove-AzVMRunCommand -ResourceGroupName $SourceResourceGroup -VMName $HyperVHostVMName -RunCommandName $runName -ErrorAction Stop | Out-Null }
            catch { Write-Warning "Terminal traffic Run Command '$runName' needs manual resource cleanup; this does not stop generators." }
        }
        if ($null -ne $job -and $job.State -in @('Completed', 'Failed', 'Stopped')) { Remove-Job -Job $job -ErrorAction SilentlyContinue }
        if ($null -ne $protected) { foreach ($parameter in $protected) { $parameter.Value = $null } }
        if ($passwordPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer) }
        $passwordPlain = $null
        $password = $null
        $protected = $null
    }
}

function Invoke-LabTrafficOffer {
    Write-Host ''
    Write-Host 'Optional lab traffic: low-rate requests create background sample orders in ContosoApp.' -ForegroundColor Yellow
    Write-Host 'Generators persist after this script/consoles close and resume after reboot while enabled.' -ForegroundColor Yellow
    Write-Host 'Keep them running through the lab only if wanted. There is NO automatic lab-completed detector or stop timer.' -ForegroundColor Yellow
    Write-Host 'Completing the lab/script alone does not stop traffic; explicitly stop it, or stop/remove VMs as part of teardown.' -ForegroundColor Yellow
    Write-Host "Stop ON '$HyperVHostVMName' in elevated PowerShell: C:\AzMigrateLab\enable-lab-traffic.ps1 -Disable (prompts for the lab password)." -ForegroundColor White
    if ($LabTraffic -eq 'Skip' -or ($LabTraffic -eq 'Prompt' -and -not $script:LabStep1Interactive -and
        -not $script:LabTrafficExplicit)) {
        Write-Host 'Traffic not initiated (Skip or supplied-input automation default). Existing generators, if any, are unchanged.' -ForegroundColor Gray
        return
    }
    if ($LabTraffic -ne 'Start') {
        $answer = Read-Host 'Would you like to initiate lab traffic as part of the immediate continuation of the lab? [y/N]'
        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host 'Traffic not initiated by this offer; no generator changes were made. Existing generators, if any, are unchanged.' -ForegroundColor Gray
            return
        }
    }
    $null = Assert-LabWorkloadPower -Stage 'Before requested traffic startup'
    Start-LabTrafficOnSelectedHost
}

# Target networking configuration
# We use 10.1.0.0/16 to clearly differentiate from the source network
# (10.0.0.0/16 for the Hyper-V host) and the guest VM subnet (192.168.0.0/24).
# This mirrors real-world migrations where the cloud landing zone has its own
# IP address space to avoid routing conflicts.
$targetVNetName       = "$TargetResourceGroup-vnet"
$targetSubnetName     = "default"
$targetAddressPrefix  = "10.1.0.0/16"
$targetSubnetPrefix   = "10.1.0.0/24"
$targetNsgName        = "$TargetResourceGroup-nsg"

# Resource providers required for Azure Migrate
# - Microsoft.OffAzure:  Manages the on-premises appliance and discovery
# - Microsoft.Migrate:   Core migration service (projects, assessments, replication)
# - Microsoft.KeyVault:  Stores secrets used during migration (e.g., credentials)
$requiredProviders = @(
    "Microsoft.OffAzure",
    "Microsoft.Migrate",
    "Microsoft.KeyVault"
)

# ================================================================
Write-Section "Step 1: Setup Azure Migrate Project & Target Landing Zone"
# ================================================================

Write-Log "Source Resource Group : $SourceResourceGroup"
Write-Log "Target Resource Group : $TargetResourceGroup"
Write-Log "Migration target region: $Location"
Write-Log "Migrate Project       : $MigrateProjectName"
Write-Host ""

# ================================================================
# PRE-FLIGHT: Verify Azure Authentication
# ================================================================
# Before doing anything, we confirm the user is logged in to Azure.
# All subsequent commands depend on having a valid Azure context.

Write-StepHeader -Step 0 -Title "Pre-flight: Verify Azure Authentication"

try {
    $context = Get-AzContext
    if (-not $context) {
        throw "Not logged in."
    }
    Write-Log "Authenticated as: $($context.Account.Id)"
    Write-Log "Subscription   : $(Format-LabSubscriptionId $context.Subscription.Id)"
} catch {
    Write-Host "ERROR: You must be logged in to Azure before running this script." -ForegroundColor Red
    Write-Host "Run:  Connect-AzAccount" -ForegroundColor Red
    Write-Host "Then: Select-AzSubscription -SubscriptionName '<your-sub>'" -ForegroundColor Red
    throw "Azure authentication required. Run Connect-AzAccount first."
}

# Verify the source resource group exists -- this proves the lab is deployed
Write-Log "Verifying source resource group '$SourceResourceGroup' exists..."
$sourceRg = Get-AzResourceGroup -Name $SourceResourceGroup -ErrorAction SilentlyContinue
if (-not $sourceRg) {
    throw "Source resource group '$SourceResourceGroup' not found. Deploy the lab first using deploy-lab.ps1."
}
Write-Log "Source RG metadata location: '$($sourceRg.Location)' (not the host or migration target region)."

$guestReadiness = Assert-LabWorkloadPower -Stage 'Step 1 pre-flight'

if ($script:LabStep1Interactive) { $null = Read-Host "Pre-flight checks passed. Press Enter to continue..." }

# ================================================================
# STEP 1: Register Resource Providers
# ================================================================
# Azure resource providers are the API backends that power each service.
# They must be registered in your subscription before you can create resources
# of that type. Registration is idempotent -- calling it when already registered
# is harmless but ensures the providers are available.
#
# Why these specific providers?
# - Microsoft.OffAzure:  Required to register and manage the Azure Migrate
#                         appliance that runs on your Hyper-V host for discovery.
# - Microsoft.Migrate:   The core provider for Azure Migrate projects,
#                         assessments, and server migration operations.
# - Microsoft.KeyVault:  Azure Migrate uses Key Vault to securely store
#                         credentials and secrets during the migration process
#                         (e.g., replication account passwords).

Write-StepHeader -Step 1 -Title "Register Required Resource Providers"

Write-Log "Registering resource providers. This ensures Azure Migrate APIs are available."
Write-Log "(This is idempotent -- safe to run multiple times.)"
Write-Host ""

foreach ($provider in $requiredProviders) {
    try {
        $registration = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop
        $state = ($registration | Select-Object -First 1).RegistrationState

        if ($state -eq "Registered") {
            Write-Log "  [ALREADY REGISTERED] $provider"
        } else {
            Write-Log "  [REGISTERING] $provider `(current state: $state`)..."
            Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | Out-Null

            # Wait for registration to complete (can take 1-2 minutes)
            $maxWait = 120  # seconds
            $elapsed = 0
            do {
                Start-Sleep -Seconds 10
                $elapsed += 10
                $registration = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop
                $state = ($registration | Select-Object -First 1).RegistrationState
                Write-Log "    Waiting... `($state, ${elapsed}s elapsed`)"
            } while ($state -ne "Registered" -and $elapsed -lt $maxWait)

            if ($state -eq "Registered") {
                Write-Log "  [REGISTERED] $provider"
            } else {
                Write-Warning "  $provider registration is still '$state' after ${maxWait}s. It may complete in the background."
            }
        }
    } catch {
        Write-Warning "Failed to register $provider`: $_"
        Write-Warning "You may need Owner or Contributor role on the subscription."
    }
}

Write-Host ""
Write-Log "Resource provider registration complete."

if ($script:LabStep1Interactive) { $null = Read-Host "Press Enter to continue to Step 2..." }

# ================================================================
# STEP 2: Create Target Resource Group (Landing Zone)
# ================================================================
# The target resource group is the "landing zone" -- the Azure environment
# where migrated VMs will live. In production migrations, the landing zone
# is prepared in advance by the cloud platform team and includes:
# - Resource groups with proper RBAC
# - Virtual networks with peering/connectivity
# - NSGs and firewall rules
# - Azure Policy assignments
# - Monitoring and logging
#
# For this workshop, we create a simple landing zone with a VNet and NSG.
# The key principle: the target environment should be fully ready BEFORE
# you start replicating or migrating workloads.

Write-StepHeader -Step 2 -Title "Create Target Resource Group"

try {
    $existingRg = Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction SilentlyContinue
    if ($existingRg) {
        Write-Log "Target resource group '$TargetResourceGroup' already exists in '$($existingRg.Location)'."
    } else {
        Write-Log "Creating resource group '$TargetResourceGroup' in '$Location'..."
        New-AzResourceGroup -Name $TargetResourceGroup -Location $Location -ErrorAction Stop | Out-Null
        Write-Log "Resource group '$TargetResourceGroup' created successfully."
    }
} catch {
    throw "Failed to create target resource group: $_"
}

if ($script:LabStep1Interactive) { $null = Read-Host "Press Enter to continue to Step 3..." }

# ================================================================
# STEP 3: Create Target Virtual Network and Subnet
# ================================================================
# Every migrated VM needs network connectivity. The target VNet defines:
# - The IP address space for migrated VMs (10.1.0.0/16)
# - Subnets for workload segmentation (10.1.0.0/24)
#
# We use 10.1.0.0/16 (not 10.0.0.0/16) because:
# 1. The source Hyper-V host already uses 10.0.0.0/16
# 2. In real migrations, you often need VNet peering or VPN between source
#    and target -- overlapping address spaces would prevent this
# 3. It clearly distinguishes "old" (10.0.x.x) from "new" (10.1.x.x) networks
#
# The /24 subnet provides 251 usable IPs -- more than enough for our 4 VMs
# plus future expansion. In production, you'd have multiple subnets for
# different tiers (web, app, data) and use service endpoints or private endpoints.

Write-StepHeader -Step 3 -Title "Create Target VNet and Subnet"

try {
    $existingVnet = Get-AzVirtualNetwork -Name $targetVNetName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue
    if ($existingVnet) {
        if ((ConvertTo-LabRegionKey $existingVnet.Location) -ne (ConvertTo-LabRegionKey $Location)) { throw "Existing target VNet region conflicts with migration target $Location." }
        Write-Log "VNet '$targetVNetName' already exists."
        $targetVNet = $existingVnet
    } else {
        Write-Log "Creating VNet '$targetVNetName' with address space $targetAddressPrefix..."
        Write-Log "  Subnet: '$targetSubnetName' `($targetSubnetPrefix`)"

        # First create the subnet configuration, then the VNet
        # The subnet is where migrated VMs will get their NICs attached
        $subnetConfig = New-AzVirtualNetworkSubnetConfig `
            -Name $targetSubnetName `
            -AddressPrefix $targetSubnetPrefix `
            -ErrorAction Stop

        $targetVNet = New-AzVirtualNetwork `
            -Name $targetVNetName `
            -ResourceGroupName $TargetResourceGroup `
            -Location $Location `
            -AddressPrefix $targetAddressPrefix `
            -Subnet $subnetConfig `
            -ErrorAction Stop

        Write-Log "VNet '$targetVNetName' created successfully."
    }
} catch {
    throw "Failed to create VNet: $_"
}

if ($script:LabStep1Interactive) { $null = Read-Host "Press Enter to continue to Step 4..." }

# ================================================================
# STEP 4: Create Network Security Group (NSG)
# ================================================================
# An NSG acts as a virtual firewall, controlling inbound and outbound
# network traffic to VMs. We create rules that balance accessibility
# (for workshop purposes) with security best practices.
#
# Rules we create:
# - Allow RDP (3389) inbound:   For connecting to migrated Windows VMs
# - Allow SSH (22) inbound:     For connecting to migrated Linux VMs
# - Allow HTTP (80) inbound:    For testing web workloads after migration
# - Allow HTTPS (443) inbound:  For secure web traffic
# - Allow Tomcat (3000) inbound: For the Tomcat application server
#
# IMPORTANT: In production, you would NOT allow RDP/SSH from the internet.
# You would use Azure Bastion, Just-In-Time VM Access, or a VPN gateway.
# These rules are intentionally permissive for workshop convenience.

Write-StepHeader -Step 4 -Title "Create Network Security Group (NSG)"

try {
    $existingNsg = Get-AzNetworkSecurityGroup -Name $targetNsgName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue
    if ($existingNsg) {
        if ((ConvertTo-LabRegionKey $existingNsg.Location) -ne (ConvertTo-LabRegionKey $Location)) { throw "Existing target NSG region conflicts with migration target $Location." }
        Write-Log "NSG '$targetNsgName' already exists."
        $targetNsg = $existingNsg
    } else {
        Write-Log "Creating NSG '$targetNsgName' with workshop-appropriate rules..."

        # Define NSG rules -- each rule has a priority (lower = evaluated first),
        # direction, and action. We space priorities by 10 to allow inserting
        # rules later if needed.
        $rules = @()

        # Rule: Allow RDP for Windows VM management
        $rules += New-AzNetworkSecurityRuleConfig `
            -Name "Allow-RDP" `
            -Description "Allow RDP for Windows VM management (workshop only)" `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Priority 100 `
            -SourceAddressPrefix "*" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix "*" `
            -DestinationPortRange "3389" `
            -ErrorAction Stop

        # Rule: Allow SSH for Linux VM management
        $rules += New-AzNetworkSecurityRuleConfig `
            -Name "Allow-SSH" `
            -Description "Allow SSH for Linux VM management (workshop only)" `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Priority 110 `
            -SourceAddressPrefix "*" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix "*" `
            -DestinationPortRange "22" `
            -ErrorAction Stop

        # Rule: Allow HTTP -- needed to verify web workloads post-migration
        $rules += New-AzNetworkSecurityRuleConfig `
            -Name "Allow-HTTP" `
            -Description "Allow HTTP for web workload verification" `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Priority 120 `
            -SourceAddressPrefix "*" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix "*" `
            -DestinationPortRange "80" `
            -ErrorAction Stop

        # Rule: Allow HTTPS
        $rules += New-AzNetworkSecurityRuleConfig `
            -Name "Allow-HTTPS" `
            -Description "Allow HTTPS for secure web traffic" `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Priority 130 `
            -SourceAddressPrefix "*" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix "*" `
            -DestinationPortRange "443" `
            -ErrorAction Stop

        # Rule: Allow Tomcat port -- OnPrem-Linux-App runs on port 3000
        $rules += New-AzNetworkSecurityRuleConfig `
            -Name "Allow-Tomcat" `
            -Description "Allow port 3000 for Tomcat application server" `
            -Access Allow `
            -Protocol Tcp `
            -Direction Inbound `
            -Priority 140 `
            -SourceAddressPrefix "*" `
            -SourcePortRange "*" `
            -DestinationAddressPrefix "*" `
            -DestinationPortRange "3000" `
            -ErrorAction Stop

        # Create the NSG with all rules
        $targetNsg = New-AzNetworkSecurityGroup `
            -Name $targetNsgName `
            -ResourceGroupName $TargetResourceGroup `
            -Location $Location `
            -SecurityRules $rules `
            -ErrorAction Stop

        Write-Log "NSG '$targetNsgName' created with 5 inbound rules."
        Write-Host ""
        Write-Host "  NSG Rules Summary:" -ForegroundColor White
        Write-Host "  Priority  Name           Port   Purpose" -ForegroundColor Gray
        Write-Host "  --------  ----           ----   -------" -ForegroundColor Gray
        Write-Host "  100       Allow-RDP      3389   Windows VM management" -ForegroundColor Gray
        Write-Host "  110       Allow-SSH      22     Linux VM management" -ForegroundColor Gray
        Write-Host "  120       Allow-HTTP     80     Web workload testing" -ForegroundColor Gray
        Write-Host "  130       Allow-HTTPS    443    Secure web traffic" -ForegroundColor Gray
        Write-Host "  140       Allow-Tomcat   3000   Tomcat application server" -ForegroundColor Gray
    }

    # Associate NSG with the target subnet
    # This ensures ALL VMs in the subnet inherit these security rules
    # automatically -- no need to attach the NSG to each NIC individually.
    Write-Log "Associating NSG with subnet '$targetSubnetName'..."
    $targetVNet = Get-AzVirtualNetwork -Name $targetVNetName -ResourceGroupName $TargetResourceGroup -ErrorAction Stop
    $subnet = Get-AzVirtualNetworkSubnetConfig -Name $targetSubnetName -VirtualNetwork $targetVNet -ErrorAction Stop

    if ($subnet.NetworkSecurityGroup) {
        Write-Log "Subnet already has an NSG associated."
    } else {
        Set-AzVirtualNetworkSubnetConfig `
            -Name $targetSubnetName `
            -VirtualNetwork $targetVNet `
            -AddressPrefix $targetSubnetPrefix `
            -NetworkSecurityGroup $targetNsg `
            -ErrorAction Stop | Out-Null

        $targetVNet | Set-AzVirtualNetwork -ErrorAction Stop | Out-Null
        Write-Log "NSG associated with subnet '$targetSubnetName'."
    }
} catch {
    throw "Failed to create or configure NSG: $_"
}

if ($script:LabStep1Interactive) { $null = Read-Host "Press Enter to continue to Step 5..." }

# ================================================================
# STEP 5: Create Azure Migrate Project
# ================================================================
# The Azure Migrate project is the central orchestration point for your
# entire migration journey. It provides:
# - A single pane of glass to track all discovered servers
# - Assessment capabilities (readiness, sizing, cost estimation)
# - Replication and migration orchestration
# - Dependency analysis visualization
#
# Under the hood, creating a project provisions:
# - An Azure Migrate project resource
# - Associated solution resources (Server Assessment, Server Migration)
# - A Log Analytics workspace for dependency data (optional)
#
# The project is created in the SOURCE resource group because it's a
# management/tooling resource -- it observes the source environment. The
# target resource group contains only the destination workloads.

Write-StepHeader -Step 5 -Title "Create Azure Migrate Project"

# Fail closed: only a successful lookup of the requested project permits Step 2 guidance.
$migrateProject = $null
$projectLookupSucceeded = $false
$rerunStep1Command = ".\migrate-step1-setup-project.ps1 -SourceResourceGroup '$SourceResourceGroup' -TargetResourceGroup '$TargetResourceGroup' -Location '$Location' -MigrateProjectName '$MigrateProjectName' -HyperVHostVMName '$HyperVHostVMName'"
$projectCreationInstructions = @(
    "1. Azure portal > search for 'Azure Migrate' > Create project."
    "2. Subscription: the one you are signed in to here."
    "3. Resource group: $SourceResourceGroup"
    "4. Project name: $MigrateProjectName"
    "5. Geography: choose the permitted PROJECT DATA geography independently; target VM region is $Location."
    "6. Create, and wait for the deployment to finish."
    "Creating it this way registers the discovery, assessment and migration tools."
    "7. Return to this PowerShell window and rerun Step 1 with the same settings:"
    "   $rerunStep1Command"
    "Do not run Step 2 until Step 1 successfully verifies the project."
)

try {
    # Project geography is a separate portal decision, never inferred from target VM region.
    Write-Log "Checking Azure Migrate project '$MigrateProjectName' (existing project unchanged)."
    $existingProject = @(Get-AzResource -ResourceGroupName $SourceResourceGroup -ErrorAction Stop | Where-Object {
        $_.Name -eq $MigrateProjectName -and $_.ResourceType -eq 'Microsoft.Migrate/migrateProjects'
    })
    if ($existingProject.Count -gt 1) { throw 'Ambiguous project resource lookup.' }
    $existingProject = if ($existingProject.Count -eq 1) { $existingProject[0] } else { $null }
    $projectLookupSucceeded = $true
    if ($existingProject) {
        Write-Log "Azure Migrate project '$MigrateProjectName' already exists."
        $migrateProject = $existingProject
    } else {
        # ----------------------------------------------------------------------------------
        # WHY THIS IS NOT CREATED HERE
        #
        # New-AzMigrateProject creates a bare Microsoft.Migrate/migrateProjects resource and
        # nothing else. Creating the project in the portal ALSO registers the tool solutions
        # the project needs -- Servers-Discovery-ServerDiscovery, Servers-Assessment-
        # ServerAssessment and Servers-Migration-ServerMigration.
        #
        # Without those solutions the project exists but is not usable. The portal's
        # "Generate key" blade reads the discovery solution, finds nothing, and fails in the
        # browser with:
        #
        #   TypeError: Cannot read properties of undefined (reading 'properties')
        #
        # There is no error in the Azure activity log, because nothing was ever submitted to
        # Azure. The same gap breaks migrate-step2's assessment stage, which writes to
        # Microsoft.Migrate/assessmentProjects/<name> -- a resource created as part of the
        # tool registration, not by New-AzMigrateProject.
        #
        # Creating a project that looks right and cannot be used is worse than not creating
        # one, so this step stops here and points at the portal, which is what Module 1
        # section 1 already instructs.
        # ----------------------------------------------------------------------------------
        $migrateProject = $null
        Write-Host ""
        Write-Warning "Azure Migrate project '$MigrateProjectName' does not exist, and this script will not create it."
        Write-Host "  Project creation instructions are shown below the landing-zone summary." -ForegroundColor White
    }

    # Display project details
    if ($migrateProject) {
        Write-Host ""
        Write-Host "  Azure Migrate Project Details:" -ForegroundColor White
        Write-Host "  Name          : $MigrateProjectName" -ForegroundColor Gray
        Write-Host "  Resource Group: $SourceResourceGroup" -ForegroundColor Gray
        Write-Host "  Location      : $($migrateProject.Location)" -ForegroundColor Gray
    }

} catch {
    $migrateProject = $null
    $projectLookupSucceeded = $false
    Write-Host "" 
    Write-Warning "Could not verify the Azure Migrate project. This does not mean the project is absent."
    Write-Host "No project was created or remapped here. Verify the project and access in the portal, then rerun Step 1." -ForegroundColor Yellow
    Write-Warning "Error details: $_"
}

# ================================================================
# SUMMARY & NEXT STEPS
# ================================================================

# A guest may have been stopped during the landing-zone/project work.
if ($migrateProject) { $guestReadiness = Assert-LabWorkloadPower -Stage 'Step 1 final readiness' }

if ($migrateProject) {
    Write-Section "STEP 1 COMPLETE -- Summary"
} else {
    Write-Section "LANDING ZONE READY -- Step 1 requires project verification"
}

Write-Host "  Resources Created:" -ForegroundColor White
Write-Host "  [+] Resource Group    : $TargetResourceGroup `(metadata location may differ`)" -ForegroundColor Green
Write-Host "  [+] Virtual Network   : $targetVNetName `($targetAddressPrefix`)" -ForegroundColor Green
Write-Host "  [+] Subnet            : $targetSubnetName `($targetSubnetPrefix`)" -ForegroundColor Green
Write-Host "  [+] NSG               : $targetNsgName `(5 inbound rules`)" -ForegroundColor Green
if ($migrateProject) {
    Write-Host "  [+] Migrate Project   : $MigrateProjectName `(existing project verified`)" -ForegroundColor Green
} elseif ($projectLookupSucceeded) {
    Write-Host "  [!] Migrate Project   : $MigrateProjectName `(not found; portal creation required`)" -ForegroundColor Yellow
} else {
    Write-Host "  [!] Migrate Project   : $MigrateProjectName `(could not verify; retry required`)" -ForegroundColor Yellow
}
Write-Host "  [i] Migration target  : $Location" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Source Environment (already deployed):" -ForegroundColor White
Write-Host "  [i] Resource Group    : $SourceResourceGroup" -ForegroundColor Cyan
Write-Host "  [i] Hyper-V Host      : $HyperVHostVMName `($($sourceHost.Location)`)" -ForegroundColor Cyan
Write-Host "  [i] Workload power verified UTC: $($guestReadiness.CheckedUtc)" -ForegroundColor Cyan
foreach ($row in $guestReadiness.Rows) { Write-Host "  [i] $($row.Name): $($row.State) (power state only)" -ForegroundColor Cyan }

Write-Log "Step 1 finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."

if ($migrateProject) {
    Write-NextSteps @(
        "Run Step 2: .\migrate-step2-discover-assess.ps1 -SourceResourceGroup '$SourceResourceGroup' -HyperVHostVMName '$HyperVHostVMName' -MigrateProjectName '$MigrateProjectName' -Location '$Location' -TargetResourceGroup '$TargetResourceGroup'"
        "Step 2 will deploy the Azure Migrate appliance on the Hyper-V host"
        "The appliance will discover all 4 on-premises VMs"
        "You will then create an assessment to evaluate migration readiness"
    )
    Invoke-LabTrafficOffer
} elseif ($projectLookupSucceeded) {
    # End on the unresolved prerequisite, not on instructions to start discovery.
    Write-ManualAction -Title "Create the Azure Migrate project in the portal (Module 1, section 1)" -Instructions $projectCreationInstructions
} else {
    Write-ManualAction -Title "Verify the Azure Migrate project, then rerun Step 1" -Instructions @(
        "1. Open Azure Migrate in the Azure portal using the subscription signed in here."
        "2. Check for project '$MigrateProjectName' in resource group '$SourceResourceGroup'."
        "3. If it exists, confirm this account can read it; do not create a duplicate."
        "4. If it is absent, create it using Module 1, section 1 and wait for deployment to finish."
        "5. Return to this PowerShell window and rerun Step 1 with the same settings:"
        "   $rerunStep1Command"
        "Do not run Step 2 until Step 1 successfully verifies the project."
    )
}
