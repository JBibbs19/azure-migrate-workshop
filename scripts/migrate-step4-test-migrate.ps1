<#
.SYNOPSIS
    Step 4: Perform test migration to validate before cutover.

.DESCRIPTION
    Runs a test migration for each VM into an isolated test VNet.
    This validates that the VMs will work correctly in Azure
    WITHOUT affecting the source VMs or production network.

    TEST MIGRATION IS NON-NEGOTIABLE in real-world migrations.
    It's your safety net before committing to cutover.

    After validation, the test resources are cleaned up.

    VMs being tested:
      - OnPrem-Web       (Windows Server + IIS)
      - OnPrem-SQL       (Windows Server + SQL Server Express)
      - OnPrem-Linux-Web (Ubuntu + Nginx)
      - OnPrem-Linux-App (Ubuntu + Node.js API)

    Prerequisites:
      - Steps 1-3 completed (Azure Migrate project exists, VMs discovered, replication enabled)
      - Replication is in a healthy "Protected" state for all VMs
      - Az PowerShell modules installed (Az.Migrate, Az.Network, Az.Compute)

.PARAMETER SourceResourceGroup
    Resource group containing the Hyper-V host and on-prem VMs.

.PARAMETER TargetResourceGroup
    Resource group where migrated VMs will land.

.PARAMETER MigrateProjectName
    Name of the Azure Migrate project.

.PARAMETER Location
    Azure region for test resources. Prompted when not supplied (example: eastus).

.PARAMETER TestVNetName
    Name of the isolated test virtual network.

.PARAMETER TestVNetAddressSpace
    Address space for the test VNet (must not overlap with production).

.EXAMPLE
    .\migrate-step4-test-migrate.ps1

.EXAMPLE
    .\migrate-step4-test-migrate.ps1 -TargetResourceGroup "mycloud-rg" -MigrateProjectName "my-migrate"
MODULE COVERAGE
    The scripts and the modules are run separately. What this completes depends on -Workload:

      -Workload Agentless   Module 2, section 8 (Test Migration), including the cleanup in 8.6.
      -Workload AgentBased  Module 3, section 10 (Test Migration), including the cleanup in 10.5.
      -Workload All         Both, in one pass. The default.

    The in-guest validation in those sections - browsing the IIS site, querying SQL, calling the
    Node.js API on the test VM - is not performed. The script confirms the test VMs exist and
    reach a healthy state; whether the application works is yours to check.
#>

[CmdletBinding()]
param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [string]$MigrateProjectName,

    [string]$Location,

    [string]$TestVNetName,

    [string]$TestVNetAddressSpace,

    [string]$TestSubnetPrefix,

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
$MigrateProjectName = Select-LabFromList -Name 'MigrateProjectName' -Value $MigrateProjectName -Options (Get-LabMigrateProjectNames -ResourceGroupName $SourceResourceGroup) -Kind ProjectName -Prompt 'Azure Migrate project' -EmptyHelp 'Run migrate-step1-setup-project.ps1 first, or create the project in the portal (Module 1 section 1).'
$Location = Resolve-LabLocation -Value $Location -ResourceGroupName $TargetResourceGroup
$TestVNetName = Read-LabParameter -Name 'TestVNetName' -Value $TestVNetName -Kind VMName -Prompt 'Isolated test VNet name' -Example 'test-migrate-vnet'
$TestVNetAddressSpace = Read-LabParameter -Name 'TestVNetAddressSpace' -Value $TestVNetAddressSpace -Kind Cidr -Prompt 'Test VNet address space (must not overlap 10.0.0.0/16 or 10.1.0.0/16)' -Example '10.2.0.0/16'
$TestSubnetPrefix = Read-LabParameter -Name 'TestSubnetPrefix' -Value $TestSubnetPrefix -Kind Cidr -Prompt 'Test subnet prefix (inside the test VNet)' -Example '10.2.0.0/24'
$Workload = Select-LabFromList -Name 'Workload' -Value $Workload -Options @('All', 'Agentless', 'AgentBased') -Kind Workload -Prompt 'Workload group (All = four VMs; Agentless = the Module 2 pair; AgentBased = the Module 3 pair)'
if (-not (Test-LabCidrContains -Outer $TestVNetAddressSpace -Inner $TestSubnetPrefix)) {
    throw "Test subnet $TestSubnetPrefix is not inside the test VNet address space $TestVNetAddressSpace. Rerun and enter a subnet within the VNet."
}


