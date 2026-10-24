# Deployment builds and verifies the standalone copy at C:\AzMigrateLab\prepare-replication.ps1.
# Run that staged copy once in Module 3, after the four-workload assessment.
[CmdletBinding()]
param([SecureString]$AdminPassword)
# LAB_HEALTH_HELPERS
# LAB_WINDOWS_GUEST_HELPERS

function Initialize-LabReplicationRoot {
    param([Parameter(Mandatory)][string]$HostVMId)
    $metadata = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' -Headers @{Metadata='true'} -TimeoutSec 15 -ErrorAction Stop
    if ([string]$metadata.compute.vmId -ine $HostVMId) { throw 'NeedsReview: prepared appliance host identity differs from IMDS.' }
    $partition = Get-Partition -DriveLetter C -ErrorAction Stop
    $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    $volume = $partition | Get-Volume -ErrorAction Stop
    if (-not $disk.IsBoot -or [string]$disk.PartitionStyle -ne 'GPT' -or
        [math]::Abs([double]$disk.Size - 2048GB) -gt 1MB -or $volume.FileSystemType -ne 'NTFS' -or
        [string]::IsNullOrWhiteSpace([string]$disk.Guid) -or [string]::IsNullOrWhiteSpace([string]$volume.UniqueId)) {
        throw 'NeedsReview: expected the existing GPT/NTFS C: filesystem on the 2048-GiB host OS disk. No extra host disk is initialized or formatted.'
    }
    $root = Join-Path $labRoot 'ReplicationAppliance'
    $marker = Join-Path $labRoot 'replication-root.json'
    $copyPath = Join-Path $root 'store-owner.json'
    if (Test-Path -LiteralPath $marker) {
        $owner = Get-Content -LiteralPath $marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $copy = Get-Content -LiteralPath $copyPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($item in @($owner,$copy)) {
            if ([int]$item.Schema -ne 1 -or [string]$item.HostVMId -ine $HostVMId -or
                [string]$item.DiskGuid -ine [string]$disk.Guid -or [string]$item.PartitionGuid -ine [string]$partition.Guid -or
                [string]$item.VolumeUniqueId -cne [string]$volume.UniqueId -or [string]$item.Root -cne $root -or
                [string]::IsNullOrWhiteSpace([string]$item.Token)) { throw 'NeedsReview: prepared appliance directory ownership does not match this host/filesystem; no adoption or overwrite.' }
        }
        if ([string]$owner.Token -cne [string]$copy.Token) { throw 'NeedsReview: prepared appliance ownership records disagree.' }
        return [pscustomobject]@{ Root=$root; Owner=$owner; Volume=$volume }
    }
    if (Test-Path -LiteralPath $root) { throw 'NeedsReview: existing unowned replication directory is never adopted or erased.' }
    $owner = [ordered]@{ Schema=1; HostVMId=$HostVMId; DiskGuid=[string]$disk.Guid; PartitionGuid=[string]$partition.Guid;
        VolumeUniqueId=[string]$volume.UniqueId; Root=$root; Token=[guid]::NewGuid().ToString() }
    # Host-side intent first: a partial directory setup fails closed on resume.
    $owner | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8 -ErrorAction Stop
    New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
    & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'NeedsReview: could not restrict prepared appliance directory permissions.' }
    $owner | ConvertTo-Json | Set-Content -LiteralPath $copyPath -Encoding UTF8 -ErrorAction Stop
    return [pscustomobject]@{ Root=$root; Owner=[pscustomobject]$owner; Volume=$volume }
}

