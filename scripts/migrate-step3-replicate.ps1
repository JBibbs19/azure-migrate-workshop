<#
.SYNOPSIS
    Step 3: Enable replication for all 4 VMs.

.DESCRIPTION
    This script configures and starts replication from Hyper-V to Azure for
    all 4 on-premises VMs using Azure Migrate's Server Migration tool.

    After running this script, initial replication will begin. The VMs continue
    running on-premises while data is replicated to Azure. Once replication
    reaches a healthy state, you can perform a test migration or cutover.

    What this script does:
    1. Retrieves discovered machines from Azure Migrate
    2. Configures replication for each VM (target RG, VNet, VM size, OS type)
    3. Starts replication for all 4 VMs
    4. Monitors replication progress and displays status
    5. Provides next steps for test migration and cutover

    How replication works:
    - Azure Migrate installs a replication provider on the Hyper-V host
    - The provider captures disk changes and sends them to Azure
    - An initial full replication copies all disk data (can take hours)
    - After initial sync, delta replication sends only changed blocks
    - During replication, the source VMs continue running normally
    - When you're ready to migrate, you perform a "cutover" which:
      a) Performs a final delta sync
      b) Shuts down the source VM
      c) Starts the VM in Azure with the replicated data

    Prerequisites:
    - Step 1 (setup project) and Step 2 (discovery) must be completed
    - All 4 VMs must be discovered in Azure Migrate
    - The target landing zone (VNet, NSG) must exist

.PARAMETER SourceResourceGroup
    The on-premises simulation resource group. Prompted when not supplied (example: rg-ces-source-01).

.PARAMETER TargetResourceGroup
    The target cloud resource group. Prompted when not supplied (example: rg-ces-target-01).

.PARAMETER Location
    Azure region. Prompted when not supplied (example: eastus).

.PARAMETER MigrateProjectName
    Name of the Azure Migrate project. Prompted when not supplied (example: ces-migrate-01).

.EXAMPLE
    .\migrate-step3-replicate.ps1

.EXAMPLE
    .\migrate-step3-replicate.ps1 -TargetResourceGroup "mycloud-rg" -Location "westus2"
MODULE COVERAGE
    The scripts and the modules are run separately. What this completes depends on -Workload:

      -Workload Agentless   Module 2, sections 5 and 6 (Configure Replication for OnPrem-Web
                            and OnPrem-Linux-Web) and section 7 (Monitor Replication).
      -Workload AgentBased  Module 3, section 8 (Configure Replication) and section 9
                            (Monitor Replication).
      -Workload All         Both of the above, in one pass. The default.

    IMPORTANT: replication here is always AGENTLESS. Module 3 sections 5 to 7 - deploy the
    replication appliance, install Mobility Service on each guest - are NOT performed. The end
    state matches; the method does not. See CHANGES.md section 11.
#>

[CmdletBinding()]
param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [string]$Location,

    [string]$MigrateProjectName,

    # Which workload group to act on (prompted when not supplied).
    #   Agentless  = OnPrem-Web, OnPrem-Linux-Web      (the Module 2 pair)
    #   AgentBased = OnPrem-SQL, OnPrem-Linux-App      (the Module 3 pair)
    #   All        = all four
    [string]$Workload
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

Write-Host ""
Write-Host "Enter the values for your lab environment. A value in [brackets] is a lab default and Enter accepts it; an (example: ...) is a hint only and must be typed." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabResourceGroupName -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Prompt 'Source resource group (contains the Hyper-V host)' -Example 'rg-ces-source-01' -MissingHelp 'It is created by deploy-lab.ps1.'
$TargetResourceGroup = Read-LabResourceGroupName -Name 'TargetResourceGroup' -Value $TargetResourceGroup -Prompt 'Target resource group (landing zone for migrated VMs)' -Example 'rg-ces-target-01' -MissingHelp 'It is created by migrate-step1-setup-project.ps1.'
$Location = Resolve-LabLocation -Value $Location -ResourceGroupName $TargetResourceGroup
$MigrateProjectName = Select-LabFromList -Name 'MigrateProjectName' -Value $MigrateProjectName -Options (Get-LabMigrateProjectNames -ResourceGroupName $SourceResourceGroup) -Kind ProjectName -Prompt 'Azure Migrate project' -EmptyHelp 'Run migrate-step1-setup-project.ps1 first, or create the project in the portal (Module 1 section 1).'
$Workload = Select-LabFromList -Name 'Workload' -Value $Workload -Options @('All', 'Agentless', 'AgentBased') -Kind Workload -Prompt 'Workload group (All = four VMs; Agentless = the Module 2 pair; AgentBased = the Module 3 pair)'