# Confirm this step's resources exist in the signed-in subscription before changing anything.
Assert-LabResources -SourceResourceGroup $SourceResourceGroup -TargetResourceGroup $TargetResourceGroup -MigrateProjectName $MigrateProjectName

# ================================================================
# Helper Functions
# ================================================================

function Write-SectionHeader {
    # Prints a visually distinct section banner so participants can easily
    # identify where they are in the script.
    param(
        [string]$SectionNumber,
        [string]$Title
    )
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "  SECTION $SectionNumber`: $Title" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
}

function Write-StepInfo {
    # Prints a timestamped informational message to help participants
    # follow along and troubleshoot timing issues.
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Write-WarningBanner {
    # Draws attention to critical warnings the participant should read.
    param([string]$Message)
    Write-Host "`n⚠️  $Message" -ForegroundColor Yellow
}

function Wait-ForSection {
    # Pauses execution between sections so participants can review output,
    # take notes, or verify results before proceeding.
    param([string]$NextSection = "the next section")
    Write-Host ""
    Read-Host "Press Enter to continue to $NextSection..."
    Write-Host ""
}

# The VM names must match what was discovered by Azure Migrate.
# These are the guest VMs inside the Hyper-V host.
$vmNames = @("OnPrem-Web", "OnPrem-SQL", "OnPrem-Linux-Web", "OnPrem-Linux-App")

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
    $vmNames = @($vmNames | Where-Object { $selected -contains $_ })
    Write-Host "Workload filter: $Workload -> $($selected -join ', ')" -ForegroundColor Cyan
}

# ================================================================
# SECTION 0: Prerequisites Check
# ================================================================
Write-SectionHeader "0" "Prerequisites Check"

Write-StepInfo "Verifying Az PowerShell modules are available..."

# We need Az.Migrate for migration cmdlets, Az.Network for VNet creation,
# and Az.Compute for VM validation after test migration.
$requiredModules = @("Az.Migrate", "Az.Network", "Az.Compute")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        throw "Required module '$mod' is not installed. Run: Install-Module -Name $mod -Scope CurrentUser -Force"
    }
    Write-StepInfo "  ✅ Module '$mod' found."
}

# Verify we have an active Azure session -- all subsequent commands need this.
try {
    $context = Get-AzContext
    if (-not $context) { throw "No Azure context found." }
    Write-StepInfo "Logged in to subscription: $(Format-LabSubscriptionId $context.Subscription.Id)"
} catch {
    throw "Azure authentication required. Run 'Connect-AzAccount' first. Error: $_"
}

# Verify the target resource group exists -- if it doesn't, test migration
# will fail with a confusing error message.
Write-StepInfo "Checking target resource group '$TargetResourceGroup' exists..."
$targetRg = Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction SilentlyContinue
if (-not $targetRg) {
    throw "Target resource group '$TargetResourceGroup' does not exist. Create it first or check the name."
}
Write-StepInfo "  ✅ Target resource group found in '$($targetRg.Location)'."