function Assert-LabReplicationMemory {
    $inventory = @(Get-VM -ErrorAction Stop)
    $discovery = @($inventory | Where-Object { $_.Name -ceq 'MigrateAppl' })
    if ($discovery.Count -gt 1 -or @($inventory | Where-Object { $_.Name -notin @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App','MigrateRepl','MigrateAppl') }).Count) {
        throw 'NeedsReview: unknown infrastructure VMs; future discovery memory reserve cannot be established safely.'
    }
    $repl = @($inventory | Where-Object { $_.Name -ceq 'MigrateRepl' })
    $replAllocated = 0L
    if ($repl.Count -eq 1) { $replAllocated = [long]$repl[0].MemoryAssigned }
    $discoveryAllocated = 0L
    if ($discovery.Count -eq 1) { $discoveryAllocated = [long]$discovery[0].MemoryAssigned }
    $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15 -ErrorAction Stop
    $available = [long]$os.FreePhysicalMemory * 1KB
    $required = [math]::Max(0L, (16GB - $replAllocated)) + [math]::Max(0L, (16GB - $discoveryAllocated)) + 8GB
    $budget = 12GB + 16GB + [math]::Max(16GB, $discoveryAllocated) + 8GB
    if (([long]$os.TotalVisibleMemorySize * 1KB) -lt $budget -or $available -lt $required) {
        throw ('NeedsReview: insufficient actual host memory. Available {0:N1} GiB; require {1:N1} GiB free including unallocated replication/discovery memory and 8-GiB host reserve. Close unrelated load; do not enable dynamic memory or resize workload VMs.' -f ($available/1GB),($required/1GB))
    }
}

function Assert-LabReplicationReservation {
    $mac = '00155D000015'
    $reservations = @(Get-DhcpServerv4Reservation -ScopeId 192.168.0.0 -ErrorAction Stop)
    $leases = @(Get-DhcpServerv4Lease -ScopeId 192.168.0.0 -ErrorAction Stop)
    foreach ($item in @($reservations) + @($leases)) {
        $client = ([string]$item.ClientId -replace '[-:]','').ToUpperInvariant()
        if (([string]$item.IPAddress -eq '192.168.0.21' -and $client -cne $mac) -or
            ($client -ceq $mac -and [string]$item.IPAddress -ne '192.168.0.21')) { throw 'NeedsReview: replication DHCP address/client collision; no reservation was overwritten.' }
    }
    $nics = @(Get-VM | Get-VMNetworkAdapter | Where-Object { $_.MacAddress -eq $mac -and $_.VMName -ne 'MigrateRepl' })
    if ($nics.Count) { throw 'NeedsReview: replication appliance MAC is assigned to another VM.' }
}

function New-LabPreparedReplicationVM {
    param($Store)
    $vmName = 'MigrateRepl'
    $root = $Store.Root
    $statePath = Join-Path $root 'prepared-vm.json'
    $existing = @(Get-VM -Name $vmName -ErrorAction SilentlyContinue)
    if ($existing.Count -or (Test-Path -LiteralPath $statePath)) {
        if ($existing.Count -ne 1 -or -not (Test-Path -LiteralPath $statePath)) { throw 'NeedsReview: existing/unmarked replication VM is never rebuilt, overwritten or adopted.' }
        $record = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([string]$record.State -cne 'PreparedOS' -or [string]$record.VMId -ine [string]$existing[0].Id -or
            [string]$record.StoreToken -cne [string]$Store.Owner.Token -or [string]$record.Root -cne $root -or
            [string]$record.HostVolumeUniqueId -cne [string]$Store.Owner.VolumeUniqueId) { throw 'NeedsReview: incomplete/mismatched prepared VM record. Preserve appliance and disks; no destructive retry.' }
        # Even a healthy registered appliance is not reconfigured on a deployment resume.
        return $record
    }
    if ((Test-Path -LiteralPath (Join-Path $root 'OS.vhdx')) -or (Test-Path -LiteralPath (Join-Path $root 'Data.vhdx')) -or
        (Test-Path -LiteralPath (Join-Path $root 'VM'))) { throw 'NeedsReview: orphaned appliance files require manual review; never overwrite them.' }
    Assert-LabReplicationReservation
    Assert-LabReplicationMemory
    $volume = Get-Volume -UniqueId $Store.Owner.VolumeUniqueId -ErrorAction Stop
    if ([long]$volume.SizeRemaining -lt 716GB) { throw 'NeedsReview: reserve full 80+620 GiB virtual capacity plus 16-GiB headroom before creating any appliance VHD; no storage oversubscription.' }
    [ordered]@{ State='Creating'; StoreToken=$Store.Owner.Token; VMId=$null } | ConvertTo-Json |
        Set-Content -LiteralPath $statePath -Encoding UTF8 -ErrorAction Stop
    # Only this infrastructure VM uses a dynamic data VHD; the full capacity is budgeted above.
    Create-WindowsGuestVM -VMName $vmName -IPAddress '192.168.0.21' -MemoryMB 16384 -CPUs 8 -DiskGB 80 -StorageRoot $root -PreparedInfrastructure -OnCreated {
        param($CreatedVM,[string]$OSPath)
        [ordered]@{ State='Creating'; StoreToken=$Store.Owner.Token; VMId=[string]$CreatedVM.Id; Root=$root;
            OSPath=$OSPath; OSDiskIdentifier=[string](Get-VHD -Path $OSPath -ErrorAction Stop).DiskIdentifier } | ConvertTo-Json |
            Set-Content -LiteralPath $statePath -Encoding UTF8 -ErrorAction Stop
    }
    $vm = Get-VM -Name $vmName -ErrorAction Stop
    $dataPath = Join-Path $root 'Data.vhdx'
    New-VHD -Path $dataPath -SizeBytes 620GB -Dynamic -ErrorAction Stop | Out-Null
    $dataIdentity = [string](Get-VHD -Path $dataPath -ErrorAction Stop).DiskIdentifier
    [ordered]@{ State='Creating'; StoreToken=$Store.Owner.Token; VMId=[string]$vm.Id; Root=$root;
        OSPath=(Join-Path $root 'OS.vhdx'); DataPath=$dataPath; DataDiskIdentifier=$dataIdentity } | ConvertTo-Json |
        Set-Content -LiteralPath $statePath -Encoding UTF8 -ErrorAction Stop
    # Format only the newly created, owned VHD by Mount-VHD's exact path association.
    # Never select a physical host RAW disk or infer a guest disk number/bus enum.
    $mounted = $null
    try {
        $mounted = Mount-VHD -Path $dataPath -NoDriveLetter -Passthru -ErrorAction Stop
        $virtual = Get-VHD -Path $dataPath -ErrorAction Stop
        $dataDisk = Get-Disk -Number $mounted.DiskNumber -ErrorAction Stop
        $hostDisk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop
        if (@($mounted).Count -ne 1 -or [string]$mounted.Path -ine $dataPath -or [string]$virtual.Path -ine $dataPath -or
            $virtual.DiskNumber -ne $mounted.DiskNumber -or [string]$virtual.DiskIdentifier -cne $dataIdentity -or
            -not $virtual.Attached -or $virtual.Size -ne 620GB -or
            [string]$virtual.VhdType -ne 'Dynamic' -or $virtual.ParentPath -or $dataDisk.Number -eq $hostDisk.Number -or
            $dataDisk.IsBoot -or $dataDisk.IsSystem -or $dataDisk.IsReadOnly -or
            [math]::Abs([double]$dataDisk.Size - 620GB) -gt 1MB -or [string]$dataDisk.PartitionStyle -ne 'RAW' -or
            @(Get-Partition -DiskNumber $dataDisk.Number -ErrorAction SilentlyContinue).Count) {
            throw 'NeedsReview: new data VHD association/empty state is not safe; no disk was formatted.'
        }
        if ($dataDisk.IsOffline) { Set-Disk -Number $dataDisk.Number -IsOffline $false -ErrorAction Stop }
        Initialize-Disk -Number $dataDisk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
        $dataPartition = New-Partition -DiskNumber $dataDisk.Number -UseMaximumSize -ErrorAction Stop
        $null = Format-Volume -Partition $dataPartition -FileSystem NTFS -NewFileSystemLabel ReplicationData -Confirm:$false -ErrorAction Stop
        $dataDisk = Get-Disk -Number $dataDisk.Number -ErrorAction Stop
        $dataPartition = Get-Partition -DiskNumber $dataDisk.Number -PartitionNumber $dataPartition.PartitionNumber -ErrorAction Stop
        $guestDiskGuid = [string]$dataDisk.Guid
        $guestPartitionGuid = [string]$dataPartition.Guid
        if (-not $guestDiskGuid -or -not $guestPartitionGuid) { throw 'NeedsReview: formatted data VHD has no persistent GPT identity.' }
    } finally { if ($mounted) { Dismount-VHD -Path $dataPath -ErrorAction Stop } }
    Add-VMHardDiskDrive -VMName $vmName -Path $dataPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1 -ErrorAction Stop
    [ordered]@{ State='NeedsReview'; StoreToken=$Store.Owner.Token; VMId=[string]$vm.Id; Root=$root;
        OSPath=(Join-Path $root 'OS.vhdx'); DataPath=$dataPath; DataDiskGuid=$guestDiskGuid; DataPartitionGuid=$guestPartitionGuid } | ConvertTo-Json |
        Set-Content -LiteralPath $statePath -Encoding UTF8 -ErrorAction Stop
    Assert-LabReplicationMemory
    Start-VM -VM $vm -ErrorAction Stop
    if (-not (Wait-ForGuestVM -VMName $vmName -TimeoutSeconds 1200)) { throw 'NeedsReview: replication Windows first boot was not verified.' }
    $job = Invoke-Command -VMName $vmName -Credential $winCred -ArgumentList $guestDiskGuid,$guestPartitionGuid -AsJob -ScriptBlock {
        param([string]$DataDiskGuid,[string]$DataPartitionGuid)
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest
        if ($env:COMPUTERNAME -ine 'MigrateRepl') { throw 'Wrong replication guest identity.' }
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        if ($os.Caption -notmatch 'Windows Server 2022' -or $cv.InstallationType -ne 'Server' -or
            (Get-WinSystemLocale).Name -notlike 'en-*') { throw 'Replication OS must be Windows Server 2022 Desktop Experience, English.' }
        foreach ($feature in @('Hyper-V','AD-Domain-Services','Web-Server')) {
            if ((Get-WindowsFeature -Name $feature -ErrorAction Stop).Installed) { throw "Replication guest contains prohibited role $feature." }
        }
        $c = Get-Partition -DriveLetter C -ErrorAction Stop
        $osDisk = Get-Disk -Number $c.DiskNumber -ErrorAction Stop
        if (-not $osDisk.IsBoot -or [math]::Abs([double]$osDisk.Size - 80GB) -gt 1MB) { throw 'Replication OS disk is not the intended 80-GiB boot disk.' }
        $size = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
        if ($c.Size -lt $size.SizeMax) { Resize-Partition -DriveLetter C -Size $size.SizeMax -ErrorAction Stop }
        $c = Get-Partition -DriveLetter C -ErrorAction Stop
        if ($c.Size -lt 78GB) { throw 'Replication Windows filesystem did not expand to use the 80-GiB OS disk; no partition deletion workaround is allowed.' }
        $disks = @(Get-Disk -ErrorAction Stop)
        $data = @($disks | Where-Object { [string]$_.Guid -ieq $DataDiskGuid -and -not $_.IsBoot -and -not $_.IsSystem -and $_.Number -ne $osDisk.Number -and [math]::Abs([double]$_.Size - 620GB) -le 1MB })
        if ($disks.Count -ne 2 -or $data.Count -ne 1 -or [string]$data[0].PartitionStyle -ne 'GPT') { throw 'Guest data disk does not match the owned VHD GPT identity; no guest disk is formatted.' }
        $parts = @(Get-Partition -DiskNumber $data[0].Number -ErrorAction Stop | Where-Object { [string]$_.Guid -ieq $DataPartitionGuid })
        if ($parts.Count -ne 1) { throw 'Guest data partition does not match the prepared VHD identity.' }
        $volume = $parts[0] | Get-Volume -ErrorAction Stop
        if ($volume.FileSystemType -ne 'NTFS' -or $volume.Size -lt 619GB) { throw 'Replication data filesystem capacity was not verified.' }
        $used = @((Get-Volume).DriveLetter) + @((Get-PSDrive -PSProvider FileSystem).Name)
        if ($volume.DriveLetter) { $used = @($used | Where-Object { $_ -ne $volume.DriveLetter }) }
        $letters = @('E','F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z' | Where-Object { $_ -notin $used })
        if (-not $letters.Count) { throw 'No free guest data drive letter.' }
        if ([string]$volume.DriveLetter -ne $letters[0]) { $parts[0] | Set-Partition -NewDriveLetter $letters[0] -ErrorAction Stop }
        $volume = Get-Volume -DriveLetter $letters[0] -ErrorAction Stop
        foreach ($port in @(443,9443)) {
            New-NetFirewallRule -Name "LabReplication$port" -DisplayName "Lab SQL/App replication $port" -Direction Inbound -Action Allow -Profile Any -Protocol TCP -LocalPort $port -RemoteAddress 192.168.0.11,192.168.0.13 -ErrorAction Stop | Out-Null
        }
        Remove-Item 'C:\Windows\Panther\unattend.xml' -Force -ErrorAction SilentlyContinue
        Remove-Item 'C:\Windows\Panther\Unattend\unattend.xml' -Force -ErrorAction SilentlyContinue
        [pscustomobject]@{ ComputerName=$env:COMPUTERNAME; OS=$os.Caption; InstallationType=$cv.InstallationType; Locale=(Get-WinSystemLocale).Name;
            OSPartitionBytes=[long]$c.Size; DataVolumeBytes=[long]$volume.Size; DataDrive=[string]$volume.DriveLetter; DataVolumeUniqueId=[string]$volume.UniqueId; DataDiskGuid=$DataDiskGuid; DataPartitionGuid=$DataPartitionGuid }
    }
    $result = @(Wait-LabJob $job 'Prepare replication guest OS and storage' -TimeoutSeconds 1200)
    if ($result.Count -ne 1 -or $result[0].ComputerName -ine $vmName -or $result[0].OSPartitionBytes -lt 78GB -or $result[0].DataVolumeBytes -lt 619GB) { throw 'NeedsReview: prepared replication OS/storage result missing or invalid.' }
    Set-VM -VM $vm -AutomaticStartAction Start -AutomaticStartDelay 150 -AutomaticStopAction ShutDown -ErrorAction Stop
    $record = [ordered]@{ State='PreparedOS'; VMId=[string]$vm.Id; StoreToken=$Store.Owner.Token; Name=$vmName; IPAddress='192.168.0.21';
        MemoryMB=16384; CPUs=8; OSDiskGB=80; DataDiskGB=620; OSPath=(Join-Path $root 'OS.vhdx'); DataPath=$dataPath;
        OSDiskIdentifier=[string](Get-VHD -Path (Join-Path $root 'OS.vhdx')).DiskIdentifier; DataDiskIdentifier=[string](Get-VHD -Path $dataPath).DiskIdentifier; Root=$root; HostVolumeUniqueId=$Store.Owner.VolumeUniqueId; Guest=$result[0]; ApplianceInstallation='ManualStudentStep' }
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath -Encoding UTF8 -ErrorAction Stop
    return [pscustomobject]$record
}

function Assert-LabPreparedReplicationVM {
    param($Record)
    $vm = Get-VM -Name MigrateRepl -ErrorAction Stop
    $memory = Get-VMMemory -VM $vm -ErrorAction Stop
    $drives = @(Get-VMHardDiskDrive -VM $vm -ErrorAction Stop)
    $nic = @(Get-VMNetworkAdapter -VM $vm -ErrorAction Stop)
    if ([string]$Record.State -cne 'PreparedOS' -or [string]$Record.VMId -ine [string]$vm.Id -or
        [string]$vm.State -cne 'Running' -or $vm.ProcessorCount -ne 8 -or $memory.DynamicMemoryEnabled -or
        $memory.Startup -ne 16GB -or $drives.Count -ne 2 -or $nic.Count -ne 1 -or
        $nic[0].SwitchName -cne $intSwitchName -or $nic[0].MacAddress -cne '00155D000015' -or
        [string]$vm.AutomaticStartAction -ne 'Start' -or $vm.AutomaticStartDelay -ne 150) { throw 'NeedsReview: prepared replication VM identity/state/hardware/boot policy changed; not automatically repaired.' }
    foreach ($spec in @(@{Name='OS.vhdx';Size=80GB;Type='Fixed';Location=0},@{Name='Data.vhdx';Size=620GB;Type='Dynamic';Location=1})) {
        $path = Join-Path $Record.Root $spec.Name
        if (@($drives | Where-Object { $_.Path -ieq $path -and $_.ControllerType -eq 'SCSI' -and $_.ControllerNumber -eq 0 -and $_.ControllerLocation -eq $spec.Location }).Count -ne 1) { throw 'NeedsReview: prepared replication disk paths changed.' }
        $vhd = Get-VHD -Path $path -ErrorAction Stop
        if ($vhd.Size -ne $spec.Size -or [string]$vhd.VhdType -ne $spec.Type -or
            ($spec.Name -ceq 'OS.vhdx' -and [string]$vhd.DiskIdentifier -ine [string]$Record.OSDiskIdentifier) -or
            ($spec.Name -ceq 'Data.vhdx' -and [string]$vhd.DiskIdentifier -ine [string]$Record.DataDiskIdentifier)) { throw 'NeedsReview: prepared replication virtual disk size/type changed.' }
    }
    Assert-LabReplicationReservation
    # Capacity is reserved in full even though the large new data VHD is dynamic.
    $volume = Get-Volume -UniqueId $Record.HostVolumeUniqueId -ErrorAction Stop
    $allocated = [long](Get-Item -LiteralPath (Join-Path $Record.Root 'Data.vhdx')).Length
    if ([long]$volume.SizeRemaining -lt (620GB - $allocated + 16GB)) { throw 'NeedsReview: remaining physical backing no longer covers full appliance disk growth and headroom.' }
    $job = Invoke-Command -VMName MigrateRepl -Credential $winCred -ArgumentList $Record.Guest.DataDrive,$Record.Guest.DataVolumeUniqueId,$Record.Guest.DataDiskGuid,$Record.Guest.DataPartitionGuid -AsJob -ScriptBlock {
        param([string]$DataDrive,[string]$DataVolumeUniqueId,[string]$DataDiskGuid,[string]$DataPartitionGuid)
        $ErrorActionPreference = 'Stop'
        Set-StrictMode -Version Latest
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if ($env:COMPUTERNAME -ine 'MigrateRepl' -or $os.Caption -notmatch 'Windows Server 2022' -or
            $cv.InstallationType -ne 'Server' -or (Get-WinSystemLocale).Name -notlike 'en-*') { throw 'Prepared replication guest OS/identity changed.' }
        foreach ($feature in @('Hyper-V','AD-Domain-Services','Web-Server')) {
            if ((Get-WindowsFeature -Name $feature -ErrorAction Stop).Installed) { throw "Prepared replication guest contains prohibited role $feature." }
        }
        $c = Get-Partition -DriveLetter C -ErrorAction Stop
        $osDisk = Get-Disk -Number $c.DiskNumber -ErrorAction Stop
        $data = Get-Volume -DriveLetter $DataDrive -ErrorAction Stop
        $parts = @(Get-Partition -DriveLetter $DataDrive -ErrorAction Stop)
        if ($parts.Count -ne 1) { throw 'Prepared replication data partition is ambiguous.' }
        $dataDisk = Get-Disk -Number $parts[0].DiskNumber -ErrorAction Stop
        $max = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
        if (-not $osDisk.IsBoot -or [math]::Abs([double]$osDisk.Size - 80GB) -gt 1MB -or $c.Size -lt 78GB -or
            [math]::Abs([double]$c.Size - $max.SizeMax) -gt 1MB -or
            $dataDisk.IsBoot -or $dataDisk.IsSystem -or $dataDisk.Number -eq $osDisk.Number -or
            [string]$dataDisk.Guid -ine $DataDiskGuid -or [string]$parts[0].Guid -ine $DataPartitionGuid -or
            [math]::Abs([double]$dataDisk.Size - 620GB) -gt 1MB -or $data.FileSystemType -ne 'NTFS' -or
            $data.Size -lt 619GB -or [string]$data.UniqueId -cne $DataVolumeUniqueId) { throw 'Prepared replication guest disk/filesystem identity or capacity changed; no repair/format attempted.' }
        $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -eq '192.168.0.21' })
        $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Where-Object { $_.NextHop -eq '192.168.0.1' })
        if ($addresses.Count -ne 1 -or -not $routes.Count) { throw 'Prepared replication DHCP address/default route is not ready.' }
        [pscustomobject]@{ State='PreparedOS'; ComputerName=$env:COMPUTERNAME; OS=$os.Caption; OSVirtualBytes=[long]$osDisk.Size;
            OSPartitionBytes=[long]$c.Size; DataVirtualBytes=[long]$dataDisk.Size; DataVolumeBytes=[long]$data.Size;
            DataDrive=$DataDrive; DataVolumeUniqueId=[string]$data.UniqueId; IPAddress='192.168.0.21'; CheckedUtc=[DateTime]::UtcNow.ToString('o') }
    }
    $guest = @(Wait-LabJob $job 'Verify prepared replication OS read-only' -TimeoutSeconds 180)
    if ($guest.Count -ne 1 -or [string]$guest[0].State -cne 'PreparedOS' -or [string]$guest[0].ComputerName -ine 'MigrateRepl') {
        throw 'NeedsReview: prepared replication guest verification did not return one valid result.'
    }
    $Record | Add-Member -NotePropertyName Verification -NotePropertyValue $guest[0] -Force
    return $Record
}

