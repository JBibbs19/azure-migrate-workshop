<#
.SYNOPSIS
    Step 1: Create Azure Migrate project and prepare the target landing zone.

.DESCRIPTION
    This script sets up the Azure Migrate project and creates the target
    resource group (rg-ces-target-01) with networking infrastructure for migrated VMs.

    Run this script ONCE before starting discovery.

    What this script does:
    1. Registers required Azure resource providers
    2. Creates the target resource group (landing zone)
    3. Creates a target VNet and subnet for migrated VMs
    4. Creates a Network Security Group with appropriate rules
    5. Creates an Azure Migrate project
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
    Azure region for all resources. Prompted when not supplied (example: eastus).

.PARAMETER MigrateProjectName
    Name for the Azure Migrate project. Prompted when not supplied (example: ces-migrate-01).

.EXAMPLE
    .\migrate-step1-setup-project.ps1

.EXAMPLE
    .\migrate-step1-setup-project.ps1 -TargetResourceGroup "mycloud-rg" -Location "westus2"
#>

[CmdletBinding()]
param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [string]$Location,

    [string]$MigrateProjectName
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

$context = Get-LabAzContext -RequiredModules @('Az.Accounts', 'Az.Resources', 'Az.Network') -OptionalModules @('Az.Migrate')

Write-Host ""
Write-Host "Enter the values for your lab environment. A value in [brackets] is a lab default and Enter accepts it; an (example: ...) is a hint only and must be typed." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabResourceGroupName -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Prompt 'Source resource group (contains the Hyper-V host)' -Example 'rg-ces-source-01' -MissingHelp 'It is created by deploy-lab.ps1.'
$TargetResourceGroup = Read-LabResourceGroupName -Name 'TargetResourceGroup' -Value $TargetResourceGroup -Prompt 'Target resource group to use as the landing zone' -Example 'rg-ces-target-01' -AllowNew
$Location = Resolve-LabLocation -Value $Location -ResourceGroupName $SourceResourceGroup
$MigrateProjectName = Select-LabFromList -Name 'MigrateProjectName' -Value $MigrateProjectName -Options (Get-LabMigrateProjectNames -ResourceGroupName $SourceResourceGroup) -Kind ProjectName -AllowNew -NewLabel 'Create a new Azure Migrate project -- you name it' -Prompt 'Azure Migrate project to create or reuse' -Example 'ces-migrate-01'


# Confirm this step's resources exist in the signed-in subscription before changing anything.
Assert-LabResources -SourceResourceGroup $SourceResourceGroup

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
# Configuration
# ================================================================

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
Write-Log "Location              : $Location"
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
Write-Log "Source resource group found in '$($sourceRg.Location)'."

Read-Host "Pre-flight checks passed. Press Enter to continue..."

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

Read-Host "Press Enter to continue to Step 2..."

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

Read-Host "Press Enter to continue to Step 3..."

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

Read-Host "Press Enter to continue to Step 4..."

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
# - Allow Node.js (3000) inbound: For the Node.js app server
#
# IMPORTANT: In production, you would NOT allow RDP/SSH from the internet.
# You would use Azure Bastion, Just-In-Time VM Access, or a VPN gateway.
# These rules are intentionally permissive for workshop convenience.

Write-StepHeader -Step 4 -Title "Create Network Security Group (NSG)"