# Confirm this step's resources exist in the signed-in subscription before changing anything.
Assert-LabResources -SourceResourceGroup $SourceResourceGroup -TargetResourceGroup $TargetResourceGroup -MigrateProjectName $MigrateProjectName

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
# VM Configuration Mapping
# ================================================================
# This mapping defines the target configuration for each VM.
# In production, these decisions come from the assessment results
# (Step 2) and architecture review. For this workshop, we pre-define
# appropriate Azure VM sizes based on each workload's role.
#
# Sizing rationale:
# - OnPrem-Web (IIS):          Standard_B2s  -- light web server, 2 vCPU/4GB
# - OnPrem-SQL (SQL Server):   Standard_B2ms -- database needs more memory, 2 vCPU/8GB
# - OnPrem-Linux-Web (Nginx):  Standard_B1ms -- lightweight reverse proxy, 1 vCPU/2GB
# - OnPrem-Linux-App (Node.js): Standard_B1ms -- small API server, 1 vCPU/2GB
#
# OS disk type: StandardSSD_LRS balances cost and performance.
# Premium_LRS would be better for production SQL workloads.

$vmConfigurations = @(
    @{
        # IIS web server -- serves the Contoso sample web application
        # Needs moderate CPU for request handling and some memory for IIS worker processes
        DisplayName    = "OnPrem-Web"
        TargetVMSize   = "Standard_B2s"
        OSType         = "Windows"
        DiskType       = "StandardSSD_LRS"
        LicenseType    = "WindowsServer"  # Azure Hybrid Benefit eligible
        IPAddress      = "192.168.0.10"
    },
    @{
        # SQL Server 2022 Express -- hosts the ContosoApp database
        # Needs more memory for SQL Server buffer pool and query processing
        # In production, consider Azure SQL Database (PaaS) instead of IaaS
        DisplayName    = "OnPrem-SQL"
        TargetVMSize   = "Standard_B2ms"
        OSType         = "Windows"
        DiskType       = "StandardSSD_LRS"
        LicenseType    = "WindowsServer"
        IPAddress      = "192.168.0.11"
    },
    @{
        # Nginx web server -- serves a static HTML site
        # Very lightweight -- Nginx is extremely memory-efficient
        DisplayName    = "OnPrem-Linux-Web"
        TargetVMSize   = "Standard_B1ms"
        OSType         = "Linux"
        DiskType       = "StandardSSD_LRS"
        LicenseType    = "NoLicenseType"
        IPAddress      = "192.168.0.12"
    },
    @{
        # Node.js Express API -- runs a REST API on port 3000
        # Moderate CPU for request handling, small memory footprint
        DisplayName    = "OnPrem-Linux-App"
        TargetVMSize   = "Standard_B1ms"
        OSType         = "Linux"
        DiskType       = "StandardSSD_LRS"
        LicenseType    = "NoLicenseType"
        IPAddress      = "192.168.0.13"
    }
)