# Verify the Azure Migrate project exists and retrieve replicating servers.
# This confirms that Steps 1-3 were completed successfully.
Write-StepInfo "Retrieving replicating servers from Azure Migrate project '$MigrateProjectName'..."
try {
    $replicatingServers = Get-AzMigrateServerReplication -ResourceGroupName $TargetResourceGroup `
                          -ProjectName $MigrateProjectName
    Write-StepInfo "  Found $($replicatingServers.Count) replicating server`(s`)."

    # Check that ALL 4 expected VMs are replicating. If any are missing,
    # the participant needs to go back and enable replication for them.
    foreach ($vmName in $vmNames) {
        $server = $replicatingServers | Where-Object { $_.MachineName -eq $vmName }
        if (-not $server) {
            Write-WarningBanner "VM '$vmName' is not found among replicating servers. Replication may not be enabled for it."
        } else {
            Write-StepInfo "  ✅ '$vmName' -- Status: $($server.MigrationState)"
        }
    }
} catch {
    Write-WarningBanner "Could not retrieve replicating servers: $_"
    Write-WarningBanner "Ensure Steps 1-3 are completed. Continuing anyway for demonstration..."
}

Write-StepInfo "Prerequisites check complete."
Wait-ForSection "Section 1: Create Test VNet"


# ================================================================
# SECTION 1: Create Test VNet
# ================================================================
Write-SectionHeader "1" "Create Test VNet"

# We create an ISOLATED virtual network for test migration.
# This is crucial -- test VMs must not interfere with production networking
# or with the source VMs still running on-prem. Using a separate address
# space (10.2.0.0/16) avoids IP conflicts with the target VNet (10.1.0.0/16).
Write-StepInfo "Creating isolated test VNet '$TestVNetName' with address space $TestVNetAddressSpace..."

try {
    # Check if the test VNet already exists (from a previous run, perhaps).
    $existingVNet = Get-AzVirtualNetwork -Name $TestVNetName -ResourceGroupName $TargetResourceGroup -ErrorAction SilentlyContinue

    if ($existingVNet) {
        Write-StepInfo "  Test VNet '$TestVNetName' already exists. Reusing it."
        $testVNet = $existingVNet
    } else {
        # Create a subnet config first -- Azure VNets need at least one subnet.
        $subnetConfig = New-AzVirtualNetworkSubnetConfig `
            -Name "test-subnet" `
            -AddressPrefix $TestSubnetPrefix

        # Create the VNet in the target resource group.
        # We place it in the same region as the target RG for low latency.
        $testVNet = New-AzVirtualNetwork `
            -Name $TestVNetName `
            -ResourceGroupName $TargetResourceGroup `
            -Location $Location `
            -AddressPrefix $TestVNetAddressSpace `
            -Subnet $subnetConfig

        Write-StepInfo "  ✅ Test VNet created successfully."
    }

    # Display VNet details so the participant can verify.
    Write-StepInfo "  VNet Name     : $($testVNet.Name)"
    Write-StepInfo "  Address Space : $($testVNet.AddressSpace.AddressPrefixes -join ', ')"
    Write-StepInfo "  Subnet        : $($testVNet.Subnets[0].Name) `($($testVNet.Subnets[0].AddressPrefix)`)"
    Write-StepInfo "  Resource Group: $TargetResourceGroup"
} catch {
    Write-Host "❌ Failed to create test VNet: $_" -ForegroundColor Red
    throw "Cannot proceed without a test VNet. Fix the error above and re-run."
}

Wait-ForSection "Section 2: Initiate Test Migration"


# ================================================================
# SECTION 2: Initiate Test Migration
# ================================================================
Write-SectionHeader "2" "Initiate Test Migration"

# Test migration creates Azure VMs from the replicated data WITHOUT
# affecting the source VMs. Think of it as a "dress rehearsal" for cutover.
# Each VM is provisioned in the isolated test VNet we just created.
Write-StepInfo "Starting test migration for all VMs..."
Write-WarningBanner "This process can take 15-45 minutes per VM depending on disk size."

# We'll store test migration jobs so we can track their progress.
$testMigrationJobs = @{}

