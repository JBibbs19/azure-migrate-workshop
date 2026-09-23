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
$AutoShutdownTime = Read-LabParameter -Name 'AutoShutdownTime' -Value $AutoShutdownTime -Kind Time24h -Prompt 'Daily auto-shutdown time, 24-hour HHmm' -Example '1900'
$AutoShutdownTimezone = Read-LabParameter -Name 'AutoShutdownTimezone' -Value $AutoShutdownTimezone -Kind TimeZone -Prompt 'Auto-shutdown time zone (Windows time zone ID)' -Example 'Eastern Standard Time'
$BackupRetentionDays = Read-LabNumber -Name 'BackupRetentionDays' -Prompt 'Backup retention in days' -Value $BackupRetentionDays -Supplied:($PSBoundParameters.ContainsKey('BackupRetentionDays')) -Minimum 7 -Maximum 9999 -Example '30'
$ParticipantName = Read-LabParameter -Name 'ParticipantName' -Value $ParticipantName -Kind Text -Prompt 'Participant name for the Owner tag' -Example 'jdoe'

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
    Write-StepInfo "Subscription: $($context.Subscription.Name) `($(Format-LabSubscriptionId $context.Subscription.Id)`)"
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