# ================================================================
# WORKLOAD GROUP FILTER
# ================================================================
# Modules 2 and 3 are parallel branches off Module 1: Module 2 takes
# OnPrem-Web and OnPrem-Linux-Web all the way through cutover, Module 3
# does the same for OnPrem-SQL and OnPrem-Linux-App. -Workload narrows
# this script to one of those branches so the lab state can be advanced
# one module at a time. All is the original behaviour.
$LabWorkloadGroups = @{
    Agentless  = @("OnPrem-Web", "OnPrem-Linux-Web")
    AgentBased = @("OnPrem-SQL", "OnPrem-Linux-App")
}
if ($Workload -ne "All") {
    $selected = $LabWorkloadGroups[$Workload]
    $vmConfigurations = @($vmConfigurations | Where-Object { $selected -contains $_.DisplayName })
    Write-Host "Workload filter: $Workload -> $($selected -join ', ')" -ForegroundColor Cyan
}

# ================================================================
Write-Section "Step 3: Enable Replication for Migration"
# ================================================================

Write-Log "Source Resource Group : $SourceResourceGroup"
Write-Log "Target Resource Group : $TargetResourceGroup"
Write-Log "Migrate Project       : $MigrateProjectName"
Write-Log "VMs to replicate      : $($vmConfigurations.Count)"
Write-Host ""

# ================================================================
# PRE-FLIGHT: Verify Prerequisites
# ================================================================

Write-StepHeader -Step 0 -Title "Pre-flight: Verify Prerequisites"

# Check Azure authentication
try {
    $context = Get-AzContext
    if (-not $context) { throw "Not logged in." }
    Write-Log "Authenticated as: $($context.Account.Id)"
    $subscriptionId = $context.Subscription.Id
} catch {
    throw "Azure authentication required. Run Connect-AzAccount first."
}

# Verify both resource groups exist
$sourceRg = Get-AzResourceGroup -Name $SourceResourceGroup -ErrorAction SilentlyContinue
if (-not $sourceRg) {
    throw "Source resource group '$SourceResourceGroup' not found."
}

$targetRg = Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction SilentlyContinue
if (-not $targetRg) {
    throw "Target resource group '$TargetResourceGroup' not found. Run Step 1 first."
}

# Verify target VNet exists
$targetVNetName = "$TargetResourceGroup-vnet"
$targetVNet = Get-AzVirtualNetwork -Name $targetVNetName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue
if (-not $targetVNet) {
    throw "Target VNet '$targetVNetName' not found. Run Step 1 first."
}
$targetSubnet = $targetVNet.Subnets | Where-Object { $_.Name -eq "default" }
if (-not $targetSubnet) {
    throw "Default subnet not found in VNet '$targetVNetName'."
}

Write-Log "Target VNet    : $targetVNetName"
Write-Log "Target Subnet  : $($targetSubnet.Name) `($($targetSubnet.AddressPrefix)`)"

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
# STEP 1: Retrieve Discovered Machines from Azure Migrate
# ================================================================
# Before we can configure replication, we need to get the list of
# discovered machines from Azure Migrate. Each discovered machine
# has a unique ID that we reference when setting up replication.
#
# The discovered machines were found by the Azure Migrate appliance
# in Step 2. We match them by display name to our VM configurations.

Write-StepHeader -Step 1 -Title "Retrieve Discovered Machines"

$discoveredMachines = @()