foreach ($vmName in $vmNames) {
    Write-StepInfo "Initiating test migration for '$vmName'..."

    try {
        # Find the replicating server object for this VM.
        # Azure Migrate tracks each VM as a "replicating server" with its own state machine.
        $server = $replicatingServers | Where-Object { $_.MachineName -eq $vmName }

        if (-not $server) {
            Write-WarningBanner "Skipping '$vmName' -- not found in replicating servers."
            continue
        }

        # Start-AzMigrateTestMigration kicks off the test failover.
        # The -TestNetworkID tells Azure which VNet to place the test VM into.
        # We use our isolated test VNet to prevent any production impact.
        $testJob = Start-AzMigrateTestMigration `
            -InputObject $server `
            -TestNetworkID $testVNet.Id

        Write-StepInfo "  ✅ Test migration initiated for '$vmName'. Job ID: $($testJob.Name)"
        $testMigrationJobs[$vmName] = $testJob

    } catch {
        Write-Host "  ❌ Failed to start test migration for '$vmName': $_" -ForegroundColor Red
        Write-WarningBanner "Continuing with remaining VMs..."
    }
}

Write-StepInfo "All test migration requests submitted."
Wait-ForSection "Section 3: Wait for Test VMs"


# ================================================================
# SECTION 3: Wait for Test VMs to be Created
# ================================================================
Write-SectionHeader "3" "Wait for Test VMs to be Created"

# Test migration is an asynchronous operation. We need to poll until
# each VM's migration state transitions to "TestMigrationSucceeded".
# This is similar to waiting for a deployment -- Azure is provisioning
# disks, networking, and the VM itself behind the scenes.
Write-StepInfo "Polling migration status every 60 seconds..."
Write-StepInfo "This typically takes 15-45 minutes. Please be patient."

$maxWaitMinutes = 60          # Maximum time to wait before giving up
$pollIntervalSeconds = 60     # How often to check status
$startTime = Get-Date

# Track which VMs have completed test migration.
$completedVMs = @{}

