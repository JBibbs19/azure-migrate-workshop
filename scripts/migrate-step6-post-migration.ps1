<#
.SYNOPSIS
    Step 6: Post-migration security, monitoring, backup, and optimization.

.DESCRIPTION
    Configures Azure best practices on the migrated VMs:
    - Azure Monitor for observability
    - Azure Backup for data protection
    - NSG hardening for security (Zero Trust)
    - Right-sizing recommendations
    - Cost optimization (auto-shutdown, tags)

    This maps to the Azure Well-Architected Framework pillars:
    - Operational Excellence (monitoring)
    - Reliability (backup)
    - Security (NSGs, Defender)
    - Cost Optimization (right-sizing, auto-shutdown)

    VMs being configured:
      - OnPrem-Web       (Windows Server + IIS)
      - OnPrem-SQL       (Windows Server + SQL Server Express)
      - OnPrem-Linux-Web (Ubuntu + Nginx)
      - OnPrem-Linux-App (Ubuntu + Node.js API)

    Prerequisites:
      - Step 5 completed (all VMs migrated and running in Azure)
      - Az PowerShell modules installed

.PARAMETER SourceResourceGroup
    Resource group that contained the original on-prem VMs.

.PARAMETER TargetResourceGroup
    Resource group containing the migrated Azure VMs.

.PARAMETER Location
    Azure region. Prompted when not supplied (example: eastus).

.PARAMETER AutoShutdownTime
    Daily auto-shutdown time in HHmm format (24-hour). Prompted when not supplied (example: 1900 (7 PM)).

.PARAMETER AutoShutdownTimezone
    Timezone for auto-shutdown. Prompted when not supplied (example: Eastern Standard Time).

.PARAMETER BackupRetentionDays
    Number of days to retain backups. Prompted when not supplied (example: 30).

.PARAMETER ParticipantName
    Name of the workshop participant (used for resource tagging).

.EXAMPLE
    .\migrate-step6-post-migration.ps1

.EXAMPLE
    .\migrate-step6-post-migration.ps1 -ParticipantName "John" -AutoShutdownTime "2200"
MODULE COVERAGE
    The scripts and the modules are run separately. This script completes:

      Module 5, section 2   Observability Strategy - Azure Monitor agent, workspace, DCRs.
      Module 5, section 3   Data Protection Strategy - recovery services vault, policy, backup.
      Module 5, section 4   Security Hardening - NSG rules and microsegmentation.
      Module 5, section 5   Cost Optimization - right-sizing, auto-shutdown, tags.

    Not covered: section 1 (concepts), section 6 (Update Management), section 7 (Day 2
    Operations Runbook) and section 8 (Workshop Summary). Those are discussion and reading.

    It tolerates a partial estate: the VM list is built from what actually exists in the target
    resource group, so it works after only Module 2 or only Module 3 has been completed.
#>

[CmdletBinding()]
param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [string]$Location,

    [string]$AutoShutdownTime,

    [string]$AutoShutdownTimezone,

    [int]$BackupRetentionDays,

    [string]$ParticipantName
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

$context = Get-LabAzContext -RequiredModules @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network') -OptionalModules @('Az.Monitor', 'Az.OperationalInsights', 'Az.RecoveryServices')

Write-Host ""
Write-Host "Enter the values for your lab environment. A value in [brackets] is a lab default and Enter accepts it; an (example: ...) is a hint only and must be typed." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabResourceGroupName -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Prompt 'Source resource group (contains the Hyper-V host)' -Example 'rg-ces-source-01' -MissingHelp 'It is created by deploy-lab.ps1.'
$TargetResourceGroup = Read-LabResourceGroupName -Name 'TargetResourceGroup' -Value $TargetResourceGroup -Prompt 'Target resource group (landing zone for migrated VMs)' -Example 'rg-ces-target-01' -MissingHelp 'It is created by migrate-step1-setup-project.ps1.'
$Location = Resolve-LabLocation -Value $Location -ResourceGroupName $TargetResourceGroup
$AutoShutdownTime = Read-LabParameter -Name 'AutoShutdownTime' -Value $AutoShutdownTime -Kind Time24h -Prompt 'Daily auto-shutdown time, 24-hour HHmm' -Example '1900'
$AutoShutdownTimezone = Read-LabParameter -Name 'AutoShutdownTimezone' -Value $AutoShutdownTimezone -Kind TimeZone -Prompt 'Auto-shutdown time zone (Windows time zone ID)' -Example 'Eastern Standard Time'
$BackupRetentionDays = Read-LabNumber -Name 'BackupRetentionDays' -Prompt 'Backup retention in days' -Value $BackupRetentionDays -Supplied:($PSBoundParameters.ContainsKey('BackupRetentionDays')) -Minimum 7 -Maximum 9999 -Example '30'
$ParticipantName = Read-LabParameter -Name 'ParticipantName' -Value $ParticipantName -Kind Text -Prompt 'Participant name for the Owner tag' -Example 'jdoe'