try {
    Write-Log "Querying Azure Migrate for discovered servers..."

    $discoveredServers = Get-AzMigrateDiscoveredServer `
        -ProjectName $MigrateProjectName `
        -ResourceGroupName $SourceResourceGroup `
        -ErrorAction Stop

    if (-not $discoveredServers -or @($discoveredServers).Count -eq 0) {
        throw "No discovered servers found. Complete Step 2 (discovery) first."
    }

    Write-Log "Found $(@($discoveredServers).Count) discovered server`(s`)."
    Write-Host ""
    Write-Host "  Discovered Servers:" -ForegroundColor White
    Write-Host "  ==================" -ForegroundColor White

    foreach ($server in $discoveredServers) {
        $osType = if ($server.OperatingSystemDetailOSType) { $server.OperatingSystemDetailOSType } else { "Unknown" }
        Write-Host "  - $($server.DisplayName) `(OS: $osType, ID: $($server.Id)`)" -ForegroundColor Gray
        $discoveredMachines += $server
    }

    # Verify we found all expected VMs
    $missingVMs = @()
    foreach ($vmConfig in $vmConfigurations) {
        $found = $discoveredMachines | Where-Object { $_.DisplayName -eq $vmConfig.DisplayName }
        if (-not $found) {
            $missingVMs += $vmConfig.DisplayName
        }
    }

    if ($missingVMs.Count -gt 0) {
        Write-Host ""
        Write-Host "WARNING: The following expected VMs were not found:" -ForegroundColor Yellow
        foreach ($missing in $missingVMs) {
            Write-Host "  - $missing" -ForegroundColor Yellow
        }
        Write-Host "Discovery may still be in progress. You can continue with available VMs." -ForegroundColor Yellow
        Read-Host "Press Enter to continue with available VMs, or Ctrl+C to abort"
    }

} catch {
    Write-Host ""
    Write-Host "ERROR: Could not retrieve discovered machines." -ForegroundColor Red
    Write-Host "Ensure Step 2 (discovery) is complete and all 4 VMs are discovered." -ForegroundColor Red
    Write-Host ""
    Write-Host "Check in the Azure portal:" -ForegroundColor Yellow
    Write-Host "  Azure Migrate > $MigrateProjectName > Discovered servers" -ForegroundColor White
    throw "Cannot proceed without discovered machines: $_"
}

Read-Host "Press Enter to continue to Step 2..."

# ================================================================
# STEP 2: Configure and Start Replication for Each VM
# ================================================================
# Replication is the process of copying VM disk data from on-premises
# to Azure. Azure Migrate uses the Hyper-V replication provider to:
#
# 1. Take an initial snapshot of all VM disks
# 2. Copy the full disk contents to Azure managed disks (initial replication)
# 3. Track ongoing disk changes using Hyper-V change tracking
# 4. Periodically sync changed blocks (delta replication)
#
# For each VM, we specify:
# - Target resource group: Where the Azure VM will be created
# - Target VNet/subnet: Network connectivity for the Azure VM
# - Target VM size: The Azure VM SKU (determined by assessment)
# - OS type: Windows or Linux (affects boot configuration)
# - Disk type: Storage tier for managed disks
# - License type: Azure Hybrid Benefit (for Windows with SA)
#
# IMPORTANT: Replication does NOT stop the source VM. The on-premises
# VM continues running normally throughout the replication process.
# This is a key advantage -- zero downtime during replication.

Write-StepHeader -Step 2 -Title "Configure and Start Replication"

$replicationResults = @()

foreach ($vmConfig in $vmConfigurations) {
    Write-Host ""
    Write-Host ("─" * 50) -ForegroundColor DarkGray
    Write-Host "  Configuring replication: $($vmConfig.DisplayName)" -ForegroundColor White
    Write-Host ("─" * 50) -ForegroundColor DarkGray

    # Find the discovered machine matching this VM
    $machine = $discoveredMachines | Where-Object { $_.DisplayName -eq $vmConfig.DisplayName }

    if (-not $machine) {
        Write-Host "  SKIPPED: '$($vmConfig.DisplayName)' not found in discovered machines." -ForegroundColor Yellow
        $replicationResults += @{
            VMName = $vmConfig.DisplayName
            Status = "Skipped"
            Reason = "Not discovered"
        }
        continue
    }

    Write-Host "  Source VM     : $($vmConfig.DisplayName) `($($vmConfig.IPAddress)`)" -ForegroundColor Gray
    Write-Host "  Target RG     : $TargetResourceGroup" -ForegroundColor Gray
    Write-Host "  Target VNet   : $targetVNetName / default" -ForegroundColor Gray
    Write-Host "  Target Size   : $($vmConfig.TargetVMSize)" -ForegroundColor Gray
    Write-Host "  OS Type       : $($vmConfig.OSType)" -ForegroundColor Gray
    Write-Host "  Disk Type     : $($vmConfig.DiskType)" -ForegroundColor Gray
    Write-Host "  License       : $($vmConfig.LicenseType)" -ForegroundColor Gray
    Write-Host ""

    try {
        # Check if replication is already configured for this VM
        $existingReplication = Get-AzMigrateServerReplication `
            -ProjectName $MigrateProjectName `
            -ResourceGroupName $SourceResourceGroup `
            -MachineName $vmConfig.DisplayName `
            -ErrorAction SilentlyContinue

        if ($existingReplication) {
            Write-Log "  Replication already configured for '$($vmConfig.DisplayName)' `(Status: $($existingReplication.MigrationState)`)."
            $replicationResults += @{
                VMName = $vmConfig.DisplayName
                Status = "AlreadyConfigured"
                Reason = $existingReplication.MigrationState
            }
            continue
        }

        # Build the disk configuration for replication
        # Each disk on the VM needs a target disk type specification
        # We collect disk IDs from the discovered machine data
        $diskIds = @()
        if ($machine.Disk) {
            foreach ($disk in $machine.Disk) {
                $diskIds += New-AzMigrateDiskMapping `
                    -DiskId $disk.Uuid `
                    -DiskType $vmConfig.DiskType `
                    -IsOSDisk ($disk.IsOSDisk -eq $true) `
                    -ErrorAction Stop
            }
        }

        # If no disks found from discovery data, create a default OS disk mapping
        # This handles cases where disk details aren't fully populated yet
        if ($diskIds.Count -eq 0) {
            Write-Log "  No disk details from discovery -- using default disk configuration."
        }

        # Start replication using the Azure Migrate Server Migration tool
        # This initiates the following sequence:
        # 1. Azure Migrate creates target managed disks in the target RG
        # 2. The Hyper-V replication provider begins copying disk data
        # 3. Initial replication syncs all disk blocks (can take hours for large disks)
        # 4. After initial sync, delta replication begins (every 5-15 minutes)
        Write-Log "  Starting replication for '$($vmConfig.DisplayName)'..."

        $replicationParams = @{
            MachineId              = $machine.Id
            ProjectName            = $MigrateProjectName
            ResourceGroupName      = $SourceResourceGroup
            TargetResourceGroupId  = $targetRg.ResourceId
            TargetNetworkId        = $targetVNet.Id
            TargetSubnetName       = "default"
            TargetVMName           = $vmConfig.DisplayName
            TargetVMSize           = $vmConfig.TargetVMSize
            LicenseType            = $vmConfig.LicenseType
            OSDiskID               = if ($diskIds.Count -gt 0) { ($diskIds | Where-Object { $_.IsOSDisk }).DiskId } else { $null }
            ErrorAction            = "Stop"
        }

        # Add disk mappings if available
        if ($diskIds.Count -gt 0) {
            $replicationParams["DiskToInclude"] = $diskIds
        }

        $replication = New-AzMigrateServerReplication @replicationParams

        Write-Log "  Replication initiated for '$($vmConfig.DisplayName)'."
        Write-Host "  Initial replication state: $($replication.MigrationState)" -ForegroundColor Green

        $replicationResults += @{
            VMName = $vmConfig.DisplayName
            Status = "Initiated"
            Reason = $replication.MigrationState
        }

    } catch {
        Write-Host "  ERROR: Failed to configure replication for '$($vmConfig.DisplayName)'" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  MANUAL ALTERNATIVE:" -ForegroundColor Yellow
        Write-Host "  1. Go to Azure portal > Azure Migrate > $MigrateProjectName" -ForegroundColor White
        Write-Host "  2. Under 'Migration tools', click 'Replicate'" -ForegroundColor White
        Write-Host "  3. Virtualization type: Hyper-V" -ForegroundColor White
        Write-Host "  4. Select '$($vmConfig.DisplayName)'" -ForegroundColor White
        Write-Host "  5. Target settings:" -ForegroundColor White
        Write-Host "     - Resource group: $TargetResourceGroup" -ForegroundColor White
        Write-Host "     - VNet: $targetVNetName" -ForegroundColor White
        Write-Host "     - VM size: $($vmConfig.TargetVMSize)" -ForegroundColor White
        Write-Host ""

        $replicationResults += @{
            VMName = $vmConfig.DisplayName
            Status = "Failed"
            Reason = $_.Exception.Message
        }
    }
}

# Display replication configuration summary
Write-Host ""
Write-Host "  Replication Configuration Summary:" -ForegroundColor White
Write-Host "  ===================================" -ForegroundColor White
Write-Host ""
Write-Host "  VM Name              Status              Details" -ForegroundColor Gray
Write-Host "  -------              ------              -------" -ForegroundColor Gray
foreach ($result in $replicationResults) {
    $statusColor = switch ($result.Status) {
        "Initiated"         { "Green" }
        "AlreadyConfigured" { "Cyan" }
        "Skipped"           { "Yellow" }
        "Failed"            { "Red" }
        default             { "Gray" }
    }
    $vmNamePadded = $result.VMName.PadRight(20)
    $statusPadded = $result.Status.PadRight(18)
    Write-Host "  $vmNamePadded  $statusPadded  $($result.Reason)" -ForegroundColor $statusColor
}

Read-Host "Press Enter to continue to Step 3..."

# ================================================================
# STEP 3: Monitor Replication Progress
# ================================================================
# After initiating replication, the initial full-disk copy begins.
# This is the most time-consuming part of the migration process.
#
# Replication goes through these states:
# 1. InitialSeedingInProgress -- Full disk copy is running
# 2. Replicating              -- Initial sync done, delta sync active
# 3. MigrationInProgress      -- Cutover/migration is executing
# 4. MigrationSucceeded       -- VM is running in Azure
#
# The initial seeding time depends on:
# - Total disk size across all VMs
# - Available upload bandwidth from Hyper-V host to Azure
# - Disk I/O activity on the source VMs
#
# For our workshop VMs (~30-50GB each), expect 30-90 minutes for initial sync.
# We poll every 60 seconds and display progress.

Write-StepHeader -Step 3 -Title "Monitor Replication Progress"

Write-Log "Monitoring replication status for all VMs..."
Write-Log "Initial replication can take 30-90 minutes."
Write-Log "You can also monitor progress in the Azure portal:"
Write-Log "  Azure Migrate > $MigrateProjectName > Replicating machines"
Write-Host ""

$allReplicating = $false
$monitorAttempts = 0
$maxMonitorAttempts = 60  # Monitor for up to 60 minutes
$pollIntervalSeconds = 60

# Allow the user to choose between active monitoring or manual checking
Write-Host "Choose monitoring mode:" -ForegroundColor White
Write-Host "  [1] Active monitoring -- poll every 60 seconds (recommended)" -ForegroundColor Gray
Write-Host "  [2] Skip monitoring -- check status later in the portal" -ForegroundColor Gray
$monitorChoice = Read-Host "Enter choice (1 or 2)"

if ($monitorChoice -eq "1") {
    Write-Host ""
    Write-Log "Starting active monitoring. Press Ctrl+C to stop monitoring at any time."
    Write-Host ""

    while (-not $allReplicating -and $monitorAttempts -lt $maxMonitorAttempts) {
        $monitorAttempts++
        $currentTime = Get-Date -Format "HH:mm:ss"

        try {
            # Get current replication status for all VMs
            $replicatingVMs = Get-AzMigrateServerReplication `
                -ProjectName $MigrateProjectName `
                -ResourceGroupName $SourceResourceGroup `
                -ErrorAction Stop

            if ($replicatingVMs) {
                Write-Host "  [$currentTime] Replication Status `(attempt $monitorAttempts/$maxMonitorAttempts`):" -ForegroundColor White

                $allHealthy = $true
                foreach ($repVM in $replicatingVMs) {
                    $state = $repVM.MigrationState
                    $health = if ($repVM.Health) { $repVM.Health } else { "Unknown" }
                    $progress = if ($repVM.ProviderSpecificDetailInitialReplicationProgressPercentage) {
                        "$($repVM.ProviderSpecificDetailInitialReplicationProgressPercentage)%"
                    } else { "N/A" }

                    $stateColor = switch ($state) {
                        "Replicating"               { "Green" }
                        "InitialSeedingInProgress"  { "Yellow" }
                        "MigrationSucceeded"        { "Cyan" }
                        default                     { "Gray" }
                    }

                    Write-Host "    $($repVM.MachineName.PadRight(22)) State: $($state.PadRight(28)) Progress: $($progress.PadRight(6)) Health: $health" -ForegroundColor $stateColor

                    if ($state -ne "Replicating" -and $state -ne "MigrationSucceeded") {
                        $allHealthy = $false
                    }
                }

                if ($allHealthy) {
                    $allReplicating = $true
                    Write-Host ""
                    Write-Log "All VMs have completed initial replication!"
                }
            } else {
                Write-Host "  [$currentTime] No replicating machines found yet..." -ForegroundColor Yellow
            }

            if (-not $allReplicating) {
                Write-Host "  Waiting $pollIntervalSeconds seconds before next check..." -ForegroundColor DarkGray
                Start-Sleep -Seconds $pollIntervalSeconds
            }

        } catch {
            Write-Host "  [$currentTime] Error checking status: $($_.Exception.Message)" -ForegroundColor Yellow
            Start-Sleep -Seconds $pollIntervalSeconds
        }
    }
} else {
    Write-Log "Skipping active monitoring."
}

Read-Host "Press Enter to continue to Step 4..."

# ================================================================
# STEP 4: Display Final Status and Migration Readiness
# ================================================================
# Once initial replication completes and VMs are in "Replicating" state,
# they are ready for migration. At this point you have two options:
#
# 1. TEST MIGRATION (recommended first):
#    - Creates a test VM in Azure from the replicated data
#    - The source VM keeps running -- no production impact
#    - You can validate the migrated VM works correctly
#    - Clean up the test VM when done
#
# 2. CUTOVER MIGRATION (final step):
#    - Performs a final delta sync to capture latest changes
#    - Shuts down the source VM
#    - Creates the production VM in Azure
#    - This is the actual migration -- the source VM is no longer used
#
# For production migrations, ALWAYS do a test migration first.
# Validate all applications, network connectivity, and integrations
# before performing the final cutover.

Write-StepHeader -Step 4 -Title "Final Status and Migration Readiness"

try {
    $replicatingVMs = Get-AzMigrateServerReplication `
        -ProjectName $MigrateProjectName `
        -ResourceGroupName $SourceResourceGroup `
        -ErrorAction Stop

    if ($replicatingVMs) {
        Write-Host ""
        Write-Host "  Current Replication Status:" -ForegroundColor White
        Write-Host "  ===========================" -ForegroundColor White
        Write-Host ""

        $readyForMigration = 0
        $totalVMs = @($replicatingVMs).Count

        foreach ($repVM in $replicatingVMs) {
            $state = $repVM.MigrationState
            $isReady = ($state -eq "Replicating")

            if ($isReady) { $readyForMigration++ }

            $statusIcon = if ($isReady) { "[READY]" } else { "[PENDING]" }
            $statusColor = if ($isReady) { "Green" } else { "Yellow" }

            Write-Host "  $statusIcon $($repVM.MachineName)" -ForegroundColor $statusColor
            Write-Host "           State    : $state" -ForegroundColor Gray
            Write-Host "           Target VM: $($repVM.TargetVMName)" -ForegroundColor Gray
            Write-Host "           Target RG: $TargetResourceGroup" -ForegroundColor Gray
            Write-Host ""
        }

        Write-Host "  Summary: $readyForMigration/$totalVMs VMs ready for migration" -ForegroundColor White
        Write-Host ""

        if ($readyForMigration -eq $totalVMs) {
            Write-Host "  ALL VMs are ready for migration!" -ForegroundColor Green
            Write-Host ""
            Write-Host "  Estimated monthly costs in Azure (approximate):" -ForegroundColor White
            Write-Host "  -----------------------------------------------" -ForegroundColor Gray
            Write-Host "  OnPrem-Web       (Standard_B2s)  : ~`$30/month" -ForegroundColor Gray
            Write-Host "  OnPrem-SQL       (Standard_B2ms) : ~`$60/month" -ForegroundColor Gray
            Write-Host "  OnPrem-Linux-Web (Standard_B1ms) : ~`$15/month" -ForegroundColor Gray
            Write-Host "  OnPrem-Linux-App (Standard_B1ms) : ~`$15/month" -ForegroundColor Gray
            Write-Host "  -----------------------------------------------" -ForegroundColor Gray
            Write-Host "  Total (Pay-As-You-Go)            : ~`$120/month" -ForegroundColor White
            Write-Host "  With Azure Hybrid Benefit (Win)   : ~`$75/month" -ForegroundColor Green
            Write-Host ""
        }
    } else {
        Write-Host "  No replicating machines found." -ForegroundColor Yellow
        Write-Host "  Check the Azure portal for replication status." -ForegroundColor Yellow
    }

} catch {
    Write-Host "  Could not retrieve final replication status." -ForegroundColor Yellow
    Write-Host "  Check the Azure portal:" -ForegroundColor Yellow
    Write-Host "  Azure Migrate > $MigrateProjectName > Replicating machines" -ForegroundColor White
    Write-Warning "Error: $_"
}

