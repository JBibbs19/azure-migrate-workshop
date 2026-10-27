<#
.SYNOPSIS
    Step 3: Read-only Hyper-V replication preflight and supported portal handoff.

.DESCRIPTION
    Checks the requested workload group, target sizing, discovered Hyper-V identities
    and installed command contracts without changing Azure resources.

    The published Az.Migrate replication API uses VMwareCbt inputs, not Hyper-V VMs.
    Az.RecoveryServices supports Hyper-V disaster recovery, but using that DR API against
    an Azure Migrate-created vault is not a verified migration contract for this lab.
    Therefore this iteration fails closed and gives the supported Azure Migrate portal
    replication and selected-set monitoring path. It never guesses ResourceName, creates
    a vault, installs a module/provider, or reports replication ready from a submitted job.

    A nonzero exit means the automated Step 3 did NOT complete. No replication writes,
    test migration, test cleanup, cutover or source shutdown are performed. Complete
    replication and monitoring in the portal; verify support separately before using
    the Step 4/5 scripts with Hyper-V. Keep both pairs on this same Hyper-V engine; test all four before one coordinated cutover in Module 3 section 11.

    Prerequisites: complete Steps 1/2, register the Hyper-V provider using the documented
    portal workflow, and review Step 1's actual SKU/provider/quota guards with the same
    selected target region. AutoCost guidance is recalculated from live metadata, prices and quota.

.PARAMETER SourceResourceGroup
    The on-premises simulation resource group. Prompted when not supplied (example: rg-ces-source-01).

.PARAMETER TargetResourceGroup
    The target cloud resource group. Prompted when not supplied (example: rg-ces-target-01).

.PARAMETER Location
    Uses the actual target VNet region, never RG metadata. Explicit mismatch stops before writes.
    Azure region. Prompted when not supplied (example: eastus).

.PARAMETER MigrateProjectName
    Name of the Azure Migrate project. Prompted when not supplied (example: ces-migrate-01).

.PARAMETER VaultResourceId
    Optional exact existing Recovery Services vault ARM ID in the selected subscription.
    Conflicting active project references block selection; no vault is created.

.PARAMETER VaultResourceGroup
    Resource group inspected for fallback vault candidates (defaults to SourceResourceGroup).
    Even a single candidate requires student selection; names/tags never prove association.

.PARAMETER RecoveryServicesProviderId
    Optional exact registered provider ARM ID, including fabric, inside the selected vault.
    GET-only identity/connection inspection; no provider installation or registration runs.

.PARAMETER ReportPath
    Optional new JSON report path. Existing files are never overwritten. The default is a
    unique file in the current directory, including on early failure when the path is writable.
    Inventory is not replication readiness or cutover authorization.

.PARAMETER Workload
    All selects four VMs; Agentless selects OnPrem-Web and OnPrem-Linux-Web;
    AgentBased (also Agent-based) selects OnPrem-SQL and OnPrem-Linux-App.
    Names are workload groups only. Later steps must use this SAME normalized value.

.PARAMETER TargetVmSizes
    Optional exact four-key mapping: OnPrem-Web, OnPrem-SQL, OnPrem-Linux-Web and
    OnPrem-Linux-App to exact eligible SKU strings. Revalidated against live subscription
    metadata, RAM and combined quotas. Omit to choose a number for each workload;
    blank cancels the entire selection. Prices may be unavailable, never a quota bypass.

.EXAMPLE
    .\migrate-step3-replicate.ps1

.EXAMPLE
    .\migrate-step3-replicate.ps1 -TargetResourceGroup "mycloud-rg" -Location "westus2"
MODULE COVERAGE
    -Workload Agentless: Module 2, sections 5-7 (replication and monitoring).
    -Workload AgentBased: Module 3, sections 8-9 (replication and monitoring).
    -Workload All: both selected groups, four VMs. Agent-based is accepted as AgentBased.

    These names select workload groups, not different replication technologies. This lab
    uses Hyper-V host-based replication. It does not deploy a replication appliance or
    install Mobility Service in the guests for Module 3 sections 5-7.
    Tests and final migration remain manual; hold all four sources for one coordinated final window in Module 3 section 11.
    This script never performs test migration, test cleanup, cutover or source shutdown.
#>

[CmdletBinding()]
param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [string]$Location,

    [string]$MigrateProjectName,

    [string]$VaultResourceId,

    [string]$VaultResourceGroup,

    [string]$RecoveryServicesProviderId,

    [string]$ReportPath,

    [hashtable]$TargetVmSizes,

    # Historical workload-group labels, not replication methods. All use Hyper-V.
    # Agentless = Web/Linux-Web; AgentBased (or Agent-based) = SQL/App; All = four.
    [string]$Workload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:LabRetailCache = @{}
$script:LabReplicationStage = 'environment-preflight'

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

function Format-LabSafeErrorDiagnostic {
    param([AllowNull()]$ErrorRecord, [AllowNull()][AllowEmptyString()][string]$Stage)
    $safeStage = 'unclassified'
    if ($Stage -in @('environment-preflight', 'authentication/Connect-AzAccount', 'installed-command-contracts',
        'target-resource-group/Get-AzResourceGroup', 'target-network/Get-AzVirtualNetwork', 'project/REST',
        'project-inventory/REST', 'project-solutions/REST', 'vault-list/REST', 'vault/REST', 'providers/REST', 'replication-inventory/REST', 'target-sizing/preflight',
        'source-inventory/Get-AzMigrateDiscoveredServer', 'backend-contract')) { $safeStage = $Stage }
    $exceptionType = 'OtherOrUnknownException'; $category = 'NotSpecified'; $lineNumber = 0
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        if ($null -ne $ErrorRecord.Exception) {
            $candidate = $ErrorRecord.Exception.GetType().FullName
            if ($candidate -in @('System.Exception', 'System.InvalidOperationException', 'System.ArgumentException',
                'System.ArgumentNullException', 'System.Management.Automation.RuntimeException',
                'System.Management.Automation.ParameterBindingException', 'System.Management.Automation.CommandNotFoundException')) {
                $exceptionType = $candidate
            }
        }
        $categoryName = [Enum]::GetName([System.Management.Automation.ErrorCategory], $ErrorRecord.CategoryInfo.Category)
        if ($null -ne $categoryName) { $category = $categoryName }
        $invocation = $ErrorRecord.InvocationInfo
        if ($null -ne $invocation -and $invocation.ScriptLineNumber -is [int] -and
            $invocation.ScriptLineNumber -ge 0 -and $invocation.ScriptLineNumber -le 1000000) {
            $lineNumber = $invocation.ScriptLineNumber
        }
    }
    return @(
        'Step 3 stopped. No replication writes were attempted.'
        "Stage: $safeStage"
        "Category: $category"
        "Exception type: $exceptionType"
        "Script line: $lineNumber"
        'Raw error text, statements, inputs, stack and resource IDs are intentionally omitted.'
    )
}

function Write-LabTerminatingError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    foreach ($line in @(Format-LabSafeErrorDiagnostic -ErrorRecord $ErrorRecord -Stage $script:LabReplicationStage)) {
        Microsoft.PowerShell.Utility\Write-Host $line -ForegroundColor Red
    }
    Microsoft.PowerShell.Utility\Write-Host 'Manual course path: Modules 2 and 3 use the same existing Hyper-V host provider for all four workloads. Hold one coordinated final cutover for Module 3 section 11. No readiness is assumed.' -ForegroundColor Yellow
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
    catch { throw '[resource-group-inventory/Get-AzResourceGroup] Read failed; resource absence was not established. No changes were made.' }
}

function Get-LabVMNames {
    param([Parameter(Mandatory = $true)][string]$ResourceGroupName)
    try { return @(Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Select-Object -ExpandProperty Name | Sort-Object) }
    catch { return @() }
}