function Assert-LabLatePreparationContext {
    $settingsPath = Join-Path $labRoot 'replication-preparation.json'
    $complete = Get-Content -LiteralPath (Join-Path $labRoot 'setup-complete.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $settings = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $expected = @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App')
    if ([int]$settings.Schema -ne 1 -or [string]$settings.State -cne 'HelperAndBaseStaged' -or
        [string]$complete.ReplicationPreparation.State -cne 'HelperAndBaseStaged' -or
        [string]$settings.HostVMId -ine [string]$complete.ReplicationPreparation.HostVMId -or
        [string]$settings.HelperSha256 -ine [string]$complete.ReplicationPreparation.HelperSha256 -or
        [string]$settings.BaseSha256 -ine [string]$complete.ReplicationPreparation.BaseSha256 -or
        [string]$settings.HelperPath -ine (Join-Path $labRoot 'prepare-replication.ps1') -or
        [string]$settings.HelperPath -ine $PSCommandPath -or
        [string]$settings.BasePath -ine (Join-Path $labRoot 'VHDs\WindowsServer2022-Base.vhdx') -or
        @($complete.VMs).Count -ne 4 -or @($settings.SourceVMIds.PSObject.Properties).Count -ne 4) { throw 'NeedsReview: completed fresh-source/staged-helper identity is not verified.' }
    foreach ($name in $expected) {
        if ($name -notin @($complete.VMs)) { throw 'NeedsReview: completion workload identity differs.' }
        $vms = @(Get-VM -Name $name -ErrorAction Stop)
        if ($vms.Count -ne 1 -or [string]$vms[0].Id -ine [string]$settings.SourceVMIds.$name -or
            [string]$settings.SourceVMIds.$name -ine [string]$complete.ReplicationPreparation.SourceVMIds.$name -or
            [string]$vms[0].State -cne 'Running' -or [string]$vms[0].AutomaticStartAction -cne 'Start') {
            throw "NeedsReview: source $name is missing, changed, stopped or retired/disarmed. No source is started or repaired by appliance preparation."
        }
    }
    if ((Get-FileHash -LiteralPath $settings.HelperPath -Algorithm SHA256 -ErrorAction Stop).Hash -ine $settings.HelperSha256 -or
        (Get-FileHash -LiteralPath $settings.BasePath -Algorithm SHA256 -ErrorAction Stop).Hash -ine $settings.BaseSha256 -or
        [long](Get-Item -LiteralPath $settings.BasePath -ErrorAction Stop).Length -ne [long]$settings.BaseFileBytes) { throw 'NeedsReview: staged helper or original generalized Windows base changed. Do not substitute/clone a workload disk.' }
    $attached = @(Get-VM | Get-VMHardDiskDrive | Where-Object { $_.Path -ieq $settings.BasePath })
    if ($attached.Count) { throw 'NeedsReview: original generalized base is attached to a VM; it cannot be used as a clean source.' }
    $existing = @(Get-VM -Name MigrateRepl -ErrorAction SilentlyContinue)
    $ownedRoot = Join-Path $labRoot 'ReplicationAppliance'
    if ($existing.Count -and ($existing.Count -ne 1 -or
        -not (Test-Path -LiteralPath (Join-Path $labRoot 'replication-root.json')) -or
        -not (Test-Path -LiteralPath (Join-Path $ownedRoot 'prepared-vm.json')))) {
        throw 'NeedsReview: existing unowned/ambiguous MigrateRepl found before any mutation. Preserve it; no adoption or replacement.'
    }
    return $settings
}