# ================================================================
# SUMMARY & NEXT STEPS
# ================================================================

Write-Section "STEP 3 COMPLETE -- Summary"

Write-Host "  What was accomplished:" -ForegroundColor White
Write-Host "  [+] Discovered machines retrieved from Azure Migrate" -ForegroundColor Green
Write-Host "  [+] Replication configured for all VMs:" -ForegroundColor Green
Write-Host "       - OnPrem-Web       -> Standard_B2s  (Windows + IIS)" -ForegroundColor Cyan
Write-Host "       - OnPrem-SQL       -> Standard_B2ms (Windows + SQL Server)" -ForegroundColor Cyan
Write-Host "       - OnPrem-Linux-Web -> Standard_B1ms (Ubuntu + Nginx)" -ForegroundColor Cyan
Write-Host "       - OnPrem-Linux-App -> Standard_B1ms (Ubuntu + Node.js)" -ForegroundColor Cyan
Write-Host "  [+] Replication initiated -- disk data syncing to Azure" -ForegroundColor Green
Write-Host "  [+] Replication progress monitored" -ForegroundColor Green
Write-Host ""
Write-Host "  Target Landing Zone:" -ForegroundColor White
Write-Host "  Resource Group : $TargetResourceGroup" -ForegroundColor Cyan
Write-Host "  VNet           : $targetVNetName `(10.1.0.0/16`)" -ForegroundColor Cyan
Write-Host "  Subnet         : default (10.1.0.0/24)" -ForegroundColor Cyan

Write-NextSteps @(
    "OPTION A: Test Migration (recommended)"
    "  In Azure portal > Azure Migrate > Replicating machines"
    "  Select a VM > click 'Test migration'"
    "  Choose the target VNet and validate the VM works correctly"
    "  Clean up test migration when done"
    ""
    "OPTION B: Cutover Migration"
    "  In Azure portal > Azure Migrate > Replicating machines"
    "  Select a VM > click 'Migrate'"
    "  Choose 'Yes' to shut down the source VM before migration"
    "  Wait for migration to complete"
    ""
    "POST-MIGRATION CHECKLIST:"
    "  [ ] Verify each VM is running in the target resource group"
    "  [ ] Test application connectivity (IIS, SQL, Nginx, Node.js)"
    "  [ ] Assign public IPs if external access is needed"
    "  [ ] Configure Azure Backup for migrated VMs"
    "  [ ] Enable Microsoft Defender for Cloud"
    "  [ ] Set up Azure Monitor alerts"
    "  [ ] Update DNS records to point to new Azure IPs"
    "  [ ] Clean up: delete replication and decommission source VMs"
)

Write-Log "Step 3 finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
Write-Log "Congratulations on completing the Azure Migrate Workshop migration steps!"