function Get-LabMigrateProjectNames {
    param([Parameter(Mandatory = $true)][string]$ResourceGroupName)
    $script:LabReplicationStage = 'project-inventory/REST'
    $null = ConvertTo-LabReplicationArmId -Value "/subscriptions/$script:LabSubscriptionId/resourceGroups/$ResourceGroupName" -Stage $script:LabReplicationStage -ResourceType 'Microsoft.Resources/resourceGroups' -SubscriptionId $script:LabSubscriptionId
    $inventory = Get-LabArmCollection "/subscriptions/$script:LabSubscriptionId/resourceGroups/$ResourceGroupName/resources" '2021-04-01'
    if (-not $inventory.Complete) { throw '[project-inventory/REST] Inventory Unknown; project absence was not established.' }
    $names = @()
    foreach ($resource in $inventory.Items) {
        if ((Get-LabReplicationField $resource 'type') -ine 'Microsoft.Migrate/migrateProjects') { continue }
        $id = Get-LabReplicationObjectId $resource 'project-inventory/REST' 'Microsoft.Migrate/migrateProjects' $script:LabSubscriptionId
        if ($id.Split('/')[4] -ine $ResourceGroupName) { throw '[project-inventory/REST] Project inventory scope mismatch.' }
        $names += $id.Split('/')[-1]
    }
    return @($names | Sort-Object -Unique)
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
        try { $group = Get-AzResourceGroup -Name $entry -ErrorAction Stop }
        catch { throw '[resource-group/Get-AzResourceGroup] Read failed; resource absence was not established. Verify the group and access in the portal. No changes were made.' }

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

# Explicit-version ARM reads only. A learner-selected vault is not proof of project binding.
function Get-LabArmFailure {
    param([AllowNull()]$ErrorRecord, [int]$StatusCode = 0, [AllowNull()]$Body)
    if ($StatusCode -eq 0 -and $null -ne $ErrorRecord) {
        $response = Get-LabReplicationField (Get-LabReplicationField $ErrorRecord 'Exception') 'Response'
        $candidate = Get-LabReplicationField $response 'StatusCode'
        $number = 0
        if ($candidate -is [Enum]) { try { $number = [int]$candidate } catch { $number = 0 } }
        elseif ($null -ne $candidate) { $null = [int]::TryParse([string]$candidate, [ref]$number) }
        if ($number -ge 100 -and $number -le 599) { $StatusCode = $number }
    }
    $code = 'Unknown'
    if ($null -ne $Body) {
        $candidate = Get-LabReplicationField (Get-LabReplicationField $Body 'error') 'code' -PreserveCollection
        if ($candidate -is [string] -and $candidate -in @('AuthorizationFailed', 'ResourceNotFound', 'ResourceGroupNotFound', 'InvalidApiVersionParameter', 'NoRegisteredProviderFound', 'MissingSubscriptionRegistration', 'TooManyRequests')) { $code = $candidate }
    }
    if ($StatusCode -lt 100 -or $StatusCode -gt 599) { $StatusCode = 0 }
    return [pscustomobject]@{ HttpStatus = $StatusCode; ServiceCode = $code }
}

function Get-LabArmEndpoint {
    $context = Get-AzContext -ErrorAction Stop
    $endpoint = Get-LabReplicationField (Get-LabReplicationField $context 'Environment') 'ResourceManagerUrl' -PreserveCollection
    $uri = $null
    if ($endpoint -isnot [string] -or -not [uri]::TryCreate($endpoint, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/' -or -not $uri.IsDefaultPort) {
        throw '[arm-read] The active Azure ARM endpoint could not be validated. No changes were made.'
    }
    return $uri.GetLeftPart([UriPartial]::Authority)
}

function Test-LabArmPageUri {
    param([string]$Value, [string]$CollectionPath, [string]$ApiVersion, [string]$Endpoint)
    $uri = $null; $root = [uri]$Endpoint
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\\\s#%](?![0-9A-Fa-f]{2})' -or
        -not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -cne 'https' -or $uri.Authority -ine $root.Authority -or $uri.UserInfo -or $uri.Fragment -or
        $uri.AbsolutePath -ine $CollectionPath -or $Value.Split('?')[0] -ine ($Endpoint.TrimEnd('/') + $CollectionPath)) { return $false }
    $versions = 0
    foreach ($part in $uri.Query.TrimStart('?').Split('&')) {
        $pair = $part.Split('=', 2)
        if ($pair.Count -ne 2 -or [string]::IsNullOrEmpty($pair[1])) { return $false }
        if ($pair[0] -ieq 'api-version') { if ($pair[1] -cne $ApiVersion) { return $false }; $versions++ }
        elseif ($pair[0] -notmatch '^(?i:\$?skiptoken|continuationtoken|\$skip)$') { return $false }
    }
    return ($versions -eq 1)
}

function Invoke-LabArmGet {
    param([string]$Uri)
    try { $response = Invoke-AzRestMethod -Uri $Uri -Method GET -ErrorAction Stop }
    catch { return [pscustomobject]@{ Success = $false; Body = $null; Failure = (Get-LabArmFailure -ErrorRecord $_); Reason = 'ReadFailed' } }
    $status = 0
    $statusValue = Get-LabReplicationField $response 'StatusCode'
    $null = [int]::TryParse([string]$statusValue, [ref]$status)
    $body = $null
    try { $body = ConvertFrom-Json -InputObject (Get-LabReplicationField $response 'Content') -ErrorAction Stop } catch { }
    if ($status -ne 200 -or $null -eq $body -or $body -is [array] -or $body -is [string] -or $body -is [ValueType]) {
        return [pscustomobject]@{ Success = $false; Body = $null; Failure = (Get-LabArmFailure -StatusCode $status -Body $body); Reason = 'HttpOrShapeInvalid' }
    }
    return [pscustomobject]@{ Success = $true; Body = $body; Failure = $null; Reason = 'Observed' }
}

function Get-LabArmCollection {
    param([string]$Path, [string]$ApiVersion)
    $endpoint = Get-LabArmEndpoint
    $uri = $endpoint + $Path + '?api-version=' + $ApiVersion
    $items = @(); $seen = @{}; $complete = $false; $reason = 'PagingIncomplete'; $failure = $null
    for ($page = 0; $page -lt 200; $page++) {
        if (-not (Test-LabArmPageUri $uri $Path $ApiVersion $endpoint) -or $seen.ContainsKey($uri)) { $reason = 'PagingUnsafe'; break }
        $seen[$uri] = $true
        $read = Invoke-LabArmGet -Uri $uri
        if (-not $read.Success) { $reason = $read.Reason; $failure = $read.Failure; break }
        $property = $read.Body.PSObject.Properties['value']
        if ($null -eq $property -or $property.Value -isnot [array]) { $reason = 'CollectionShapeInvalid'; break }
        $rows = $property.Value
        $malformed = $false
        foreach ($row in $rows) {
            if ($null -eq $row -or $row -is [array] -or $row -is [string] -or $row -is [ValueType]) { $malformed = $true; break }
        }
        if ($malformed) { $reason = 'CollectionElementInvalid'; break }
        $items += $rows
        $next = $read.Body.PSObject.Properties['nextLink']
        if ($null -eq $next -or $null -eq $next.Value -or ($next.Value -is [string] -and [string]::IsNullOrWhiteSpace($next.Value))) { $complete = $true; $reason = 'Complete'; break }
        if ($next.Value -isnot [string]) { $reason = 'PagingShapeInvalid'; break }
        $uri = $next.Value
    }
    # Partial pages never become an empty or authoritative inventory.
    if (-not $complete) { $items = @() }
    return [pscustomobject]@{ Complete = $complete; Items = @($items); Reason = $reason; Failure = $failure }
}

function Get-LabMigrateProjectRead {
    param([string]$ResourceGroupName, [string]$Name)
    $id = ConvertTo-LabReplicationArmId -Value "/subscriptions/$script:LabSubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Migrate/migrateProjects/$Name" -Stage 'project/REST' -ResourceType 'Microsoft.Migrate/migrateProjects' -SubscriptionId $script:LabSubscriptionId
    $read = Invoke-LabArmGet -Uri ((Get-LabArmEndpoint) + $id + '?api-version=2018-09-01-preview')
    if (-not $read.Success) { throw '[project/REST] Project read failed; absence was not established. No changes were made.' }
    $actual = Get-LabReplicationObjectId $read.Body 'project/REST' 'Microsoft.Migrate/migrateProjects' $script:LabSubscriptionId
    if ($actual -ine $id -or (Get-LabReplicationField $read.Body 'type') -ine 'Microsoft.Migrate/migrateProjects') { throw '[project/REST] Project identity/type mismatch. No changes were made.' }
    return $read.Body
}

function Get-LabProjectVaultAssociation {
    param($Inventory, [string]$ProjectId, [string]$SubscriptionId)
    $references = @(); $unsafe = -not $Inventory.Complete; $activeCount = 0; $summaries = @()
    foreach ($solution in $Inventory.Items) {
        try {
            $id = Get-LabReplicationObjectId $solution 'project-solutions/REST' 'Microsoft.Migrate/migrateProjects/solutions' $SubscriptionId
            if (-not $id.StartsWith(($ProjectId + '/solutions/'), [StringComparison]::OrdinalIgnoreCase)) { throw '[project-solutions/REST] Wrong project.' }
            $properties = Get-LabReplicationField $solution 'properties' -PreserveCollection
            $goal = Get-LabReplicationField $properties 'goal' -PreserveCollection
            $purpose = Get-LabReplicationField $properties 'purpose' -PreserveCollection
            $status = Get-LabReplicationField $properties 'status' -PreserveCollection
            if ($goal -isnot [string] -or $purpose -isnot [string] -or $status -isnot [string]) { $unsafe = $true; continue }
            $active = ($goal -ceq 'Servers' -and $purpose -ceq 'Migration' -and $status -ceq 'Active')
            $referenceState = 'IgnoredInactiveOrOtherTool'
            if ($active) {
                $activeCount++; $referenceState = 'NoReference'
                $details = Get-LabReplicationField $properties 'details' -PreserveCollection
                $extended = Get-LabReplicationField $details 'extendedDetails' -PreserveCollection
                if ($null -ne $extended -and $extended -isnot [array] -and $extended -isnot [string]) {
                    $property = $extended.PSObject.Properties['vaultId']
                    if ($null -ne $property) {
                        # Read directly under the presence guard; do not pipeline-unroll a one-element array.
                        $link = $extended.PSObject.Properties['vaultId'].Value
                        if ($link -is [string] -and [string]::IsNullOrWhiteSpace($link)) { $referenceState = 'NoReference' }
                        else {
                            $referenceState = 'Malformed'; $valid = $null
                            try { $valid = ConvertTo-LabReplicationArmId $link 'project-solutions/vault-reference' 'Microsoft.RecoveryServices/vaults' $SubscriptionId } catch { $unsafe = $true }
                            if ($null -ne $valid) { $references += $valid; $referenceState = 'ValidReference' }
                        }
                    }
                } elseif ($null -ne $extended) { $unsafe = $true; $referenceState = 'Malformed' }
            }
            $summaries += [pscustomobject]@{ Id = $id; IsActiveServerMigration = $active; ReferenceState = $referenceState }
        } catch { $unsafe = $true }
    }
    $unique = @($references | Sort-Object -Unique)
    $state = 'Unknown'; $source = 'None'; $vaultId = $null; $reason = 'NoValidatedActiveReference'
    if ($unique.Count -gt 1) { $reason = 'ConflictingActiveReferences' }
    elseif ($unsafe) { $reason = 'ReadOrShapeUnknown' }
    elseif ($unique.Count -eq 1) { $state = 'AzureVerified'; $source = 'AzureVerified'; $vaultId = $unique[0]; $reason = 'UniqueActiveServiceReference' }
    return [pscustomobject]@{ State = $state; AssociationSource = $source; VaultId = $vaultId; Reason = $reason; Complete = $Inventory.Complete; ActiveServerMigrationCount = $activeCount; ValidReferences = @($unique); Solutions = @($summaries) }
}

function Get-LabVaultSafeText {
    param([AllowNull()]$Value)
    if ($Value -is [string] -and $Value.Length -le 160 -and $Value -match '^[A-Za-z0-9 ._():/+\-]+$') { return $Value }
    return 'Unknown'
}

function Get-LabVaultCandidate {
    param($Object, [string]$SubscriptionId)
    $id = Get-LabReplicationObjectId $Object 'vault/REST' 'Microsoft.RecoveryServices/vaults' $SubscriptionId
    if ((Get-LabReplicationField $Object 'type') -ine 'Microsoft.RecoveryServices/vaults') { throw '[vault/REST] Vault type mismatch.' }
    $properties = Get-LabReplicationField $Object 'properties' -PreserveCollection
    return [pscustomobject]@{ Id = $id; Name = $id.Split('/')[-1]; Location = (Get-LabVaultSafeText (Get-LabReplicationField $Object 'location' -PreserveCollection)); ProvisioningState = (Get-LabVaultSafeText (Get-LabReplicationField $properties 'provisioningState' -PreserveCollection)) }
}

function Select-LabVaultInventoryEntry {
    param([object[]]$Entries, [string]$Label)
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        Write-Host "  [$($i + 1)] $($Entries[$i].Name) | $($Entries[$i].Summary) | $($Entries[$i].Id)"
    }
    while ($true) {
        $answer = Read-Host "$Label number (blank cancels; no default or inferred project binding)"
        if ([string]::IsNullOrWhiteSpace($answer)) { throw '[Cancelled] Read-only inventory selection cancelled. No changes were made.' }
        $number = 0
        if ($answer -match '^[0-9]+$' -and [int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Entries.Count) { return $Entries[$number - 1].Id }
        Write-Warning "Enter a number from 1 to $($Entries.Count), or blank to cancel."
    }
}

function Get-LabProviderProjection {
    param($Object, [string]$VaultId, [string]$SubscriptionId)
    $id = Get-LabReplicationObjectId $Object 'providers/REST' 'Microsoft.RecoveryServices/vaults/replicationFabrics/replicationRecoveryServicesProviders' $SubscriptionId
    if (-not $id.StartsWith(($VaultId + '/replicationFabrics/'), [StringComparison]::OrdinalIgnoreCase)) { throw '[providers/REST] Provider belongs to another vault.' }
    if ((Get-LabReplicationField $Object 'type') -ine 'Microsoft.RecoveryServices/vaults/replicationFabrics/replicationRecoveryServicesProviders') { throw '[providers/REST] Provider type mismatch.' }
    $properties = Get-LabReplicationField $Object 'properties' -PreserveCollection
    $connection = Get-LabReplicationField $properties 'connectionStatus' -PreserveCollection
    if ($connection -isnot [string] -or $connection -cnotin @('Connected', 'Disconnected', 'NotConnected')) { $connection = 'Unknown' }
    $heartbeat = Get-LabReplicationField $properties 'lastHeartBeat' -PreserveCollection
    $date = ConvertTo-LabVaultUtcTime $heartbeat
    $timestamp = $null; $age = $null
    if ($null -ne $date) {
        $timestamp = $date.ToString('o'); $age = [math]::Round(([DateTimeOffset]::UtcNow - $date).TotalSeconds)
    }
    return [pscustomobject]@{ Id = $id; Name = (Get-LabVaultSafeText (Get-LabReplicationField $properties 'friendlyName' -PreserveCollection)); CurrentConnection = $connection; Connected = ($connection -ceq 'Connected'); LastHeartBeatUtc = $timestamp; HeartBeatAgeSeconds = $age; ProviderVersion = (Get-LabVaultSafeText (Get-LabReplicationField $properties 'providerVersion' -PreserveCollection)); FabricType = (Get-LabVaultSafeText (Get-LabReplicationField $properties 'fabricType' -PreserveCollection)) }
}

function Get-LabReplicationInventoryProjection {
    param($Inventory, [string]$VaultId, [string]$SubscriptionId, [string]$ProviderId, [ValidateSet('Items', 'Jobs')][string]$Kind)
    $scope = if ($Kind -eq 'Jobs') { 'VaultScopedProviderAttributionUnknown' } elseif ($ProviderId) { 'ExactProviderFiltered' } else { 'VaultScoped' }
    $result = [ordered]@{ Complete = $Inventory.Complete; Reason = $Inventory.Reason; Failure = $Inventory.Failure; ObservedCount = $null; ProviderFilterId = $ProviderId; Scope = $scope; MatchingProviderCount = 0; UnattributedCount = 0; Items = @(); SourceIdentityMapping = 'NotVerified'; Readiness = 'NotVerified' }
    if (-not $Inventory.Complete) { return [pscustomobject]$result }
    $safe = @(); $unattributed = 0; $matching = 0
    try {
        foreach ($item in $Inventory.Items) {
            $type = if ($Kind -eq 'Items') { 'Microsoft.RecoveryServices/vaults/replicationFabrics/replicationProtectionContainers/replicationProtectedItems' } else { 'Microsoft.RecoveryServices/vaults/replicationJobs' }
            $id = Get-LabReplicationObjectId $item 'replication-inventory/REST' $type $SubscriptionId
            if (-not $id.StartsWith(($VaultId + '/'), [StringComparison]::OrdinalIgnoreCase)) { throw '[replication-inventory/REST] Wrong vault.' }
            $properties = Get-LabReplicationField $item 'properties' -PreserveCollection
            $specific = Get-LabReplicationField $properties 'providerSpecificDetails' -PreserveCollection
            $provider = Get-LabReplicationField $properties 'recoveryServicesProviderId' -PreserveCollection
            $providerIdentity = $null
            if ($null -ne $provider) {
                $providerIdentity = ConvertTo-LabReplicationArmId $provider 'replication-inventory/provider' 'Microsoft.RecoveryServices/vaults/replicationFabrics/replicationRecoveryServicesProviders' $SubscriptionId
                if (-not $providerIdentity.StartsWith(($VaultId + '/replicationFabrics/'), [StringComparison]::OrdinalIgnoreCase)) { throw '[replication-inventory/provider] Wrong vault.' }
            }
            if ($null -eq $providerIdentity) { $unattributed++ }
            if ($Kind -eq 'Items' -and $ProviderId -and $providerIdentity -ine $ProviderId) { continue }
            if (-not $ProviderId -or $providerIdentity -ieq $ProviderId) { $matching++ }
            $guid = [guid]::Empty; $sourceGuid = $null
            $vmId = Get-LabReplicationField $specific 'vmId' -PreserveCollection
            if ($vmId -is [string] -and [guid]::TryParse($vmId, [ref]$guid)) { $sourceGuid = $guid.ToString() }
            $safe += [pscustomobject]@{ Id = $id; FriendlyName = (Get-LabVaultSafeText (Get-LabReplicationField $properties 'friendlyName' -PreserveCollection)); ProviderId = $providerIdentity; SourceVmGuid = $sourceGuid; InstanceType = (Get-LabVaultSafeText (Get-LabReplicationField $specific 'instanceType' -PreserveCollection)); ProtectionState = (Get-LabVaultSafeText (Get-LabReplicationField $properties 'protectionState' -PreserveCollection)); ReplicationHealth = (Get-LabVaultSafeText (Get-LabReplicationField $properties 'replicationHealth' -PreserveCollection)); JobState = (Get-LabVaultSafeText (Get-LabReplicationField $properties 'state' -PreserveCollection)); StartTime = (Get-LabVaultInventoryTime (Get-LabReplicationField $properties 'startTime' -PreserveCollection)); EndTime = (Get-LabVaultInventoryTime (Get-LabReplicationField $properties 'endTime' -PreserveCollection)) }
        }
        $result.ObservedCount = $Inventory.Items.Count; $result.MatchingProviderCount = $matching; $result.UnattributedCount = $unattributed; $result.Items = @($safe)
    } catch { $result.Complete = $false; $result.Reason = 'IdentityOrShapeUnknown'; $result.Items = @(); $result.ObservedCount = $null }
    return [pscustomobject]$result
}

function ConvertTo-LabVaultUtcTime {
    param([AllowNull()]$Value)
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) {
        # ARM timestamps without an offset (Unspecified) are interpreted as UTC, never local time.
        $utc = if ($Value.Kind -eq [DateTimeKind]::Unspecified) { [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc) } else { $Value.ToUniversalTime() }
        return [DateTimeOffset]::new($utc)
    }
    $date = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ($Value -is [string] -and [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$date)) { return $date.ToUniversalTime() }
    return $null
}