try {
    $existingNsg = Get-AzNetworkSecurityGroup -Name $targetNsgName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue
    if ($existingNsg) {
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

        # Rule: Allow Node.js port -- OnPrem-Linux-App runs on port 3000
        $rules += New-AzNetworkSecurityRuleConfig `
            -Name "Allow-NodeJS" `
            -Description "Allow port 3000 for Node.js app server" `
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
        Write-Host "  140       Allow-NodeJS   3000   Node.js app server" -ForegroundColor Gray
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

Read-Host "Press Enter to continue to Step 5..."

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

try {
    # Check if the Az.Migrate module is available
    $migrateModule = Get-Module -ListAvailable -Name Az.Migrate
    if (-not $migrateModule) {
        Write-Log "Az.Migrate module not found. Installing..."
        Install-Module -Name Az.Migrate -Force -AllowClobber -Scope CurrentUser
        Import-Module Az.Migrate
        Write-Log "Az.Migrate module installed and imported."
    } else {
        Import-Module Az.Migrate -ErrorAction SilentlyContinue
        Write-Log "Az.Migrate module is available `(version: $($migrateModule.Version)`)."
    }

    # Create the Azure Migrate project
    # We place it in the SOURCE resource group because it's a management tool
    # that needs to observe and interact with the source environment.
    # Azure Migrate projects must be in specific regions -- map common regions
    # to supported Migrate project locations. See error message for full list.
    $migrateLocationMap = @{
        "eastus" = "centralus"; "eastus2" = "centralus"; "westus" = "westus2";
        "westus3" = "westus2"; "centralus" = "centralus"; "northcentralus" = "centralus";
        "southcentralus" = "centralus"; "westcentralus" = "centralus";
        "northeurope" = "northeurope"; "westeurope" = "westeurope";
        "uksouth" = "uksouth"; "ukwest" = "ukwest";
        "australiaeast" = "australiaeast"; "australiasoutheast" = "australiasoutheast";
        "southeastasia" = "southeastasia"; "eastasia" = "eastasia";
        "japaneast" = "japaneast"; "japanwest" = "japanwest";
        "canadacentral" = "canadacentral"; "centralindia" = "centralindia";
        "koreacentral" = "koreacentral"; "brazilsouth" = "brazilsouth";
        "francecentral" = "francecentral"; "germanywestcentral" = "germanywestcentral";
        "norwayeast" = "norwayeast"; "swedencentral" = "swedencentral";
        "switzerlandnorth" = "switzerlandnorth"; "uaenorth" = "uaenorth"
    }
    $migrateLocation = if ($migrateLocationMap.ContainsKey($Location)) { $migrateLocationMap[$Location] } else { "centralus" }
    Write-Log "Creating Azure Migrate project '$MigrateProjectName'..."
    Write-Log "  Resource Group: $SourceResourceGroup"
    Write-Log "  Migrate Location: $migrateLocation (mapped from deployment region '$Location')"

    $existingProject = Get-AzMigrateProject -Name $MigrateProjectName -ResourceGroupName $SourceResourceGroup -ErrorAction SilentlyContinue
    if ($existingProject) {
        Write-Log "Azure Migrate project '$MigrateProjectName' already exists."
        $migrateProject = $existingProject
    } else {
        $migrateProject = New-AzMigrateProject `
            -Name $MigrateProjectName `
            -ResourceGroupName $SourceResourceGroup `
            -Location $migrateLocation `
            -ErrorAction Stop

        Write-Log "Azure Migrate project created successfully."
    }

    # Display project details
    Write-Host ""
    Write-Host "  Azure Migrate Project Details:" -ForegroundColor White
    Write-Host "  Name          : $MigrateProjectName" -ForegroundColor Gray
    Write-Host "  Resource Group: $SourceResourceGroup" -ForegroundColor Gray
    Write-Host "  Location      : $migrateLocation" -ForegroundColor Gray

} catch {
    Write-Host ""
    Write-Host "WARNING: Could not create Azure Migrate project via PowerShell." -ForegroundColor Yellow
    Write-Host "This can happen if the Az.Migrate module version doesn't support New-AzMigrateProject." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "MANUAL ALTERNATIVE:" -ForegroundColor Yellow
    Write-Host "  1. Go to https://portal.azure.com" -ForegroundColor White
    Write-Host "  2. Search for 'Azure Migrate'" -ForegroundColor White
    Write-Host "  3. Click 'Create project'" -ForegroundColor White
    Write-Host "  4. Resource group: $SourceResourceGroup" -ForegroundColor White
    Write-Host "  5. Project name: $MigrateProjectName" -ForegroundColor White
    Write-Host "  6. Geography: United States (or matching your region)" -ForegroundColor White
    Write-Host ""
    Write-Warning "Error details: $_"
}

# ================================================================
# SUMMARY & NEXT STEPS
# ================================================================

Write-Section "STEP 1 COMPLETE -- Summary"

Write-Host "  Resources Created:" -ForegroundColor White
Write-Host "  [+] Resource Group    : $TargetResourceGroup `($Location`)" -ForegroundColor Green
Write-Host "  [+] Virtual Network   : $targetVNetName `($targetAddressPrefix`)" -ForegroundColor Green
Write-Host "  [+] Subnet            : $targetSubnetName `($targetSubnetPrefix`)" -ForegroundColor Green
Write-Host "  [+] NSG               : $targetNsgName `(5 inbound rules`)" -ForegroundColor Green
Write-Host "  [+] Migrate Project   : $MigrateProjectName `(in $SourceResourceGroup`)" -ForegroundColor Green
Write-Host ""
Write-Host "  Source Environment (already deployed):" -ForegroundColor White
Write-Host "  [i] Resource Group    : $SourceResourceGroup" -ForegroundColor Cyan
Write-Host "  [i] Hyper-V Host      : HyperVHost" -ForegroundColor Cyan
Write-Host "  [i] Guest VMs         : OnPrem-Web, OnPrem-SQL, OnPrem-Linux-Web, OnPrem-Linux-App" -ForegroundColor Cyan

Write-NextSteps @(
    "Run Step 2: .\migrate-step2-discover-assess.ps1"
    "Step 2 will deploy the Azure Migrate appliance on the Hyper-V host"
    "The appliance will discover all 4 on-premises VMs"
    "You will then create an assessment to evaluate migration readiness"
)

Write-Log "Step 1 finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')."