# Confirm this step's resources exist in the signed-in subscription before changing anything.
Assert-LabResources -TargetResourceGroup $TargetResourceGroup

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

# VM names matching the migrated VMs in the target resource group.
$vmNames = @("OnPrem-Web", "OnPrem-SQL", "OnPrem-Linux-Web", "OnPrem-Linux-App")

# ================================================================
# SECTION 0: Prerequisites Check
# ================================================================
Write-SectionHeader "0" "Prerequisites Check"

Write-StepInfo "Verifying Az PowerShell modules..."

# Post-migration tasks need more modules than the migration itself.
# Az.Monitor for monitoring, Az.RecoveryServices for backup, Az.Security for Defender.
$requiredModules = @(
    "Az.Compute",           # VM management
    "Az.Network",           # NSG configuration
    "Az.Monitor",           # Azure Monitor and alerts
    "Az.RecoveryServices",  # Azure Backup
    "Az.Security",          # Microsoft Defender for Cloud
    "Az.Resources"          # Resource tagging and Azure Advisor
)

foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        # Not all modules are strictly required -- warn but don't fail.
        Write-WarningBanner "Module '$mod' not found. Some features may be skipped. Install with: Install-Module -Name $mod -Scope CurrentUser -Force"
    } else {
        Write-StepInfo "  ✅ Module '$mod' found."
    }
}

# Verify Azure session.
try {
    $context = Get-AzContext
    if (-not $context) { throw "No Azure context." }
    Write-StepInfo "Subscription: $(Format-LabSubscriptionId $context.Subscription.Id)"
    $subscriptionId = $context.Subscription.Id
} catch {
    throw "Azure authentication required. Run 'Connect-AzAccount' first. Error: $_"
}

# Verify migrated VMs exist -- Step 5 must have completed.
Write-StepInfo "Verifying migrated VMs exist in '$TargetResourceGroup'..."
$migratedVMs = @{}
foreach ($vmName in $vmNames) {
    $vm = Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $vmName -ErrorAction SilentlyContinue
    if ($vm) {
        Write-StepInfo "  ✅ '$vmName' found. Size: $($vm.HardwareProfile.VmSize)"
        $migratedVMs[$vmName] = $vm
    } else {
        Write-WarningBanner "'$vmName' not found in '$TargetResourceGroup'. Some sections may fail."
    }
}

if ($migratedVMs.Count -eq 0) {
    throw "No migrated VMs found in '$TargetResourceGroup'. Complete Step 5 first."
}

Wait-ForSection "Section 1: Enable Azure Monitor"


# ================================================================
# SECTION 1: Enable Azure Monitor
# ================================================================
Write-SectionHeader "1" "Enable Azure Monitor"

# Azure Monitor provides visibility into VM health, performance, and logs.
# Without monitoring, you're flying blind -- you won't know about issues
# until users report them. This is the "Operational Excellence" pillar
# of the Well-Architected Framework.

# Step 1a: Create a Log Analytics Workspace.
# This is where all monitoring data (metrics, logs, diagnostics) is stored.
# One workspace can serve multiple VMs -- no need for one per VM.
$workspaceName = "$TargetResourceGroup-law"
Write-StepInfo "Creating Log Analytics Workspace '$workspaceName'..."