function Get-LabVaultInventoryTime {
    param([AllowNull()]$Value)
    $date = ConvertTo-LabVaultUtcTime $Value
    if ($null -ne $date) { return $date.ToString('o') }
    return $null
}

function Write-LabVaultReport {
    try {
        $script:LabVaultReport.Stage = $script:LabReplicationStage
        $script:LabVaultReport.FinishedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        $path = $ReportPath
        if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path (Get-Location).Path ('step3-vault-inventory-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N') + '.json') }
        $path = [IO.Path]::GetFullPath($path)
        $json = ConvertTo-Json -InputObject $script:LabVaultReport -Depth 16
        $stream = $null; $writer = $null
        try {
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            $writer.WriteLine($json); $writer.Flush()
        } finally { if ($null -ne $writer) { $writer.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() } }
        Write-Host "Read-only Step 3 JSON report saved: $path" -ForegroundColor Cyan
    } catch { Write-Warning 'The sanitized JSON report could not be saved (existing paths are never overwritten); no error body is displayed.' }
}

function Invoke-LabVaultInspection {
    param([string]$ProjectId, [string]$ScopeResourceGroup, [string]$ExplicitVaultId, [string]$ExplicitProviderId)
    $report = $script:LabVaultReport
    $scope = "/subscriptions/$script:LabSubscriptionId/resourceGroups/$ScopeResourceGroup/providers/Microsoft.RecoveryServices/vaults"
    $null = ConvertTo-LabReplicationArmId -Value "/subscriptions/$script:LabSubscriptionId/resourceGroups/$ScopeResourceGroup" -Stage 'vault-list/REST' -ResourceType 'Microsoft.Resources/resourceGroups' -SubscriptionId $script:LabSubscriptionId
    $report.VaultDiscoveryScope = [ordered]@{ ResourceGroup = $ScopeResourceGroup; CollectionId = $scope; Complete = $false; State = 'Unknown'; Candidates = @(); Failure = $null }
    $script:LabReplicationStage = 'project-solutions/REST'
    $solutions = Get-LabArmCollection ($ProjectId + '/solutions') '2018-09-01-preview'
    $association = Get-LabProjectVaultAssociation $solutions $ProjectId $script:LabSubscriptionId
    $report.ProjectAssociation = $association
    $chosen = $null
    if ($ExplicitVaultId) { $chosen = ConvertTo-LabReplicationArmId $ExplicitVaultId 'vault/explicit-id' 'Microsoft.RecoveryServices/vaults' $script:LabSubscriptionId }
    if ($association.ValidReferences.Count -gt 1 -or ($chosen -and @($association.ValidReferences | Where-Object { $_ -ine $chosen }).Count -gt 0)) {
        $report.Handoff = 'BlockedConflictingVaultIntent'
        throw '[vault/REST] Explicit intent or active project references conflict. No alternate vault was selected.'
    }
    if (-not $chosen -and $association.State -ceq 'AzureVerified') { $chosen = $association.VaultId }
    if (-not $chosen) {
        $script:LabReplicationStage = 'vault-list/REST'
        $inventory = Get-LabArmCollection $scope '2026-07-01'
        $report.VaultDiscoveryScope.Complete = $inventory.Complete; $report.VaultDiscoveryScope.Failure = $inventory.Failure
        $candidates = @()
        if ($inventory.Complete) {
            try {
                foreach ($row in $inventory.Items) {
                    $candidate = Get-LabVaultCandidate $row $script:LabSubscriptionId
                    if ($candidate.Id.Substring(0, $candidate.Id.LastIndexOf('/')) -ine $scope) { throw '[vault-list/REST] Out-of-scope vault.' }
                    if (@($candidates | Where-Object { $_.Id -ieq $candidate.Id }).Count -gt 0) { throw '[vault-list/REST] Duplicate vault.' }
                    $candidates += $candidate
                }
            } catch { $report.VaultDiscoveryScope.Complete = $false; $candidates = @() }
        }
        $report.VaultDiscoveryScope.Candidates = @($candidates)
        if (-not $report.VaultDiscoveryScope.Complete) {
            $report.Handoff = 'ManualInspectUnknownInventory'
            Write-Warning 'Vault inventory Unknown: a failed/malformed/incomplete read is not absence. Inspect permissions/project resources; do not create a replacement vault.'
            return
        }
        if ($candidates.Count -eq 0) {
            $report.VaultDiscoveryScope.State = 'VaultNotObservedInInspectedScope'; $report.Handoff = 'ManualInspectProjectPreparation'
            Write-Warning 'VaultNotObservedInInspectedScope: only this selected resource-group inventory was empty. Inspect the project resources and region lock in Azure Migrate. Use its Create resources action ONLY if the project is genuinely not prepared; never create a separate ASR vault.'
            return
        }
        $report.VaultDiscoveryScope.State = 'CandidatesObserved'
        Write-Warning 'Existing vault candidates are not project associations. Name/prefix, location, resource group and tags are NOT binding evidence. Choose your own lab vault for read-only inspection.'
        $entries = @($candidates | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Summary = ($_.Location + ' | provisioning=' + $_.ProvisioningState) } })
        $chosen = Select-LabVaultInventoryEntry $entries 'Vault'
    }
    if (@($association.ValidReferences | Where-Object { $_ -ine $chosen }).Count -gt 0) {
        $report.Handoff = 'BlockedConflictingVaultIntent'
        throw '[vault/REST] Selected vault conflicts with an active valid service reference. No alternate vault was selected.'
    }
    if ($association.State -cne 'AzureVerified') { $association.AssociationSource = 'StudentSelected' }
    $script:LabReplicationStage = 'vault/REST'
    $report.Vault.Id = $chosen
    $read = Invoke-LabArmGet ((Get-LabArmEndpoint) + $chosen + '?api-version=2026-07-01')
    if (-not $read.Success) { $report.Vault.Failure = $read.Failure; $report.Handoff = 'ManualInspectUnknownVault'; return }
    $vault = Get-LabVaultCandidate $read.Body $script:LabSubscriptionId
    if ($vault.Id -ine $chosen) { throw '[vault/REST] Selected vault identity mismatch. No alternate vault was selected.' }
    $vaultRegion = ConvertTo-LabRegionKey $vault.Location
    $targetRegion = ConvertTo-LabRegionKey $report.Inputs.TargetLocation
    $regionState = 'Unknown'
    if ($vaultRegion -and $vaultRegion -ne 'unknown' -and $vaultRegion -match '^[a-z0-9]+$' -and $targetRegion) {
        $regionState = if ($vaultRegion -ceq $targetRegion) { 'Match' } else { 'Mismatch' }
    }
    $report.PortalConfigurationGuidanceAllowed = ($regionState -ceq 'Match' -and $vault.ProvisioningState -ceq 'Succeeded')
    $report.Vault = [ordered]@{ Id = $vault.Id; Name = $vault.Name; Location = $vault.Location; ProvisioningState = $vault.ProvisioningState; TargetRegionValidation = $regionState; ExistenceObserved = $true; VaultCreated = $true; Failure = $null }
    $report.Handoff = 'ManualActionRequired'
    Write-Host "VaultCreated observed by HTTP 200: $($vault.Name), $($vault.Location), provisioning=$($vault.ProvisioningState). No vault creation was submitted." -ForegroundColor Cyan
    if ($association.State -cne 'AzureVerified') { Write-Warning 'ProjectAssociation is Unknown / StudentSelected: confirm this vault binding in your project portal. Selection is not service-verified association.' }
    $script:LabReplicationStage = 'providers/REST'
    $providers = Get-LabArmCollection ($chosen + '/replicationRecoveryServicesProviders') '2026-07-01'
    $projected = @()
    if ($providers.Complete) {
        try {
            foreach ($row in $providers.Items) {
                $provider = Get-LabProviderProjection $row $chosen $script:LabSubscriptionId
                if (@($projected | Where-Object { $_.Id -ieq $provider.Id }).Count -gt 0) { throw '[providers/REST] Duplicate provider.' }
                $projected += $provider
            }
        } catch { $providers.Complete = $false; $providers.Reason = 'IdentityOrShapeUnknown'; $projected = @() }
    }
    $report.ProviderInventory = [ordered]@{ Complete = $providers.Complete; Reason = $providers.Reason; Failure = $providers.Failure; Items = @($projected); Selected = $null; State = 'Unknown' }
    $providerId = $null
    if ($ExplicitProviderId) {
        $providerId = ConvertTo-LabReplicationArmId $ExplicitProviderId 'providers/explicit-id' 'Microsoft.RecoveryServices/vaults/replicationFabrics/replicationRecoveryServicesProviders' $script:LabSubscriptionId
        if (-not $providerId.StartsWith(($chosen + '/replicationFabrics/'), [StringComparison]::OrdinalIgnoreCase)) { throw '[providers/REST] Explicit provider is outside the selected vault. No replacement was selected.' }
    } elseif ($projected.Count -eq 1) { $providerId = $projected[0].Id }
    elseif ($projected.Count -gt 1) {
        $entries = @($projected | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Summary = ('connection=' + $_.CurrentConnection + ' | heartbeat=' + $_.LastHeartBeatUtc) } })
        $providerId = Select-LabVaultInventoryEntry $entries 'Registered provider'
    }
    if ($providerId) {
        $providerRead = Invoke-LabArmGet ((Get-LabArmEndpoint) + $providerId + '?api-version=2026-07-01')
        if ($providerRead.Success) {
            $selected = Get-LabProviderProjection $providerRead.Body $chosen $script:LabSubscriptionId
            if ($selected.Id -ine $providerId) { throw '[providers/REST] Provider GET identity mismatch.' }
            $report.ProviderInventory.Selected = $selected
            $report.ProviderInventory.State = if ($selected.Connected) { 'ProviderConnected' } else { 'ProviderConnectionNotVerified' }
        } else {
            $report.ProviderInventory.Failure = $providerRead.Failure
            if ($ExplicitProviderId) { $report.Handoff = 'BlockedSelectedProviderReadUnverified' }
        }
    } elseif ($providers.Complete -and $projected.Count -eq 0) { $report.ProviderInventory.State = 'ProviderRegistrationRequired' }
    $script:LabReplicationStage = 'replication-inventory/REST'
    $items = Get-LabArmCollection ($chosen + '/replicationProtectedItems') '2026-07-01'
    $jobs = Get-LabArmCollection ($chosen + '/replicationJobs') '2026-07-01'
    $report.ReplicationInventory = Get-LabReplicationInventoryProjection $items $chosen $script:LabSubscriptionId $providerId 'Items'
    $report.JobInventory = Get-LabReplicationInventoryProjection $jobs $chosen $script:LabSubscriptionId $providerId 'Jobs'
    if ($regionState -cne 'Match') {
        $report.Handoff = if ($regionState -ceq 'Mismatch') { 'BlockedVaultTargetRegionMismatch' } else { 'VaultTargetRegionUnverified' }
        Write-Warning 'Vault/actual target VNet region does not match or is unverified. Inventory was retained, but provider registration and replication configuration guidance are suppressed. Inspect the existing project region lock; do not create a replacement vault.'
    } elseif ($vault.ProvisioningState -cne 'Succeeded') {
        $report.Handoff = if ($vault.ProvisioningState -ceq 'Failed') { 'BlockedExistingVaultDeployment' } else { 'VaultProvisioningPendingOrUnknown' }
        Write-Warning 'An existing vault is pending/failed/unknown, not absent. Inspect the existing deployment; do not create another vault.'
    }
    if ($report.ProviderInventory.State -ceq 'ProviderConnected') {
        Write-Host 'ProviderConnected observed for the exact registered provider. Skip Create resources and provider registration; inspect existing selected-source replication. Heartbeat age is reported, not a replication-readiness gate.' -ForegroundColor Green
    } elseif ($report.ProviderInventory.State -ceq 'ProviderRegistrationRequired' -and $vault.ProvisioningState -ceq 'Succeeded' -and $regionState -ceq 'Match') {
        Write-Warning 'Complete provider inventory is empty: ProviderRegistrationRequired. In this Azure Migrate project, manually download the provider/project registration key, install on the intended Hyper-V host and finalize registration. Never expose the key in this report.'
    } else { Write-Warning 'Provider connection/inventory Unknown or not Connected: inspect the existing provider. A failed read does not authorize registering another provider.' }
    Write-Host "Existing vault replication inventory: itemsComplete=$($report.ReplicationInventory.Complete), observedItems=$($report.ReplicationInventory.ObservedCount); jobsComplete=$($report.JobInventory.Complete), observedJobs=$($report.JobInventory.ObservedCount). Inventory only, not readiness." -ForegroundColor Cyan
    Write-Warning 'Before any retry inspect and reuse existing replication/jobs for the exact source VM GUID and registered host. Names or a Succeeded job do not prove source mapping or completion. Do not reinitialize, resize or overwrite existing replication.'
    if ($regionState -ceq 'Match') { Write-Warning 'Only genuinely missing sources may be configured manually after GUID verification and separate operator review.' }
}

