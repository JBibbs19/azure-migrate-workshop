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
# the command line; no value is taken silently from a default. The subscription and
# tenant IDs are truncated wherever this script writes to the console.
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'migrate-common.ps1')
$null = Enable-LabOutputMasking
trap { Write-LabTerminatingError $_; exit 1 }

Write-Host ""
Write-Host "Enter the values for your lab environment (examples are hints only; Enter does not accept them)." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabParameter -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Kind ResourceGroup -Prompt 'Source resource group (contains HyperVHost)' -Example 'rg-ces-source-01'
$TargetResourceGroup = Read-LabParameter -Name 'TargetResourceGroup' -Value $TargetResourceGroup -Kind ResourceGroup -Prompt 'Target resource group (landing zone for migrated VMs)' -Example 'rg-ces-target-01'
$Location = Read-LabParameter -Name 'Location' -Value $Location -Kind Region -Prompt 'Azure target region chosen in Module 0' -Example 'eastus'
$MigrateProjectName = Read-LabParameter -Name 'MigrateProjectName' -Value $MigrateProjectName -Kind ProjectName -Prompt 'Azure Migrate project name' -Example 'ces-migrate-01'

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
    Write-Log "Subscription   : $($context.Subscription.Name) `($(Format-LabSubscriptionId $context.Subscription.Id)`)"
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