try {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion -lt [version]'5.1') { throw 'Use elevated Windows PowerShell 5.1 on HyperVHost, not Cloud Shell or a guest.' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Open Windows PowerShell as Administrator on HyperVHost.' }
    $labRoot = 'C:\AzMigrateLab'
    $logFile = Join-Path $labRoot 'replication-setup-log.txt'
    if (-not (Get-Command Create-WindowsGuestVM -CommandType Function -ErrorAction SilentlyContinue)) { throw 'Use the staged standalone helper at C:\AzMigrateLab\prepare-replication.ps1; this checkout template is not the staged executable.' }
    Initialize-LabProgress -Mode Plain -EmitMarkers
    $settings = Assert-LabLatePreparationContext
    $intSwitchName = 'intSwitch'
    $vhdPath = Join-Path $labRoot 'VHDs'
    $windowsBaseVhd = [string]$settings.BasePath
    if ($null -eq $AdminPassword) { $AdminPassword = Read-Host 'Existing lab guest Administrator password' -AsSecureString }
    $winCred = [pscredential]::new('Administrator',$AdminPassword)
    $guestAdminPwd = $winCred.GetNetworkCredential().Password
    if ([string]::IsNullOrWhiteSpace($guestAdminPwd)) { throw 'A lab Administrator password is required.' }
    $credentialProbe = Invoke-Command -VMName OnPrem-Web -Credential $winCred -ScriptBlock { $env:COMPUTERNAME } -AsJob -ErrorAction Stop
    $credentialResult = @(Wait-LabJob $credentialProbe 'Verify existing guest Administrator credential read-only' -TimeoutSeconds 60)
    if ($credentialResult.Count -ne 1 -or [string]$credentialResult[0] -ine 'OnPrem-Web') { throw 'Existing lab guest Administrator credential was not verified; no appliance VM was created.' }
    # Read-only context checks above do not prove assessment completion; module order is manual.
    $replicationStore = Initialize-LabReplicationRoot -HostVMId $settings.HostVMId
    $record = New-LabPreparedReplicationVM -Store $replicationStore
    $record = Assert-LabPreparedReplicationVM -Record $record
    Remove-Item -LiteralPath (Join-Path $labRoot 'Unattend\MigrateRepl') -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'MigrateRepl prepared Windows OS is Running: 16-GiB static RAM, 8 shared vCPUs, 80+620-GiB local guest disks, private 192.168.0.21.'
    Write-Host ('Guest data volume: {0}:; run the current project-sourced DRInstaller as Administrator INSIDE MigrateRepl next. No appliance installation or registration was automated.' -f $record.Guest.DataDrive)
    Write-Output 'LAB_REPLICATION_OS_PREPARED'
} catch {
    Write-Error ('Replication OS preparation stopped: ' + $_.Exception.Message + ' Preserve the owned VM/disks/markers for review; never rerun deployment or delete a registered appliance to retry.') -ErrorAction Continue
    throw
} finally {
    if (Get-Command Complete-LabProgress -CommandType Function -ErrorAction SilentlyContinue) { Complete-LabProgress }
    $guestAdminPwd = $null
    $AdminPassword = $null
    $winCred = $null
}