function Save-LabErrorReport {
    param([Parameter(Mandatory = $true)]$ErrorRecord, [AllowNull()][AllowEmptyString()][string]$ScriptPath)
    $script:LabVaultReport.SafeDiagnostic = @(Format-LabSafeErrorDiagnostic -ErrorRecord $ErrorRecord -Stage $script:LabReplicationStage)
    Write-LabVaultReport
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
        $script:LabReplicationStage = 'authentication/Connect-AzAccount'
        try { $null = Connect-AzAccount -ErrorAction Stop }
        catch { throw '[authentication/Connect-AzAccount] Azure sign-in did not complete. Raw service details are omitted; review the sign-in flow separately.' }
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
    $script:LabReplicationStage = 'environment-preflight'
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
                $project = @(Get-LabMigrateProjectRead -ResourceGroupName $SourceResourceGroup -Name $MigrateProjectName)
                if (-not $project.Count) {
                    $problems += Get-LabNotFoundMessage "Azure Migrate project '$MigrateProjectName' in '$SourceResourceGroup'" "Create it in the portal (Module 1 section 1), then rerun migrate-step1-setup-project.ps1 with the same environment settings."
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

function Get-LabField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function Test-LabField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return $Object.Contains($Name) }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Get-LabCapability {
    param($Sku, [string]$Name)
    $rows = @(Get-LabField $Sku 'Capabilities' | Where-Object { (Get-LabField $_ 'Name') -eq $Name })
    if ($rows.Count -ne 1) { return $null }
    return [string](Get-LabField $rows[0] 'Value')
}

function Get-LabSizingWorkloads {
    return @(
        [pscustomobject]@{ DisplayName = 'OnPrem-Web'; OSType = 'Windows'; MinimumMemoryGB = 4 },
        [pscustomobject]@{ DisplayName = 'OnPrem-SQL'; OSType = 'Windows'; MinimumMemoryGB = 8 },
        [pscustomobject]@{ DisplayName = 'OnPrem-Linux-Web'; OSType = 'Linux'; MinimumMemoryGB = 2 },
        [pscustomobject]@{ DisplayName = 'OnPrem-Linux-App'; OSType = 'Linux'; MinimumMemoryGB = 2 }
    )
}

function Get-LabSizingCandidates {
    param([object[]]$Skus, [object[]]$Usage, [string]$Location)
    foreach ($sku in $Skus) {
        $name = [string](Get-LabField $sku 'Name')
        if ($name -notmatch '^Standard_[BD]2') { continue }
        $reasons = @(); $memory = 0.0
        if ($name -notmatch '^Standard_(B2(?:a?l?s|a?ts)_v2|D2(?:a|s|as|d|ds|ad|ads|ls|lds)?_v[45])$') {
            $reasons += 'Outside current x64 Bsv2/Basv2 or stable Dv4/v5 scope; legacy, ARM, special-purpose and newer guest-readiness-unverified versions excluded.'
        }
        if ((Get-LabField $sku 'ResourceType') -ne 'virtualMachines' -or @((Get-LabField $sku 'Locations')) -notcontains $Location) {
            $reasons += 'Actual VM SKU location metadata does not establish eligibility in the selected region.'
        }
        foreach ($capability in @('vCPUs', 'vCPUsAvailable')) {
            $cores = 0L
            if (-not [long]::TryParse((Get-LabCapability $sku $capability), [ref]$cores) -or $cores -ne 2) {
                $reasons += "$capability must explicitly establish exactly two visible AND billable vCPUs; missing/constrained values excluded."
            }
        }
        if ((Get-LabCapability $sku 'CpuArchitectureType') -ne 'x64') { $reasons += 'Explicit x64 architecture capability missing or unsupported.' }
        if (@((Get-LabCapability $sku 'HyperVGenerations') -split ',' | ForEach-Object { $_.Trim() }) -notcontains 'V2') { $reasons += 'Explicit Generation 2 (V2) capability missing.' }
        if (-not [double]::TryParse((Get-LabCapability $sku 'MemoryGB'), [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$memory) -or [double]::IsNaN($memory) -or [double]::IsInfinity($memory) -or $memory -lt 2) {
            $reasons += 'MemoryGB is missing/invalid or below the Linux minimum of 2 GiB.'
        }
        if (@((Get-LabCapability $sku 'DiskControllerTypes') -split ',' | ForEach-Object { $_.Trim() }) -notcontains 'SCSI') {
            $reasons += 'Explicit SCSI support missing; NVMe-only guests require separate driver/readiness validation.'
        }
        if ((Get-LabCapability $sku 'PremiumIO') -ne 'True') { $reasons += 'Explicit PremiumIO support required for possible original Premium_LRS disks.' }
        $family = [string](Get-LabField $sku 'Family')
        $familyQuota = Get-LabQuotaRow -Usage $Usage -Key $family
        if ([string]::IsNullOrWhiteSpace($family) -or $null -eq $familyQuota -or $familyQuota.Remaining -lt 2) {
            $reasons += 'Actual SKU Family quota is unknown or has fewer than two vCPUs remaining.'
        }
        if (-not (Test-LabField $sku 'Restrictions')) { $reasons += 'Restriction metadata missing; not proof of subscription eligibility.' }
        foreach ($restriction in @(Get-LabField $sku 'Restrictions')) {
            if ($null -eq $restriction) { $reasons += 'Unknown restriction entry.'; continue }
            $type = [string](Get-LabField $restriction 'Type')
            $values = @(Get-LabField $restriction 'Values' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            $info = Get-LabField $restriction 'RestrictionInfo'
            $regions = @(Get-LabField $info 'Locations' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if ($type -notin @('Location', 'Zone')) { $reasons += 'Unknown restriction type; excluded conservatively.'; continue }
            $scopeKnown = ($regions.Count -gt 0 -or ($type -eq 'Location' -and $values.Count -gt 0))
            if (-not $scopeKnown) { $reasons += 'Restriction location scope missing/null/blank; relevance unknown, excluded conservatively.' }
            $relevant = if ($type -eq 'Location') { ($values -contains $Location -or $regions -contains $Location -or ($values.Count -eq 0 -and $regions.Count -eq 0)) }
                        else { ($regions.Count -eq 0 -or $regions -contains $Location) }
            if ($relevant) { $reasons += "$type restriction relevant to selected region; no zone chosen, conservatively excluded (not a claim that all regional capacity is restricted)." }
        }
        if (@($Skus | Where-Object { (Get-LabField $_ 'Name') -eq $name -and (Get-LabField $_ 'ResourceType') -eq 'virtualMachines' }).Count -ne 1) { $reasons += 'Duplicate SKU metadata is ambiguous.' }
        [pscustomobject]@{ Name = $name; Family = $family; MemoryGB = $memory; Eligible = ($reasons.Count -eq 0); Reasons = $reasons }
    }
}

function Test-LabRetailUri {
    param([string]$Value)
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return ($uri.Scheme -ceq 'https' -and $uri.Host -ieq 'prices.azure.com' -and $uri.Port -eq 443 -and
        [string]::IsNullOrEmpty($uri.UserInfo) -and [string]::IsNullOrEmpty($uri.Fragment) -and $uri.AbsolutePath -ceq '/api/retail/prices')
}

function Invoke-LabRetailPage {
    param([string]$Uri)
    if (-not (Test-LabRetailUri $Uri)) { throw 'Retail URL is not the approved public HTTPS endpoint.' }
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            # Public endpoint only: no Azure token, subscription, credentials or custom headers.
            return Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 30 -MaximumRedirection 0 -ErrorAction Stop
        } catch {
            $response = Get-LabField $_.Exception 'Response'
            $status = Get-LabField $response 'StatusCode'
            $code = 0; if ($null -ne $status) { try { $code = [int]$status } catch { $code = 0 } }
            $timeout = $_.Exception -is [TimeoutException] -or $_.Exception -is [System.Threading.Tasks.TaskCanceledException] -or
                (($_.Exception -is [System.Net.WebException]) -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout)
            if ($attempt -eq 0 -and ($timeout -or ($code -ge 500 -and $code -le 599))) { continue }
            throw 'Public retail price read failed; no complete price ordering is available. Service error bodies omitted.'
        }
    }
}

function Get-LabRetailSnapshot {
    param([string]$Location)
    if ($Location -notmatch '^[a-z0-9]+$') { throw 'Retail region must be a validated Azure location name.' }
    $cache = Get-Variable -Name LabRetailCache -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $cache) { $cache = @{}; $script:LabRetailCache = $cache }
    if ($cache.ContainsKey($Location)) { return $cache[$Location] }
    $filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Location' and priceType eq 'Consumption' and (startswith(armSkuName, 'Standard_B2') or startswith(armSkuName, 'Standard_D2'))"
    $uri = 'https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=%27USD%27&$filter=' + [Uri]::EscapeDataString($filter)
    $items = @(); $seen = @{}; $complete = $false; $issues = @()
    try {
        for ($page = 0; $page -lt 500; $page++) {
            if (-not (Test-LabRetailUri $uri) -or $seen.ContainsKey($uri)) { throw 'Invalid or repeated retail continuation.' }
            $seen[$uri] = $true
            $payload = Invoke-LabRetailPage -Uri $uri
            if (-not (Test-LabField $payload 'Items') -or -not (Test-LabField $payload 'NextPageLink')) { throw 'Malformed retail page.' }
            if ($payload -is [System.Collections.IDictionary]) { $rawRows = $payload['Items'] }
            else { $rawRows = $payload.PSObject.Properties['Items'].Value }
            if ($null -eq $rawRows -or $rawRows -is [string] -or -not ($rawRows -is [System.Collections.IEnumerable])) { throw 'Malformed retail Items.' }
            $items += @($rawRows)
            if ($items.Count -gt 100000) { throw 'Retail item safety limit reached.' }
            $next = Get-LabField $payload 'NextPageLink'
            if ($null -ne $next -and $next -isnot [string]) { throw 'Malformed retail continuation.' }
            if ([string]::IsNullOrWhiteSpace([string]$next)) { $complete = $true; break }
            $uri = [string]$next
        }
        if (-not $complete) { throw 'Retail page safety limit reached.' }
    } catch { $issues += 'Retail snapshot incomplete or unavailable; automatic selection blocked. No static price fallback.' }
    $result = [pscustomobject]@{ Complete = $complete; Items = $items; RetrievedAt = [DateTimeOffset]::UtcNow; Issues = $issues }
    $cache[$Location] = $result
    return $result
}

function Get-LabRetailRate {
    param([object[]]$Items, [string]$SkuName, [string]$Location, [ValidateSet('Windows', 'Linux')][string]$OSType, [DateTimeOffset]$Now)
    $validRates = @(); $invalid = $false
    foreach ($item in $Items) {
        if ((Get-LabField $item 'armSkuName') -cne $SkuName -or (Get-LabField $item 'armRegionName') -cne $Location -or
            (Get-LabField $item 'currencyCode') -cne 'USD' -or (Get-LabField $item 'serviceName') -cne 'Virtual Machines' -or
            (Get-LabField $item 'type') -cne 'Consumption' -or (Get-LabField $item 'unitOfMeasure') -cne '1 Hour' -or
            (Get-LabField $item 'isPrimaryMeterRegion') -isnot [bool] -or (Get-LabField $item 'isPrimaryMeterRegion') -ne $true) { continue }
        $product = [string](Get-LabField $item 'productName')
        if ($product -cnotmatch '^Virtual Machines [A-Za-z0-9 -]+ Series( Windows)?$') { continue }
        $rowOS = if ($product.EndsWith(' Windows', [StringComparison]::Ordinal)) { 'Windows' } else { 'Linux' }
        if ($rowOS -cne $OSType) { continue }
        $meter = [string](Get-LabField $item 'meterName'); $sku = [string](Get-LabField $item 'skuName')
        if ($meter -match '(?i)spot|low.?priority|dev.?test|reservation|savings.?plan|rhel|red.?hat|suse|sql|ubuntu.?pro|marketplace|software' -or $sku -match '(?i)spot|low.?priority|dev.?test|reservation|savings.?plan|rhel|red.?hat|suse|sql|ubuntu.?pro|marketplace|software') { continue }
        if ([string]::IsNullOrWhiteSpace($meter) -or [string]::IsNullOrWhiteSpace($sku)) { $invalid = $true; continue }
        if (-not [string]::IsNullOrWhiteSpace([string](Get-LabField $item 'reservationTerm'))) { continue }
        $tier = 0.0; $price = 0.0; $amount = [decimal]0; $effective = [DateTimeOffset]::MinValue
        if (-not [double]::TryParse([string](Get-LabField $item 'tierMinimumUnits'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$tier)) { $invalid = $true; continue }
        if ($tier -ne 0) { continue }
        if (-not [DateTimeOffset]::TryParse([string](Get-LabField $item 'effectiveStartDate'), [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$effective)) { $invalid = $true; continue }
        if ($effective -gt $Now) { continue }
        $rawPrice = Get-LabField $item 'retailPrice'
        $priceText = if ($rawPrice -is [IFormattable]) { $rawPrice.ToString($null, [Globalization.CultureInfo]::InvariantCulture) } else { [string]$rawPrice }
        if (-not [double]::TryParse($priceText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$price) -or
            [double]::IsNaN($price) -or [double]::IsInfinity($price) -or $price -le 0 -or
            -not [decimal]::TryParse($priceText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$amount) -or $amount -le 0) { $invalid = $true; continue }
        $validRates += [pscustomobject]@{ Rate = $amount; Effective = $effective }
    }
    if ($invalid -or $validRates.Count -eq 0) { return $null }
    $ordered = @($validRates | Sort-Object Effective -Descending)
    $latest = @($ordered | Where-Object { $_.Effective -eq $ordered[0].Effective })
    if ($latest.Count -ne 1) { return $null }
    return $latest[0]
}

function Get-LabCostOrderedOptions {
    param([object[]]$Options)
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($option in $Options) {
        $index = 0
        while ($index -lt $ordered.Count -and ($ordered[$index].Rate -lt $option.Rate -or
            ($ordered[$index].Rate -eq $option.Rate -and [string]::CompareOrdinal($ordered[$index].Name, $option.Name) -le 0))) { $index++ }
        $ordered.Insert($index, $option)
    }
    return $ordered.ToArray()
}

function Get-LabCostTargetPlan {
    param([object[]]$Candidates, [object[]]$Usage, $Retail, [string]$Location)
    $workloads = @(Get-LabSizingWorkloads); $alternatives = @{}; $issues = @(); $unpriced = @()
    $eligible = @($Candidates | Where-Object { $_.Eligible })
    if (-not $Retail.Complete) { $issues += 'Price pagination incomplete: no automated recommendation.' }
    foreach ($workload in $workloads) {
        $options = @()
        foreach ($candidate in @($eligible | Where-Object { $_.MemoryGB -ge $workload.MinimumMemoryGB })) {
            $rate = Get-LabRetailRate -Items $Retail.Items -SkuName $candidate.Name -Location $Location -OSType $workload.OSType -Now $Retail.RetrievedAt
            if ($null -eq $rate) { $unpriced += "$($workload.DisplayName): $($candidate.Name) ($($workload.OSType)) Unknown price"; continue }
            $options += [pscustomobject]@{ Name = $candidate.Name; Family = $candidate.Family; Rate = $rate.Rate; PriceTimestamp = $rate.Effective; MemoryGB = $candidate.MemoryGB }
        }
        $alternatives[$workload.DisplayName] = @(Get-LabCostOrderedOptions -Options $options)
        if ($options.Count -eq 0) { $issues += "No fully priced eligible options for $($workload.DisplayName)." }
    }
    if ($unpriced.Count -gt 0) { $issues += 'Eligible candidates have unknown/ambiguous prices: a complete cheapest ordering is not established; automatic selection blocked.' }
    $regional = Get-LabQuotaRow -Usage $Usage -Key 'cores'; $vmCount = Get-LabQuotaRow -Usage $Usage -Key 'virtualMachines'
    if ($null -eq $regional -or $regional.Remaining -lt 8) { $issues += 'Target Total Regional vCPU quota Unknown or insufficient for four two-vCPU VMs.' }
    if ($null -eq $vmCount -or $vmCount.Remaining -lt 4) { $issues += 'Target regional VM-count quota Unknown or insufficient for four VMs.' }
    $selected = @(); $total = [decimal]0
    if ($issues.Count -eq 0) {
        # Equal core demand means only the cheapest SKU per actual family/workload is needed
        # in the search. Dynamic programming retains the cheapest prefix for each quota state.
        $states = @{ '' = [pscustomobject]@{ Choices = @(); Used = @{}; Cost = [decimal]0; Tie = '' } }
        foreach ($workload in $workloads) {
            $families = @{}; $nextStates = @{}
            foreach ($option in $alternatives[$workload.DisplayName]) { if (-not $families.ContainsKey($option.Family)) { $families[$option.Family] = $option } }
            foreach ($state in $states.Values) { foreach ($option in $families.Values) {
                $used = @{}; foreach ($key in $state.Used.Keys) { $used[$key] = $state.Used[$key] }
                if (-not $used.ContainsKey($option.Family)) { $used[$option.Family] = 0 }
                $used[$option.Family] += 2
                $quota = Get-LabQuotaRow -Usage $Usage -Key $option.Family
                if ($null -eq $quota -or $used[$option.Family] -gt $quota.Remaining) { continue }
                $key = (@($used.Keys | Sort-Object | ForEach-Object { $_ + ':' + $used[$_] }) -join '|')
                $cost = $state.Cost + $option.Rate; $tie = $state.Tie + '|' + $option.Name
                if (-not $nextStates.ContainsKey($key) -or $cost -lt $nextStates[$key].Cost -or
                    ($cost -eq $nextStates[$key].Cost -and [string]::CompareOrdinal($tie, $nextStates[$key].Tie) -lt 0)) {
                    $choice = [pscustomobject]@{ DisplayName = $workload.DisplayName; Name = $option.Name; Family = $option.Family; Rate = $option.Rate; PriceTimestamp = $option.PriceTimestamp }
                    $nextStates[$key] = [pscustomobject]@{ Choices = @($state.Choices) + $choice; Used = $used; Cost = $cost; Tie = $tie }
                }
            } }
            if ($nextStates.Count -gt 100000) { $issues += 'Cost-plan state safety limit reached; no recommendation.'; break }
            $states = $nextStates
        }
        if ($issues.Count -eq 0 -and $states.Count -gt 0) {
            $best = $null
            foreach ($state in $states.Values) { if ($null -eq $best -or $state.Cost -lt $best.Cost -or ($state.Cost -eq $best.Cost -and [string]::CompareOrdinal($state.Tie, $best.Tie) -lt 0)) { $best = $state } }
            $selected = @($best.Choices); $total = $best.Cost
        } elseif ($issues.Count -eq 0) { $issues += 'No feasible aggregate family-quota plan for all four workloads; no fixed fallback.' }
    }
    return [pscustomobject]@{ Complete = ($issues.Count -eq 0 -and $selected.Count -eq 4); Selected = $selected; Alternatives = $alternatives; Unpriced = $unpriced; Issues = $issues; TotalHourlyUSD = $total; Candidates = $Candidates; RetrievedAt = $Retail.RetrievedAt }
}

function Show-LabCostTargetPlan {
    param($Plan, [string]$Location, [string[]]$Names = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App'))
    Write-Host "READ-ONLY cost recommendation only (never accepted automatically) | region=$Location | priceRetrievedUTC=$($Plan.RetrievedAt.ToUniversalTime().ToString('o'))" -ForegroundColor Cyan
    Write-Host 'Scope: subscription SKU metadata, current/stable x64 B2/D2, Gen2, two visible/billable vCPUs, SCSI and PremiumIO; four-workload aggregate quota. Not an assessment or capacity reservation.'
    Write-Host 'Retail USD/hour, Windows and Linux meters separately. Excludes disks/network, tax, SQL/software licenses, commitments and license benefits. Burstable CPU performance needs assessment review.'
    Write-Warning 'SCSI metadata alone does NOT prove guest drivers/MANA or Azure Migrate Hyper-V provider eligibility. Confirm original disk type, guest readiness and actual offered sizes in the portal. Dv6/v7 excluded pending guest readiness validation.'
    foreach ($candidate in @($Plan.Candidates | Where-Object { -not $_.Eligible })) { Write-Host "  Excluded $($candidate.Name): $($candidate.Reasons -join '; ')" }
    foreach ($name in $Names) {
        Write-Host "  $name -- ordered priced alternatives (not allocation/retry instructions):"
        foreach ($option in @($Plan.Alternatives[$name])) {
            Write-Host "    $($option.Name) | family=$($option.Family) | RAM=$($option.MemoryGB) GiB | USD/hr=$($option.Rate.ToString([Globalization.CultureInfo]::InvariantCulture)) | priceTimestamp=$($option.PriceTimestamp.ToUniversalTime().ToString('o'))"
        }
        foreach ($unknown in @($Plan.Unpriced | Where-Object { $_.StartsWith($name + ':', [StringComparison]::Ordinal) })) { Write-Warning $unknown }
        $choice = @($Plan.Selected | Where-Object { $_.DisplayName -ceq $name })
        if ($Plan.Complete -and $choice.Count -eq 1) { Write-Host "    Current aggregate-quota recommendation: $($choice[0].Name)" -ForegroundColor Green }
        else { Write-Warning 'No complete cost recommendation; eligible unpriced sizes may still be chosen explicitly.' }
    }
    if ($Plan.Complete) { Write-Host "Least-cost complete eligible four-workload plan: USD/hr=$($Plan.TotalHourlyUSD.ToString([Globalization.CultureInfo]::InvariantCulture)); no resources allocated or resized." }
    foreach ($issue in $Plan.Issues) { Write-Warning $issue }
}

function Get-LabTargetSizeOptions {
    param([object[]]$Candidates, [object[]]$Usage, $Retail, [string]$Location, $Workload)
    $priced = @(); $unknown = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in @($Candidates | Where-Object { $_.Eligible -and $_.MemoryGB -ge $Workload.MinimumMemoryGB })) {
        $rate = $null
        if ($Retail.Complete) { $rate = Get-LabRetailRate -Items $Retail.Items -SkuName $candidate.Name -Location $Location -OSType $Workload.OSType -Now $Retail.RetrievedAt }
        $amount = $null; $timestamp = $null
        if ($null -ne $rate) { $amount = $rate.Rate; $timestamp = $rate.Effective }
        $quota = Get-LabQuotaRow -Usage $Usage -Key $candidate.Family
        $option = [pscustomobject]@{ Name = $candidate.Name; Family = $candidate.Family; MemoryGB = $candidate.MemoryGB; OSType = $Workload.OSType; Rate = $amount; PriceTimestamp = $timestamp; FamilyRemaining = $quota.Remaining }
        if ($null -ne $rate) { $priced += $option }
        else {
            $index = 0
            while ($index -lt $unknown.Count -and [string]::CompareOrdinal($unknown[$index].Name, $option.Name) -le 0) { $index++ }
            $unknown.Insert($index, $option)
        }
    }
    return @(@(Get-LabCostOrderedOptions -Options $priced) + $unknown.ToArray())
}

function Test-LabTargetSizeMapping {
    param([AllowNull()][hashtable]$Mapping, [hashtable]$Options, [object[]]$Usage)
    $workloads = @(Get-LabSizingWorkloads); $issues = @(); $selected = @(); $canonical = @{}; $used = @{}; $seen = @{}
    if ($null -eq $Mapping -or $Mapping.Count -ne 4) { $issues += 'TargetVmSizes requires exactly four workload-name keys.' }
    if ($null -ne $Mapping) {
        foreach ($key in $Mapping.Keys) {
            if ($key -isnot [string] -or @($workloads | Where-Object { $_.DisplayName -ceq $key }).Count -ne 1) { $issues += 'TargetVmSizes contains an unknown or non-exact workload name.'; continue }
            if ($seen.ContainsKey($key)) { $issues += 'TargetVmSizes contains duplicate case-insensitive workload keys.' }
            $seen[$key] = $true
        }
    }
    foreach ($workload in $workloads) {
        $name = $workload.DisplayName
        $keys = @()
        if ($null -ne $Mapping) { $keys = @($Mapping.Keys | Where-Object { $_ -is [string] -and $_ -ceq $name }) }
        if ($keys.Count -ne 1) { $issues += "TargetVmSizes is missing exact key '$name'."; continue }
        $value = $Mapping[$keys[0]]
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { $issues += "TargetVmSizes '$name' must be one exact SKU string."; continue }
        $eligibleOptions = @($Options[$name] | Where-Object { $_.Name -ceq $value })
        if ($eligibleOptions.Count -ne 1) { $issues += "TargetVmSizes '$name' SKU '$value' is unknown, ineligible or below its RAM minimum in current subscription metadata."; continue }
        $option = $eligibleOptions[0]
        $canonical[$name] = $option.Name
        $selected += [pscustomobject]@{ DisplayName = $name; Name = $option.Name; Family = $option.Family; MemoryGB = $option.MemoryGB; OSType = $option.OSType; Rate = $option.Rate; PriceTimestamp = $option.PriceTimestamp }
        if (-not $used.ContainsKey($option.Family)) { $used[$option.Family] = 0L }
        $used[$option.Family] += 2
    }
    $regional = Get-LabQuotaRow -Usage $Usage -Key 'cores'; $vmCount = Get-LabQuotaRow -Usage $Usage -Key 'virtualMachines'
    if ($null -eq $regional -or $regional.Remaining -lt 8) { $issues += 'Target Total Regional vCPU quota Unknown or insufficient for the four-choice plan (+8 vCPUs).' }
    if ($null -eq $vmCount -or $vmCount.Remaining -lt 4) { $issues += 'Target regional VM-count quota Unknown or insufficient for the four-choice plan (+4 VMs).' }
    foreach ($family in $used.Keys) {
        $quota = Get-LabQuotaRow -Usage $Usage -Key $family
        if ($null -eq $quota -or $used[$family] -gt $quota.Remaining) { $issues += "Combined choices exceed or cannot establish family '$family' remaining quota (need $($used[$family]) vCPUs). Earlier choices were NOT changed." }
    }
    return [pscustomobject]@{ SelectionComplete = ($issues.Count -eq 0 -and $selected.Count -eq 4); Selected = $selected; TargetVmSizes = $canonical; Issues = $issues }
}

function Select-LabTargetVmSizes {
    param($Snapshot, $Retail, [string]$Location, [AllowNull()][hashtable]$Mapping, [switch]$MappingSupplied)
    $workloads = @(Get-LabSizingWorkloads); $options = @{}; $issues = @($Snapshot.Issues)
    $candidates = @(Get-LabSizingCandidates -Skus $Snapshot.Skus -Usage $Snapshot.Usage -Location $Location)
    foreach ($workload in $workloads) {
        $options[$workload.DisplayName] = @(Get-LabTargetSizeOptions -Candidates $candidates -Usage $Snapshot.Usage -Retail $Retail -Location $Location -Workload $workload)
        if ($options[$workload.DisplayName].Count -eq 0) { $issues += "No authorized eligible subscription choices for $($workload.DisplayName); metadata/quota/RAM cannot be bypassed." }
    }
    $regional = Get-LabQuotaRow -Usage $Snapshot.Usage -Key 'cores'; $vmCount = Get-LabQuotaRow -Usage $Snapshot.Usage -Key 'virtualMachines'
    if ($null -eq $regional -or $regional.Remaining -lt 8) { $issues += 'Target Total Regional vCPU quota Unknown or insufficient for four two-vCPU VMs.' }
    if ($null -eq $vmCount -or $vmCount.Remaining -lt 4) { $issues += 'Target regional VM-count quota Unknown or insufficient for four VMs.' }
    if ($issues.Count -gt 0) {
        if ($MappingSupplied) { throw ('[Blocked] TargetVmSizes live validation failed: ' + ($issues -join '; ')) }
        return [pscustomobject]@{ SelectionComplete = $false; Selected = @(); TargetVmSizes = @{}; Issues = $issues }
    }
    if ($MappingSupplied) {
        $result = Test-LabTargetSizeMapping -Mapping $Mapping -Options $options -Usage $Snapshot.Usage
        if (-not $result.SelectionComplete) { throw ('[Blocked] Invalid TargetVmSizes: ' + ($result.Issues -join '; ')) }
        return $result
    }
    Write-Host 'Select ALL FOUR workload target sizes explicitly (even for a Step 3 workload pair); aggregate quota is checked for the combined set. Source host is NOT resized.' -ForegroundColor Cyan
    Write-Host 'Signed-in subscription metadata and remaining quota only; not current physical capacity, a reservation or an assessment. No resources are allocated.'
    while ($true) {
        $chosen = @{}
        foreach ($workload in $workloads) {
            $name = $workload.DisplayName; $choices = @($options[$name])
            Write-Host "$name | $($workload.OSType) | minimum RAM=$($workload.MinimumMemoryGB) GiB | exactly 2 vCPUs"
            if (@($choices | Where-Object { $null -eq $_.Rate }).Count -gt 0) { Write-Warning 'Price unavailable for eligible choices: not a complete cost ranking. Unknown prices follow known prices in stable SKU order; no cheapest claim.' }
            $unpricedHeading = $false
            for ($i = 0; $i -lt $choices.Count; $i++) {
                $option = $choices[$i]; $price = 'Price unavailable'
                if ($null -ne $option.Rate) { $price = 'USD/hr=' + $option.Rate.ToString([Globalization.CultureInfo]::InvariantCulture) }
                elseif (-not $unpricedHeading) { Write-Host '  Eligible choices with unavailable prices:'; $unpricedHeading = $true }
                Write-Host "  [$($i + 1)] $($option.Name) | RAM=$($option.MemoryGB) GiB | OS=$($option.OSType) | $price | family=$($option.Family) remaining=$($option.FamilyRemaining) vCPUs (before this four-choice plan)"
            }
            while ($true) {
                $answer = Read-Host "Number for $name (blank cancels entire selection; no default)"
                if ([string]::IsNullOrWhiteSpace($answer)) { throw '[Cancelled] Entire VM selection cancelled before resource/provider writes. No earlier choice was accepted.' }
                $number = 0
                if ($answer -match '^[0-9]+$' -and [int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $choices.Count) { $chosen[$name] = $choices[$number - 1].Name; break }
                Write-Warning "Enter a number from 1 to $($choices.Count), or blank to cancel."
            }
        }
        $result = Test-LabTargetSizeMapping -Mapping $chosen -Options $options -Usage $Snapshot.Usage
        if ($result.SelectionComplete) { return $result }
        foreach ($issue in $result.Issues) { Write-Warning $issue }
        while ($true) {
            $restart = Read-Host '[1] Reselect all four sizes  [2] Stop (blank also stops)'
            if ($restart -eq '1') { break }
            if ([string]::IsNullOrWhiteSpace($restart) -or $restart -eq '2') { throw '[Cancelled] Combined plan is infeasible; stopped without changing choices or allocating resources.' }
            Write-Warning 'Enter 1 to restart selection or 2 to stop.'
        }
    }
}

function Show-LabTargetSizeSelection {
    param($Selection)
    if (-not $Selection.SelectionComplete) { Write-Warning 'VM selection incomplete: NETWORK-ONLY setup is not VM allocation approval.'; return }
    Write-Host 'Explicit four-workload choices validated against current subscription SKU metadata and aggregate quota (not a capacity guarantee):' -ForegroundColor Cyan
    foreach ($choice in $Selection.Selected) {
        $price = 'Price unavailable'
        if ($null -ne $choice.Rate) { $price = 'USD/hr=' + $choice.Rate.ToString([Globalization.CultureInfo]::InvariantCulture) }
        Write-Host "  $($choice.DisplayName) -> $($choice.Name) | RAM=$($choice.MemoryGB) GiB | OS=$($choice.OSType) | $price"
    }
    $entries = @($Selection.Selected | ForEach-Object { "'$($_.DisplayName)' = '$($_.Name)'" })
    Write-Host ('$targetVmSizes = @{ ' + ($entries -join '; ') + ' }')
    Write-Host 'Copy this mapping with the same-environment Step 3 command; Step 3 revalidates live eligibility/quota and never silently reprices into a different SKU. No local state file.'
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
        catch { $issues += "Get-AzVMUsage '$Location': Unknown (read failed; service details omitted)." }
        try { $skus = @(Get-AzComputeResourceSku -Location $Location -ErrorAction Stop | Where-Object { $_.ResourceType -eq 'virtualMachines' }) }
        catch { $issues += "Get-AzComputeResourceSku '$Location': Unknown (read failed; service details omitted)." }
    } catch { $issues += "Read-only Compute preflight '$Location': Unknown (read failed; service details omitted)." }
    return [pscustomobject]@{ Usage = $usage; Skus = $skus; Issues = $issues }
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
    try { $network = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $name -ErrorAction Stop }
    catch { throw '[target-network/Get-AzVirtualNetwork] Target network lookup failed; absence was not established. Check access and the selected environment. No changes were made.' }
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

function Get-LabReplicationField {
    param([AllowNull()]$InputObject, [string]$Name, [switch]$PreserveCollection)
    if ($null -eq $InputObject) { return $null }
    $value = $null
    if ($InputObject -is [System.Collections.IDictionary]) { $value = $InputObject[$Name] }
    else {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) { $value = $property.Value }
    }
    if ($PreserveCollection) { return ,$value }
    return $value
}

function ConvertTo-LabReplicationArmId {
    param([AllowNull()]$Value, [string]$Stage, [string]$ResourceType, [string]$SubscriptionId)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value -cne $Value.Trim() -or
        $Value -match '[?#%\\\s]' -or $Value -match '/\.{1,2}(?:/|$)') {
        throw "[$Stage] Expected one nonempty, unambiguous ARM resource ID string. No changes were made."
    }
    $pattern = '^/subscriptions/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/resourceGroups/([^/]+)(?:/providers/([^/]+)/(.+))?$'
    $match = [regex]::Match($Value, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success -or ($SubscriptionId -and $match.Groups[1].Value -ine $SubscriptionId) -or
        $match.Groups[2].Value -notmatch '^[\p{L}\p{M}\p{N}_.()-]{1,90}$' -or $match.Groups[2].Value.EndsWith('.')) {
        throw "[$Stage] ARM resource ID is malformed or outside the selected subscription. No changes were made."
    }
    $actualType = 'Microsoft.Resources/resourceGroups'
    if ($match.Groups[3].Success) {
        $segments = $match.Groups[4].Value.Split('/')
        if ($match.Groups[3].Value -notmatch '^[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)+$' -or $segments.Count % 2 -ne 0 -or
            @($segments | Where-Object { $_ -notmatch '^[\p{L}\p{M}\p{N}_.()-]+$' }).Count -gt 0) {
            throw "[$Stage] ARM resource ID has incomplete resource-type/name pairs. No changes were made."
        }
        $types = @($match.Groups[3].Value)
        for ($i = 0; $i -lt $segments.Count; $i += 2) { $types += $segments[$i] }
        $actualType = $types -join '/'
    }
    if ($ResourceType -and $actualType -ine $ResourceType) {
        throw "[$Stage] ARM resource ID has the wrong resource type; expected $ResourceType. No changes were made."
    }
    return $Value
}

function Get-LabReplicationObjectId {
    param([AllowNull()]$InputObject, [string]$Stage, [string]$ResourceType, [string]$SubscriptionId)
    if ($null -eq $InputObject -or $InputObject -is [string] -or $InputObject -is [array] -or
        ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [System.Collections.IDictionary])) {
        throw "[$Stage] Expected exactly one resource object, not an empty result, string or collection. No changes were made."
    }
    $ids = @()
    foreach ($field in @('Id', 'ResourceId')) {
        $value = Get-LabReplicationField $InputObject $field -PreserveCollection
        if ($null -eq $value) { continue }
        $ids += ConvertTo-LabReplicationArmId -Value $value -Stage "$Stage/$field" -ResourceType $ResourceType -SubscriptionId $SubscriptionId
    }
    if ($ids.Count -eq 0 -or ($ids.Count -eq 2 -and $ids[0] -ine $ids[1])) {
        throw "[$Stage] Resource object has no usable identity or conflicting Id/ResourceId fields. No changes were made."
    }
    return $ids[0]
}

function Resolve-LabReplicationWorkload {
    param([AllowNull()][AllowEmptyString()][string]$Value)
    $entry = if ($null -ne $Value) { $Value.Trim() } else { '' }
    switch ($entry) {
        'All' { return 'All' }
        'Agentless' { return 'Agentless' }
        'AgentBased' { return 'AgentBased' }
        'Agent-based' { return 'AgentBased' }
        default { throw 'Workload must be All, Agentless or AgentBased (Agent-based is also accepted). No changes were made.' }
    }
}

function Get-LabReplicationWorkloadGroup {
    param([Parameter(Mandatory = $true)][string]$Workload)
    $normalized = Resolve-LabReplicationWorkload $Workload
    $groups = @{
        Agentless = @('OnPrem-Web', 'OnPrem-Linux-Web')
        AgentBased = @('OnPrem-SQL', 'OnPrem-Linux-App')
        All = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App')
    }
    return [pscustomobject]@{
        Workload = $normalized; SelectedWorkloads = [string[]]$groups[$normalized]
        ReplicationEngine = 'HyperVHostProvider'; HistoricalGroupLabelOnly = $true
        ManualActionRequired = $true; SharedFinalCutover = 'Module 3 section 11'
    }
}

function Get-LabReplicationSelectedMachines {
    param([object[]]$Inventory, [object[]]$Configurations, [string]$SubscriptionId)
    if ($Configurations.Count -eq 0) { throw '[source-inventory] No workloads were selected. No changes were made.' }
    $seenNames = @{}; $seenIds = @{}
    foreach ($configuration in $Configurations) {
        $name = Get-LabReplicationField $configuration 'DisplayName' -PreserveCollection
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $seenNames.ContainsKey($name)) {
            throw '[source-inventory] Selected workload names are empty or duplicated. No changes were made.'
        }
        if ($name -notin @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App')) {
            throw '[source-inventory] Unknown or infrastructure VM is not an approved workload. No changes were made.'
        }
        $seenNames[$name] = $true
        $matches = @($Inventory | Where-Object {
            $displayName = Get-LabReplicationField $_ 'DisplayName' -PreserveCollection
            $displayName -is [string] -and $displayName -ieq $name
        })
        if ($matches.Count -ne 1) {
            throw "[source-inventory] '$name' must resolve to exactly one discovered Hyper-V machine (found $($matches.Count)). No changes were made."
        }
        $id = Get-LabReplicationObjectId $matches[0] "source-inventory/$name" 'Microsoft.OffAzure/HyperVSites/machines' $SubscriptionId
        if ($seenIds.ContainsKey($id)) { throw '[source-inventory] Selected workloads resolve to duplicate source IDs. No changes were made.' }
        $seenIds[$id] = $true
        [pscustomobject]@{ VMName = $name; DiscoveredId = $id; Machine = $matches[0]; Configuration = $configuration }
    }
}