while ($completedVMs.Count -lt $testMigrationJobs.Count) {
    # Safety check: don't wait forever if something is stuck.
    $elapsed = (Get-Date) - $startTime
    if ($elapsed.TotalMinutes -gt $maxWaitMinutes) {
        Write-WarningBanner "Maximum wait time `($maxWaitMinutes minutes`) exceeded. Some VMs may not have completed."
        break
    }

    foreach ($vmName in $testMigrationJobs.Keys) {
        # Skip VMs that already completed -- no need to re-check them.
        if ($completedVMs.ContainsKey($vmName)) { continue }

        try {
            # Re-fetch the replicating server to get updated status.
            # The MigrationState property tells us where the VM is in the test migration lifecycle.
            $server = Get-AzMigrateServerReplication -ResourceGroupName $TargetResourceGroup `
                      -ProjectName $MigrateProjectName |
                      Where-Object { $_.MachineName -eq $vmName }

            $state = $server.TestMigrateState

            if ($state -eq "TestMigrationSucceeded") {
                # Test migration completed successfully -- the test VM is now running in Azure.
                Write-StepInfo "  ✅ '$vmName' -- Test migration SUCCEEDED."
                $completedVMs[$vmName] = $true
            } elseif ($state -eq "TestMigrationFailed") {
                # Something went wrong during provisioning. Check Azure Migrate for details.
                Write-Host "  ❌ '$vmName' -- Test migration FAILED." -ForegroundColor Red
                $completedVMs[$vmName] = $false
            } else {
                # Still in progress -- show current state so participant knows it's working.
                Write-StepInfo "  ⏳ '$vmName' -- State: $state `(waiting...`)"
            }
        } catch {
            Write-WarningBanner "Error checking status for '$vmName': $_"
        }
    }

    # Only sleep if there are still VMs pending -- avoid unnecessary delay at the end.
    if ($completedVMs.Count -lt $testMigrationJobs.Count) {
        $remaining = $testMigrationJobs.Count - $completedVMs.Count
        Write-StepInfo "  $remaining VM`(s`) still in progress. Waiting $pollIntervalSeconds seconds..."
        Start-Sleep -Seconds $pollIntervalSeconds
    }
}

# Print a summary of test migration results.
Write-Host "`n--- Test Migration Results ---" -ForegroundColor White
foreach ($vmName in $testMigrationJobs.Keys) {
    $result = if ($completedVMs[$vmName] -eq $true) { "✅ SUCCEEDED" } else { "❌ FAILED/UNKNOWN" }
    Write-Host "  $vmName : $result"
}

Wait-ForSection "Section 4: Validate Test VMs"


# ================================================================
# SECTION 4: Validate Test VMs
# ================================================================
Write-SectionHeader "4" "Validate Test VMs"

# Now that test VMs are running in Azure, we validate that the workloads
# are functional. This is THE WHOLE POINT of test migration -- catching
# issues here saves you from a failed cutover in production.
Write-StepInfo "Validating test VMs..."

# We'll collect validation results so we can print a summary at the end.
$validationResults = @{}

foreach ($vmName in $vmNames) {
    Write-Host "`n--- Validating: $vmName ---" -ForegroundColor White

    try {
        # The test VM is created with a "test-" prefix in the target resource group.
        # Azure Migrate appends "-test" to the VM name by convention.
        $testVmName = "$vmName-test"

        # Try to find the test VM. The naming convention may vary,
        # so we also check without the "-test" suffix.
        $testVm = Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $testVmName -ErrorAction SilentlyContinue
        if (-not $testVm) {
            $testVm = Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $vmName -ErrorAction SilentlyContinue
        }

        if (-not $testVm) {
            Write-WarningBanner "Test VM not found for '$vmName'. Skipping validation."
            $validationResults[$vmName] = "VM NOT FOUND"
            continue
        }

        # CHECK 1: Is the VM running?
        # A VM that exists but isn't running indicates a boot or driver issue.
        $vmStatus = Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $testVm.Name -Status
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus

        if ($powerState -eq "VM running") {
            Write-StepInfo "  ✅ VM is running."
        } else {
            Write-Host "  ❌ VM power state: $powerState" -ForegroundColor Red
            $validationResults[$vmName] = "NOT RUNNING `($powerState`)"
            continue
        }

        # Get the VM's private IP for connectivity tests.
        # Test VMs are on the isolated test VNet, so they may not have public IPs.
        $nic = Get-AzNetworkInterface -ResourceGroupName $TargetResourceGroup |
               Where-Object { $_.VirtualMachine.Id -eq $testVm.Id }
        $privateIp = $nic.IpConfigurations[0].PrivateIpAddress
        Write-StepInfo "  Private IP: $privateIp"

        # Check for a public IP (if one was assigned to the test VM).
        $publicIpId = $nic.IpConfigurations[0].PublicIpAddress.Id
        $publicIp = $null
        if ($publicIpId) {
            $pipResource = Get-AzPublicIpAddress | Where-Object { $_.Id -eq $publicIpId }
            $publicIp = $pipResource.IpAddress
            Write-StepInfo "  Public IP : $publicIp"
        }

        # Use either public IP (if available) or private IP for tests.
        $testIp = if ($publicIp -and $publicIp -ne "Not Assigned") { $publicIp } else { $privateIp }

        # CHECK 2: Workload-specific validation.
        # Each VM has a different workload, so we test accordingly.
        switch -Wildcard ($vmName) {
            "OnPrem-Web" {
                # IIS web server should respond with HTTP 200 on port 80.
                Write-StepInfo "  Testing IIS HTTP response on port 80..."
                try {
                    $response = Invoke-WebRequest -Uri "http://$testIp" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        Write-StepInfo "  ✅ IIS returned HTTP 200."
                        $validationResults[$vmName] = "PASSED"
                    } else {
                        Write-WarningBanner "  IIS returned HTTP $($response.StatusCode)."
                        $validationResults[$vmName] = "HTTP $($response.StatusCode)"
                    }
                } catch {
                    Write-WarningBanner "  HTTP test failed: $_"
                    Write-StepInfo "  (This may be expected if NSG blocks test VNet traffic.)"
                    $validationResults[$vmName] = "HTTP UNREACHABLE (may be NSG)"
                }
            }

            "OnPrem-SQL" {
                # SQL Server Express listens on port 1433.
                # We test TCP connectivity -- a full SQL query would require credentials.
                Write-StepInfo "  Testing SQL Server TCP connectivity on port 1433..."
                try {
                    $tcpTest = Test-NetConnection -ComputerName $testIp -Port 1433 -WarningAction SilentlyContinue
                    if ($tcpTest.TcpTestSucceeded) {
                        Write-StepInfo "  ✅ SQL Server port 1433 is reachable."
                        $validationResults[$vmName] = "PASSED"
                    } else {
                        Write-WarningBanner "  Port 1433 is NOT reachable."
                        $validationResults[$vmName] = "PORT 1433 CLOSED"
                    }
                } catch {
                    Write-WarningBanner "  TCP test failed: $_"
                    $validationResults[$vmName] = "TCP TEST FAILED"
                }
            }

            "OnPrem-Linux-Web" {
                # Nginx web server should respond with HTTP 200 on port 80.
                Write-StepInfo "  Testing Nginx HTTP response on port 80..."
                try {
                    $response = Invoke-WebRequest -Uri "http://$testIp" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        Write-StepInfo "  ✅ Nginx returned HTTP 200."
                        $validationResults[$vmName] = "PASSED"
                    } else {
                        Write-WarningBanner "  Nginx returned HTTP $($response.StatusCode)."
                        $validationResults[$vmName] = "HTTP $($response.StatusCode)"
                    }
                } catch {
                    Write-WarningBanner "  HTTP test failed: $_"
                    $validationResults[$vmName] = "HTTP UNREACHABLE (may be NSG)"
                }
            }

            "OnPrem-Linux-App" {
                # Node.js Express API should respond on port 3000 at /api/health.
                Write-StepInfo "  Testing Node.js API health endpoint on port 3000..."
                try {
                    $response = Invoke-WebRequest -Uri "http://${testIp}:3000/api/health" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        Write-StepInfo "  ✅ Node.js API returned HTTP 200."
                        $validationResults[$vmName] = "PASSED"
                    } else {
                        Write-WarningBanner "  API returned HTTP $($response.StatusCode)."
                        $validationResults[$vmName] = "HTTP $($response.StatusCode)"
                    }
                } catch {
                    Write-WarningBanner "  API health check failed: $_"
                    $validationResults[$vmName] = "API UNREACHABLE (may be NSG)"
                }
            }
        }

    } catch {
        Write-Host "  ❌ Validation error for '$vmName': $_" -ForegroundColor Red
        $validationResults[$vmName] = "ERROR"
    }
}

Wait-ForSection "Section 5: Validation Checklist"


# ================================================================
# SECTION 5: Print Validation Checklist
# ================================================================
Write-SectionHeader "5" "Validation Checklist"

# This checklist lets the participant manually confirm items that
# automated tests can't easily verify (e.g., visual appearance of a web page).
Write-Host "Automated test results:" -ForegroundColor White
Write-Host "========================" -ForegroundColor White
foreach ($vmName in $vmNames) {
    $result = if ($validationResults.ContainsKey($vmName)) { $validationResults[$vmName] } else { "NOT TESTED" }
    $color = if ($result -eq "PASSED") { "Green" } else { "Yellow" }
    Write-Host "  $vmName : $result" -ForegroundColor $color
}

# Manual verification steps that can't be automated.
# The participant should open a browser and check these.
Write-Host "`n📋 MANUAL VERIFICATION CHECKLIST:" -ForegroundColor White
Write-Host "  Please confirm each item by browsing to the test VMs:" -ForegroundColor White
Write-Host ""
Write-Host "  [ ] OnPrem-Web       -- Can you see the Contoso website in a browser?" -ForegroundColor White
Write-Host "  [ ] OnPrem-SQL       -- Can you connect with SSMS and see the ContosoApp database?" -ForegroundColor White
Write-Host "  [ ] OnPrem-Linux-Web -- Can you see the Nginx welcome page in a browser?" -ForegroundColor White
Write-Host "  [ ] OnPrem-Linux-App -- Does /api/health return { status: 'ok' }?" -ForegroundColor White
Write-Host "  [ ] All VMs          -- Are VM sizes and disk configurations correct?" -ForegroundColor White
Write-Host "  [ ] All VMs          -- Are OS versions matching the source?" -ForegroundColor White
Write-Host ""
Write-WarningBanner "If any test FAILED, investigate before proceeding to cutover (Step 5)."
Write-WarningBanner "Common issues: NSG blocking traffic, services not started, DNS not configured."

Read-Host "`nPress Enter after completing manual verification to proceed to cleanup..."


# ================================================================
# SECTION 6: Clean Up Test Migration
# ================================================================
Write-SectionHeader "6" "Clean Up Test Migration"

# Test resources must be cleaned up before you can proceed to production cutover.
# Azure Migrate enforces this -- you CANNOT start a real migration while test
# migration resources still exist. This is a safety mechanism.
Write-StepInfo "Cleaning up test migration resources..."
Write-WarningBanner "This will delete the test VMs but NOT affect source VMs or replication."

foreach ($vmName in $vmNames) {
    Write-StepInfo "Cleaning up test migration for '$vmName'..."

    try {
        # Find the replicating server for this VM.
        $server = Get-AzMigrateServerReplication -ResourceGroupName $TargetResourceGroup `
                  -ProjectName $MigrateProjectName |
                  Where-Object { $_.MachineName -eq $vmName }

        if (-not $server) {
            Write-WarningBanner "Skipping '$vmName' -- not found in replicating servers."
            continue
        }

        # Start-AzMigrateTestMigrationCleanup removes the test VM and its
        # associated resources (disks, NICs) while preserving replication state.
        # After cleanup, the VM returns to "Protected" state, ready for cutover.
        # Output discarded: the returned job carries the full subscription resource ID.
        Start-AzMigrateTestMigrationCleanup -InputObject $server | Out-Null

        Write-StepInfo "  ✅ Test cleanup initiated for '$vmName'."

    } catch {
        Write-Host "  ❌ Cleanup failed for '$vmName': $_" -ForegroundColor Red
        Write-WarningBanner "You may need to clean up manually in the Azure portal."
    }
}

# Wait for cleanup to propagate.
Write-StepInfo "Waiting 60 seconds for cleanup to propagate..."
Start-Sleep -Seconds 60

# Optionally clean up the test VNet too, since we no longer need it.
Write-StepInfo "Removing test VNet '$TestVNetName'..."
try {
    Remove-AzVirtualNetwork -Name $TestVNetName -ResourceGroupName $TargetResourceGroup -Force
    Write-StepInfo "  ✅ Test VNet removed."
} catch {
    Write-WarningBanner "Could not remove test VNet: $_"
    Write-StepInfo "  You can remove it manually later from the Azure portal."
}


# ================================================================
# SECTION 7: Test Results Summary & Next Steps
# ================================================================
Write-SectionHeader "7" "Test Results Summary & Next Steps"

# Final summary of everything that happened in this script.
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           TEST MIGRATION RESULTS SUMMARY            ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Cyan

foreach ($vmName in $vmNames) {
    $result = if ($validationResults.ContainsKey($vmName)) { $validationResults[$vmName] } else { "NOT TESTED" }
    $icon = if ($result -eq "PASSED") { "✅" } else { "⚠️ " }
    $paddedName = $vmName.PadRight(22)
    Write-Host "║  $icon $paddedName $result" -ForegroundColor Cyan
}

Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Test VNet created  : $TestVNetName" -ForegroundColor Cyan
Write-Host "║  Test VNet cleaned  : Yes" -ForegroundColor Cyan
Write-Host "║  Test VMs cleaned   : Yes" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Guide the participant to the next step.
Write-Host "`n📌 NEXT STEPS:" -ForegroundColor Green
Write-Host "  1. Review the test results above." -ForegroundColor White
Write-Host "  2. If all tests PASSED -- proceed to Step 5 (Production Cutover)." -ForegroundColor White
Write-Host "  3. If any tests FAILED -- investigate and re-run test migration." -ForegroundColor White
Write-Host "  4. Run: .\migrate-step5-cutover.ps1" -ForegroundColor White
Write-Host ""
Write-Host "  ⏱️  Estimated time for Step 5: 30-60 minutes" -ForegroundColor Gray
Write-Host ""
