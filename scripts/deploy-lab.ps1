<#
.SYNOPSIS
Deploy the TD SYNNEX Cloud Enablement Services Hyper-V workshop.
.DESCRIPTION
Creates one Standard-security Windows host and provisions four nested workload VMs
(two Windows, two Linux) that behave as one small-business environment. No appliance
OS VM is created: Module 1 downloads the Azure Migrate appliance VHD onto the host's
own OS disk and imports it. This script creates billable Azure resources.
Use a new dedicated resource group. Existing groups are refused intentionally.
.PARAMETER SubscriptionId
The workshop subscription GUID, supplied as a SecureString so it is masked at the prompt
rather than displayed on a shared screen. It is not treated as a stored secret.
.PARAMETER AdminSourceCidr
Your public IPv4 address as a /32, supplied as a SecureString for the same reason.
Required for the host RDP rule.
.PARAMETER AzureOperationTimeoutMinutes
Maximum monitored wait for each Azure host, network or disk creation operation.
.PARAMETER GuestSetupTimeoutMinutes
Azure's execution limit for ConfigureWorkshop; individual installer limits also apply.
.PARAMETER ApplianceStoreSizeGB
Size of the dedicated partition carved out of the host OS disk for the Azure Migrate
appliance. The guest VHDs never touch it, so the appliance has capacity of its own.
.PARAMETER ApplianceStoreDriveLetter
Drive letter for that partition inside HyperVHost. Leave it unset and deployment uses the
first unassigned letter, which is E: on the default host size: C: is the OS disk and D: is
the virtual DVD drive. Supply a letter only to override that choice.
.PARAMETER HealthPath
Local JSON status summary, without credentials or raw Run Command output.
.EXAMPLE
$secureSubscriptionId = Read-Host 'Workshop subscription ID' -AsSecureString
$secureAdminCidr = Read-Host 'Your public IPv4 address followed by /32' -AsSecureString
$password = Read-Host 'Lab password' -AsSecureString
.\scripts\deploy-lab.ps1 -SubscriptionId $secureSubscriptionId -ResourceGroupName 'rg-ces-source-01' -AdminUsername 'labadmin' -AdminPassword $password -AdminSourceCidr $secureAdminCidr
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][SecureString]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,60}$')][string]$ResourceGroupName,
    [string]$Location = 'eastus',
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,18}$')][string]$AdminUsername,
    [Parameter(Mandatory)][SecureString]$AdminPassword,
    [Parameter(Mandatory)][SecureString]$AdminSourceCidr,
    [string]$VMSize = 'Standard_E8s_v7',
    [ValidateRange(15,120)][int]$AzureOperationTimeoutMinutes = 60,
    [ValidateRange(30,240)][int]$GuestSetupTimeoutMinutes = 240,
    [ValidateRange(60,400)][int]$ApplianceStoreSizeGB = 100,
    [ValidatePattern('^([D-Zd-z])?$')][string]$ApplianceStoreDriveLetter = '',
    [string]$HealthPath
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
# Both values arrive masked. Convert once, validate, then use the plain form internally.
$subscriptionIdPlain = ConvertFrom-LabSecureString -Secure $SubscriptionId -Name 'SubscriptionId'
Assert-LabSubscriptionId $subscriptionIdPlain
$adminSourceCidrPlain = ConvertFrom-LabSecureString -Secure $AdminSourceCidr -Name 'AdminSourceCidr'
$hostScript = Read-LabHostConfiguration "$PSScriptRoot/host/configure-host.ps1"
. "$PSScriptRoot/health.ps1"
Initialize-LabProgress -Activity 'TD SYNNEX | Hyper-V deployment' -Steps @(
    'Source deployment', 'Create source network', 'Create host public IP', 'Create host firewall rules',
    'Create host network interface', 'Create Azure host', 'Install Hyper-V and DHCP', 'Restart Azure host',
    'Check Hyper-V readiness', 'Create appliance store partition', 'Create guest image disk',
    'Submit guest setup', 'Guest setup'
)
if (-not $HealthPath) { $HealthPath = Join-Path $PSScriptRoot "../.artifacts/deployment-health-$ResourceGroupName.json" }
Assert-LabAdminSource $adminSourceCidrPlain
Assert-LabHostSizeName $VMSize
foreach ($module in @('Az.Accounts','Az.Resources','Az.Network','Az.Compute')) {
    Import-Module $module -ErrorAction Stop
}
$null = Assert-LabContext $subscriptionIdPlain
foreach ($command in @('Set-AzVMRunCommand','Get-AzVMRunCommand')) { $null = Get-Command $command -ErrorAction Stop }
if (-not (Get-Command Set-AzVMRunCommand).Parameters.ContainsKey('ProtectedParameter')) { throw 'Update Az.Compute; managed Run Command protected parameters are required.' }
if ($AdminUsername -in @('admin','administrator','root','guest','user','test')) { throw 'Choose a non-reserved administrator username, such as labadmin.' }
$credential = [pscredential]::new($AdminUsername,$AdminPassword)
$passwordPlain = $credential.GetNetworkCredential().Password
if ($passwordPlain.Length -lt 12 -or $passwordPlain.Length -gt 72 -or $passwordPlain -match '[\r\n\x00-\x1f]') { throw 'Use a 12-72 character lab password without control characters.' }
$classes = @('[a-z]','[A-Z]','[0-9]','[^a-zA-Z0-9]') | Where-Object { $passwordPlain -cmatch $_ }
if (@($classes).Count -lt 3) { throw 'The password must include at least three character categories: lower, upper, number, symbol.' }
$runNameProbe = 'ConfigureWorkshop'
# An existing group is allowed only when it is this workshop's own and its host never
# finished provisioning, so an interrupted run resumes instead of costing a full rebuild.
# A group that is not tagged as this workshop, or whose host completed setup, is refused:
# replaying provisioning after migration has begun could restart retired source VMs.
$existingGroup = Get-LabResourceGroup -Name $ResourceGroupName -AllowMissing
$resumeDeployment = $false
if ($existingGroup) {
    if (-not $existingGroup.Tags -or $existingGroup.Tags['Workshop'] -ne 'TD-SYNNEX-CES-HyperV') {
        throw "Resource group '$ResourceGroupName' exists and is not tagged as this workshop. Use a new, dedicated source resource group."
    }
    $existingHost = Get-AzVM -ResourceGroupName $ResourceGroupName -Name 'HyperVHost' -ErrorAction SilentlyContinue
    if (-not $existingHost) {
        throw "Resource group '$ResourceGroupName' exists but has no HyperVHost. Inspect and remove it, then deploy into a clean group."
    }
    $completed = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName 'HyperVHost' -RunCommandName $runNameProbe -Expand InstanceView -ErrorAction SilentlyContinue
    if ($completed -and [string]$completed.InstanceView.ExecutionState -eq 'Succeeded') {
        throw "Guest setup already succeeded in '$ResourceGroupName'. Deployment is not a post-migration repair command; use a new group for a fresh lab."
    }
    $resumeDeployment = $true
    Write-Host "Resuming the incomplete deployment in '$ResourceGroupName'. Existing resources are reused; unfinished guests are rebuilt."
}
$hostSku = Get-LabHostSku -VMSize $VMSize -Location $Location
$windowsImages = Get-LabWindowsImages -Location $Location
$guestDiskConfig = New-LabWindowsGuestDiskConfig -Location $Location -ImageId $windowsImages.Guest.Id
Write-Host "Selected host: $($hostSku.Name), $($hostSku.Cores) enabled vCPUs, $($hostSku.MemoryGB) GiB RAM. Confirm this series supports nested virtualization with Standard security before running deployment."
$storeDriveLabel = if ($ApplianceStoreDriveLetter) { "$($ApplianceStoreDriveLetter.ToUpperInvariant()):" } else { 'the first unassigned drive letter, normally E:' }
Write-Host "Appliance store: a $ApplianceStoreSizeGB GB partition is created as $storeDriveLabel for the Module 1 appliance VHD."
Write-Host 'Guest disks are fixed, not dynamic: 140 GB is allocated in full during setup, which adds roughly 20-40 minutes to deployment.'
foreach ($provider in @('Microsoft.Compute','Microsoft.Network','Microsoft.Storage','Microsoft.Migrate','Microsoft.OffAzure','Microsoft.RecoveryServices','Microsoft.KeyVault')) {
    $state = @(Get-AzResourceProvider -ProviderNamespace $provider)[0].RegistrationState
    if ($state -ne 'Registered') { throw "Register $provider first with Register-AzResourceProvider and wait until Registered." }
}
Write-Host "Creating source lab in the selected subscription, region $Location."
Write-LabHealth 'Source deployment' Preparing 0 'Preflight passed. Starting dedicated workshop resource creation.' $HealthPath
$tags = @{ Workshop = 'TD-SYNNEX-CES-HyperV'; Team = 'Cloud Enablement Services'; Purpose = 'Training' }
$vmName = 'HyperVHost'
$diskName = 'WinServerBase-temp'
# Resolved by the host during the store step, since only the host knows which letters are free.
$storeDrive = $null
$appliancePath = $null
$runName = 'ConfigureWorkshop'
$diskCreated = $false
$runCreated = $false
$setupPassed = $false
$setupObservation = @{ Terminal = $false }
$deploymentClock = [Diagnostics.Stopwatch]::StartNew()
try {
    if (-not $resumeDeployment) { New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $tags | Out-Null }
    # Every resource below is created only when absent, so a resumed run continues from the
    # point the previous attempt stopped instead of rebuilding what already exists.
    $vnet = Get-AzVirtualNetwork -Name "$ResourceGroupName-vnet" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($vnet) { Write-Host 'Reusing the existing source network.' } else {
        $subnet = New-AzVirtualNetworkSubnetConfig -Name default -AddressPrefix '10.0.0.0/24' -DefaultOutboundAccess $false
        $job = New-AzVirtualNetwork -Name "$ResourceGroupName-vnet" -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix '10.0.0.0/16' -Subnet $subnet -AsJob
        $vnet = Wait-LabJob $job 'Create source network' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    # The host's attached Standard public IP provides explicit outbound connectivity.
    $pip = Get-AzPublicIpAddress -Name "$vmName-pip" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($pip) { Write-Host 'Reusing the existing host public IP.' } else {
        $job = New-AzPublicIpAddress -Name "$vmName-pip" -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard -AsJob
        $pip = Wait-LabJob $job 'Create host public IP' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    $nsg = Get-AzNetworkSecurityGroup -Name "$vmName-nsg" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($nsg) { Write-Host 'Reusing the existing host firewall rules.' } else {
        $rdp = New-AzNetworkSecurityRuleConfig -Name Allow-RDP -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix $adminSourceCidrPlain -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389
        $job = New-AzNetworkSecurityGroup -Name "$vmName-nsg" -ResourceGroupName $ResourceGroupName -Location $Location -SecurityRules $rdp -AsJob
        $nsg = Wait-LabJob $job 'Create host firewall rules' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    $nic = Get-AzNetworkInterface -Name "$vmName-nic" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($nic) { Write-Host 'Reusing the existing host network interface.' } else {
        $job = New-AzNetworkInterface -Name "$vmName-nic" -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id -EnableAcceleratedNetworking:$hostSku.AcceleratedNetworking -AsJob
        $nic = Wait-LabJob $job 'Create host network interface' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    $existingHostVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction SilentlyContinue
    if ($existingHostVm) { Write-Host 'Reusing the existing Azure host; Hyper-V setup is re-verified below.' }
    else {
    $vm = New-AzVMConfig -VMName $vmName -VMSize $VMSize -SecurityType Standard
    $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $vmName -Credential $credential -ProvisionVMAgent -EnableAutoUpdate
    $vm = Set-AzVMSourceImage -VM $vm -PublisherName $windowsImages.Host.Publisher -Offer $windowsImages.Host.Offer -Skus $windowsImages.Host.Sku -Version $windowsImages.Host.Version
    $vm = Set-AzVMOSDisk -VM $vm -Name "$vmName-osdisk" -CreateOption FromImage -StorageAccountType Premium_LRS -DiskSizeInGB 512
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id
    $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
    $job = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vm -Tag $tags -AsJob
    $null = Wait-LabJob $job 'Create Azure host' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    # Idempotent on the host: Install-WindowsFeature is a no-op when the role is present.
    $install = @'
$ErrorActionPreference = 'Stop'
$result = Install-WindowsFeature Hyper-V,DHCP -IncludeManagementTools
if (-not $result.Success) { throw 'Hyper-V installation failed.' }
Write-Output 'HYPERV_INSTALLED'
'@
    $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId RunPowerShellScript -ScriptString $install -AsJob
    $result = Wait-LabJob $job 'Install Hyper-V and DHCP' -TimeoutSeconds 1800 -HealthPath $HealthPath
    $null = Assert-LabRunResult $result 'HYPERV_INSTALLED'
    $job = Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -AsJob
    $null = Wait-LabJob $job 'Restart Azure host' -TimeoutSeconds 900 -HealthPath $HealthPath
    $ready = $false
    $readinessClock = [Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        try {
            $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId RunPowerShellScript -ScriptString "if ((Get-Service vmms).Status -ne 'Running') { throw 'Hyper-V not ready' }; Write-Output 'HYPERV_READY'" -AsJob
            $probe = Wait-LabJob $job 'Check Hyper-V readiness' -TimeoutSeconds 120 -HealthPath $HealthPath
            $null = Assert-LabRunResult $probe 'HYPERV_READY'
            $ready = $true; break
        } catch {
            Write-LabHealth 'Check Hyper-V readiness' Warning $readinessClock.Elapsed.TotalSeconds 'VM agent and Hyper-V service are not ready; retrying within the readiness limit.' $HealthPath -TimeoutSeconds 900
        }
    }
    if (-not $ready) { throw 'Hyper-V host did not become ready.' }
    # The guest VHDs are fixed and consume 140 GB of the OS disk in full. Carve a dedicated
    # partition for the appliance out of the remainder so the two never compete, and do it
    # before any guest disk work so a capacity problem surfaces in minutes, not an hour.
    $storeTemplate = @'
$ErrorActionPreference = 'Stop'
$requested = '__DRIVE__'
$storeBytes = __STOREGB__GB
$label = 'ApplianceStore'
$guestReserveBytes = 140GB
$existing = Get-Volume -FileSystemLabel $label -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
    $letter = $existing.DriveLetter
} else {
    # Only the host knows which letters are free. C: is the OS disk, and on a size with no
    # local temporary disk Windows gives the next letter to the virtual DVD drive, so the
    # first unassigned letter is normally E:. Nothing is moved or reassigned.
    $taken = @()
    $taken += @(Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter.TrimEnd(':').ToUpperInvariant() })
    $taken += @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.Length -eq 1 } | ForEach-Object { $_.Name.ToUpperInvariant() })
    if ($requested) {
        $letter = $requested.ToUpperInvariant()
        if ($letter -in $taken) {
            $occupant = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '${letter}:'" -ErrorAction SilentlyContinue
            $detail = if ($occupant) { "type $($occupant.DriveType), label '$($occupant.Label)'" } else { 'an existing drive' }
            throw "Drive ${letter}: is already in use on this host ($detail). Omit -ApplianceStoreDriveLetter to take the first free letter, or choose another."
        }
    } else {
        $letter = @(68..90 | ForEach-Object { [char]$_ }) | Where-Object { $_ -notin $taken } | Select-Object -First 1
        if (-not $letter) { throw 'No unassigned drive letter is available for the appliance store.' }
    }
    $system = Get-Partition -DriveLetter C -ErrorAction Stop
    $supported = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    # Azure creates the OS disk at the requested size but leaves C: at the image's native
    # size, so most of the disk is normally unallocated. SizeMax is what C: could occupy --
    # its current size plus the adjacent free space -- so sizing C: to SizeMax minus the
    # store leaves exactly the store free, whether that means growing C: or shrinking it.
    $targetSize = $supported.SizeMax - $storeBytes
    $usedBytes = $system.Size - (Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining
    # C: must still hold Windows, the base images and the 140 GB of fixed guest disks.
    $needed = $guestReserveBytes + 60GB
    $toGB = { param($b) [math]::Round($b / 1GB, 1) }
    if ($targetSize -lt $supported.SizeMin) {
        $maxStore = & $toGB ($supported.SizeMax - $supported.SizeMin)
        throw ("Cannot reserve __STOREGB__ GB for the appliance store. C: is $(& $toGB $system.Size) GB and can range from $(& $toGB $supported.SizeMin) GB to $(& $toGB $supported.SizeMax) GB on this disk, so at most $maxStore GB can be set aside. Deploy with a larger OS disk, or pass -ApplianceStoreSizeGB with a value at or below $maxStore.")
    }
    if (($targetSize - $usedBytes) -lt $needed) {
        throw ("Reserving __STOREGB__ GB would leave C: with $(& $toGB ($targetSize - $usedBytes)) GB free, below the $(& $toGB $needed) GB the 140 GB of fixed guest disks and their base images require. Deploy with a larger OS disk or a smaller -ApplianceStoreSizeGB.")
    }
    if ($targetSize -ne $system.Size) {
        $action = if ($targetSize -gt $system.Size) { 'Extending' } else { 'Shrinking' }
        Write-Output ("{0} C: from {1} GB to {2} GB to free space for the appliance store." -f $action, (& $toGB $system.Size), (& $toGB $targetSize))
        Resize-Partition -DriveLetter C -Size $targetSize -ErrorAction Stop
    }
    $partition = New-Partition -DiskNumber $system.DiskNumber -UseMaximumSize -DriveLetter $letter -ErrorAction Stop
    $null = Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop
}
$store = Get-Volume -DriveLetter $letter -ErrorAction Stop
if ($store.FileSystemLabel -ne $label) { throw "Drive ${letter}: is not the appliance store." }
New-Item -ItemType Directory -Path "${letter}:\Appliance" -Force | Out-Null
# Grant the lab administrator explicit rights so a non-elevated browser download can write here.
& icacls.exe "${letter}:\Appliance" /grant:r '__ADMINUSER__:(OI)(CI)M' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not grant the lab administrator access to the appliance store.' }
$system = Get-Volume -DriveLetter C -ErrorAction Stop
Write-Output ("APPLIANCE_STORE_DRIVE|{0}" -f $letter)
Write-Output ("Appliance store {0}: {1} GB free; system C: {2} GB free before guest disks." -f $letter,
    [math]::Round($store.SizeRemaining/1GB,1), [math]::Round($system.SizeRemaining/1GB,1))
Write-Output 'APPLIANCE_STORE_READY'
'@
    $storeScript = $storeTemplate.Replace('__DRIVE__', $ApplianceStoreDriveLetter.ToUpperInvariant()).Replace('__STOREGB__', [string]$ApplianceStoreSizeGB).Replace('__ADMINUSER__', $AdminUsername)
    $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId RunPowerShellScript -ScriptString $storeScript -AsJob
    $storeResult = Wait-LabJob $job 'Create appliance store partition' -TimeoutSeconds 1800 -HealthPath $HealthPath
    $storeOutput = Assert-LabRunResult $storeResult 'APPLIANCE_STORE_READY'
    $driveMatch = [regex]::Match($storeOutput, '(?m)^APPLIANCE_STORE_DRIVE\|([A-Z])\r?$')
    if (-not $driveMatch.Success) { throw 'The appliance store step did not report which drive letter it used.' }
    $storeDrive = $driveMatch.Groups[1].Value
    $appliancePath = "${storeDrive}:\Appliance"
    Write-Host "Appliance store created as ${storeDrive}: ($ApplianceStoreSizeGB GB)."
    $stagingSummary = @($storeOutput -split "`n" | Where-Object { $_ -match 'GB free' } | ForEach-Object { $_.Trim() })[0]
    if (Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -ErrorAction SilentlyContinue) {
        Write-Host 'Reusing the existing guest image disk.'
    } else {
        $job = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Disk $guestDiskConfig -AsJob
        $null = Wait-LabJob $job 'Create guest image disk' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    $diskCreated = $true
    $access = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName -Access Read -DurationInSecond 18000
    $parameters = @(@{ Name = 'AdminUsername'; Value = $AdminUsername })
    $protected = @(@{ Name = 'AdminPassword'; Value = $passwordPlain }, @{ Name = 'WindowsVhdSasUrl'; Value = $access.AccessSAS })
    # A Run Command left by an interrupted attempt would block the new submission.
    $staleRun = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -ErrorAction SilentlyContinue
    if ($staleRun) {
        Write-Host 'Removing the Run Command left by the previous attempt before resubmitting.'
        Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -ErrorAction Stop | Out-Null
    }
    $runCreated = $true
    $job = Set-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -Location $Location -RunCommandName $runName `
        -SourceScript $hostScript -Parameter $parameters -ProtectedParameter $protected -TimeoutInSecond ($GuestSetupTimeoutMinutes * 60) -AsyncExecution -AsJob
    $null = Wait-LabJob $job 'Submit guest setup' -TimeoutSeconds 900 -HealthPath $HealthPath
    $null = Wait-LabManagedSetup -ReadStatus {
        Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -Expand InstanceView -ErrorAction Stop
    } -Observation $setupObservation -TimeoutSeconds (($GuestSetupTimeoutMinutes * 60) + 600) -HealthPath $HealthPath
    $setupPassed = $true
    Write-Host "Workload setup verified. Host public IP: $($pip.IpAddress). Host login: $AdminUsername."
    Write-Host 'Windows guests: Administrator and the supplied lab password. Linux guests: the supplied username/password.'
    Write-Host 'Four workload VMs are running: OnPrem-Web (.10), OnPrem-SQL (.11), OnPrem-Linux-Web (.12) and OnPrem-Linux-App (.13).'
    if ($stagingSummary) { Write-Host $stagingSummary }
    Write-Host 'Guest disks are fixed: OnPrem-Web 40 GB, OnPrem-SQL 40 GB, OnPrem-Linux-Web 30 GB, OnPrem-Linux-App 30 GB.'
    Write-Host 'Optional traffic generator staged on the host at C:\AzMigrateLab\enable-lab-traffic.ps1 with its settings file. It is not running; start it from HyperVHost if you want a populated dependency map.'
    Write-Host "Download and extract the Azure Migrate appliance VHD into $appliancePath on HyperVHost, then import and register it as described in docs/Module-1-Discovery.md."
} catch {
    try {
        $lastHealth = Get-Content -LiteralPath $HealthPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($lastHealth.State -ne 'NeedsReview') {
            Write-LabHealth 'Source deployment' NeedsReview $deploymentClock.Elapsed.TotalSeconds "Deployment stopped after $($lastHealth.Stage). Inspect the terminal and Azure/host diagnostics before retrying." $HealthPath
        }
    } catch { Write-Warning 'Could not update the local health summary. Preserve the terminal error and inspect Azure directly.' }
    throw
} finally {
    Complete-LabProgress
    $passwordPlain = $null
    $subscriptionIdPlain = $null
    $adminSourceCidrPlain = $null
    $protected = $null
    if ($diskCreated -and (-not $runCreated -or $setupObservation.Terminal)) {
        try {
            Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName | Out-Null
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Force | Out-Null
        } catch { Write-Warning 'Temporary disk cleanup failed. Revoke its export access and remove WinServerBase-temp in the source resource group.' }
    } elseif ($diskCreated) {
        Write-Warning 'Setup termination is unconfirmed. WinServerBase-temp is retained so a running download is not interrupted. Its export access expires after five hours; revoke access and remove the disk after confirming ConfigureWorkshop has stopped.'
    }
    if ($runCreated -and $setupPassed) {
        try { Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName | Out-Null }
        catch { Write-Warning 'Managed Run Command removal failed. Inspect and remove ConfigureWorkshop from the host when it has stopped.' }
    } elseif ($runCreated) {
        Write-Warning 'ConfigureWorkshop is retained for failure diagnostics. Inspect its instance view and remove it after it has stopped.'
    }
}