function Test-LabReplicationCommandContract {
    param([AllowNull()]$Command, [string[]]$Parameters, [hashtable]$Types = @{})
    if ($null -eq $Command -or $Command -is [array]) { return $false }
    $sets = @(Get-LabReplicationField $Command 'ParameterSets')
    foreach ($set in $sets) {
        $members = @(Get-LabReplicationField $set 'Parameters')
        $valid = $true
        foreach ($name in $Parameters) {
            $member = @($members | Where-Object { (Get-LabReplicationField $_ 'Name') -ieq $name })
            if ($member.Count -ne 1) { $valid = $false; break }
            if ($Types.ContainsKey($name) -and (Get-LabReplicationField $member[0] 'ParameterType') -ne $Types[$name]) { $valid = $false; break }
        }
        foreach ($member in $members) {
            if ((Get-LabReplicationField $member 'IsMandatory') -eq $true -and
                (Get-LabReplicationField $member 'Name') -notin $Parameters) { $valid = $false }
        }
        if ($valid) { return $true }
    }
    return $false
}

function Get-LabReplicationVaultDiagnostic {
    param([AllowNull()]$Solution, [string]$SubscriptionId)
    $state = 'FieldUnavailable'; $vaultId = $null
    if ($null -ne $Solution -and $Solution -isnot [array] -and $Solution -isnot [string]) {
        $detail = Get-LabReplicationField $Solution 'DetailExtendedDetail' -PreserveCollection
        $additional = Get-LabReplicationField $detail 'AdditionalProperties' -PreserveCollection
        $value = Get-LabReplicationField $additional 'vaultId' -PreserveCollection
        if ($null -ne $value) {
            $state = 'Invalid'
            if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) { $state = 'Empty' }
            else {
                try {
                    $vaultId = ConvertTo-LabReplicationArmId -Value $value -Stage 'solution/vault-reference' -ResourceType 'Microsoft.RecoveryServices/vaults' -SubscriptionId $SubscriptionId
                    $state = 'PresentAndWellFormed'
                } catch { $vaultId = $null }
            }
        }
    }
    return [pscustomobject]@{ State = $state; HasValidReference = ($state -eq 'PresentAndWellFormed'); VaultId = $vaultId }
}

