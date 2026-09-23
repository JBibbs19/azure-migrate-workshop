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
$TestVNetName = Read-LabParameter -Name 'TestVNetName' -Value $TestVNetName -Kind VMName -Prompt 'Isolated test VNet name' -Example 'test-migrate-vnet'
$TestVNetAddressSpace = Read-LabParameter -Name 'TestVNetAddressSpace' -Value $TestVNetAddressSpace -Kind Cidr -Prompt 'Test VNet address space (must not overlap 10.0.0.0/16 or 10.1.0.0/16)' -Example '10.2.0.0/16'
$TestSubnetPrefix = Read-LabParameter -Name 'TestSubnetPrefix' -Value $TestSubnetPrefix -Kind Cidr -Prompt 'Test subnet prefix (inside the test VNet)' -Example '10.2.0.0/24'
$Workload = Read-LabParameter -Name 'Workload' -Value $Workload -Kind Workload -Prompt 'Workload group: All (four VMs), Agentless (OnPrem-Web, OnPrem-Linux-Web) or AgentBased (OnPrem-SQL, OnPrem-Linux-App)' -Example 'All'
if (-not (Test-LabCidrContains -Outer $TestVNetAddressSpace -Inner $TestSubnetPrefix)) {
    throw "Test subnet $TestSubnetPrefix is not inside the test VNet address space $TestVNetAddressSpace. Rerun and enter a subnet within the VNet."
}

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
    Write-StepInfo "Logged in to subscription: $($context.Subscription.Name) `($(Format-LabSubscriptionId $context.Subscription.Id)`)"
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
