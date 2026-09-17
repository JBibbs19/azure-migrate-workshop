<#
.SYNOPSIS
Deploy the TD SYNNEX Cloud Enablement Services Hyper-V workshop.
.DESCRIPTION
Creates one Standard-security Windows host and provisions four nested workload VMs
(two Windows, two Linux) that behave as one small-business environment. No appliance
OS VM is created: Module 1 downloads the Azure Migrate appliance VHD onto the host's
dedicated staging volume and imports it. This script creates billable Azure resources.
Use a new dedicated resource group. Existing groups are refused intentionally.
.PARAMETER AdminSourceCidr
Your public IPv4 address as a /32. Required for the host RDP rule.
.PARAMETER AzureOperationTimeoutMinutes
Maximum monitored wait for each Azure host, network or disk creation operation.
.PARAMETER GuestSetupTimeoutMinutes
Azure's execution limit for ConfigureWorkshop; individual installer limits also apply.
.PARAMETER ApplianceStagingDiskSizeGB
Size of the data disk attached to the host for the Azure Migrate appliance VHD download
and extraction. It is kept free of lab guest disks so at least 30 GB stays unused.
.PARAMETER ApplianceStagingDiskType
Managed disk SKU for the staging disk. StandardSSD_LRS keeps the lab's cost lower;
Premium_LRS shortens extraction time.
.PARAMETER ApplianceStagingDriveLetter
Drive letter presented inside HyperVHost for the staging volume.
.PARAMETER HealthPath
Local JSON status summary, without credentials or raw Run Command output.
.EXAMPLE
$password = Read-Host 'Lab password' -AsSecureString
.\scripts\deploy-lab.ps1 -SubscriptionId $subscriptionId -ResourceGroupName 'rg-ces-source-01' -AdminUsername 'labadmin' -AdminPassword $password -AdminSourceCidr $adminCidr
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,60}$')][string]$ResourceGroupName,
    [string]$Location = 'eastus',
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,18}$')][string]$AdminUsername,
    [Parameter(Mandatory)][SecureString]$AdminPassword,
    [Parameter(Mandatory)][string]$AdminSourceCidr,
    [string]$VMSize = 'Standard_E8s_v7',
    [ValidateRange(15,120)][int]$AzureOperationTimeoutMinutes = 60,
    [ValidateRange(30,240)][int]$GuestSetupTimeoutMinutes = 240,
    [ValidateRange(64,4095)][int]$ApplianceStagingDiskSizeGB = 128,
    [ValidateSet('StandardSSD_LRS','Premium_LRS')][string]$ApplianceStagingDiskType = 'StandardSSD_LRS',
    [ValidatePattern('^[E-Ze-z]$')][string]$ApplianceStagingDriveLetter = 'L',
    [string]$HealthPath
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/common.ps1"
$hostScript = Read-LabHostConfiguration "$PSScriptRoot/host/configure-host.ps1"
. "$PSScriptRoot/health.ps1"
Initialize-LabProgress -Activity 'TD SYNNEX | Hyper-V deployment' -Steps @(
    'Source deployment', 'Create source network', 'Create host public IP', 'Create host firewall rules',
    'Create host network interface', 'Create Azure host', 'Install Hyper-V and DHCP', 'Restart Azure host',
    'Check Hyper-V readiness', 'Prepare appliance staging volume', 'Create guest image disk',
    'Submit guest setup', 'Guest setup'
)
if (-not $HealthPath) { $HealthPath = Join-Path $PSScriptRoot "../.artifacts/deployment-health-$ResourceGroupName.json" }
Assert-LabAdminSource $AdminSourceCidr
Assert-LabHostSizeName $VMSize
foreach ($module in @('Az.Accounts','Az.Resources','Az.Network','Az.Compute')) {
    Import-Module $module -ErrorAction Stop
}
$null = Assert-LabContext $SubscriptionId
foreach ($command in @('Set-AzVMRunCommand','Get-AzVMRunCommand')) { $null = Get-Command $command -ErrorAction Stop }
if (-not (Get-Command Set-AzVMRunCommand).Parameters.ContainsKey('ProtectedParameter')) { throw 'Update Az.Compute; managed Run Command protected parameters are required.' }
if ($AdminUsername -in @('admin','administrator','root','guest','user','test')) { throw 'Choose a non-reserved administrator username, such as labadmin.' }
$credential = [pscredential]::new($AdminUsername,$AdminPassword)
$passwordPlain = $credential.GetNetworkCredential().Password
if ($passwordPlain.Length -lt 12 -or $passwordPlain.Length -gt 72 -or $passwordPlain -match '[\r\n\x00-\x1f]') { throw 'Use a 12-72 character lab password without control characters.' }
$classes = @('[a-z]','[A-Z]','[0-9]','[^a-zA-Z0-9]') | Where-Object { $passwordPlain -cmatch $_ }
if (@($classes).Count -lt 3) { throw 'The password must include at least three character categories: lower, upper, number, symbol.' }
if (Get-LabResourceGroup -Name $ResourceGroupName -AllowMissing) { throw 'Use a new, dedicated source resource group. Deployment is not a post-migration repair command.' }
$hostSku = Get-LabHostSku -VMSize $VMSize -Location $Location
$windowsImages = Get-LabWindowsImages -Location $Location
$guestDiskConfig = New-LabWindowsGuestDiskConfig -Location $Location -ImageId $windowsImages.Guest.Id
Write-Host "Selected host: $($hostSku.Name), $($hostSku.Cores) enabled vCPUs, $($hostSku.MemoryGB) GiB RAM. Confirm this series supports nested virtualization with Standard security before running deployment."
Write-Host "Appliance staging disk: $ApplianceStagingDiskSizeGB GB $ApplianceStagingDiskType presented as $($ApplianceStagingDriveLetter.ToUpperInvariant()): for the Module 1 appliance VHD."
foreach ($provider in @('Microsoft.Compute','Microsoft.Network','Microsoft.Storage','Microsoft.Migrate','Microsoft.OffAzure','Microsoft.RecoveryServices','Microsoft.KeyVault')) {
    $state = @(Get-AzResourceProvider -ProviderNamespace $provider)[0].RegistrationState
    if ($state -ne 'Registered') { throw "Register $provider first with Register-AzResourceProvider and wait until Registered." }
}
Write-Host "Creating source lab in subscription $SubscriptionId, region $Location."
Write-LabHealth 'Source deployment' Preparing 0 'Preflight passed. Starting dedicated workshop resource creation.' $HealthPath
$tags = @{ Workshop = 'TD-SYNNEX-CES-HyperV'; Team = 'Cloud Enablement Services'; Purpose = 'Training' }
$vmName = 'HyperVHost'
$diskName = 'WinServerBase-temp'
$stagingDiskName = "$vmName-appliance-staging"
$stagingDrive = $ApplianceStagingDriveLetter.ToUpperInvariant()
$runName = 'ConfigureWorkshop'
$diskCreated = $false
$runCreated = $false
$setupPassed = $false
$setupObservation = @{ Terminal = $false }
$deploymentClock = [Diagnostics.Stopwatch]::StartNew()
try {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $tags | Out-Null
    $subnet = New-AzVirtualNetworkSubnetConfig -Name default -AddressPrefix '10.0.0.0/24' -DefaultOutboundAccess $false
    $job = New-AzVirtualNetwork -Name "$ResourceGroupName-vnet" -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix '10.0.0.0/16' -Subnet $subnet -AsJob
    $vnet = Wait-LabJob $job 'Create source network' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    # The host's attached Standard public IP provides explicit outbound connectivity.
    $job = New-AzPublicIpAddress -Name "$vmName-pip" -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard -AsJob
    $pip = Wait-LabJob $job 'Create host public IP' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    $rdp = New-AzNetworkSecurityRuleConfig -Name Allow-RDP -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix $AdminSourceCidr -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389
    $job = New-AzNetworkSecurityGroup -Name "$vmName-nsg" -ResourceGroupName $ResourceGroupName -Location $Location -SecurityRules $rdp -AsJob
    $nsg = Wait-LabJob $job 'Create host firewall rules' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    $job = New-AzNetworkInterface -Name "$vmName-nic" -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id -EnableAcceleratedNetworking:$hostSku.AcceleratedNetworking -AsJob
    $nic = Wait-LabJob $job 'Create host network interface' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    $vm = New-AzVMConfig -VMName $vmName -VMSize $VMSize -SecurityType Standard
    $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $vmName -Credential $credential -ProvisionVMAgent -EnableAutoUpdate
    $vm = Set-AzVMSourceImage -VM $vm -PublisherName $windowsImages.Host.Publisher -Offer $windowsImages.Host.Offer -Skus $windowsImages.Host.Sku -Version $windowsImages.Host.Version
    $vm = Set-AzVMOSDisk -VM $vm -Name "$vmName-osdisk" -CreateOption FromImage -StorageAccountType Premium_LRS -DiskSizeInGB 512
    # Guest VHDs stay on the OS disk. This separate empty data disk is created with the
    # host so the appliance VHD always has its own unused capacity; it is never consumed
    # by base image downloads, guest disks or SQL growth.
    $vm = Add-AzVMDataDisk -VM $vm -Name $stagingDiskName -Lun 0 -CreateOption Empty -DiskSizeInGB $ApplianceStagingDiskSizeGB -StorageAccountType $ApplianceStagingDiskType -Caching None
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id
    $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
    $job = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vm -Tag $tags -AsJob
    $null = Wait-LabJob $job 'Create Azure host' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
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
    # Bring the staging disk online as its own NTFS volume and prove the appliance VHD has
    # room before any guest disk work starts. Reported free space is observed, not assumed.
    $stagingTemplate = @'
$ErrorActionPreference = 'Stop'
$letter = '__DRIVE__'
$label = 'ApplianceStaging'
$requiredBytes = 30GB
$volume = Get-Volume -FileSystemLabel $label -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $volume) {
    $candidate = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and -not $_.IsBoot -and -not $_.IsSystem } |
        Sort-Object Number | Select-Object -First 1
    if (-not $candidate) { throw 'No uninitialized data disk is present for appliance staging.' }
    Initialize-Disk -Number $candidate.Number -PartitionStyle GPT -ErrorAction Stop
    $partition = New-Partition -DiskNumber $candidate.Number -UseMaximumSize -DriveLetter $letter -ErrorAction Stop
    $volume = Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop
}
if ($volume.DriveLetter -ne $letter) { throw "Appliance staging volume is mounted as $($volume.DriveLetter), not $letter." }
New-Item -ItemType Directory -Path "${letter}:\Appliance" -Force | Out-Null
$staging = Get-Volume -DriveLetter $letter -ErrorAction Stop
if ($staging.SizeRemaining -lt $requiredBytes) {
    throw "Appliance staging volume has $([math]::Round($staging.SizeRemaining/1GB,1)) GB free; at least 30 GB is required for the appliance VHD."
}
$system = Get-Volume -DriveLetter C -ErrorAction Stop
Write-Output ("Appliance staging {0}: {1} GB free; system C: {2} GB free." -f $letter,
    [math]::Round($staging.SizeRemaining/1GB,1), [math]::Round($system.SizeRemaining/1GB,1))
