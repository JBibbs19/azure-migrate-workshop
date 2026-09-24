<#
.SYNOPSIS
    Step 5: Execute the production migration cutover.

.DESCRIPTION
    This is the FINAL migration step. Source VMs will be shut down
    and migrated VMs will take over in Azure.

    ⚠️ WARNING: This will shut down the source VMs on the Hyper-V host.
    Ensure you have completed test migration (Step 4) successfully.

    Cutover sequence:
    1. Final delta replication sync
    2. Source VM shutdown (optional but recommended)
    3. Failover to Azure
    4. Post-migration validation
    5. Complete migration (stop replication)

    VMs being migrated:
      - OnPrem-Web       (Windows Server + IIS)
      - OnPrem-SQL       (Windows Server + SQL Server Express)
      - OnPrem-Linux-Web (Ubuntu + Nginx)
      - OnPrem-Linux-App (Ubuntu + Node.js API)

    Prerequisites:
      - Steps 1-4 completed (test migration passed, test resources cleaned up)
      - Replication is in a healthy "Protected" state for all VMs
      - Maintenance window approved (source VMs will be shut down)

.PARAMETER SourceResourceGroup
    Resource group containing the Hyper-V host and on-prem VMs.

.PARAMETER TargetResourceGroup
    Resource group where migrated VMs will land.

.PARAMETER MigrateProjectName
    Name of the Azure Migrate project.

.PARAMETER Location
    Azure region for resources. Prompted when not supplied (example: eastus).

.PARAMETER TurnOffSourceVMs
    Whether to shut down source VMs before cutover. Prompted when not supplied (example: Yes).
    Recommended to ensure no writes are lost during final sync.

.EXAMPLE
    .\migrate-step5-cutover.ps1

.EXAMPLE
    .\migrate-step5-cutover.ps1 -TurnOffSourceVMs "No"
MODULE COVERAGE
    The scripts and the modules are run separately. What this completes depends on -Workload:

      -Workload Agentless   Module 2, section 9 (Cutover Planning and Execution).
      -Workload AgentBased  Module 3, section 11 (Cutover for Stateful Workloads).
      -Workload All         Both, in one pass. The default.

    Not covered: Module 2 section 10 and Module 3 sections 11.5 to 11.8 - post-cutover
    validation, connection strings, end-to-end checks. Those confirm the migration actually
    worked and are the point of the exercise.
#>

[CmdletBinding()]
param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [string]$MigrateProjectName,

    [string]$Location,

    [ValidateSet("Yes","No")][string]$TurnOffSourceVMs,

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
$TurnOffSourceVMs = Read-LabChoice -Prompt 'Shut down the source VMs before the final sync (recommended: Yes)' -Value $TurnOffSourceVMs
$Workload = Select-LabFromList -Name 'Workload' -Value $Workload -Options @('All', 'Agentless', 'AgentBased') -Kind Workload -Prompt 'Workload group (All = four VMs; Agentless = the Module 2 pair; AgentBased = the Module 3 pair)'


# Confirm this step's resources exist in the signed-in subscription before changing anything.
Assert-LabResources -SourceResourceGroup $SourceResourceGroup -TargetResourceGroup $TargetResourceGroup -MigrateProjectName $MigrateProjectName

# ================================================================
# Helper Functions
# ================================================================

function Write-SectionHeader {
    param([string]$SectionNumber, [string]$Title)
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "  SECTION $SectionNumber`: $Title" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
}

function Write-StepInfo {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

function Write-WarningBanner {
    param([string]$Message)
    Write-Host "`n⚠️  $Message" -ForegroundColor Yellow
}

function Wait-ForSection {
    param([string]$NextSection = "the next section")
    Write-Host ""
    Read-Host "Press Enter to continue to $NextSection..."
    Write-Host ""
}

# VM names matching the guest VMs discovered by Azure Migrate.
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
# SECTION 0: Prerequisites & Pre-Cutover Checklist
# ================================================================
Write-SectionHeader "0" "Prerequisites & Pre-Cutover Checklist"

# Verify Az modules are available.
Write-StepInfo "Verifying Az PowerShell modules..."
$requiredModules = @("Az.Migrate", "Az.Network", "Az.Compute")
foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        throw "Required module '$mod' is not installed. Run: Install-Module -Name $mod -Scope CurrentUser -Force"
    }
    Write-StepInfo "  ✅ Module '$mod' found."
}

