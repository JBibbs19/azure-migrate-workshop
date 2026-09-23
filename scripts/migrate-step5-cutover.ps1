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
$MigrateProjectName = Read-LabParameter -Name 'MigrateProjectName' -Value $MigrateProjectName -Kind ProjectName -Prompt 'Azure Migrate project name' -Example 'ces-migrate-01'
$Location = Read-LabParameter -Name 'Location' -Value $Location -Kind Region -Prompt 'Azure target region chosen in Module 0' -Example 'eastus'
$TurnOffSourceVMs = Read-LabChoice -Prompt 'Shut down the source VMs before the final sync (recommended: Yes)' -Value $TurnOffSourceVMs
$Workload = Read-LabParameter -Name 'Workload' -Value $Workload -Kind Workload -Prompt 'Workload group: All (four VMs), Agentless (OnPrem-Web, OnPrem-Linux-Web) or AgentBased (OnPrem-SQL, OnPrem-Linux-App)' -Example 'All'

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
    Write-StepInfo "Subscription: $($context.Subscription.Name)"
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