Write-Output 'APPLIANCE_STAGING_READY'
'@
    $stagingScript = $stagingTemplate.Replace('__DRIVE__', $stagingDrive)
    $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId RunPowerShellScript -ScriptString $stagingScript -AsJob
    $stagingResult = Wait-LabJob $job 'Prepare appliance staging volume' -TimeoutSeconds 1800 -HealthPath $HealthPath
    $stagingOutput = Assert-LabRunResult $stagingResult 'APPLIANCE_STAGING_READY'
    $stagingSummary = @($stagingOutput -split "`n" | Where-Object { $_ -match 'GB free' } | ForEach-Object { $_.Trim() })[0]
    $job = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Disk $guestDiskConfig -AsJob
    $null = Wait-LabJob $job 'Create guest image disk' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    $diskCreated = $true
    $access = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName -Access Read -DurationInSecond 18000
    $parameters = @(@{ Name = 'AdminUsername'; Value = $AdminUsername })
    $protected = @(@{ Name = 'AdminPassword'; Value = $passwordPlain }, @{ Name = 'WindowsVhdSasUrl'; Value = $access.AccessSAS })
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
    Write-Host 'Optional traffic generator staged on the host at C:\AzMigrateLab\enable-lab-traffic.ps1 with its settings file. It is not running; start it from HyperVHost if you want a populated dependency map.'
    Write-Host "Download and extract the Azure Migrate appliance VHD into ${stagingDrive}:\Appliance on HyperVHost, then import and register it as described in docs/Module-1-Discovery.md."
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