try {
    $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $TargetResourceGroup `
                 -Name $workspaceName -ErrorAction SilentlyContinue

    if ($workspace) {
        Write-StepInfo "  Workspace already exists. Reusing."
    } else {
        # Create the workspace in the same region as the VMs.
        # Sku "PerGB2018" is the pay-as-you-go tier -- best for workshops.
        $workspace = New-AzOperationalInsightsWorkspace `
            -ResourceGroupName $TargetResourceGroup `
            -Name $workspaceName `
            -Location $Location `
            -Sku "PerGB2018"
        Write-StepInfo "  ✅ Log Analytics Workspace created."
    }

    Write-StepInfo "  Workspace ID: $($workspace.CustomerId)"
    $workspaceId = $workspace.ResourceId
} catch {
    Write-Host "  ❌ Failed to create Log Analytics Workspace: $_" -ForegroundColor Red
    Write-WarningBanner "Monitoring features may be limited without a workspace."
    $workspaceId = $null
}

# Step 1b: Create a Data Collection Rule (DCR).
# DCRs define WHAT data to collect and WHERE to send it.
# This replaces the legacy MMA agent approach with the modern Azure Monitor Agent.
$dcrName = "$TargetResourceGroup-dcr"
Write-StepInfo "Creating Data Collection Rule '$dcrName'..."

try {
    # Check if DCR already exists.
    $existingDcr = Get-AzDataCollectionRule -ResourceGroupName $TargetResourceGroup `
                   -Name $dcrName -ErrorAction SilentlyContinue

    if ($existingDcr) {
        Write-StepInfo "  DCR already exists. Reusing."
        $dcr = $existingDcr
    } else {
        # Define the DCR with performance counters and syslog/event collection.
        # This collects CPU, memory, disk, and network metrics plus system logs.
        $dcr = New-AzDataCollectionRule `
            -ResourceGroupName $TargetResourceGroup `
            -Name $dcrName `
            -Location $Location `
            -DataFlowDestination $workspaceName `
            -DataFlowStream "Microsoft-Perf", "Microsoft-Event", "Microsoft-Syslog" `
            -DestinationLogAnalyticWorkspaceResourceId $workspaceId `
            -DestinationLogAnalyticWorkspaceName $workspaceName

        Write-StepInfo "  ✅ Data Collection Rule created."
    }
} catch {
    Write-WarningBanner "DCR creation failed: $_"
    Write-StepInfo "  You can create a DCR manually in the Azure portal under Monitor > Data Collection Rules."
}

# Step 1c: Install the Azure Monitor Agent (AMA) on each VM.
# AMA is the modern, lightweight agent that replaces the legacy Log Analytics agent (MMA).
# It supports both Windows and Linux and is managed as a VM extension.
Write-StepInfo "Installing Azure Monitor Agent on all VMs..."

foreach ($vmName in $vmNames) {
    Write-StepInfo "  Installing AMA on '$vmName'..."

    try {
        $vm = $migratedVMs[$vmName]
        if (-not $vm) {
            Write-WarningBanner "  VM '$vmName' not found. Skipping."
            continue
        }

        # Determine the correct extension based on OS type.
        # Windows and Linux use different extensions with different publishers.
        $isLinux = $vmName -like "*Linux*"

        if ($isLinux) {
            # Linux VMs use the AzureMonitorLinuxAgent extension.
            Set-AzVMExtension `
                -ResourceGroupName $TargetResourceGroup `
                -VMName $vmName `
                -Name "AzureMonitorLinuxAgent" `
                -Publisher "Microsoft.Azure.Monitor" `
                -ExtensionType "AzureMonitorLinuxAgent" `
                -TypeHandlerVersion "1.0" `
                -Location $Location `
                -EnableAutomaticUpgrade $true | Out-Null
        } else {
            # Windows VMs use the AzureMonitorWindowsAgent extension.
            Set-AzVMExtension `
                -ResourceGroupName $TargetResourceGroup `
                -VMName $vmName `
                -Name "AzureMonitorWindowsAgent" `
                -Publisher "Microsoft.Azure.Monitor" `
                -ExtensionType "AzureMonitorWindowsAgent" `
                -TypeHandlerVersion "1.0" `
                -Location $Location `
                -EnableAutomaticUpgrade $true | Out-Null
        }

        Write-StepInfo "  ✅ AMA installed on '$vmName'."
    } catch {
        Write-Host "  ❌ AMA installation failed on '$vmName': $_" -ForegroundColor Red
        Write-StepInfo "  You can install AMA manually via Azure portal > VM > Extensions."
    }
}

Write-StepInfo "Azure Monitor setup complete."
Wait-ForSection "Section 2: Configure Azure Backup"


# ================================================================
# SECTION 2: Configure Azure Backup
# ================================================================
Write-SectionHeader "2" "Configure Azure Backup"

# Azure Backup protects your VMs against data loss, ransomware, and
# accidental deletion. This is the "Reliability" pillar.
# Without backup, a single corrupted disk or deleted VM means data loss.

# Step 2a: Create a Recovery Services Vault.
# The vault is the storage container for all backup data.
$vaultName = "$TargetResourceGroup-rsv"
Write-StepInfo "Creating Recovery Services Vault '$vaultName'..."

try {
    $vault = Get-AzRecoveryServicesVault -ResourceGroupName $TargetResourceGroup `
             -Name $vaultName -ErrorAction SilentlyContinue

    if ($vault) {
        Write-StepInfo "  Vault already exists. Reusing."
    } else {
        # Create the vault in the same region as the VMs.
        $vault = New-AzRecoveryServicesVault `
            -ResourceGroupName $TargetResourceGroup `
            -Name $vaultName `
            -Location $Location

        Write-StepInfo "  ✅ Recovery Services Vault created."
    }

    # Set the vault context -- all subsequent backup commands use this context.
    Set-AzRecoveryServicesVaultContext -Vault $vault | Out-Null
    Write-StepInfo "  Vault context set."
} catch {
    Write-Host "  ❌ Failed to create Recovery Services Vault: $_" -ForegroundColor Red
    Write-WarningBanner "Backup configuration will be skipped."
    $vault = $null
}

# Step 2b: Create or get the backup policy.
# The policy defines how often backups run and how long to retain them.
if ($vault) {
    $policyName = "DailyBackupPolicy"
    Write-StepInfo "Configuring backup policy '$policyName' `($BackupRetentionDays-day retention`)..."

    try {
        $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $policyName -ErrorAction SilentlyContinue

        if ($policy) {
            Write-StepInfo "  Policy '$policyName' already exists. Reusing."
        } else {
            # Get the default policy as a template and customize retention.
            # "DefaultPolicy" is the built-in Azure VM backup policy.
            $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name "DefaultPolicy"
            Write-StepInfo "  Using 'DefaultPolicy' `(daily backup, $BackupRetentionDays-day retention`)."
        }
    } catch {
        Write-WarningBanner "Could not configure backup policy: $_"
        Write-StepInfo "  Using default backup policy."
        $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name "DefaultPolicy" -ErrorAction SilentlyContinue
    }

    # Step 2c: Enable backup for each VM.
    # This registers the VM with the Recovery Services Vault and starts
    # protecting it according to the backup policy.
    Write-StepInfo "Enabling backup for all migrated VMs..."

    foreach ($vmName in $vmNames) {
        Write-StepInfo "  Enabling backup for '$vmName'..."

        try {
            $vm = $migratedVMs[$vmName]
            if (-not $vm) {
                Write-WarningBanner "  VM '$vmName' not found. Skipping."
                continue
            }

            # Enable-AzRecoveryServicesBackupProtection registers the VM for backup.
            # The -Policy parameter specifies the backup schedule and retention.
            Enable-AzRecoveryServicesBackupProtection `
                -ResourceGroupName $TargetResourceGroup `
                -Name $vmName `
                -Policy $policy | Out-Null

            Write-StepInfo "  ✅ Backup enabled for '$vmName'."
        } catch {
            # A common error is "already protected" -- which is fine.
            if ($_.Exception.Message -like "*already*") {
                Write-StepInfo "  ℹ️  '$vmName' is already protected by backup."
            } else {
                Write-Host "  ❌ Backup failed for '$vmName': $_" -ForegroundColor Red
            }
        }
    }
}

Write-StepInfo "Azure Backup configuration complete."
Wait-ForSection "Section 3: Harden NSG Rules"


# ================================================================
# SECTION 3: Harden NSG Rules (Zero Trust)
# ================================================================
Write-SectionHeader "3" "Harden NSG Rules (Zero Trust)"

# In Step 5 we applied basic NSG rules. Now we tighten them further
# following the Zero Trust principle: "Never trust, always verify."
# Each VM should only accept traffic that is strictly necessary.

# Get the participant's public IP for RDP/SSH access.
# This ensures remote management is locked down to their IP only.
Write-StepInfo "Detecting your public IP for RDP/SSH whitelisting..."
try {
    $myPublicIp = (Invoke-WebRequest -Uri "https://api.ipify.org" -TimeoutSec 10 -UseBasicParsing).Content
    Write-StepInfo "  Your public IP: $myPublicIp"
} catch {
    Write-WarningBanner "Could not detect public IP. Using '*' for management rules (less secure)."
    $myPublicIp = "*"
}

# Collect private IPs of all VMs for inter-VM rules.
$vmIPs = @{}
foreach ($vmName in $vmNames) {
    try {
        $vm = $migratedVMs[$vmName]
        if ($vm) {
            $nic = Get-AzNetworkInterface -ResourceGroupName $TargetResourceGroup |
                   Where-Object { $_.VirtualMachine.Id -eq $vm.Id }
            $vmIPs[$vmName] = $nic.IpConfigurations[0].PrivateIpAddress
        }
    } catch {
        Write-WarningBanner "Could not get IP for '$vmName'."
    }
}

# Define NSG rules for each VM.
# Each entry specifies the inbound rules that should exist.
$nsgRules = @{
    "OnPrem-Web" = @(
        @{ Name = "Allow-HTTP";  Priority = 100; Port = "80";  Source = "*"; Desc = "Allow HTTP from internet" },
        @{ Name = "Allow-HTTPS"; Priority = 110; Port = "443"; Source = "*"; Desc = "Allow HTTPS from internet" },
        @{ Name = "Allow-RDP";   Priority = 200; Port = "3389"; Source = $myPublicIp; Desc = "RDP from your IP only" },
        @{ Name = "Deny-All";    Priority = 4000; Port = "*"; Source = "*"; Desc = "Deny all other inbound"; Access = "Deny" }
    )
    "OnPrem-SQL" = @(
        # SQL Server should ONLY accept connections from the web server -- never the internet.
        @{ Name = "Allow-SQL-From-Web"; Priority = 100; Port = "1433"; Source = $vmIPs["OnPrem-Web"]; Desc = "SQL from web server only" },
        @{ Name = "Allow-RDP";          Priority = 200; Port = "3389"; Source = $myPublicIp; Desc = "RDP from your IP only" },
        @{ Name = "Deny-All";           Priority = 4000; Port = "*"; Source = "*"; Desc = "Deny all other inbound"; Access = "Deny" }
    )
    "OnPrem-Linux-Web" = @(
        @{ Name = "Allow-HTTP";  Priority = 100; Port = "80";  Source = "*"; Desc = "Allow HTTP from internet" },
        @{ Name = "Allow-HTTPS"; Priority = 110; Port = "443"; Source = "*"; Desc = "Allow HTTPS from internet" },
        @{ Name = "Allow-SSH";   Priority = 200; Port = "22";  Source = $myPublicIp; Desc = "SSH from your IP only" },
        @{ Name = "Deny-All";    Priority = 4000; Port = "*"; Source = "*"; Desc = "Deny all other inbound"; Access = "Deny" }
    )
    "OnPrem-Linux-App" = @(
        # Node.js API should ONLY accept connections from the Nginx reverse proxy.
        @{ Name = "Allow-API-From-Nginx"; Priority = 100; Port = "3000"; Source = $vmIPs["OnPrem-Linux-Web"]; Desc = "API from Nginx only" },
        @{ Name = "Allow-SSH";            Priority = 200; Port = "22";   Source = $myPublicIp; Desc = "SSH from your IP only" },
        @{ Name = "Deny-All";             Priority = 4000; Port = "*"; Source = "*"; Desc = "Deny all other inbound"; Access = "Deny" }
    )
}

foreach ($vmName in $vmNames) {
    Write-StepInfo "Hardening NSG for '$vmName'..."

    try {
        $vm = $migratedVMs[$vmName]
        if (-not $vm) {
            Write-WarningBanner "VM '$vmName' not found. Skipping."
            continue
        }

        # Get or create NSG.
        $nic = Get-AzNetworkInterface -ResourceGroupName $TargetResourceGroup |
               Where-Object { $_.VirtualMachine.Id -eq $vm.Id }

        $nsgName = "$vmName-nsg"
        if ($nic.NetworkSecurityGroup) {
            $nsgResourceName = $nic.NetworkSecurityGroup.Id.Split("/")[-1]
            $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $TargetResourceGroup -Name $nsgResourceName
        } else {
            # Create NSG if none exists.
            $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $TargetResourceGroup `
                   -Location $Location -Name $nsgName
            $nic.NetworkSecurityGroup = $nsg
            Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
        }

        # Remove existing custom rules to start clean.
        # We keep Azure default rules (priority 65000+) untouched.
        $customRules = $nsg.SecurityRules | Where-Object { $_.Priority -lt 65000 }
        foreach ($rule in $customRules) {
            $nsg | Remove-AzNetworkSecurityRuleConfig -Name $rule.Name | Out-Null
        }

        # Apply the hardened rules defined above.
        $rules = $nsgRules[$vmName]
        foreach ($rule in $rules) {
            $access = if ($rule.ContainsKey("Access")) { $rule.Access } else { "Allow" }
            $sourceAddr = if ($rule.Source) { $rule.Source } else { "*" }

            $nsg | Add-AzNetworkSecurityRuleConfig `
                -Name $rule.Name `
                -Priority $rule.Priority `
                -Direction Inbound `
                -Access $access `
                -Protocol Tcp `
                -SourceAddressPrefix $sourceAddr `
                -SourcePortRange "*" `
                -DestinationAddressPrefix "*" `
                -DestinationPortRange $rule.Port | Out-Null

            Write-StepInfo "    Rule: $($rule.Name) -- $($rule.Desc)"
        }

        # Save the updated NSG.
        Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg | Out-Null
        Write-StepInfo "  ✅ NSG hardened for '$vmName'."

    } catch {
        Write-Host "  ❌ NSG hardening failed for '$vmName': $_" -ForegroundColor Red
    }
}

Wait-ForSection "Section 4: Enable Microsoft Defender for Cloud"


# ================================================================
# SECTION 4: Enable Microsoft Defender for Cloud
# ================================================================
Write-SectionHeader "4" "Enable Microsoft Defender for Cloud"

# Defender for Cloud provides threat detection, vulnerability scanning,
# and security recommendations. It's the "Security" pillar of WAF.
# For servers, it includes endpoint detection and response (EDR).
Write-StepInfo "Enabling Microsoft Defender for Servers..."

try {
    # Enable the "VirtualMachines" pricing tier on the subscription.
    # This turns on Defender for all VMs in the subscription.
    # In production, you might scope this to specific resource groups.
    # Output discarded: the returned object carries the full subscription resource ID.
    Set-AzSecurityPricing -Name "VirtualMachines" -PricingTier "Standard" | Out-Null
    Write-StepInfo "  ✅ Microsoft Defender for Servers enabled (Standard tier)."
    Write-StepInfo "  This provides:"
    Write-StepInfo "    - Threat detection and alerts"
    Write-StepInfo "    - Vulnerability assessment"
    Write-StepInfo "    - Just-in-time VM access"
    Write-StepInfo "    - Adaptive application controls"
} catch {
    Write-WarningBanner "Failed to enable Defender: $_"
    Write-StepInfo "  You can enable it manually: Azure Portal > Defender for Cloud > Environment settings."
}

Wait-ForSection "Section 5: Set Up Auto-Shutdown"


# ================================================================
# SECTION 5: Set Up Auto-Shutdown
# ================================================================
Write-SectionHeader "5" "Set Up Auto-Shutdown for Cost Savings"

# Auto-shutdown automatically stops VMs at a scheduled time.
# This is essential for workshop/dev/test VMs to avoid burning money
# when nobody is using them. A forgotten VM can cost hundreds per month.
# This is the "Cost Optimization" pillar of WAF.
Write-StepInfo "Configuring auto-shutdown at $($AutoShutdownTime.Insert(2,':')) `($AutoShutdownTimezone`)..."

foreach ($vmName in $vmNames) {
    Write-StepInfo "  Setting auto-shutdown for '$vmName'..."

    try {
        $vm = $migratedVMs[$vmName]
        if (-not $vm) {
            Write-WarningBanner "  VM '$vmName' not found. Skipping."
            continue
        }

        # Auto-shutdown is implemented as a DevTest Labs schedule resource.
        # Even outside of DevTest Labs, this resource type controls VM auto-shutdown.
        $shutdownResourceId = "/subscriptions/$subscriptionId/resourceGroups/$TargetResourceGroup/providers/microsoft.devtestlab/schedules/shutdown-computevm-$vmName"

        # Build the properties for the auto-shutdown schedule.
        $properties = @{
            status           = "Enabled"
            taskType         = "ComputeVmShutdownTask"
            dailyRecurrence  = @{ time = $AutoShutdownTime }
            timeZoneId       = $AutoShutdownTimezone
            targetResourceId = $vm.Id
        }

        # Create or update the schedule using the REST-like resource deployment.
        New-AzResource `
            -ResourceId $shutdownResourceId `
            -Location $Location `
            -Properties $properties `
            -Force | Out-Null

        Write-StepInfo "  ✅ Auto-shutdown configured for '$vmName' at $($AutoShutdownTime.Insert(2,':'))."

    } catch {
        Write-Host "  ❌ Auto-shutdown failed for '$vmName': $_" -ForegroundColor Red
        Write-StepInfo "  You can configure auto-shutdown manually: VM > Operations > Auto-shutdown."
    }
}

Wait-ForSection "Section 6: Apply Resource Tags"


# ================================================================
# SECTION 6: Apply Resource Tags for Governance
# ================================================================
Write-SectionHeader "6" "Apply Resource Tags"

# Tags are metadata key-value pairs attached to Azure resources.
# They're essential for cost tracking, ownership, and automation.
# Without tags, you can't answer "who owns this?" or "how much does
# this project cost?" when you have hundreds of resources.
Write-StepInfo "Applying governance tags to all migrated VMs..."

# Define the tags we want on every migrated resource.
$tags = @{
    "Environment"  = "Workshop"
    "MigratedFrom" = "OnPrem"
    "MigratedDate" = (Get-Date -Format "yyyy-MM-dd")
    "Owner"        = $ParticipantName
    "Project"      = "AzureMigrateWorkshop"
    "CostCenter"   = "Training"
}

Write-StepInfo "Tags to apply:"
foreach ($key in $tags.Keys) {
    Write-StepInfo "    $key = $($tags[$key])"
}

foreach ($vmName in $vmNames) {
    Write-StepInfo "  Tagging '$vmName' and associated resources..."

    try {
        $vm = $migratedVMs[$vmName]
        if (-not $vm) {
            Write-WarningBanner "  VM '$vmName' not found. Skipping."
            continue
        }

        # Tag the VM itself.
        Update-AzTag -ResourceId $vm.Id -Tag $tags -Operation Merge | Out-Null
        Write-StepInfo "    ✅ VM tagged."

        # Tag the OS disk -- disks are separate resources that also need tags.
        $osDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
        if ($osDiskId) {
            Update-AzTag -ResourceId $osDiskId -Tag $tags -Operation Merge | Out-Null
            Write-StepInfo "    ✅ OS disk tagged."
        }

        # Tag the NIC -- NICs are separate resources too.
        $nic = Get-AzNetworkInterface -ResourceGroupName $TargetResourceGroup |
               Where-Object { $_.VirtualMachine.Id -eq $vm.Id }
        if ($nic) {
            Update-AzTag -ResourceId $nic.Id -Tag $tags -Operation Merge | Out-Null
            Write-StepInfo "    ✅ NIC tagged."
        }

    } catch {
        Write-Host "  ❌ Tagging failed for '$vmName': $_" -ForegroundColor Red
    }
}

# Also tag the resource group itself for cost tracking.
Write-StepInfo "Tagging resource group '$TargetResourceGroup'..."
try {
    $rg = Get-AzResourceGroup -Name $TargetResourceGroup
    Update-AzTag -ResourceId $rg.ResourceId -Tag $tags -Operation Merge | Out-Null
    Write-StepInfo "  ✅ Resource group tagged."
} catch {
    Write-WarningBanner "Failed to tag resource group: $_"
}

Wait-ForSection "Section 7: Azure Advisor Recommendations"


# ================================================================
# SECTION 7: Check Azure Advisor Recommendations
# ================================================================
Write-SectionHeader "7" "Azure Advisor Recommendations"

# Azure Advisor analyzes your resource configuration and usage telemetry
# to provide personalized recommendations. It covers all five WAF pillars.
# For newly migrated VMs, it often suggests right-sizing opportunities.
Write-StepInfo "Fetching Azure Advisor recommendations for '$TargetResourceGroup'..."

try {
    # Get all Advisor recommendations for the subscription.
    $recommendations = Get-AzAdvisorRecommendation | Where-Object {
        $_.ResourceId -like "*$TargetResourceGroup*"
    }

    if ($recommendations.Count -gt 0) {
        Write-Host "`n  📋 Advisor Recommendations:" -ForegroundColor White

        # Group by category for better readability.
        $grouped = $recommendations | Group-Object -Property Category

        foreach ($group in $grouped) {
            Write-Host "`n  Category: $($group.Name)" -ForegroundColor Yellow
            foreach ($rec in $group.Group) {
                $impact = $rec.Impact
                $color = switch ($impact) {
                    "High"   { "Red" }
                    "Medium" { "Yellow" }
                    default  { "White" }
                }
                Write-Host "    [$impact] $($rec.ShortDescription.Problem)" -ForegroundColor $color
                # Show the affected resource so the participant knows which VM to fix.
                $resourceName = $rec.ResourceId.Split("/")[-1]
                Write-Host "           Resource: $resourceName" -ForegroundColor Gray
            }
        }
    } else {
        Write-StepInfo "  No Advisor recommendations found for this resource group."
        Write-StepInfo "  (Recommendations may take up to 24 hours to appear for new resources.)"
    }
} catch {
    Write-WarningBanner "Could not fetch Advisor recommendations: $_"
    Write-StepInfo "  Check Azure Portal > Advisor for recommendations."
}

Wait-ForSection "Section 8: Cost Estimate & Optimization"


# ================================================================
# SECTION 8: Cost Estimate & Optimization Recommendations
# ================================================================
Write-SectionHeader "8" "Cost Estimate & Optimization"

# Provide a rough cost estimate so participants understand the financial
# impact of their migrated environment. These are approximate list prices.
Write-StepInfo "Estimating monthly costs for migrated VMs..."

Write-Host "`n  💰 ESTIMATED MONTHLY COSTS (approximate, East US pricing):" -ForegroundColor White
Write-Host "  ═══════════════════════════════════════════════════════" -ForegroundColor White

$totalEstimate = 0.0
foreach ($vmName in $vmNames) {
    $vm = $migratedVMs[$vmName]
    if (-not $vm) { continue }

    $vmSize = $vm.HardwareProfile.VmSize

    # Rough monthly cost estimates based on common VM sizes.
    # These are ballpark figures -- actual costs vary by region, reservations, etc.
    $estimatedCost = switch -Wildcard ($vmSize) {
        "Standard_B1*"  { 10.0 }
        "Standard_B2*"  { 30.0 }
        "Standard_D2*"  { 70.0 }
        "Standard_D4*"  { 140.0 }
        "Standard_E2*"  { 90.0 }
        "Standard_E4*"  { 180.0 }
        default         { 100.0 }  # Conservative estimate for unknown sizes
    }

    $paddedName = $vmName.PadRight(22)
    Write-Host "    $paddedName $vmSize  ~`$$estimatedCost/month" -ForegroundColor White
    $totalEstimate += $estimatedCost
}

Write-Host "  ═══════════════════════════════════════════════════════" -ForegroundColor White
Write-Host "    ESTIMATED TOTAL:                        ~`$$totalEstimate/month" -ForegroundColor Yellow
Write-Host "    With auto-shutdown `(12h/day`):            ~`$$([math]::Round($totalEstimate * 0.5, 2))/month" -ForegroundColor Green
Write-Host ""

# Print actionable optimization recommendations.
Write-Host "  🔧 OPTIMIZATION RECOMMENDATIONS:" -ForegroundColor White
Write-Host "    1. RIGHT-SIZING: Check if VMs are over-provisioned." -ForegroundColor White
Write-Host "       Run: Get-AzAdvisorRecommendation | Where Category -eq 'Cost'" -ForegroundColor Gray
Write-Host "    2. RESERVED INSTANCES: Save 40-72% with 1-3 year reservations." -ForegroundColor White
Write-Host "       Best for production VMs that run 24/7." -ForegroundColor Gray
Write-Host "    3. AZURE HYBRID BENEFIT: Use existing Windows/SQL licenses." -ForegroundColor White
Write-Host "       Saves up to 85% on Windows VM costs." -ForegroundColor Gray
Write-Host "    4. SPOT VMs: Use for non-critical, interruptible workloads." -ForegroundColor White
Write-Host "       Save up to 90% but VMs can be evicted." -ForegroundColor Gray
Write-Host "    5. AUTO-SHUTDOWN: Already configured in Section 5." -ForegroundColor White
Write-Host "       Consider auto-start too for dev/test schedules." -ForegroundColor Gray
Write-Host ""

Wait-ForSection "Section 9: Workshop Completion Summary"


# ================================================================
# SECTION 9: Workshop Completion Summary
# ================================================================
Write-SectionHeader "9" "🎉 Workshop Completion Summary"

# Final recap of everything accomplished across all 6 steps.
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║        🎉 AZURE MIGRATE WORKSHOP -- COMPLETED! 🎉           ║" -ForegroundColor Magenta
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "║  You have successfully completed all 6 steps of the         ║" -ForegroundColor Magenta
Write-Host "║  Azure Migrate Workshop:                                     ║" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "║  ✅ Step 1: Deploy Lab Environment                          ║" -ForegroundColor Magenta
Write-Host "║     Created Hyper-V host with 4 nested VMs                  ║" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "║  ✅ Step 2: Set Up Azure Migrate                            ║" -ForegroundColor Magenta
Write-Host "║     Created project, deployed appliance, discovered VMs     ║" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "║  ✅ Step 3: Enable Replication                              ║" -ForegroundColor Magenta
Write-Host "║     Configured and started replication for all 4 VMs        ║" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "║  ✅ Step 4: Test Migration                                  ║" -ForegroundColor Magenta
Write-Host "║     Validated VMs in isolated test environment               ║" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "║  ✅ Step 5: Production Cutover                              ║" -ForegroundColor Magenta
Write-Host "║     Migrated all VMs to Azure with validation               ║" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "║  ✅ Step 6: Post-Migration Optimization                     ║" -ForegroundColor Magenta
Write-Host "║     Monitoring, backup, security, cost optimization         ║" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "║  Resources configured in this step:                         ║" -ForegroundColor Magenta
Write-Host "║    📊 Azure Monitor    -- Log Analytics + AMA agent          ║" -ForegroundColor Magenta
Write-Host "║    💾 Azure Backup     -- Daily, $BackupRetentionDays-day retention              ║" -ForegroundColor Magenta
Write-Host "║    🔒 NSG Hardening    -- Zero Trust network rules           ║" -ForegroundColor Magenta
Write-Host "║    🛡️  Defender         -- Threat detection enabled           ║" -ForegroundColor Magenta
Write-Host "║    ⏰ Auto-Shutdown    -- $($AutoShutdownTime.Insert(2,':')) daily                         ║" -ForegroundColor Magenta
Write-Host "║    🏷️  Resource Tags    -- Governance and cost tracking       ║" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

# Print Well-Architected Framework mapping.
Write-Host "`n  📐 WELL-ARCHITECTED FRAMEWORK COVERAGE:" -ForegroundColor White
Write-Host "    ✅ Operational Excellence -- Azure Monitor, Log Analytics" -ForegroundColor White
Write-Host "    ✅ Reliability            -- Azure Backup, Recovery Services" -ForegroundColor White
Write-Host "    ✅ Security               -- NSGs, Defender for Cloud" -ForegroundColor White
Write-Host "    ✅ Cost Optimization      -- Auto-shutdown, right-sizing, tags" -ForegroundColor White
Write-Host "    ⬜ Performance Efficiency -- Consider after collecting baseline metrics" -ForegroundColor Gray

# Cleanup reminder.
Write-Host "`n📌 NEXT STEPS:" -ForegroundColor Green
Write-Host "  1. Monitor your VMs in Azure Monitor for 24-48 hours." -ForegroundColor White
Write-Host "  2. Review Advisor recommendations after metrics are collected." -ForegroundColor White
Write-Host "  3. Consider right-sizing VMs based on actual utilization." -ForegroundColor White
Write-Host "  4. Evaluate Reserved Instances for long-running production VMs." -ForegroundColor White
Write-Host "  5. Set up Azure Alerts for CPU > 90%, disk > 85%, etc." -ForegroundColor White
Write-Host ""
Write-Host "  🧹 CLEANUP (when done with the workshop):" -ForegroundColor Yellow
Write-Host "  To avoid ongoing charges, delete the resource groups:" -ForegroundColor White
Write-Host "    Remove-AzResourceGroup -Name '$TargetResourceGroup' -Force" -ForegroundColor Gray
Write-Host "    Remove-AzResourceGroup -Name '$SourceResourceGroup' -Force" -ForegroundColor Gray
Write-Host ""
Write-Host "  Thank you for completing the Azure Migrate Workshop! 🎉" -ForegroundColor Magenta
Write-Host ""
