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
$Location = Read-LabParameter -Name 'Location' -Value $Location -Kind Region -Prompt 'Azure target region chosen in Module 0' -Example 'eastus'
$MigrateProjectName = Read-LabParameter -Name 'MigrateProjectName' -Value $MigrateProjectName -Kind ProjectName -Prompt 'Azure Migrate project name' -Example 'ces-migrate-01'


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