# endregion Lab helpers
# $PSCommandPath is the full path of this script; it is captured so the error report can be
# written beside it. The trap records the failure and holds the window open, because a console
# launched by double-click closes the moment the script exits.
$script:LabScriptPath = $PSCommandPath
$script:LabVaultReport = [ordered]@{
    SchemaVersion = '1.1'; StartedUtc = [DateTimeOffset]::UtcNow.ToString('o'); FinishedUtc = $null
    Stage = 'environment-preflight'; Handoff = 'ManualActionRequired'
    Inputs = [ordered]@{ Subscription = 'Unknown'; SourceResourceGroup = $null; TargetResourceGroup = $null; ProjectId = $null; TargetLocation = $null; Workload = $null }
    VaultDiscoveryScope = [ordered]@{ Complete = $false; State = 'Unknown' }
    ProjectAssociation = [ordered]@{ State = 'Unknown'; AssociationSource = 'None'; Reason = 'NotRead' }
    Vault = [ordered]@{ Id = $null; ExistenceObserved = $false; VaultCreated = $null; Failure = $null }
    ProviderInventory = [ordered]@{ Complete = $false; State = 'Unknown'; Items = @(); Selected = $null }
    ReplicationInventory = [ordered]@{ Complete = $false; ObservedCount = $null; Items = @(); SourceIdentityMapping = 'NotVerified' }
    JobInventory = [ordered]@{ Complete = $false; ObservedCount = $null; Items = @() }
    SourceInventory = @(); TargetSizing = 'NotEvaluated'; SafeDiagnostic = @()
    WorkloadGroup = $null
    KnownGaps = @('StudentSelected is not service-verified project binding.', 'Source VM GUID/host to protected-item identity mapping is not verified.', 'Connection and heartbeat inventory do not verify replication readiness.', 'Job success does not prove initial replication complete.', 'No supported automatic Hyper-V replication backend is enabled.')
    PortalConfigurationGuidanceAllowed = $false
    AzureWritesSubmitted = 0; ReplicationEnabledByScript = $false; CanCutOver = $false; ReplicationReadinessNotVerified = $true
}
trap {
    Write-LabTerminatingError $_
    Save-LabErrorReport -ErrorRecord $_ -ScriptPath $script:LabScriptPath
    Wait-LabBeforeExit
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($Workload)) { $Workload = Resolve-LabReplicationWorkload $Workload }
$Workload = Select-LabFromList -Name 'Workload' -Value $Workload -Options @('All', 'Agentless', 'AgentBased') -Kind Workload -Prompt 'Historical workload group (All = four; Agentless = Web/Linux-Web; AgentBased = SQL/App; all use Hyper-V)'
$workloadGroup = Get-LabReplicationWorkloadGroup -Workload $Workload
$script:LabVaultReport.Inputs.Workload = $workloadGroup.Workload
$script:LabVaultReport.WorkloadGroup = $workloadGroup