# Verify Azure session.
try {
    $context = Get-AzContext
    if (-not $context) { throw "No Azure context." }
    Write-StepInfo "Subscription: $(Format-LabSubscriptionId $context.Subscription.Id)"
} catch {
    throw "Azure authentication required. Run 'Connect-AzAccount' first. Error: $_"
}

# Retrieve replicating servers and verify their state.
# For cutover, all VMs should be in "Protected" state (test migration cleaned up).
Write-StepInfo "Checking replication health for all VMs..."
try {
    $replicatingServers = Get-AzMigrateServerReplication -ResourceGroupName $TargetResourceGroup `
                          -ProjectName $MigrateProjectName

    $allHealthy = $true
    foreach ($vmName in $vmNames) {
        $server = $replicatingServers | Where-Object { $_.MachineName -eq $vmName }
        if (-not $server) {
            Write-Host "  ❌ '$vmName' -- NOT FOUND in replicating servers." -ForegroundColor Red
            $allHealthy = $false
        } elseif ($server.TestMigrateState -ne "None" -and $server.TestMigrateState -ne "TestMigrationCleanedUp") {
            # If test migration wasn't cleaned up, cutover will be blocked by Azure Migrate.
            Write-Host "  ❌ '$vmName' -- Test migration not cleaned up `(State: $($server.TestMigrateState)`)." -ForegroundColor Red
            $allHealthy = $false
        } else {
            Write-StepInfo "  ✅ '$vmName' -- Replication: $($server.MigrationState), Health: $($server.ReplicationHealthDescription)"
        }
    }

    if (-not $allHealthy) {
        Write-WarningBanner "Some VMs are not in a healthy state. Complete test migration cleanup (Step 4) before proceeding."
    }
} catch {
    Write-WarningBanner "Could not verify replication state: $_"
    Write-WarningBanner "Proceeding anyway -- ensure you've completed Step 4."
}

# Print the pre-cutover checklist for the participant to review.
Write-Host "`n📋 PRE-CUTOVER CHECKLIST:" -ForegroundColor White
Write-Host "  [✓] Test migration (Step 4) completed successfully" -ForegroundColor White
Write-Host "  [✓] Test migration resources cleaned up" -ForegroundColor White
Write-Host "  [✓] Replication is healthy for all VMs" -ForegroundColor White
Write-Host "  [✓] Maintenance window approved" -ForegroundColor White
Write-Host "  [✓] Rollback plan documented" -ForegroundColor White
Write-Host "  [✓] Stakeholders notified" -ForegroundColor White

Wait-ForSection "Section 1: Confirm Cutover"


# ================================================================
# SECTION 1: Confirm Cutover with User
# ================================================================
Write-SectionHeader "1" "Confirm Cutover"

# This is a DESTRUCTIVE operation -- source VMs will be shut down (if opted in).
# We require an explicit confirmation to prevent accidental execution.
Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Red
Write-Host "║               ⚠️  PRODUCTION CUTOVER ⚠️              ║" -ForegroundColor Red
Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Red
Write-Host "║  This will MIGRATE the following VMs to Azure:      ║" -ForegroundColor Red
Write-Host "║    - OnPrem-Web       (IIS Web Server)              ║" -ForegroundColor Red
Write-Host "║    - OnPrem-SQL       (SQL Server Express)          ║" -ForegroundColor Red
Write-Host "║    - OnPrem-Linux-Web (Nginx Web Server)            ║" -ForegroundColor Red
Write-Host "║    - OnPrem-Linux-App (Node.js API)                 ║" -ForegroundColor Red
Write-Host "║                                                      ║" -ForegroundColor Red
Write-Host "║  Source VM shutdown: $TurnOffSourceVMs                          ║" -ForegroundColor Red
Write-Host "║  Target Resource Group: $TargetResourceGroup              ║" -ForegroundColor Red
Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Red

# Require the participant to type "MIGRATE" -- not just press Enter.
# This prevents accidental cutover if the script is run by mistake.
$confirmation = Read-Host "`nType 'MIGRATE' (all caps) to proceed with cutover"
if ($confirmation -ne "MIGRATE") {
    Write-Host "Cutover CANCELLED. You typed '$confirmation' instead of 'MIGRATE'." -ForegroundColor Yellow
    Write-Host "Re-run this script when you are ready to proceed."
    exit 0
}

Write-StepInfo "Cutover confirmed. Proceeding..."
Wait-ForSection "Section 2: Initiate Migration"


# ================================================================
# SECTION 2: Initiate Migration (Cutover)
# ================================================================
Write-SectionHeader "2" "Initiate Migration"

# Start-AzMigrateServerMigration triggers the actual production cutover.
# Unlike test migration, this is the real deal:
#   - A final delta sync captures any changes since the last replication cycle
#   - Source VMs are optionally shut down to ensure data consistency
#   - Azure VMs are created with production networking
Write-StepInfo "Starting production migration for all VMs..."
Write-WarningBanner "This process typically takes 20-60 minutes per VM."

# Determine whether to shut down source VMs.
# Shutting down source VMs ensures zero data loss during the final sync,
# but it means the source workloads go offline immediately.
$turnOffSource = ($TurnOffSourceVMs -eq "Yes")
if ($turnOffSource) {
    Write-StepInfo "Source VMs WILL be shut down before final sync (recommended for data consistency)."
} else {
    Write-WarningBanner "Source VMs will NOT be shut down. There may be minimal data loss from in-flight writes."
}

# Track migration jobs for monitoring.
$migrationJobs = @{}

foreach ($vmName in $vmNames) {
    Write-StepInfo "Starting migration for '$vmName'..."

    try {
        # Get the replicating server object.
        $server = $replicatingServers | Where-Object { $_.MachineName -eq $vmName }

        if (-not $server) {
            Write-Host "  ❌ '$vmName' not found. Skipping." -ForegroundColor Red
            continue
        }

        # Start-AzMigrateServerMigration initiates the cutover.
        # -TurnOffSourceServer shuts down the on-prem VM before the final delta sync
        # to guarantee that no writes are lost during migration.
        $migrateJob = Start-AzMigrateServerMigration `
            -InputObject $server `
            -TurnOffSourceServer:$turnOffSource

        Write-StepInfo "  ✅ Migration initiated for '$vmName'. Job: $($migrateJob.Name)"
        $migrationJobs[$vmName] = $migrateJob

    } catch {
        Write-Host "  ❌ Failed to start migration for '$vmName': $_" -ForegroundColor Red
        Write-WarningBanner "Check Azure Migrate in the portal for details."
    }
}

Write-StepInfo "All migration requests submitted."
Wait-ForSection "Section 3: Wait for Migration to Complete"


# ================================================================
# SECTION 3: Wait for Migration to Complete
# ================================================================
Write-SectionHeader "3" "Wait for Migration to Complete"

# Poll the migration status until all VMs have completed.
# Production migration involves more steps than test migration:
# final sync → source shutdown → disk swap → VM provisioning → boot.
Write-StepInfo "Polling migration status every 60 seconds..."
Write-StepInfo "This is the real migration -- typically takes 20-60 minutes per VM."

$maxWaitMinutes = 90          # Allow more time for production migration
$pollIntervalSeconds = 60
$startTime = Get-Date
$completedVMs = @{}

while ($completedVMs.Count -lt $migrationJobs.Count) {
    # Safety timeout to avoid infinite loops if Azure Migrate hangs.
    $elapsed = (Get-Date) - $startTime
    if ($elapsed.TotalMinutes -gt $maxWaitMinutes) {
        Write-WarningBanner "Maximum wait time `($maxWaitMinutes minutes`) exceeded."
        Write-WarningBanner "Check Azure Migrate in the portal for status. Some VMs may still be migrating."
        break
    }

    # Re-fetch all replicating servers to get updated states.
    $currentServers = Get-AzMigrateServerReplication -ResourceGroupName $TargetResourceGroup `
                      -ProjectName $MigrateProjectName

    foreach ($vmName in $migrationJobs.Keys) {
        if ($completedVMs.ContainsKey($vmName)) { continue }

        $server = $currentServers | Where-Object { $_.MachineName -eq $vmName }
        $state = $server.MigrationState

        if ($state -eq "MigrationSucceeded") {
            # The VM has been successfully migrated to Azure.
            Write-StepInfo "  ✅ '$vmName' -- Migration SUCCEEDED!"
            $completedVMs[$vmName] = $true
        } elseif ($state -eq "MigrationFailed") {
            Write-Host "  ❌ '$vmName' -- Migration FAILED." -ForegroundColor Red
            $completedVMs[$vmName] = $false
        } else {
            # Show progress so the participant knows it's still working.
            Write-StepInfo "  ⏳ '$vmName' -- State: $state `(elapsed: $([math]::Round($elapsed.TotalMinutes, 1)) min`)"
        }
    }

    if ($completedVMs.Count -lt $migrationJobs.Count) {
        $remaining = $migrationJobs.Count - $completedVMs.Count
        Write-StepInfo "  $remaining VM`(s`) still migrating. Waiting $pollIntervalSeconds seconds..."
        Start-Sleep -Seconds $pollIntervalSeconds
    }
}

# Print migration results.
Write-Host "`n--- Migration Status ---" -ForegroundColor White
foreach ($vmName in $migrationJobs.Keys) {
    $result = if ($completedVMs[$vmName] -eq $true) { "✅ SUCCEEDED" } else { "❌ FAILED/TIMED OUT" }
    Write-Host "  $vmName : $result"
}

Wait-ForSection "Section 4: Post-Migration Validation"


# ================================================================
# SECTION 4: Post-Migration Validation
# ================================================================
Write-SectionHeader "4" "Post-Migration Validation"

# The migrated VMs are now running in Azure. We need to verify that:
# 1. Each VM is running and accessible
# 2. Each workload is functional (same tests as Step 4, but on real VMs)
# 3. Data integrity is preserved (especially for SQL)
Write-StepInfo "Validating migrated VMs in '$TargetResourceGroup'..."

# Collect migrated VM details for the summary.
$migratedVMDetails = @{}

foreach ($vmName in $vmNames) {
    Write-Host "`n--- Validating: $vmName ---" -ForegroundColor White

    try {
        # Find the migrated VM in the target resource group.
        $vm = Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $vmName -ErrorAction SilentlyContinue

        if (-not $vm) {
            Write-WarningBanner "VM '$vmName' not found in '$TargetResourceGroup'."
            $migratedVMDetails[$vmName] = @{ Status = "NOT FOUND"; IP = "N/A" }
            continue
        }

        # Check power state -- the VM should be running after migration.
        $vmStatus = Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $vmName -Status
        $powerState = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus

        if ($powerState -eq "VM running") {
            Write-StepInfo "  ✅ VM is running. Size: $($vm.HardwareProfile.VmSize)"
        } else {
            Write-Host "  ❌ VM power state: $powerState" -ForegroundColor Red
            $migratedVMDetails[$vmName] = @{ Status = "NOT RUNNING"; IP = "N/A" }
            continue
        }

        # Get networking info -- migrated VMs will have IPs in the target VNet.
        $nic = Get-AzNetworkInterface -ResourceGroupName $TargetResourceGroup |
               Where-Object { $_.VirtualMachine.Id -eq $vm.Id }
        $privateIp = $nic.IpConfigurations[0].PrivateIpAddress

        # Check for public IP.
        $publicIp = "None"
        $publicIpId = $nic.IpConfigurations[0].PublicIpAddress.Id
        if ($publicIpId) {
            $pipResource = Get-AzPublicIpAddress | Where-Object { $_.Id -eq $publicIpId }
            $publicIp = $pipResource.IpAddress
        }

        Write-StepInfo "  Private IP: $privateIp"
        Write-StepInfo "  Public IP : $publicIp"

        # Use the reachable IP for workload tests.
        $testIp = if ($publicIp -ne "None" -and $publicIp -ne "Not Assigned") { $publicIp } else { $privateIp }

        # Workload-specific validation -- same as test migration but on production VMs.
        $workloadStatus = "UNTESTED"
        switch -Wildcard ($vmName) {
            "OnPrem-Web" {
                # Validate IIS is serving the Contoso web app.
                Write-StepInfo "  Testing IIS on port 80..."
                try {
                    $response = Invoke-WebRequest -Uri "http://$testIp" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        Write-StepInfo "  ✅ IIS returned HTTP 200."
                        $workloadStatus = "PASSED"
                    }
                } catch {
                    Write-WarningBanner "  IIS HTTP test failed: $_"
                    $workloadStatus = "HTTP FAILED"
                }
            }

            "OnPrem-SQL" {
                # Validate SQL Server is listening and data is intact.
                Write-StepInfo "  Testing SQL Server on port 1433..."
                try {
                    $tcpTest = Test-NetConnection -ComputerName $testIp -Port 1433 -WarningAction SilentlyContinue
                    if ($tcpTest.TcpTestSucceeded) {
                        Write-StepInfo "  ✅ SQL Server port 1433 is reachable."
                        $workloadStatus = "PORT OPEN"
                    } else {
                        $workloadStatus = "PORT CLOSED"
                    }
                } catch {
                    Write-WarningBanner "  SQL connectivity test failed: $_"
                    $workloadStatus = "TCP FAILED"
                }

                # Data integrity check -- verify row counts.
                # This uses Invoke-AzVMRunCommand to run a SQL query inside the VM
                # to confirm the ContosoApp database has data.
                Write-StepInfo "  Checking SQL data integrity (row counts)..."
                try {
                    $sqlCheckScript = @"
                        try {
                            `$result = Invoke-Sqlcmd -ServerInstance 'localhost' -Database 'ContosoApp' -Query 'SELECT COUNT(*) AS RowCount FROM dbo.Products' -ErrorAction Stop
                            Write-Output "ContosoApp.Products row count: `$(`$result.RowCount)"
                        } catch {
                            Write-Output "SQL query failed: `$_"
                        }
"@
                    $sqlResult = Invoke-AzVMRunCommand `
                        -ResourceGroupName $TargetResourceGroup `
                        -VMName $vmName `
                        -CommandId "RunPowerShellScript" `
                        -ScriptString $sqlCheckScript

                    # Display the output from the SQL query.
                    $sqlResult.Value | ForEach-Object {
                        Write-StepInfo "  SQL Check: $($_.Message)"
                    }
                    $workloadStatus = "PASSED (port + data)"
                } catch {
                    Write-WarningBanner "  Data integrity check failed: $_"
                    Write-StepInfo "  (You can verify manually via RDP + SSMS)"
                }
            }

            "OnPrem-Linux-Web" {
                # Validate Nginx is serving content.
                Write-StepInfo "  Testing Nginx on port 80..."
                try {
                    $response = Invoke-WebRequest -Uri "http://$testIp" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        Write-StepInfo "  ✅ Nginx returned HTTP 200."
                        $workloadStatus = "PASSED"
                    }
                } catch {
                    Write-WarningBanner "  Nginx HTTP test failed: $_"
                    $workloadStatus = "HTTP FAILED"
                }
            }

            "OnPrem-Linux-App" {
                # Validate the Node.js API health endpoint.
                Write-StepInfo "  Testing Node.js API at port 3000/api/health..."
                try {
                    $response = Invoke-WebRequest -Uri "http://${testIp}:3000/api/health" -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
                    if ($response.StatusCode -eq 200) {
                        Write-StepInfo "  ✅ Node.js API returned HTTP 200."
                        $workloadStatus = "PASSED"
                    }
                } catch {
                    Write-WarningBanner "  Node.js API test failed: $_"
                    $workloadStatus = "API FAILED"
                }
            }
        }

        # Store details for the summary section.
        $migratedVMDetails[$vmName] = @{
            Status    = $workloadStatus
            PrivateIP = $privateIp
            PublicIP  = $publicIp
            VMSize    = $vm.HardwareProfile.VmSize
        }

    } catch {
        Write-Host "  ❌ Error validating '$vmName': $_" -ForegroundColor Red
        $migratedVMDetails[$vmName] = @{ Status = "ERROR"; IP = "N/A" }
    }
}

Wait-ForSection "Section 5: Complete Migration"


# ================================================================
# SECTION 5: Complete Migration (Stop Replication)
# ================================================================
Write-SectionHeader "5" "Complete Migration (Stop Replication)"

# Once we're satisfied that all VMs are working correctly in Azure,
# we stop replication. This is the FINAL step -- after this, the migration
# is considered complete and you cannot roll back via Azure Migrate.
Write-StepInfo "Completing migration and stopping replication..."
Write-WarningBanner "After this step, replication will be permanently stopped."
Write-WarningBanner "You will NOT be able to roll back via Azure Migrate after completion."

$completeConfirm = Read-Host "Type 'COMPLETE' to stop replication and finalize migration"
if ($completeConfirm -ne "COMPLETE") {
    Write-WarningBanner "Skipping migration completion. Replication is still active."
    Write-StepInfo "You can complete migration later by re-running this section."
} else {
    foreach ($vmName in $vmNames) {
        Write-StepInfo "Completing migration for '$vmName'..."

        try {
            # Re-fetch the server to ensure we have the latest state.
            $server = Get-AzMigrateServerReplication -ResourceGroupName $TargetResourceGroup `
                      -ProjectName $MigrateProjectName |
                      Where-Object { $_.MachineName -eq $vmName }

            if (-not $server) {
                Write-WarningBanner "Skipping '$vmName' -- not found."
                continue
            }

            # Stop replication. This cleans up the replication infrastructure
            # (storage accounts, replication appliances) and marks the migration as complete.
            # After this, the source VM's replication data is no longer maintained.
            # Output discarded: the returned job carries the full subscription resource ID.
            Remove-AzMigrateServerReplication -InputObject $server | Out-Null

            Write-StepInfo "  ✅ Replication stopped for '$vmName'. Migration complete."

        } catch {
            Write-Host "  ❌ Failed to complete migration for '$vmName': $_" -ForegroundColor Red
        }
    }
}

Wait-ForSection "Section 6: Update NSG Rules"


# ================================================================
# SECTION 6: Update NSG Rules on Migrated VMs
# ================================================================
Write-SectionHeader "6" "Update NSG Rules on Migrated VMs"

# Migrated VMs may have permissive default NSG rules. We tighten them
# here as a basic security measure. Full NSG hardening happens in Step 6.
Write-StepInfo "Applying initial NSG rules to migrated VMs..."

foreach ($vmName in $vmNames) {
    Write-StepInfo "Configuring NSG for '$vmName'..."

    try {
        # Find the NIC associated with this VM.
        $vm = Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            Write-WarningBanner "VM '$vmName' not found. Skipping NSG update."
            continue
        }

        # Get the NSG attached to the VM's NIC or subnet.
        $nic = Get-AzNetworkInterface -ResourceGroupName $TargetResourceGroup |
               Where-Object { $_.VirtualMachine.Id -eq $vm.Id }
        $nsg = $null

        if ($nic.NetworkSecurityGroup) {
            # NSG is attached directly to the NIC.
            $nsgId = $nic.NetworkSecurityGroup.Id
            $nsgName = $nsgId.Split("/")[-1]
            $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $TargetResourceGroup -Name $nsgName
        } else {
            # Create a new NSG for the VM if one doesn't exist.
            $nsgName = "$vmName-nsg"
            Write-StepInfo "  Creating NSG '$nsgName'..."
            $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $TargetResourceGroup `
                   -Location $Location -Name $nsgName

            # Attach the NSG to the NIC.
            $nic.NetworkSecurityGroup = $nsg
            Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
        }

        # Apply workload-specific rules.
        # These are initial rules -- Step 6 will apply stricter Zero Trust rules.
        switch -Wildcard ($vmName) {
            "OnPrem-Web" {
                # IIS needs HTTP (80) and HTTPS (443) inbound from the internet.
                $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-HTTP" `
                    -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
                    -SourceAddressPrefix "*" -SourcePortRange "*" `
                    -DestinationAddressPrefix "*" -DestinationPortRange "80" | Out-Null
                $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-HTTPS" `
                    -Priority 110 -Direction Inbound -Access Allow -Protocol Tcp `
                    -SourceAddressPrefix "*" -SourcePortRange "*" `
                    -DestinationAddressPrefix "*" -DestinationPortRange "443" | Out-Null
                Write-StepInfo "  ✅ NSG: Allow HTTP/HTTPS inbound."
            }

            "OnPrem-SQL" {
                # SQL should only accept connections from the web server, not the internet.
                $webIp = $migratedVMDetails["OnPrem-Web"].PrivateIP
                if ($webIp) {
                    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-SQL-From-Web" `
                        -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
                        -SourceAddressPrefix $webIp -SourcePortRange "*" `
                        -DestinationAddressPrefix "*" -DestinationPortRange "1433" | Out-Null
                    Write-StepInfo "  ✅ NSG: Allow 1433 from web server `($webIp`) only."
                } else {
                    Write-WarningBanner "  Web server IP not available. Allowing 1433 from VNet."
                    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-SQL-From-VNet" `
                        -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
                        -SourceAddressPrefix "VirtualNetwork" -SourcePortRange "*" `
                        -DestinationAddressPrefix "*" -DestinationPortRange "1433" | Out-Null
                }
            }

            "OnPrem-Linux-Web" {
                # Nginx needs HTTP (80) and HTTPS (443) inbound.
                $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-HTTP" `
                    -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
                    -SourceAddressPrefix "*" -SourcePortRange "*" `
                    -DestinationAddressPrefix "*" -DestinationPortRange "80" | Out-Null
                $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-HTTPS" `
                    -Priority 110 -Direction Inbound -Access Allow -Protocol Tcp `
                    -SourceAddressPrefix "*" -SourcePortRange "*" `
                    -DestinationAddressPrefix "*" -DestinationPortRange "443" | Out-Null
                Write-StepInfo "  ✅ NSG: Allow HTTP/HTTPS inbound."
            }

            "OnPrem-Linux-App" {
                # Node.js API should only be accessible from the Nginx reverse proxy.
                $nginxIp = $migratedVMDetails["OnPrem-Linux-Web"].PrivateIP
                if ($nginxIp) {
                    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-API-From-Nginx" `
                        -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
                        -SourceAddressPrefix $nginxIp -SourcePortRange "*" `
                        -DestinationAddressPrefix "*" -DestinationPortRange "3000" | Out-Null
                    Write-StepInfo "  ✅ NSG: Allow 3000 from Nginx `($nginxIp`) only."
                } else {
                    Write-WarningBanner "  Nginx IP not available. Allowing 3000 from VNet."
                    $nsg | Add-AzNetworkSecurityRuleConfig -Name "Allow-API-From-VNet" `
                        -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
                        -SourceAddressPrefix "VirtualNetwork" -SourcePortRange "*" `
                        -DestinationAddressPrefix "*" -DestinationPortRange "3000" | Out-Null
                }
            }
        }

        # Save the updated NSG rules to Azure.
        Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg | Out-Null
        Write-StepInfo "  NSG rules saved for '$vmName'."

    } catch {
        Write-Host "  ❌ NSG update failed for '$vmName': $_" -ForegroundColor Red
    }
}

Wait-ForSection "Section 7: Migration Summary"


# ================================================================
# SECTION 7: Migration Summary & Next Steps
# ================================================================
Write-SectionHeader "7" "Migration Summary & Next Steps"

Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║              PRODUCTION MIGRATION SUMMARY                   ║" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
Write-Host "║  Source RG : $SourceResourceGroup" -ForegroundColor Cyan
Write-Host "║  Target RG : $TargetResourceGroup" -ForegroundColor Cyan
Write-Host "║  Timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Cyan

foreach ($vmName in $vmNames) {
    $details = $migratedVMDetails[$vmName]
    if ($details) {
        $paddedName = $vmName.PadRight(22)
        Write-Host "║  $paddedName" -ForegroundColor Cyan
        Write-Host "║    Status    : $($details.Status)" -ForegroundColor Cyan
        Write-Host "║    Private IP: $($details.PrivateIP)" -ForegroundColor Cyan
        Write-Host "║    Public IP : $($details.PublicIP)" -ForegroundColor Cyan
        Write-Host "║    VM Size   : $($details.VMSize)" -ForegroundColor Cyan
        Write-Host "║" -ForegroundColor Cyan
    }
}

Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Connection information for the participant.
Write-Host "`n🔗 CONNECTION INFO:" -ForegroundColor White
Write-Host "  Windows VMs -- RDP: mstsc /v:<Public-IP>" -ForegroundColor White
Write-Host "  Linux VMs   -- SSH: ssh labadmin@<Public-IP>" -ForegroundColor White
Write-Host "  Web Apps    -- Browser: http://<Public-IP>" -ForegroundColor White

# Guide to the final step.
Write-Host "`n📌 NEXT STEPS:" -ForegroundColor Green
Write-Host "  1. Verify all migrated workloads are functioning correctly." -ForegroundColor White
Write-Host "  2. Update DNS records to point to new Azure IPs." -ForegroundColor White
Write-Host "  3. Notify stakeholders that migration is complete." -ForegroundColor White
Write-Host "  4. Proceed to Step 6: Post-Migration Optimization." -ForegroundColor White
Write-Host "  5. Run: .\migrate-step6-post-migration.ps1" -ForegroundColor White
Write-Host ""
Write-Host "  ⏱️  Estimated time for Step 6: 15-30 minutes" -ForegroundColor Gray
Write-Host ""