Write-Host 'Read-only Hyper-V preflight for the selected group. Subscription-first size selection uses the actual target VNet region.' -ForegroundColor Cyan
$context = Get-LabAzContext -RequiredModules @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network') -OptionalModules @('Az.Migrate')

Write-Host ""
Write-Host "Enter the values for your lab environment. A value in [brackets] is a lab default and Enter accepts it; an (example: ...) is a hint only and must be typed." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabResourceGroupName -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Prompt 'Source resource group (contains the Hyper-V host)' -Example 'rg-ces-source-01' -MissingHelp 'It is created by deploy-lab.ps1.'
$TargetResourceGroup = Read-LabResourceGroupName -Name 'TargetResourceGroup' -Value $TargetResourceGroup -Prompt 'Target resource group (landing zone for migrated VMs)' -Example 'rg-ces-target-01' -MissingHelp 'It is created by migrate-step1-setup-project.ps1.'
$Location = Resolve-LabTargetNetworkLocation -Value $Location -ResourceGroupName $TargetResourceGroup
$MigrateProjectName = Select-LabFromList -Name 'MigrateProjectName' -Value $MigrateProjectName -Options (Get-LabMigrateProjectNames -ResourceGroupName $SourceResourceGroup) -Kind ProjectName -Prompt 'Azure Migrate project' -EmptyHelp "Create the project in the portal (Module 1 section 1), then rerun migrate-step1-setup-project.ps1 with the same environment settings."
# Every historical workload group uses this same Hyper-V pipeline. Vault/provider
# evidence remains reachable even when a later sizing guard blocks the preflight.
$script:LabVaultReport.Inputs.Subscription = Format-LabSubscriptionId $script:LabSubscriptionId
$script:LabVaultReport.Inputs.SourceResourceGroup = $SourceResourceGroup
$script:LabVaultReport.Inputs.TargetResourceGroup = $TargetResourceGroup
$script:LabVaultReport.Inputs.TargetLocation = $Location
$script:LabVaultReport.Inputs.Workload = $Workload
if ([string]::IsNullOrWhiteSpace($VaultResourceGroup)) { $VaultResourceGroup = $SourceResourceGroup }
$script:LabReplicationStage = 'project/REST'
$inspectionProject = Get-LabMigrateProjectRead -ResourceGroupName $SourceResourceGroup -Name $MigrateProjectName
$inspectionProjectId = Get-LabReplicationObjectId $inspectionProject 'project/REST' 'Microsoft.Migrate/migrateProjects' $script:LabSubscriptionId
$script:LabVaultReport.Inputs.ProjectId = $inspectionProjectId
Invoke-LabVaultInspection -ProjectId $inspectionProjectId -ScopeResourceGroup $VaultResourceGroup -ExplicitVaultId $VaultResourceId -ExplicitProviderId $RecoveryServicesProviderId



# Resource identity reads below fail closed; failed reads never authorize replication.

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
# Target recommendations are guidance only; original disk/licensing/IP fields are not changed.
$targetSnapshot = Get-LabRegionQuotaSnapshot -Location $Location
$targetRetail = Get-LabRetailSnapshot -Location $Location
$targetCandidates = @(Get-LabSizingCandidates -Skus $targetSnapshot.Skus -Usage $targetSnapshot.Usage -Location $Location)
$targetSizing = Get-LabCostTargetPlan -Candidates $targetCandidates -Usage $targetSnapshot.Usage -Retail $targetRetail -Location $Location
$script:LabReplicationStage = 'target-sizing/preflight'
$script:LabVaultReport.TargetSizing = 'BlockedOrUnresolved'
$targetSelection = Select-LabTargetVmSizes -Snapshot $targetSnapshot -Retail $targetRetail -Location $Location -Mapping $TargetVmSizes -MappingSupplied:($PSBoundParameters.ContainsKey('TargetVmSizes'))
if (-not $targetSelection.SelectionComplete) { throw ('[Blocked] Target VM selection unresolved: ' + ($targetSelection.Issues -join '; ')) }
$script:LabVaultReport.TargetSizing = 'SelectionValidatedNotCapacityGuaranteed'
Show-LabTargetSizeSelection -Selection $targetSelection

$vmConfigurations = @(
    @{
        # IIS web server -- serves the Contoso sample web application
        # Needs moderate CPU for request handling and some memory for IIS worker processes
        DisplayName    = "OnPrem-Web"
        TargetVMSize   = $null
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
        TargetVMSize   = $null
        OSType         = "Windows"
        DiskType       = "StandardSSD_LRS"
        LicenseType    = "WindowsServer"
        IPAddress      = "192.168.0.11"
    },
    @{
        # Nginx web server -- serves a static HTML site
        # Very lightweight -- Nginx is extremely memory-efficient
        DisplayName    = "OnPrem-Linux-Web"
        TargetVMSize   = $null
        OSType         = "Linux"
        DiskType       = "StandardSSD_LRS"
        LicenseType    = "NoLicenseType"
        IPAddress      = "192.168.0.12"
    },
    @{
        # Tomcat JSP order desk -- runs a REST API on port 3000
        # Moderate CPU for request handling, small memory footprint
        DisplayName    = "OnPrem-Linux-App"
        TargetVMSize   = $null
        OSType         = "Linux"
        DiskType       = "StandardSSD_LRS"
        LicenseType    = "NoLicenseType"
        IPAddress      = "192.168.0.13"
    }
)

foreach ($configuration in $vmConfigurations) {
    $choice = @($targetSelection.Selected | Where-Object { $_.DisplayName -ceq $configuration.DisplayName })
    if ($targetSelection.SelectionComplete -and $choice.Count -eq 1) { $configuration.TargetVMSize = $choice[0].Name }
}

# ================================================================
# WORKLOAD GROUP FILTER
# ================================================================
# Full four-role sizing remains the shared application plan. Group selection narrows
# read-only identity checks only; it never selects a different replication technology.
# Both pairs must be configured before tests and share the final Module 3 section 11 window.
$selected = $workloadGroup.SelectedWorkloads
$vmConfigurations = @($vmConfigurations | Where-Object { $selected -contains $_.DisplayName })
if ($selected.Count -eq 0 -or $vmConfigurations.Count -ne $selected.Count -or
    @($vmConfigurations | Where-Object { $_.DisplayName -notin $selected }).Count -gt 0) {
    throw '[backend-contract] Selected workload group is empty, incomplete or unknown. No replication writes were attempted.'
}
Write-Host "Workload filter: $Workload -> $($selected -join ', ')" -ForegroundColor Cyan

# ================================================================
Write-Section "Step 3: Hyper-V Replication Preflight (read-only)"
# ================================================================

Write-Log "Source Resource Group : $SourceResourceGroup"
Write-Log "Target Resource Group : $TargetResourceGroup"
Write-Log "Migrate Project       : $MigrateProjectName"
Write-Log "Selected VMs          : $($vmConfigurations.Count)"
Show-LabCostTargetPlan -Plan $targetSizing -Location $Location -Names @($vmConfigurations | ForEach-Object { $_.DisplayName })
foreach ($vmConfig in $vmConfigurations) { Write-Host "  $($vmConfig.DisplayName) -> $($vmConfig.TargetVMSize)" -ForegroundColor Cyan }
Write-Warning 'AutoCost is not assessment-derived and cannot establish Hyper-V provider or guest readiness. No allocation, automatic retry, fallback or capacity guarantee.'
Write-Host ""

function Get-LabReplicationApiDecision {
    param([AllowNull()]$MigrateCommand, [AllowNull()]$AsrCommand)
    $blocker = 'Az.Migrate replication command is unavailable.'
    if ($null -ne $MigrateCommand) {
        $blocker = 'Installed replication schema is not a verified Azure Migrate Hyper-V-to-Azure contract.'
        foreach ($set in @(Get-LabReplicationField $MigrateCommand 'ParameterSets')) {
            foreach ($parameter in @(Get-LabReplicationField $set 'Parameters')) {
                $type = Get-LabReplicationField $parameter 'ParameterType'
                if ($null -ne $type -and (Get-LabReplicationField $type 'FullName') -match '(?i)VMware|VMwareCbt') {
                    $blocker = 'Az.Migrate replication uses VMware/VMwareCbt inputs, not Hyper-V machine identities.'
                }
            }
        }
    }
    $asrHyperV = $false
    foreach ($set in @(Get-LabReplicationField $AsrCommand 'ParameterSets')) {
        foreach ($parameter in @(Get-LabReplicationField $set 'Parameters')) {
            if ((Get-LabReplicationField $parameter 'Name') -eq 'HyperVToAzure') { $asrHyperV = $true }
        }
    }
    if ($asrHyperV) {
        $blocker += ' ASR HyperVToAzure is a DR API; support against this Migrate project vault and exact VM-GUID/host mapping is not verified.'
    }
    return [pscustomobject]@{ Path = 'Portal'; CanWrite = $false; AsrHyperVSurface = $asrHyperV; Blocker = $blocker }
}

# ================================================================
# REPLICATION BACKEND PREFLIGHT
# ================================================================
# Az.Migrate's published replication commands use VMwareCbt. Azure Migrate's documented
# Hyper-V path is the portal. ASR HyperVToAzure is DR, not a verified replacement against
# a Migrate-created vault; never create a separate vault/policy or guess a resource name.
Write-StepHeader -Step 0 -Title 'Read-only Hyper-V replication capability and identity preflight'
Write-Host 'Selected-group Hyper-V preflight: follow Modules 2 and 3 manually using the same existing host provider; configure both pairs before either test walkthrough.' -ForegroundColor Cyan
Write-Host 'Hold one shared final cutover for Module 3 section 11. No test, cleanup, cutover or source shutdown runs here.' -ForegroundColor Yellow

$script:LabReplicationStage = 'installed-command-contracts'
$discoveryCommand = Get-Command -Name Get-AzMigrateDiscoveredServer -ErrorAction SilentlyContinue
$solutionCommand = Get-Command -Name Get-AzMigrateSolution -ErrorAction SilentlyContinue
$migrateCommand = Get-Command -Name New-AzMigrateServerReplication -ErrorAction SilentlyContinue
$asrCommand = Get-Command -Name New-AzRecoveryServicesAsrReplicationProtectedItem -ErrorAction SilentlyContinue
foreach ($entry in @(
    @{ Label = 'discovery'; Command = $discoveryCommand },
    @{ Label = 'Migrate solution read'; Command = $solutionCommand },
    @{ Label = 'Migrate replication'; Command = $migrateCommand },
    @{ Label = 'ASR replication'; Command = $asrCommand }
)) {
    $module = Get-LabReplicationField $entry.Command 'Module'
    $moduleName = [string](Get-LabReplicationField $module 'Name')
    if ([string]::IsNullOrWhiteSpace($moduleName)) { $moduleName = 'module unknown' }
    $version = if ($null -ne $entry.Command) { [string](Get-LabReplicationField $module 'Version') } else { 'not available' }
    if ([string]::IsNullOrWhiteSpace($version)) { $version = 'version unknown' }
    Write-Host "  Installed $($entry.Label) command: $moduleName $version" -ForegroundColor Gray
}
$apiDecision = Get-LabReplicationApiDecision -MigrateCommand $migrateCommand -AsrCommand $asrCommand
Write-Warning "[backend-contract] $($apiDecision.Blocker)"

$diagnosticProblems = @()
if (-not $targetSelection.SelectionComplete -or $targetSnapshot.Issues.Count -gt 0) { $diagnosticProblems += 'target-sizing/selection-quota-unresolved' }
$selectedMachines = @()
$projectId = $null
try {
    $script:LabReplicationStage = 'target-resource-group/Get-AzResourceGroup'
    $targetRg = Get-AzResourceGroup -Name $TargetResourceGroup -ErrorAction Stop
    $targetRgId = Get-LabReplicationObjectId $targetRg $script:LabReplicationStage 'Microsoft.Resources/resourceGroups' $script:LabSubscriptionId
    $script:LabReplicationStage = 'target-network/Get-AzVirtualNetwork'
    $targetVNetName = "$TargetResourceGroup-vnet"
    $targetVNet = Get-AzVirtualNetwork -Name $targetVNetName -ResourceGroupName $TargetResourceGroup -ErrorAction Stop
    $targetVNetId = Get-LabReplicationObjectId $targetVNet $script:LabReplicationStage 'Microsoft.Network/virtualNetworks' $script:LabSubscriptionId
    if (-not $targetVNetId.StartsWith(($targetRgId + '/providers/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw '[target-network] Target network is outside the selected target resource group. No changes were made.'
    }
    $subnets = @(Get-LabReplicationField $targetVNet 'Subnets' | Where-Object { (Get-LabReplicationField $_ 'Name') -eq 'default' })
    if ($subnets.Count -ne 1) { throw '[target-subnet] Exactly one default subnet must exist. No changes were made.' }
    $null = Get-LabReplicationObjectId $subnets[0] 'target-subnet' 'Microsoft.Network/virtualNetworks/subnets' $script:LabSubscriptionId
    $script:LabReplicationStage = 'project/REST'
    $project = Get-LabMigrateProjectRead -ResourceGroupName $SourceResourceGroup -Name $MigrateProjectName
    $projectId = Get-LabReplicationObjectId $project 'project/REST' 'Microsoft.Migrate/migrateProjects' $script:LabSubscriptionId
    Write-Host '  Target group, network, subnet and project resource identities validated (read-only).' -ForegroundColor Green
} catch {
    $diagnosticProblems += $script:LabReplicationStage
    Write-Warning "[$script:LabReplicationStage] Read-only target/project validation failed (requires one object with valid, consistent Id/ResourceId fields, target ownership and one default subnet); no absence or permission assumption was made. Verify access and inspect the named resource in the portal. No replication write was attempted."
}

Write-Host "  Project association: $($script:LabVaultReport.ProjectAssociation.State) / $($script:LabVaultReport.ProjectAssociation.AssociationSource). Independent vault/provider inventory is recorded in the JSON report." -ForegroundColor Cyan

if (Test-LabReplicationCommandContract -Command $discoveryCommand -Parameters @('ProjectName', 'ResourceGroupName', 'SourceMachineType') -Types @{ ProjectName = [string]; ResourceGroupName = [string]; SourceMachineType = [string] }) {
    try {
        $script:LabReplicationStage = 'source-inventory/Get-AzMigrateDiscoveredServer'
        $discoveredServers = @(Get-AzMigrateDiscoveredServer -ProjectName $MigrateProjectName -ResourceGroupName $SourceResourceGroup -SourceMachineType 'HyperV' -ErrorAction Stop)
        $selectedMachines = @(Get-LabReplicationSelectedMachines -Inventory $discoveredServers -Configurations $vmConfigurations -SubscriptionId $script:LabSubscriptionId)
        $script:LabVaultReport.SourceInventory = @($selectedMachines | ForEach-Object { [pscustomobject]@{ VMName = $_.VMName; DiscoveredId = $_.DiscoveredId; ProtectedItemMapping = 'NotVerified' } })
        Write-Host "  Selected discovered Hyper-V identities validated: $($selectedMachines.Count)/$($vmConfigurations.Count)." -ForegroundColor Green
        foreach ($machine in $selectedMachines) {
            $discoveredNameGuid = [guid]::Empty
            $isGuidName = [guid]::TryParse($machine.DiscoveredId.Split('/')[-1], [ref]$discoveredNameGuid)
            Write-Host "    $($machine.VMName): ARM type HyperVSites/machines; discoveredNameIsGuid=$isGuidName; replication state NOT VERIFIED" -ForegroundColor Gray
        }
    } catch {
        $diagnosticProblems += $script:LabReplicationStage
        Write-Warning "[$script:LabReplicationStage] Selected inventory could not be proven complete, unique and correctly typed. A failed read is NOT an absent or unreplicated VM. Verify the selected machines in this project's portal inventory."
    }
} else {
    $diagnosticProblems += 'source-inventory/installed-command-contract'
    Write-Warning '[source-inventory/installed-command-contract] Discovery parameters, required arguments or input types do not match the installed cmdlet. No discovery call or replication write was attempted.'
}

Write-Section 'STEP 3 BLOCKED -- Hyper-V portal action required'
Write-Host "  Selected workload: $Workload ($($vmConfigurations.Count) VMs)" -ForegroundColor White
Write-Host '  Explicit target choices (not assessment-derived; full four-workload plan validated):' -ForegroundColor White
foreach ($vmConfig in $vmConfigurations) { Write-Host "    $($vmConfig.DisplayName) -> $($vmConfig.TargetVMSize); OS=$($vmConfig.OSType); disk=$($vmConfig.DiskType)" -ForegroundColor Cyan }
Write-Host '  Replication writes submitted: 0. Existing replication was not overwritten or resized.' -ForegroundColor Yellow
Write-Host '  Replication readiness: NOT VERIFIED. No module replication/monitoring sections are claimed complete.' -ForegroundColor Yellow
Write-Host '  ResourceName binding failure: the original failing call cannot be proven without its stack; it is not evidence of an assessment or target-SKU fault.' -ForegroundColor Gray
if ($diagnosticProblems.Count -gt 0) { Write-Host "  Read-only diagnostic blockers: $($diagnosticProblems -join ', ')" -ForegroundColor Yellow }
if ($script:LabVaultReport.PortalConfigurationGuidanceAllowed) {
Write-NextSteps @(
    "Open Azure portal > Azure Migrate > $MigrateProjectName > Migration / Server Migration > Replicate."
    'Supported Hyper-V portal procedure: https://learn.microsoft.com/azure/migrate/tutorial-migrate-hyper-v'
    'Inspect existing replication and jobs first. For only genuinely missing sources, select Hyper-V and the workload VMs listed above after exact source GUID/host verification. Do not create a separate ASR vault.'
    'Confirm each actual source VM GUID and registered Hyper-V host, not just a matching display name, before selecting it.'
    'Review Windows licensing eligibility explicitly in the portal wizard; no Azure Hybrid Benefit is applied by this script.'
    'For genuinely missing replication only: Review + Start replication is a separate explicit manual action. It starts initial replication, not cutover or source shutdown.'
    "Confirm target resource group '$TargetResourceGroup', region '$Location', VNet '$TargetResourceGroup-vnet', subnet 'default', each requested VM size and actual OS disk in the wizard."
    'Review Step 1 in the SAME target region and the current ranked alternatives above. Confirm Hyper-V provider, original disk and guest driver readiness in the portal. No SKU fallback or capacity guarantee.'
    'If a selected VM already replicates, inspect and reuse that exact source VM/host entry; do not overwrite it to match a recommendation.'
    'Monitor ONLY this selected set in the portal. Submission or an in-progress job is not replication readiness; there is no fixed completion-time or cost promise.'
    'If a previous attempt may have submitted a job, inspect the project replication jobs and live selected-source state before retrying; a failed lookup does not authorize creation.'
    'Follow Module 2 sections 7-8 and Module 3 sections 9-10 for selected-group monitoring/tests; both pairs use the same Hyper-V provider and must be configured before testing.'
    'Use the manual portal stages in the modules, not unverified Step 4/5 automation. No test, cleanup or cutover is run or authorized here.'
    'Keep both pairs replicating and hold final cutover for the one shared maintenance window in Module 3 section 11; frontend readiness alone does not authorize application cutover.'
)
} else {
    Write-NextSteps @(
        'Read-only inventory only: inspect this existing project/vault, actual target VNet region and any region lock in the portal. No replacement vault is authorized.'
        'Configuration guidance is withheld until the existing vault region matches the actual target VNet and provisioning is Succeeded. Provider/replication inventory is not readiness.'
        'Inspect existing replication/jobs using exact source VM GUID and registered Hyper-V host; do not reinitialize, overwrite or resize existing replication.'
        'Follow the manual module stages after resolving blockers. No test, cleanup or cutover is authorized; hold the shared final window for Module 3 section 11.'
    )
}
$script:LabReplicationStage = 'backend-contract'
throw '[backend-contract] No verified Azure Migrate Hyper-V PowerShell replication backend is available in this script. Portal replication and selected-set monitoring are required; Step 3 did not complete. No replication writes were attempted.'
