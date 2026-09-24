# Runs as SYSTEM on the Windows Hyper-V host through managed Run Command.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AdminUsername,
    [Parameter(Mandatory)][string]$AdminPassword,
    [Parameter(Mandatory)][string]$WindowsVhdSasUrl,
    [string]$WorkshopTitle = 'TD SYNNEX - Cloud Enablement Services'
)
try {
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
# LAB_HEALTH_HELPERS
Initialize-LabProgress -Mode Plain -EmitMarkers

# ---------- Logging ----------
$labRoot = "C:\AzMigrateLab"
$logFile = "$labRoot\setup-log.txt"
New-Item -ItemType Directory -Path $labRoot -Force | Out-Null
if (Test-Path "$labRoot\setup-complete.json") {
    # A completed host is refused: replaying provisioning after migration has begun could
    # recreate or restart retired source VMs. An INCOMPLETE host has no marker and is
    # resumed instead, so a failed run does not cost a full rebuild.
    throw 'This host has already been provisioned. Use validation, not deployment, after migration starts.'
}
$labResuming = Test-Path "$labRoot\setup-log.txt"
# This directory contains unattended setup material; limit it to local administrators and SYSTEM.
& icacls.exe $labRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not restrict setup directory permissions.' }

function Write-Log {
    param([string]$Message)
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry -ErrorAction SilentlyContinue
    $stage = switch -Regex ($Message) {
        '^PHASE 1:' { 'network'; break }; '^PHASE 2:' { 'images'; break }
        '^PHASE 3:' { 'guests'; break }; '^PHASE 4:' { 'boot'; break }
        '^PHASE 5:' { 'workloads'; break }; '^--- Configuring OnPrem-Web' { 'iis'; break }
        '^--- Configuring OnPrem-SQL' { 'sql'; break }; '^Validating sample applications' { 'validation'; break }
        '^PHASE 6:' { 'traffic'; break }; '^PHASE 7:' { 'hostprep'; break }
    }
    if ($stage) { Write-Host "LAB_STAGE|$stage" }
}

function Expand-LabTextTemplate {
    param([string]$Template, [System.Collections.IDictionary]$Values)
    # Replace only tokens present in the template. Never interpret inserted
    # passwords as more template tokens, PowerShell, or regex replacements.
    return [regex]::Replace($Template, '__[A-Z][A-Z0-9_]*__', [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        if (-not $Values.Contains($match.Value)) { throw "Missing template value: $($match.Value)" }
        return [string]$Values[$match.Value]
    })
}

function Assert-LabSourceWorkloads {
    foreach ($address in @('http://192.168.0.10','http://192.168.0.12')) {
        $page = Invoke-WebRequest $address -UseBasicParsing -TimeoutSec 10
        if ($page.StatusCode -ne 200 -or $page.Content -notmatch 'TD SYNNEX') {
            throw "Workshop sample site missing at $address."
        }
    }
    $api = Invoke-RestMethod 'http://192.168.0.13:3000/api/health' -TimeoutSec 10
    if ($api.status -ne 'healthy' -or $api.server -ne 'OnPrem-Linux-App') { throw 'Node API unhealthy or wrong application.' }
    if (-not (Test-NetConnection 192.168.0.11 -Port 1433 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        throw 'SQL TCP listener unavailable.'
    }
}

$vhdPath       = "$labRoot\VHDs"
$intSwitchName = "intSwitch"
$natName       = "LabNAT"
$natPrefix     = "192.168.0.0/24"
$hostIp        = "192.168.0.1"
$guestAdminPwd = $AdminPassword
$guestUser = $AdminUsername
$windowsVhdSasUrl = $WindowsVhdSasUrl

New-Item -ItemType Directory -Path $vhdPath -Force | Out-Null

# =============================================================
# PHASE 1 - Virtual networking
# =============================================================
if ($labResuming) {
    Write-Log 'Resuming an incomplete run. Existing switch, NAT, DHCP scope and base images are reused; partially built guests are rebuilt.'
}
Write-Log "PHASE 1: Configuring virtual networking..."

$existingSwitch = Get-VMSwitch -Name $intSwitchName -ErrorAction SilentlyContinue
if ($existingSwitch) {
    Write-Log "Virtual switch '$intSwitchName' already exists."
} else {
    New-VMSwitch -SwitchType Internal -Name $intSwitchName -ErrorAction Stop | Out-Null
    Write-Log "Created internal switch '$intSwitchName'."
}

$adapter = Get-NetAdapter -Name "vEthernet ($intSwitchName)" -ErrorAction Stop
if ($adapter) {
    $existingIp = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $hostIp }
    if (-not $existingIp) {
        New-NetIPAddress -IPAddress $hostIp -PrefixLength 24 -InterfaceIndex $adapter.ifIndex -ErrorAction Stop | Out-Null
        Write-Log "Assigned $hostIp to host adapter."
    } else {
        Write-Log "Host adapter already has IP $hostIp."
    }
} else {
    throw "Could not find adapter for switch '$intSwitchName'."
}

$existingNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
if ($existingNat) {
    Write-Log "NAT '$natName' already exists."
} else {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $natPrefix -ErrorAction Stop | Out-Null
    Write-Log "Created NAT '$natName' with prefix $natPrefix."
}

# The internal NAT has no DHCP service of its own. Provide DHCP on intSwitch
# so guest OS NICs already use DHCP when copied into an Azure VNet.
Add-DhcpServerSecurityGroup -ErrorAction Stop
foreach ($binding in Get-DhcpServerv4Binding) {
    Set-DhcpServerv4Binding -InterfaceAlias $binding.InterfaceAlias -BindingState ($binding.InterfaceAlias -eq "vEthernet ($intSwitchName)")
}
if (-not (Get-DhcpServerv4Scope -ScopeId 192.168.0.0 -ErrorAction SilentlyContinue)) {
    Add-DhcpServerv4Scope -Name Workshop -StartRange 192.168.0.10 -EndRange 192.168.0.200 -SubnetMask 255.255.255.0 -State Active | Out-Null
}
Set-DhcpServerv4OptionValue -ScopeId 192.168.0.0 -Router 192.168.0.1 -DnsServer 1.1.1.1,8.8.8.8
Restart-Service DHCPServer

# Host-side firewall for the nested subnet only. The public NIC stays governed by the
# Azure NSG, which still permits RDP from the single deployment /32. The Azure Migrate
# appliance reaches this host over WinRM, and instructors expect ping to work both ways.
$hostLabRange = '192.168.0.0/24'
foreach ($rule in @(
    @{ Name='LabHostIcmp4';   Display='Lab host ICMPv4 echo';        Protocol='ICMPv4'; Ports=$null },
    @{ Name='LabHostWinRM';   Display='Lab host WinRM from nested';  Protocol='TCP';    Ports=@(5985,5986) },
    @{ Name='LabHostSmb';     Display='Lab host SMB from nested';    Protocol='TCP';    Ports=@(445) })) {
    if (Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $rule.Name }
    $parameters = @{ Name=$rule.Name; DisplayName=$rule.Display; Direction='Inbound'; Action='Allow'
        Profile='Any'; Protocol=$rule.Protocol; RemoteAddress=$hostLabRange }
    if ($rule.Protocol -eq 'ICMPv4') { $parameters['IcmpType'] = 8 }
    if ($rule.Ports) { $parameters['LocalPort'] = $rule.Ports }
    New-NetFirewallRule @parameters | Out-Null
}
Write-Log "Host firewall permits ICMP, WinRM and SMB from $hostLabRange."
function Set-LabReservation {
    param([string]$VMName,[string]$IPAddress)
    $mac = '00155D0000' + ([int]($IPAddress.Split('.')[-1])).ToString('X2')
    Set-VMNetworkAdapter -VMName $VMName -StaticMacAddress $mac
    if (-not (Get-DhcpServerv4Reservation -ScopeId 192.168.0.0 | Where-Object IPAddress -EQ $IPAddress)) {
        Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress $IPAddress -ClientId ($mac -replace '(..)(?!$)', '$1-') -Name $VMName | Out-Null
    }
}

# =============================================================
# PHASE 2 - Download OS images
# =============================================================
Write-Log "PHASE 2: Downloading OS images..."

# --- Start the Azure Migrate appliance download in the background -------------------
# The appliance VHD is ~11 GB and is published at a static link, so it does not depend on
# the project key: only REGISTERING the appliance does. Starting it here means it downloads
# alongside the OS images instead of costing the instructor a separate wait in Module 1.
# The store partition is created by deploy-lab.ps1 before this script runs, so it already
# exists; it is found by its volume label rather than by assuming a drive letter.
# This is best-effort. Nothing later in this script depends on it, and Module 1 section 3.3
# still works unchanged if it did not run.
$applianceJob = $null
$applianceRoot = $null
try {
    $storeVolume = Get-Volume -FileSystemLabel 'ApplianceStore' -ErrorAction SilentlyContinue |
                   Where-Object { $_.DriveLetter } | Select-Object -First 1
    if (-not $storeVolume) {
        Write-Log "No ApplianceStore volume found; the appliance VHD will not be pre-staged."
    } else {
        $applianceRoot = "$($storeVolume.DriveLetter):\Appliance"
        New-Item -ItemType Directory -Path $applianceRoot -Force | Out-Null
        $applianceJob = Start-Job -Name 'LabApplianceDownload' -ScriptBlock {
            param($Root)
            $ErrorActionPreference = 'Stop'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $zip = Join-Path $Root 'MigrateAppl.zip'
            $done = Join-Path $Root 'download-complete.json'
            if (Test-Path $done) { return 'ALREADY_PRESENT' }
            # curl.exe, not Start-BitsTransfer: BITS fails in a non-interactive SYSTEM
            # context, which is what this script runs as. --continue-at - resumes a partial
            # file after a drop. This matches what migrate-step2 already does for the same
            # archive.
            $partial = "$zip.partial"
            $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
            if (-not (Test-Path $curl)) { throw 'curl.exe was not found on this host.' }
            $attempt = 0
            while ($true) {
                $attempt++
                & $curl --location --fail --silent --show-error --retry 5 --retry-delay 20 `
                        --continue-at - --output $partial 'https://aka.ms/migrate/appliance/hyperv'
                if ($LASTEXITCODE -eq 0) { break }
                if ($attempt -ge 5) { throw "curl.exe exited with code $LASTEXITCODE after $attempt attempts." }
                Start-Sleep -Seconds 30
            }
            Move-Item -LiteralPath $partial -Destination $zip -Force
            if (-not (Test-Path $zip)) { throw 'The appliance archive did not download.' }
            $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
            $extract = Join-Path $Root 'Extracted'
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            Expand-Archive -Path $zip -DestinationPath $extract -Force
            $vhd = Get-ChildItem $extract -Recurse -Include *.vhd,*.vhdx -ErrorAction SilentlyContinue |
                   Select-Object -First 1
            if (-not $vhd) { throw 'No VHD was found inside the appliance archive.' }
            [ordered]@{
                CompletedUtc = (Get-Date).ToUniversalTime().ToString('o')
                Archive      = $zip
                ArchiveSha256 = $hash
                ExtractedVhd = $vhd.FullName
                Source       = 'https://aka.ms/migrate/appliance/hyperv'
            } | ConvertTo-Json | Set-Content $done -Encoding UTF8
            return "READY|$($vhd.FullName)|$hash"
        } -ArgumentList $applianceRoot
        Write-Log "Azure Migrate appliance download started in the background into $applianceRoot."
    }
} catch {
    Write-Log "WARNING: could not start the appliance download ($($_.Exception.Message)). Module 1 section 3.3 still applies."
    $applianceJob = $null
}


# Install Windows ADK Deployment Tools (provides oscdimg.exe for cloud-init ISO creation)
$oscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
if (-not (Test-Path $oscdimgPath)) {
    Write-Log "Installing Windows ADK Deployment Tools (for oscdimg)..."
    $adkInstaller = "$labRoot\adksetup.exe"
    $adkUrl = "https://go.microsoft.com/fwlink/?linkid=2243390"
    Invoke-WebRequest -Uri $adkUrl -OutFile $adkInstaller -UseBasicParsing -ErrorAction Stop -TimeoutSec 300
    $signature = Get-AuthenticodeSignature $adkInstaller
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') { throw 'ADK signature validation failed.' }
    Invoke-LabProcess -FilePath $adkInstaller -Arguments '/quiet /norestart /features OptionId.DeploymentTools' -Stage 'Install ADK' -LogDirectory $labRoot -TimeoutSeconds 3600 -SuccessCodes @(0,3010)
    if (-not (Test-Path $oscdimgPath)) { throw 'ADK Deployment Tools installation failed.' }
    Write-Log "Windows ADK Deployment Tools installed."
} else {
    Write-Log "Windows ADK Deployment Tools already installed."
}

$ubuntuCloudUrl = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
$ubuntuQcow2    = "$vhdPath\Ubuntu2204-cloudimg.img"
$ubuntuBaseVhd  = "$vhdPath\Ubuntu2204-Base.vhdx"

$windowsBaseVhd = "$vhdPath\WindowsServer2022-Base.vhdx"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -- Install qemu-img (needed for image conversion) --
$qemuImg = "C:\Program Files\qemu\qemu-img.exe"
if (-not (Test-Path $qemuImg)) {
    $qemuImg = (Get-ChildItem "C:\ProgramData\chocolatey" -Recurse -Filter "qemu-img.exe" -ErrorAction SilentlyContinue | Select-Object -First 1) | Select-Object -ExpandProperty FullName
}
if (-not $qemuImg -or -not (Test-Path $qemuImg)) {
    Write-Log "Installing qemu-img via Chocolatey..."
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        $bootstrap = Join-Path $labRoot 'install-chocolatey.ps1'
        Invoke-WebRequest 'https://community.chocolatey.org/install.ps1' -OutFile $bootstrap -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        Invoke-LabProcess -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
            -Arguments "-NoProfile -ExecutionPolicy Bypass -File `"$bootstrap`"" -Stage 'Install Chocolatey' -LogDirectory $labRoot -TimeoutSeconds 1800
    }
    $chocoCommand = Get-Command choco -ErrorAction SilentlyContinue
    $chocoPath = if ($chocoCommand) { $chocoCommand.Source } else { "$env:ProgramData\chocolatey\bin\choco.exe" }
    Invoke-LabProcess -FilePath $chocoPath -Arguments 'install qemu --no-progress -y' -Stage 'Install QEMU' -LogDirectory $labRoot -TimeoutSeconds 1800
    $qemuImg = (Get-ChildItem "C:\Program Files\qemu" -Filter "qemu-img.exe" -ErrorAction SilentlyContinue | Select-Object -First 1) | Select-Object -ExpandProperty FullName
    if (-not $qemuImg) {
        $qemuImg = (Get-ChildItem "C:\ProgramData\chocolatey" -Recurse -Filter "qemu-img.exe" -ErrorAction SilentlyContinue | Select-Object -First 1) | Select-Object -ExpandProperty FullName
    }
    if (-not $qemuImg) { throw "qemu-img.exe not found after installation." }
}
Write-Log "qemu-img available at: $qemuImg"

# -- Ubuntu cloud image (download QCOW2, convert to VHDX via qemu-img) --
if (-not (Test-Path $ubuntuBaseVhd)) {
    # Download Ubuntu QCOW2 cloud image
    if (Test-Path $ubuntuQcow2) { Remove-Item $ubuntuQcow2 -Force }
    if (-not (Test-Path $ubuntuQcow2)) {
        Write-Log "Downloading Ubuntu 22.04 cloud image (QCOW2 format, ~600MB)..."
        Invoke-LabDownload -Uri $ubuntuCloudUrl -Destination $ubuntuQcow2 -Stage 'Download Ubuntu image'
        $hashPath = "$vhdPath\SHA256SUMS"
        Invoke-WebRequest -Uri 'https://cloud-images.ubuntu.com/jammy/current/SHA256SUMS' -OutFile $hashPath -UseBasicParsing -TimeoutSec 300
        $hashLine = Get-Content $hashPath | Where-Object { $_ -match ' [ *]?jammy-server-cloudimg-amd64.img$' }
        if (@($hashLine).Count -ne 1) { throw 'Cannot identify Ubuntu image checksum; retry if the current image changed.' }
        $expectedHash = ($hashLine -split '\s+')[0]
        if ((Get-FileHash $ubuntuQcow2 -Algorithm SHA256).Hash -ne $expectedHash) { Remove-Item $ubuntuQcow2 -Force; throw 'Ubuntu image checksum mismatch.' }
        Write-Log "Ubuntu cloud image downloaded and SHA256 verified."
    }

    # Convert QCOW2 to VHDX using qemu-img
    Write-Log "Converting Ubuntu QCOW2 to VHDX (this may take a few minutes)..."
    Invoke-LabProcess -FilePath $qemuImg -Arguments "convert -f qcow2 -O vhdx -o subformat=dynamic `"$ubuntuQcow2`" `"$ubuntuBaseVhd`"" -Stage 'Convert Ubuntu image' -LogDirectory $labRoot -TimeoutSeconds 1800
    # Remove sparse file attribute (required by Hyper-V for differencing disks)
    fsutil sparse setflag "$ubuntuBaseVhd" 0
    Write-Log "Ubuntu base VHDX created."

    # Cleanup downloaded QCOW2
    Remove-Item -Path $ubuntuQcow2 -Force -ErrorAction SilentlyContinue
} else {
    Write-Log "Ubuntu base VHDX already exists."
}

# -- Windows Server 2022 base VHDX (downloaded from Azure marketplace managed disk via SAS) --
if (-not (Test-Path $windowsBaseVhd)) {
    if ([string]::IsNullOrWhiteSpace($windowsVhdSasUrl)) {
        throw "Windows VHD SAS URL not provided. Cannot create Windows guest VMs."
    }

    $windowsVhdTemp = "$vhdPath\WindowsServer2022-temp.vhd"
    if (Test-Path $windowsVhdTemp) { Remove-Item $windowsVhdTemp -Force }
    if (-not (Test-Path $windowsVhdTemp)) {
        Remove-Item -Path $windowsVhdTemp -Force -ErrorAction SilentlyContinue
        Write-Log "Downloading Windows Server 2022 VHD from Azure marketplace disk (intra-Azure, fast)..."
        # Install azcopy for reliable large file downloads
        $azcopy = (Get-ChildItem "$labRoot\azcopy" -Recurse -Filter "azcopy.exe" -ErrorAction SilentlyContinue | Select-Object -First 1) | Select-Object -ExpandProperty FullName
        if (-not $azcopy) {
            Write-Log "Installing azcopy..."
            Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile "$labRoot\azcopy.zip" -UseBasicParsing -ErrorAction Stop -TimeoutSec 300
            Expand-Archive -Path "$labRoot\azcopy.zip" -DestinationPath "$labRoot\azcopy" -Force
            $azcopy = (Get-ChildItem "$labRoot\azcopy" -Recurse -Filter "azcopy.exe" | Select-Object -First 1) | Select-Object -ExpandProperty FullName
            Write-Log "azcopy installed at: $azcopy"
        }
        Invoke-LabProcess -FilePath $azcopy -Arguments "copy `"$windowsVhdSasUrl`" `"$windowsVhdTemp`" --check-md5 NoCheck --log-level NONE --output-level quiet" -Stage 'Download Windows image' -LogDirectory $labRoot -TimeoutSeconds 5400
        if (-not (Test-Path $windowsVhdTemp) -or (Get-Item $windowsVhdTemp).Length -lt 1GB) {
            throw "azcopy download failed or file is too small."
        }
        Write-Log "Windows Server VHD downloaded ($([math]::Round((Get-Item $windowsVhdTemp).Length/1GB, 1)) GB)."
    }

    $job = Convert-VHD -Path $windowsVhdTemp -DestinationPath $windowsBaseVhd -VHDType Dynamic -AsJob -ErrorAction Stop
    $null = Wait-LabJob $job 'Convert Windows image' -TimeoutSeconds 1800
    Write-Log 'Windows Server base VHDX created.'

    # Cleanup temp VHD
    Remove-Item -Path $windowsVhdTemp -Force -ErrorAction SilentlyContinue
} else {
    Write-Log "Windows Server base VHDX already exists."
}

# =============================================================
# PHASE 3 - Create guest VMs
# =============================================================
Write-Log "PHASE 3: Creating guest VMs..."

# --- Helper: Create-WindowsGuestVM ---
function Create-WindowsGuestVM {
    param(
        [string]$VMName, [string]$IPAddress,
        [int]$MemoryMB = 4096, [int]$CPUs = 2, [int]$DiskGB = 40
    )

    $existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existingVM) {
        # Left behind by an interrupted run. Its provisioning never completed, so discard it
        # and rebuild rather than adopting a guest in an unknown state.
        Write-Log "VM '$VMName' exists from an incomplete run; removing it before rebuilding."
        if ($existingVM.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force -ErrorAction Stop }
        Remove-VM -Name $VMName -Force -ErrorAction Stop
        Remove-Item "$vhdPath\$VMName.vhdx" -Force -ErrorAction SilentlyContinue
        Remove-Item "$labRoot\VMs\$VMName" -Recurse -Force -ErrorAction SilentlyContinue
        Get-DhcpServerv4Reservation -ScopeId 192.168.0.0 -ErrorAction SilentlyContinue |
            Where-Object Name -EQ $VMName | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue
    }

    Write-Log "Creating Windows VM '$VMName'..."

    $vmVhdPath = "$vhdPath\$VMName.vhdx"
    if (-not (Test-Path $vmVhdPath)) {
        # Fixed, not dynamic. The guest disks are allocated in full at creation so host
        # capacity is deterministic and does not shift under the workshop as the guests
        # write. A dynamic disk also produces expansion write amplification, which shows up
        # as erratic disk I/O in the performance-based assessment in Module 1.
        $job = Convert-VHD -Path $windowsBaseVhd -DestinationPath $vmVhdPath -VHDType Fixed -AsJob -ErrorAction Stop
        $null = Wait-LabJob $job "Create $VMName disk" -TimeoutSeconds 5400
        Resize-VHD -Path $vmVhdPath -SizeBytes ($DiskGB * 1GB)
        $created = Get-VHD -Path $vmVhdPath
        if ($created.VhdType -ne 'Fixed') { throw "$VMName disk is $($created.VhdType); the workshop requires a fixed disk." }
        Write-Log "Created $VMName disk: ${DiskGB} GB fixed."
    }

    # Generate unattend.xml
    $unattendDir = "$labRoot\Unattend\$VMName"
    New-Item -ItemType Directory -Path $unattendDir -Force | Out-Null

    $unattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>__VMNAME__</ComputerName>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>__PASSWORD__</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
    </component>
  </settings>
</unattend>
'@
    $unattendXml = Expand-LabTextTemplate $unattendXml @{
        '__VMNAME__' = $VMName
        '__PASSWORD__' = [System.Security.SecurityElement]::Escape($guestAdminPwd)
    }
    $null = [xml]$unattendXml
    $unattendXml | Out-File -FilePath "$unattendDir\unattend.xml" -Encoding UTF8 -Force

    $vmDir = "$labRoot\VMs\$VMName"
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    New-VM -Name $VMName -MemoryStartupBytes ($MemoryMB * 1MB) -VHDPath $vmVhdPath `
        -SwitchName $intSwitchName -Path $vmDir -Generation 2 -ErrorAction Stop | Out-Null
    Set-LabReservation -VMName $VMName -IPAddress $IPAddress
    Set-VMProcessor -VMName $VMName -Count $CPUs -ErrorAction Stop
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -ErrorAction Stop
    Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off -ErrorAction Stop
    Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
    # Inject unattend.xml into the independent guest VHD.
    try {
        $mountResult = Mount-VHD -Path $vmVhdPath -Passthru -ErrorAction Stop
        $partitions = @($mountResult | Get-Disk | Get-Partition | Where-Object { $_.Type -eq 'Basic' })
        foreach ($partition in $partitions) {
            if (-not $partition.DriveLetter) { $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop }
        }
        $dl = @($mountResult | Get-Disk | Get-Partition | Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path "$($_.DriveLetter):\Windows") } | Select-Object -ExpandProperty DriveLetter)
        if ($dl.Count -ne 1) { throw 'Expected exactly one Windows partition.' }
        $dl = $dl[0]
        if ($dl -and (Test-Path "${dl}:\Windows")) {
            $pantherDir = "${dl}:\Windows\Panther"
            New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
            Copy-Item -Path "$unattendDir\unattend.xml" -Destination "$pantherDir\unattend.xml" -Force
            Write-Log "Injected unattend.xml into VHD for '$VMName'."
        } else {
            throw "Windows directory not found for $VMName."
        }
    } catch {
        throw "Failed to inject unattend.xml for $VMName."
    } finally {
        Dismount-VHD -Path $vmVhdPath -ErrorAction SilentlyContinue
    }

    Write-Log "VM '$VMName' created ($CPUs vCPUs, ${MemoryMB}MB RAM, IP $IPAddress)."
}

# --- Helper: Create-LinuxGuestVM ---
function Create-LinuxGuestVM {
    param(
        [string]$VMName, [string]$IPAddress,
        [int]$MemoryMB = 2048, [int]$CPUs = 2, [int]$DiskGB = 30,
        [string[]]$ExtraPackages = @(),
        [string]$ExtraRunCmdYaml = ""
    )

    $existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($existingVM) {
        Write-Log "VM '$VMName' exists from an incomplete run; removing it before rebuilding."
        if ($existingVM.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force -ErrorAction Stop }
        Remove-VM -Name $VMName -Force -ErrorAction Stop
        Remove-Item "$vhdPath\$VMName.vhdx" -Force -ErrorAction SilentlyContinue
        Remove-Item "$vhdPath\$VMName-cidata.iso" -Force -ErrorAction SilentlyContinue
        Remove-Item "$labRoot\VMs\$VMName" -Recurse -Force -ErrorAction SilentlyContinue
        Get-DhcpServerv4Reservation -ScopeId 192.168.0.0 -ErrorAction SilentlyContinue |
            Where-Object Name -EQ $VMName | Remove-DhcpServerv4Reservation -ErrorAction SilentlyContinue
    }

    Write-Log "Creating Linux VM '$VMName'..."

    $vmVhdPath = "$vhdPath\$VMName.vhdx"
    if (-not (Test-Path $vmVhdPath)) {
        # Fixed for the same reason as the Windows guests: predictable host capacity and
        # steady disk I/O for the Module 1 assessment.
        $job = Convert-VHD -Path $ubuntuBaseVhd -DestinationPath $vmVhdPath -VHDType Fixed -AsJob -ErrorAction Stop
        $null = Wait-LabJob $job "Create $VMName disk" -TimeoutSeconds 5400
    }

    # Resize the standalone disk so cloud-init has room. On a fixed disk this allocates the
    # remaining capacity on the host now rather than on first write.
    Resize-VHD -Path $vmVhdPath -SizeBytes ($DiskGB * 1GB) -ErrorAction Stop
    $created = Get-VHD -Path $vmVhdPath
    if ($created.VhdType -ne 'Fixed') { throw "$VMName disk is $($created.VhdType); the workshop requires a fixed disk." }
    Write-Log "Created $VMName disk: ${DiskGB} GB fixed."


    # Cloud-init files
    $cloudInitDir = "$labRoot\CloudInit\$VMName"
    New-Item -ItemType Directory -Path $cloudInitDir -Force | Out-Null

    $metaData = "instance-id: $VMName`nlocal-hostname: $VMName"
    [System.IO.File]::WriteAllText("$cloudInitDir\meta-data", $metaData, [System.Text.UTF8Encoding]::new($false))

    $macAddress = '00155D0000' + ([int]($IPAddress.Split('.')[-1])).ToString('X2')
    $macColon = ($macAddress -replace '(..)(?!$)', '$1:').ToLowerInvariant()
    $networkConfig = @'
version: 2
ethernets:
  labnic:
    match:
      macaddress: "__MAC__"
    set-name: eth0
    dhcp4: true
    dhcp-identifier: mac
'@
    $networkConfig = Expand-LabTextTemplate $networkConfig @{ '__MAC__' = $macColon }
    [System.IO.File]::WriteAllText("$cloudInitDir\network-config", $networkConfig, [System.Text.UTF8Encoding]::new($false))

    # linux-cloud-tools-common supplies the systemd units and helper scripts for the
    # Hyper-V guest daemons. The matching per-kernel binaries are installed in runcmd,
    # where the running kernel version can be resolved.
    # plocate provides the locate command. Azure Migrate software inventory runs locate on
    # Linux guests to find installed applications, and Ubuntu cloud images omit it.
    # Azure Migrate runs a fixed command set over SSH for software inventory and agentless
    # dependency analysis. net-tools supplies netstat, iproute2 supplies ss, libcap2-bin
    # supplies getcap and plocate supplies locate -- none of which ship in a cloud image.
    $basePackages = @("openssh-server", "curl", "wget", "net-tools", "iproute2", "libcap2-bin",
        "walinuxagent", "linux-cloud-tools-common", "plocate")
    $allPackages  = $basePackages + $ExtraPackages
    $pkgYaml = ($allPackages | ForEach-Object { "  - $_" }) -join "`n"

    $networkPrepare = @'
  - |
    cat > /etc/netplan/50-cloud-init.yaml << 'NETPLAN'
    network:
      version: 2
      ethernets:
        primary:
          match:
            name: "e*"
          dhcp4: true
          dhcp-identifier: mac
    NETPLAN
  - chmod 600 /etc/netplan/50-cloud-init.yaml
  - |
    echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
  - netplan generate
'@
    # ufw is present but inactive on Ubuntu cloud images; the explicit disable keeps an
    # enclosed lab guest reachable for ping and lab traffic even if an image ships it enabled.
    # Hyper-V Data Exchange (KVP) is how the host reports this guest's operating system
    # and IP address. Azure Migrate reads guest OS details through the host, so without the
    # daemon the guest is discovered but its OS information is blank.
    #
    # Two separate pieces are needed and both are missing from an Ubuntu cloud image as
    # provisioned. The hv_utils kernel module publishes /dev/vmbus/hv_kvp; the daemon's
    # systemd unit Requires that device, so starting the service before the module is
    # loaded fails with 'A dependency job for hv-kvp-daemon.service failed'. Load the
    # module first and persist it, then install the userspace daemons.
    #
    # hv_utils is distinct from hv_netvsc and hv_storvsc, which the image already loads --
    # a guest can therefore have working network and disk while reporting nothing about
    # itself to the host. The per-kernel package matches the running kernel and needs no
    # reboot; the -virtual meta-packages are a fallback for images whose exact version is
    # not in the archive, and that path does require a reboot to take effect.
    $hyperVIntegration = @'
  - modprobe hv_utils || true
  - |
    echo hv_utils > /etc/modules-load.d/hyperv.conf
  - |
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y "linux-cloud-tools-$(uname -r)" \
      || apt-get install -y linux-cloud-tools-virtual linux-tools-virtual \
      || true
  - udevadm control --reload-rules || true
  - udevadm trigger --subsystem-match=vmbus || true
  - udevadm settle || true
  - systemctl enable hv-kvp-daemon.service || true
  - systemctl enable hv-vss-daemon.service || true
  - systemctl start hv-kvp-daemon.service || true
  - systemctl start hv-vss-daemon.service || true
  - updatedb || true
  - |
    if systemctl is-active --quiet hv-kvp-daemon.service; then
      echo 'LAB_KVP_DAEMON_RUNNING'
    else
      # Expected on first pass. The tools package installs udev rules that create
      # /dev/vmbus/hv_kvp, and the daemon unit Requires that device, so the service cannot
      # start until the rules have been applied to a fresh boot. The services are enabled,
      # so the reboot below starts them. Record why for the log either way.
      echo 'LAB_KVP_DAEMON_PENDING_REBOOT - services enabled; starting after the scheduled reboot'
      lsmod | grep -q hv_utils || echo 'LAB_KVP_CAUSE - hv_utils module is not loaded'
      test -e /dev/vmbus/hv_kvp || echo 'LAB_KVP_CAUSE - /dev/vmbus/hv_kvp does not exist yet'
      command -v hv_kvp_daemon >/dev/null 2>&1 || ls /usr/lib/linux-tools/*/hv_kvp_daemon >/dev/null 2>&1 \
        || echo 'LAB_KVP_CAUSE - daemon binary not installed for this kernel'
    fi
  - |
    # Confirm the account and command set Azure Migrate needs over SSH, so a gap appears in
    # the cloud-init log rather than as an empty inventory days later.
    sudo -n true 2>/dev/null && echo 'LAB_SUDO_NOPASSWD_OK' || echo 'LAB_SUDO_NOPASSWD_MISSING'
    # passwd -S reports P for a usable password, L for locked, NP for none.
    case "$(passwd -S __USER__ 2>/dev/null | awk '{print $2}')" in
      P) echo 'LAB_GUEST_PASSWORD_SET' ;;
      L) echo 'LAB_GUEST_PASSWORD_LOCKED - console and SSH sign-in will fail' ;;
      *) echo 'LAB_GUEST_PASSWORD_MISSING - console and SSH sign-in will fail' ;;
    esac
    missing=''
    for c in ls netstat ss touch chmod cat ps grep echo sha256sum awk sudo dpkg sed getcap which date locate; do
      command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
    done
    if [ -n "$missing" ]; then echo "LAB_DEPENDENCY_COMMANDS_MISSING -$missing"; else echo 'LAB_DEPENDENCY_COMMANDS_OK'; fi
    systemctl is-active --quiet ssh && echo 'LAB_SSH_ACTIVE' || echo 'LAB_SSH_INACTIVE'
'@
    $baseRun = @("  - systemctl enable ssh", "  - systemctl start ssh", "  - systemctl enable walinuxagent", "  - systemctl start walinuxagent",
        "  - ufw --force disable || true")
    # Expand-LabTextTemplate replaces tokens in one pass and never rescans inserted text,
    # so any token inside the runcmd fragments must be resolved before they are joined in.
    $hyperVIntegration = $hyperVIntegration.Replace('__USER__', $guestUser)
    $runYaml = ($baseRun -join "`n") + "`n" + $networkPrepare + "`n" + $hyperVIntegration
    if ($ExtraRunCmdYaml) { $runYaml += "`n$ExtraRunCmdYaml" }

    # The password is set through chpasswd's users list, which names the account directly.
    # The top-level 'password:' key applies to the distro DEFAULT user, and because this
    # file replaces 'users:' without including 'default', no default user exists -- so that
    # form silently applied the password to nobody. 'plain_text_passwd' is also deprecated.
    $userData = @'
#cloud-config
ssh_pwauth: true
users:
  - name: __USER__
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
chpasswd:
  expire: false
  users:
    - name: __USER__
      password: __PASSWORD__
      type: text
packages:
__PKGYAML__
runcmd:
__RUNYAML__
power_state:
  mode: reboot
  message: Restarting to activate the Hyper-V guest daemons
  timeout: 30
  condition: true
'@
    $passwordYaml = ConvertTo-Json -InputObject $guestAdminPwd -Compress
    $userData = Expand-LabTextTemplate $userData @{
        '__PASSWORD__' = $passwordYaml
        '__USER__' = $guestUser
        '__PKGYAML__' = $pkgYaml
        '__RUNYAML__' = $runYaml
    }
    [System.IO.File]::WriteAllText("$cloudInitDir\user-data", $userData, [System.Text.UTF8Encoding]::new($false))

    # Create cloud-init ISO
    $ciIsoPath = "$vhdPath\$VMName-cidata.iso"
    $oscdimg = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"

    $isoCreated = $false
    if (Test-Path $oscdimg) {
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        & $oscdimg -j2 -lcidata "$cloudInitDir" "$ciIsoPath" 2>&1 | Out-Null
        $ErrorActionPreference = $prevEAP
        if ($LASTEXITCODE -eq 0 -and (Test-Path $ciIsoPath)) { $isoCreated = $true }
    }

    if (-not $isoCreated) { throw "Cloud-init ISO creation failed for $VMName. No guest was created." }

    $vmDir = "$labRoot\VMs\$VMName"
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

    New-VM -Name $VMName -MemoryStartupBytes ($MemoryMB * 1MB) -VHDPath $vmVhdPath `
        -SwitchName $intSwitchName -Path $vmDir -Generation 2 -ErrorAction Stop | Out-Null
    Set-VMProcessor -VMName $VMName -Count $CPUs -ErrorAction Stop
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -ErrorAction Stop
    Set-VMFirmware -VMName $VMName -EnableSecureBoot Off -ErrorAction Stop
    Set-LabReservation -VMName $VMName -IPAddress $IPAddress
    Set-VM -Name $VMName -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
    Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

    if ($ciIsoPath -and (Test-Path $ciIsoPath)) {
        Add-VMDvdDrive -VMName $VMName -Path $ciIsoPath -ErrorAction Stop
        Write-Log "Attached cloud-init ISO to '$VMName'."
    }

    Write-Log "VM '$VMName' created ($CPUs vCPUs, ${MemoryMB}MB RAM, IP $IPAddress)."
}

# --- Define cloud-init runcmd YAML for Linux workloads ---

# Nginx web server setup (packages directive installs nginx before runcmd runs)
$nginxRunCmdYaml = @'
  - systemctl enable nginx
  - systemctl start nginx
  - |
    cat > /var/www/html/index.html << 'HTMLEOF'
    <!DOCTYPE html>
    <html>
    <head>
        <title>TD SYNNEX - Cloud Enablement Services</title>
        <style>
            body { font-family: 'Segoe UI', sans-serif; margin: 40px; background: #1a1a2e; color: #eee; }
            .container { max-width: 800px; margin: 0 auto; background: #16213e; padding: 40px; border-radius: 8px; }
            h1 { color: #e94560; }
            .info { background: #0f3460; padding: 15px; border-radius: 4px; margin: 20px 0; }
            .status { color: #4ecca3; font-weight: bold; }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>TD SYNNEX | Linux Web</h1><p>Cloud Enablement Services</p>
            <p class="status">&#x2705; Nginx is running</p>
            <div class="info">
                <h3>Environment Details</h3>
                <ul>
                    <li><strong>Server:</strong> OnPrem-Linux-Web</li>
                    <li><strong>Platform:</strong> Ubuntu 22.04 + Nginx</li>
                    <li><strong>IP Address:</strong> 192.168.0.12</li>
                    <li><strong>Status:</strong> On-Premises (Pre-Migration)</li>
                </ul>
            </div>
            <p>This is a sample Linux-hosted website for the Azure Migrate Workshop.</p>
        </div>
    </body>
    </html>
    HTMLEOF
'@

# Node.js + Express.js app setup
$nodeJsRunCmdYaml = @'
  - apt-get update -y
  - curl -fsSL https://deb.nodesource.com/setup_24.x -o /tmp/nodesource_setup.sh
  - bash /tmp/nodesource_setup.sh
  - DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  - mkdir -p /opt/contoso-app
  - |
    cat > /opt/contoso-app/package.json << 'PKGJSON'
    {
      "name": "contoso-app",
      "version": "1.0.0",
      "description": "Contoso sample Node.js application for Azure Migrate Workshop",
      "main": "server.js",
      "scripts": { "start": "node server.js" },
      "dependencies": { "express": "5.2.1" }
    }
    PKGJSON
  - |
    cat > /opt/contoso-app/server.js << 'SERVERJS'
    const express = require('express');
    const os = require('os');
    const app = express();
    const PORT = 3000;

    app.get('/', (req, res) => {
      res.send(`
        <!DOCTYPE html>
        <html>
        <head>
          <title>TD SYNNEX - Cloud Enablement Services</title>
          <style>
            body { font-family: 'Segoe UI', sans-serif; margin: 40px; background: #0d1117; color: #c9d1d9; }
            .container { max-width: 800px; margin: 0 auto; background: #161b22; padding: 40px; border-radius: 8px; border: 1px solid #30363d; }
            h1 { color: #58a6ff; }
            pre { background: #0d1117; padding: 15px; border-radius: 4px; overflow-x: auto; }
            .status { color: #3fb950; font-weight: bold; }
          </style>
        </head>
        <body>
          <div class="container">
            <h1>TD SYNNEX | Application Server</h1><p>Cloud Enablement Services</p>
            <p class="status">&#x2705; Node.js API is running</p>
            <h3>System Info</h3>
            <pre>${JSON.stringify({
              hostname: os.hostname(),
              platform: os.platform(),
              arch: os.arch(),
              uptime: Math.floor(os.uptime()) + 's',
              memory: Math.floor(os.totalmem() / 1024 / 1024) + 'MB',
              nodeVersion: process.version
            }, null, 2)}</pre>
            <h3>API Endpoints</h3>
            <ul>
              <li><a href="/api/health" style="color:#58a6ff">/api/health</a> - Health check</li>
              <li><a href="/api/info" style="color:#58a6ff">/api/info</a> - System information</li>
            </ul>
          </div>
        </body>
        </html>
      `);
    });

    app.get('/api/health', (req, res) => {
      res.json({ status: 'healthy', timestamp: new Date().toISOString(), server: 'OnPrem-Linux-App' });
    });

    app.get('/api/info', (req, res) => {
      res.json({
        hostname: os.hostname(),
        platform: os.platform(),
        arch: os.arch(),
        uptime: os.uptime(),
        memory: { total: os.totalmem(), free: os.freemem() },
        cpus: os.cpus().length,
        nodeVersion: process.version,
        environment: 'on-premises'
      });
    });

    app.listen(PORT, '0.0.0.0', () => {
      console.log(`Contoso App Server running on port ${PORT}`);
    });
    SERVERJS
  - cd /opt/contoso-app && npm install --omit=dev
  - |
    cat > /etc/systemd/system/contoso-app.service << 'SVCFILE'
    [Unit]
    Description=Contoso Node.js Application
    After=network.target

    [Service]
    Type=simple
    User=contosoapp
    NoNewPrivileges=true
    WorkingDirectory=/opt/contoso-app
    ExecStart=/usr/bin/node server.js
    Restart=on-failure
    RestartSec=10
    Environment=NODE_ENV=production

    [Install]
    WantedBy=multi-user.target
    SVCFILE
  - useradd --system --no-create-home --shell /usr/sbin/nologin contosoapp
  - chown -R contosoapp:contosoapp /opt/contoso-app
  - systemctl daemon-reload
  - systemctl enable contoso-app
  - systemctl start contoso-app
'@

# --- Create VMs ---
Create-WindowsGuestVM -VMName "OnPrem-Web" -IPAddress "192.168.0.10" -MemoryMB 4096 -CPUs 2
Create-WindowsGuestVM -VMName "OnPrem-SQL" -IPAddress "192.168.0.11" -MemoryMB 4096 -CPUs 2
# No appliance OS VM is built here. The Azure Migrate appliance arrives as Microsoft's
# published VHD, downloaded and imported by the instructor in Module 1; its host memory
# and 192.168.0.20 reservation are deliberately left unused for that import.
Create-LinuxGuestVM   -VMName "OnPrem-Linux-Web" -IPAddress "192.168.0.12" -MemoryMB 2048 -CPUs 2 -ExtraPackages @("nginx") -ExtraRunCmdYaml $nginxRunCmdYaml
Create-LinuxGuestVM   -VMName "OnPrem-Linux-App" -IPAddress "192.168.0.13" -MemoryMB 2048 -CPUs 2 -ExtraRunCmdYaml $nodeJsRunCmdYaml

# =============================================================
# PHASE 4 - Start VMs and wait for boot
# =============================================================
Write-Log "PHASE 4: Starting guest VMs..."

$allVMs = @("OnPrem-Web", "OnPrem-SQL", "OnPrem-Linux-Web", "OnPrem-Linux-App")
foreach ($vm in $allVMs) {
    $v = Get-VM -Name $vm -ErrorAction SilentlyContinue
    if ($v -and $v.State -ne "Running") {
        Start-VM -Name $vm -ErrorAction Stop
        Write-Log "Started VM '$vm'."
    } elseif ($v) {
        Write-Log "VM '$vm' is already running."
    } else {
        Write-Log "WARNING: VM '$vm' not found."
    }
}

Write-Log 'Checking guest first boot immediately; readiness still requires heartbeat and Windows sign-in.'

# --- Wait helper ---
function Wait-ForGuestVM {
    param([string]$VMName, [int]$TimeoutSeconds = 900)
    Write-Log "Waiting for '$VMName' heartbeat..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $guest = Get-VM -Name $VMName -ErrorAction Stop
        if ([string]$guest.State -match 'Critical|Paused|Saved|Off') { throw "Guest $VMName is $($guest.State). Inspect its console and Hyper-V events." }
        Write-Log "Guest '$VMName': $($guest.State); waiting for heartbeat and management readiness."
        $hb = Get-VMIntegrationService -VMName $VMName -Name "Heartbeat" -ErrorAction SilentlyContinue
        if ($hb -and $hb.PrimaryStatusDescription -eq "OK") {
            if ($VMName -notlike '*Linux*') {
                try {
                    $job = Invoke-Command -VMName $VMName -Credential $winCred -ScriptBlock { $env:COMPUTERNAME } -AsJob -ErrorAction Stop
                    $null = Wait-LabJob $job "Sign in to $VMName" -TimeoutSeconds 60
                }
                catch { Start-Sleep -Seconds 10; continue }
            }
            Write-Log "'$VMName' is responding."
            return $true
        }
        Start-Sleep -Seconds 10
    }
    Write-Log "WARNING: Timed out waiting for '$VMName'."
    return $false
}

# =============================================================
# PHASE 5 - Install workloads
# =============================================================
Write-Log "PHASE 5: Installing workloads..."

$winCred = New-Object System.Management.Automation.PSCredential(
    "Administrator",
    (ConvertTo-SecureString $guestAdminPwd -AsPlainText -Force)
)

# Expand the Windows OS partitions and enable private management after first boot.
foreach ($name in @('OnPrem-Web','OnPrem-SQL')) {
    if (-not (Wait-ForGuestVM -VMName $name)) { throw "Guest setup did not finish: $name" }
    Invoke-Command -VMName $name -Credential $winCred -ScriptBlock {
        $ErrorActionPreference = 'Stop'
        $size = Get-PartitionSupportedSize -DriveLetter C
        if ((Get-Partition -DriveLetter C).Size -lt $size.SizeMax) { Resize-Partition -DriveLetter C -Size $size.SizeMax }
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

        # Azure Migrate software inventory connects to each guest over PowerShell remoting to
        # read installed roles, features and applications. Windows Server enables WinRM by
        # default, but a DHCP guest can classify its network as Public and refuse the
        # listener, so configure it explicitly rather than relying on the default.
        Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null
        if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }

        # Enclosed training lab: the nested subnet, the Hyper-V host and the target/test
        # VNets are trusted. Two scoped rules replace ad-hoc group enablement such as
        # 'File and Printer Sharing', which would also open SMB and NetBIOS to obtain ping.
        $labRanges = @('192.168.0.0/24','10.0.0.0/16','10.1.0.0/16','10.2.0.0/16')
        # A DHCP guest often classifies the lab NIC as Public. Private keeps the built-in
        # groups behaving as an instructor expects; the rules below are profile-independent.
        Get-NetConnectionProfile -ErrorAction SilentlyContinue |
            Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
        if (Get-NetFirewallRule -Name LabTrustedIcmp4 -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -Name LabTrustedIcmp4
        }
        # Stated separately from the rule below so ping keeps working if an instructor
        # later narrows or deletes the any-protocol rule.
        New-NetFirewallRule -Name LabTrustedIcmp4 -DisplayName 'Lab trusted ICMPv4 echo' `
            -Direction Inbound -Action Allow -Profile Any -Protocol ICMPv4 -IcmpType 8 `
            -RemoteAddress $labRanges | Out-Null
        if (Get-NetFirewallRule -Name LabTrustedInbound -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -Name LabTrustedInbound
        }
        New-NetFirewallRule -Name LabTrustedInbound -DisplayName 'Lab trusted inbound (any protocol)' `
            -Direction Inbound -Action Allow -Profile Any -Protocol Any `
            -RemoteAddress $labRanges | Out-Null
    }
}
# Software inventory depends on this path; prove it from the host rather than assuming.
foreach ($name in @('OnPrem-Web','OnPrem-SQL')) {
    $address = if ($name -eq 'OnPrem-Web') { '192.168.0.10' } else { '192.168.0.11' }
    if (Test-NetConnection $address -Port 5985 -InformationLevel Quiet -WarningAction SilentlyContinue) {
        Write-Log "PowerShell remoting reachable on $name ($address)."
    } else {
        Write-Log "WARNING: WinRM port 5985 is not reachable on $name ($address). Azure Migrate software inventory will return no applications for this guest."
    }
}

# ---- OnPrem-Web: IIS + ASP.NET + sample site ----
Write-Log "--- Configuring OnPrem-Web (192.168.0.10) ---"
try {
    if (-not (Wait-ForGuestVM -VMName "OnPrem-Web")) { throw "Windows web guest not ready." }

    $workloadJob = Invoke-Command -VMName "OnPrem-Web" -Credential $winCred -AsJob -ScriptBlock {
        $ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

        if (-not (Get-WindowsFeature Web-Server).Installed) {
            Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction Stop | Out-Null
        }
        if (-not (Get-WindowsFeature Web-Asp-Net45).Installed) {
            Install-WindowsFeature -Name Web-Asp-Net45 -ErrorAction Stop | Out-Null
        }

        # Enable RDP for private lab validation; network access remains restricted.
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
        $sitePath = "C:\inetpub\wwwroot"
        @'
<!DOCTYPE html>
<html>
<head>
    <title>TD SYNNEX - Cloud Enablement Services</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; margin: 40px; background: #f0f0f0; }
        .container { max-width: 800px; margin: 0 auto; background: white; padding: 40px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #0078d4; }
        .info { background: #e8f4fd; padding: 15px; border-radius: 4px; margin: 20px 0; }
        .status { color: #107c10; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <h1>TD SYNNEX | Windows Web</h1><p>Cloud Enablement Services</p>
        <p class="status">&#x2705; Application is running</p>
        <div class="info">
            <h3>Environment Details</h3>
            <ul>
                <li><strong>Server:</strong> OnPrem-Web</li>
                <li><strong>Platform:</strong> Windows Server 2022 + IIS</li>
                <li><strong>IP Address:</strong> 192.168.0.10</li>
                <li><strong>Sample:</strong> Standalone static site (no database connection)</li>
                <li><strong>Status:</strong> On-Premises (Pre-Migration)</li>
            </ul>
        </div>
        <p>This is a sample on-premises web application for the Azure Migrate Workshop.</p>
    </div>
</body>
</html>
'@ | Out-File -FilePath "$sitePath\index.html" -Encoding UTF8 -Force
        Write-Output "IIS and sample website deployed on OnPrem-Web."
    } -ErrorAction Stop

    $null = Wait-LabJob $workloadJob 'Install IIS sample' -TimeoutSeconds 1800
    Write-Log "OnPrem-Web configured successfully."
} catch {
    throw "OnPrem-Web workload setup failed: $_"
}

# ---- OnPrem-SQL: SQL Server 2022 Express + ContosoApp DB ----
Write-Log "--- Configuring OnPrem-SQL (192.168.0.11) ---"
try {
    if (-not (Wait-ForGuestVM -VMName "OnPrem-SQL")) { throw "SQL guest not ready." }

    $workloadJob = Invoke-Command -VMName "OnPrem-SQL" -Credential $winCred -AsJob -ScriptBlock {
        $ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

        # The older Download Center package is rejected by Microsoft's current bootstrap manifest.
        # This is the version-specific SQL 2022 package, not a generic latest-SQL redirect.
        $sqlSseiUrl = "https://download.microsoft.com/download/e5d37105-aa68-4488-8ed5-b579e3809ea1/SQL2022-SSEI-Expr.exe"
        $sqlBootstrapManifestUrl = "https://download.microsoft.com/download/e5d37105-aa68-4488-8ed5-b579e3809ea1/Manifest_Bootstrap_All.xml"
        $sqlSsei = "C:\Temp\SQL2022-SSEI-Expr.exe"
        $sqlBootstrapManifestPath = "C:\Temp\SQL2022-Bootstrap-Manifest.xml"

        function Assert-LabSqlInstaller {
            param($VersionInfo, $Signature, [string]$ManifestText)
            if ($null -eq $Signature -or $Signature.Status -ne 'Valid' -or $null -eq $Signature.SignerCertificate -or
                $Signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
                throw 'SQL installer signature is invalid or is not from Microsoft Corporation. The installer was not started.'
            }
            if ($null -eq $VersionInfo -or $VersionInfo.OriginalFilename -cne 'SQL2022-SSEI-Expr.exe' -or $VersionInfo.FileMajorPart -ne 16) {
                throw 'The downloaded package is not the expected SQL Server 2022 Express installer. The installer was not started.'
            }
            $actual = [version]::new($VersionInfo.FileMajorPart,$VersionInfo.FileMinorPart,$VersionInfo.FileBuildPart,$VersionInfo.FilePrivatePart)
            # Read only the published version fields; never process DTDs or external XML entities.
            $settings = [Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $settings.MaxCharactersInDocument = 1MB
            $reader = $null; $textReader = $null
            try {
                $textReader = [IO.StringReader]::new($ManifestText)
                $reader = [Xml.XmlReader]::Create($textReader,$settings)
                $manifest = [Xml.XmlDocument]::new()
                $manifest.XmlResolver = $null
                $manifest.Load($reader)
                $namespaces = [Xml.XmlNamespaceManager]::new($manifest.NameTable)
                $namespaces.AddNamespace('m','http://schemas.datacontract.org/2004/07/InstallerEngine')
                $namespaces.AddNamespace('s','http://schemas.datacontract.org/2004/07/System')
                $parts = @(foreach ($name in @('_Major','_Minor','_Build','_Revision')) {
                    $nodes = $manifest.SelectNodes("/m:Manifest/m:SupportedEngineVersion/s:$name",$namespaces)
                    if ($nodes.Count -ne 1 -or $nodes[0].InnerText -notmatch '^\d{1,5}$' -or [int]$nodes[0].InnerText -gt 65535) {
                        throw 'Missing or invalid version field.'
                    }
                    [int]$nodes[0].InnerText
                })
                $minimum = [version]::new($parts[0],$parts[1],$parts[2],$parts[3])
                if ($minimum.Major -ne 16) { throw 'Unexpected SQL major version.' }
            } catch {
                throw 'Could not verify the SQL Server 2022 bootstrap manifest. Check the download endpoint or obtain a reviewed workshop update; the installer was not started.'
            } finally {
                if ($null -ne $reader) { $reader.Dispose() }
                if ($null -ne $textReader) { $textReader.Dispose() }
            }
            if ($actual -lt $minimum) {
                throw "SQL Server 2022 Express installer version $actual is below Microsoft's required minimum $minimum. Obtain the current SQL 2022 installer; the installer was not started."
            }
            return [pscustomobject]@{ Version=$actual.ToString(); MinimumVersion=$minimum.ToString() }
        }

        New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null

        $sqlService = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
        if (-not $sqlService) {
            Write-Output "Downloading SQL Server 2022 Express installer..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            try {
                Invoke-WebRequest -Uri $sqlBootstrapManifestUrl -OutFile $sqlBootstrapManifestPath -UseBasicParsing -ErrorAction Stop -TimeoutSec 60
                $bootstrapManifestText = Get-Content -LiteralPath $sqlBootstrapManifestPath -Raw -Encoding UTF8 -ErrorAction Stop
            } catch { throw 'Could not retrieve the SQL Server 2022 bootstrap manifest. Check outbound HTTPS/proxy access; the installer was not started.' }
            Invoke-WebRequest -Uri $sqlSseiUrl -OutFile $sqlSsei -UseBasicParsing -ErrorAction Stop -TimeoutSec 300

            $signature = Get-AuthenticodeSignature $sqlSsei
            $installerInfo = Assert-LabSqlInstaller -VersionInfo (Get-Item -LiteralPath $sqlSsei).VersionInfo -Signature $signature -ManifestText $bootstrapManifestText
            Write-Output "Verified Microsoft SQL 2022 Express installer $($installerInfo.Version); required minimum $($installerInfo.MinimumVersion)."
            $install = Start-Process -FilePath $sqlSsei -ArgumentList '/ACTION=Install /QUIET /IACCEPTSQLSERVERLICENSETERMS' -PassThru
            $null = $install.Handle
            if (-not $install.WaitForExit(3600000)) {
                & taskkill.exe /PID $install.Id /T /F 2>&1 | Out-Null
                throw 'SQL Express installation exceeded 60 minutes. Inspect SQL Setup Bootstrap logs before retrying.'
            }
            if ($install.ExitCode -notin @(0,3010)) { throw "SQL Express installer failed: $($install.ExitCode)" }
            if (-not (Get-Service 'MSSQL$SQLEXPRESS' -ErrorAction SilentlyContinue)) { throw 'SQLEXPRESS service not found after installation.' }
        } else {
            Write-Output "SQL Server Express is already installed."
        }

        $instanceId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').SQLEXPRESS
        $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
        Set-ItemProperty $tcpPath -Name Enabled -Value 1
        Set-ItemProperty "$tcpPath\IPAll" -Name TcpDynamicPorts -Value ''
        Set-ItemProperty "$tcpPath\IPAll" -Name TcpPort -Value '1433'
        Restart-Service 'MSSQL$SQLEXPRESS'
        if (-not (Get-NetFirewallRule -Name LabSql -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name LabSql -DisplayName 'Lab SQL from private networks' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 1433 -RemoteAddress 192.168.0.0/24,10.1.0.0/16,10.2.0.0/16 | Out-Null
        }
        Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
        # Create sample database using PowerShell SqlServer module
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
            Install-Module -Name SqlServer -Force -AllowClobber -ErrorAction Stop

            Invoke-Sqlcmd -TrustServerCertificate -ServerInstance ".\SQLEXPRESS" -Query "IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'ContosoApp') CREATE DATABASE ContosoApp;" -ErrorAction Stop

            $createTables = "USE ContosoApp; IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Customers') BEGIN CREATE TABLE Customers (CustomerID INT PRIMARY KEY IDENTITY(1,1), FirstName NVARCHAR(50), LastName NVARCHAR(50), Email NVARCHAR(100), City NVARCHAR(50), CreatedDate DATETIME DEFAULT GETDATE()); INSERT INTO Customers (FirstName, LastName, Email, City) VALUES ('Alice','Johnson','alice@contoso.com','Seattle'),('Bob','Smith','bob@contoso.com','Portland'),('Carol','Williams','carol@contoso.com','San Francisco'),('Dave','Brown','dave@contoso.com','Los Angeles'),('Eve','Davis','eve@contoso.com','Denver'); END; IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Orders') BEGIN CREATE TABLE Orders (OrderID INT PRIMARY KEY IDENTITY(1,1), CustomerID INT FOREIGN KEY REFERENCES Customers(CustomerID), ProductName NVARCHAR(100), Quantity INT, UnitPrice DECIMAL(10,2), OrderDate DATETIME DEFAULT GETDATE()); INSERT INTO Orders (CustomerID, ProductName, Quantity, UnitPrice) VALUES (1,'Azure Certification Guide',2,49.99),(2,'Cloud Architecture Poster',1,19.99),(3,'DevOps Handbook',3,39.99),(1,'Kubernetes Stickers',10,4.99),(4,'Serverless Cookbook',1,34.99); END;"
            Invoke-Sqlcmd -TrustServerCertificate -ServerInstance ".\SQLEXPRESS" -Query $createTables -ErrorAction Stop
            # Permit the Azure VM agent's SYSTEM identity to validate only this lab database.
            Invoke-Sqlcmd -TrustServerCertificate -ServerInstance ".\SQLEXPRESS" -Query "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name=N'NT AUTHORITY\SYSTEM') CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS; USE ContosoApp; IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name=N'NT AUTHORITY\SYSTEM') CREATE USER [NT AUTHORITY\SYSTEM] FOR LOGIN [NT AUTHORITY\SYSTEM]; ALTER ROLE db_owner ADD MEMBER [NT AUTHORITY\SYSTEM];" -ErrorAction Stop
            Write-Output "Sample database 'ContosoApp' created with Customers and Orders tables."
        } catch {
            throw "Could not create sample database: $_"
        }
    } -ErrorAction Stop

    $null = Wait-LabJob $workloadJob 'Install SQL sample' -TimeoutSeconds 4500
    Write-Log "OnPrem-SQL configured successfully."
} catch {
    throw "OnPrem-SQL workload setup failed: $_"
}

# The Linux guests reboot once at the end of cloud-init so the Hyper-V guest daemons start
# against the udev rules their tools package installed. Validation already retries for 20
# minutes, which absorbs that restart; a guest that is briefly unreachable here is normal.
# Workload success must be observed, not inferred from VM heartbeat.
Write-Log 'Validating sample applications...'
$deadline = (Get-Date).AddMinutes(20)
$healthy = $false
while ((Get-Date) -lt $deadline) {
    try {
        Assert-LabSourceWorkloads
        $healthy = $true
        break
    } catch { Write-Log "Application readiness pending: $($_.Exception.Message)"; Start-Sleep -Seconds 20 }
}
if (-not $healthy) { throw 'Workload readiness timed out. Check guest services and cloud-init logs; setup is incomplete.' }
# Delete Windows setup password material after successful first boot.
foreach ($name in @('OnPrem-Web','OnPrem-SQL')) {
    Invoke-Command -VMName $name -Credential $winCred -ScriptBlock {
        Remove-Item 'C:\Windows\Panther\unattend.xml' -Force -ErrorAction SilentlyContinue
        Remove-Item 'C:\Windows\Panther\Unattend\unattend.xml' -Force -ErrorAction SilentlyContinue
    }
}
Remove-Item "$labRoot\Unattend" -Recurse -Force -ErrorAction SilentlyContinue
# Detach the cloud-init seed to keep it out of migration disk selection.
foreach ($name in @('OnPrem-Linux-Web','OnPrem-Linux-App')) {
    Get-VMDvdDrive -VMName $name | Set-VMDvdDrive -Path $null
    Remove-Item "$vhdPath\$name-cidata.iso" -Force -ErrorAction SilentlyContinue
}
Remove-Item "$labRoot\CloudInit" -Recurse -Force -ErrorAction SilentlyContinue
# cloud-init retains a root-only copy of user-data within Linux; credentials are lab-only.
# =============================================================
# PHASE 6 - Stage the optional traffic generator on the host
# =============================================================
# Written to disk only. Nothing here starts traffic: the instructor decides whether to run
# it, and when. Delivering it now means no file has to be copied onto HyperVHost by hand.
Write-Log "PHASE 6: Staging the optional lab traffic generator..."
$trafficScriptPath = "$labRoot\enable-lab-traffic.ps1"
$trafficSettingsPath = "$labRoot\lab-traffic.settings.json"
$trafficPayload = '__LAB_TRAFFIC_PAYLOAD__'
$payloadStream = [IO.MemoryStream]::new([Convert]::FromBase64String($trafficPayload))
$decompressor = [IO.Compression.GzipStream]::new($payloadStream, [IO.Compression.CompressionMode]::Decompress)
$payloadReader = [IO.StreamReader]::new($decompressor, [Text.UTF8Encoding]::new($false))
try { $trafficScript = $payloadReader.ReadToEnd() } finally { $payloadReader.Dispose() }
if ([string]::IsNullOrWhiteSpace($trafficScript)) { throw 'The staged lab traffic script decoded empty.' }
[IO.File]::WriteAllText($trafficScriptPath, $trafficScript, [Text.UTF8Encoding]::new($false))
# Deployment knows the lab user and the guest addresses; record them so the script can be
# run on this host with no arguments beyond the lab password.
[ordered]@{
    SchemaVersion    = 1
    GeneratedUtc     = (Get-Date).ToUniversalTime().ToString('o')
    LinuxUsername    = $guestUser
    WindowsGuests    = @('OnPrem-Web','OnPrem-SQL')
    LinuxGuests      = @('OnPrem-Linux-Web','OnPrem-Linux-App')
    WorkloadAddresses = [ordered]@{
        'onprem-web'   = '192.168.0.10'
        'onprem-sql'   = '192.168.0.11'
        'onprem-nginx' = '192.168.0.12'
        'onprem-app'   = '192.168.0.13'
    }
    SqlLogin         = 'labapp'
    IntervalSeconds  = 20
} | ConvertTo-Json -Depth 4 | Set-Content $trafficSettingsPath -Encoding UTF8
Write-Log "Traffic generator staged at $trafficScriptPath (not started)."

# =============================================================
# PHASE 7 - Prepare this host for Azure Migrate discovery
# =============================================================
# This is Module 1 section 2 applied automatically. Microsoft's table of what the
# host-preparation script does maps to four things the appliance needs, and one it does not:
#
#   WinRM service, ports 5985/5986   - the appliance pulls metadata over a CIM session.
#   PowerShell remoting              - the appliance runs PowerShell on this host over WinRM.
#   A discovery account              - must be a host administrator, or hold Remote Management
#                                      Users + Hyper-V Administrators + Performance Monitor Users.
#   Hyper-V Integration Services     - supplies each guest's OS detail and IP to the host.
#   CredSSP                          - only for guest disks on remote SMB shares. NOT used here;
#                                      these disks are local, and CredSSP relays credentials to
#                                      the host, so it is left off deliberately.
#
# Each step is applied directly and idempotently rather than by driving the interactive script,
# because a Run Command session has no console to answer prompts on. Microsoft's script is then
# run as a verifier if it can be fetched. The whole phase is best-effort: a failure is recorded
# and setup continues, because the instructor can complete Module 1 section 2 by hand.
Write-Log "PHASE 7: Preparing the host for Azure Migrate discovery..."

$hostPrep = [ordered]@{}

try {
    if ((Get-WindowsFeature -Name Hyper-V -ErrorAction Stop).InstallState -eq 'Installed') {
        $hostPrep['HyperVRole'] = 'Installed'
    } else {
        $hostPrep['HyperVRole'] = 'NOT INSTALLED'
    }
} catch { $hostPrep['HyperVRole'] = "Unchecked: $($_.Exception.Message)" }

try {
    Enable-PSRemoting -Force -SkipNetworkProfileCheck -ErrorAction Stop | Out-Null
    if ((Get-Service WinRM).Status -ne 'Running') { Start-Service WinRM }
    Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
    $hostPrep['PowerShellRemoting'] = 'Enabled'
} catch { $hostPrep['PowerShellRemoting'] = "Failed: $($_.Exception.Message)" }

# The WinRM firewall openings were already created in PHASE 1, scoped to the nested lab
# subnet. Microsoft's script opens 5985/5986 without a scope; the existing scoped rules are
# confirmed here instead so the host is not widened to the whole VNet.
try {
    $winrmRule = Get-NetFirewallRule -DisplayName 'Lab host WinRM from nested' -ErrorAction SilentlyContinue
    $hostPrep['WinRmFirewall'] = if ($winrmRule) { "Allowed from $hostLabRange only (ports 5985, 5986)" } else { 'NOT FOUND - check PHASE 1' }
} catch { $hostPrep['WinRmFirewall'] = "Unchecked: $($_.Exception.Message)" }

# The lab administrator is already a host administrator, which satisfies Microsoft's option 1.
# The three groups from option 2 are added as well where they exist, so a least-privilege
# account works too and the instructor can demonstrate either path.
try {
    $added = @()
    foreach ($group in @('Remote Management Users', 'Hyper-V Administrators', 'Performance Monitor Users')) {
        if (-not (Get-LocalGroup -Name $group -ErrorAction SilentlyContinue)) { continue }
        $already = Get-LocalGroupMember -Group $group -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -like "*\$AdminUsername" }
        if (-not $already) {
            Add-LocalGroupMember -Group $group -Member $AdminUsername -ErrorAction Stop
            $added += $group
        }
    }
    $hostPrep['DiscoveryAccount'] = if ($added.Count) { "$AdminUsername added to: $($added -join ', ')" }
                                    else { "$AdminUsername already held the required group memberships" }
} catch { $hostPrep['DiscoveryAccount'] = "Failed: $($_.Exception.Message)" }

try {
    $noIntegration = @()
    foreach ($vm in $allVMs) {
        $svc = Get-VMIntegrationService -VMName $vm -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -in @('Heartbeat', 'Key-Value Pair Exchange') -and -not $_.Enabled }
        if ($svc) { $noIntegration += $vm }
    }
    $hostPrep['IntegrationServices'] = if ($noIntegration.Count) { "Incomplete on: $($noIntegration -join ', ')" }
                                       else { 'Heartbeat and Key-Value Pair Exchange enabled on all four guests' }
} catch { $hostPrep['IntegrationServices'] = "Unchecked: $($_.Exception.Message)" }

$hostPrep['CredSSP'] = 'Not enabled (guest disks are local, not on SMB shares)'

# Microsoft's own script, run as a verifier. It is Authenticode-signed, so the signature is
# checked rather than a published hash, which changes with each release.
try {
    $prepScript = "$labRoot\MicrosoftAzureMigrate-Hyper-V.ps1"
    $curlExe = Join-Path $env:SystemRoot 'System32\curl.exe'
    & $curlExe --location --fail --silent --show-error --max-time 300 --output $prepScript 'https://aka.ms/migrate/script/hyperv'
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $prepScript)) { throw "Download failed (curl exit $LASTEXITCODE)." }
    $sig = Get-AuthenticodeSignature $prepScript
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
        throw "Signature check failed (status $($sig.Status)). The script was not run."
    }
    $hostPrep['MicrosoftScriptSha256'] = (Get-FileHash -Path $prepScript -Algorithm SHA256).Hash

    # The script is INTERACTIVE. Its answers cannot be piped in: Read-Host reads the console,
    # not the pipeline. This session has no console, so the script will either exit early or
    # block on its first prompt. It is therefore run inside a job with a hard timeout, so a
    # blocked prompt costs 5 minutes and a log line instead of hanging the deployment. Its
    # checks still print useful detail before any prompt is reached.
    # Nothing here is load-bearing: the steps above already configured the host, idempotently.
    $scriptJob = Start-Job -ScriptBlock {
        param($Path)
        try { & $Path 2>&1 | Out-String } catch { "Script raised: $($_.Exception.Message)" }
    } -ArgumentList $prepScript
    if (Wait-Job -Job $scriptJob -Timeout 300) {
        $prepOutput = (Receive-Job -Job $scriptJob) -join "`n"
        $hostPrep['MicrosoftScript'] = "Ran to completion; output in $labRoot\hyperv-prep-output.txt"
        Write-Log "Microsoft host-preparation script completed. Output saved to $labRoot\hyperv-prep-output.txt"
    } else {
        $prepOutput = ((Receive-Job -Job $scriptJob) -join "`n") +
                      "`n[stopped after 300s - the script was waiting for console input]"
        $hostPrep['MicrosoftScript'] = 'Stopped at an interactive prompt (expected; it needs a console)'
        Write-Log "Microsoft host-preparation script stopped at a prompt, as expected without a console."
        Write-Log "         The prerequisites above were applied directly, so this is not a failure."
    }
    Stop-Job -Job $scriptJob -ErrorAction SilentlyContinue
    Remove-Job -Job $scriptJob -Force -ErrorAction SilentlyContinue
    Set-Content -Path "$labRoot\hyperv-prep-output.txt" -Value $prepOutput -Encoding UTF8
} catch {
    $hostPrep['MicrosoftScript'] = "Did not run: $($_.Exception.Message)"
    Write-Log "WARNING: Microsoft's host-preparation script did not run ($($_.Exception.Message))."
    Write-Log "         The prerequisites above were applied directly, so discovery should still work."
    Write-Log "         Confirm Module 1 section 2 by hand if the appliance cannot reach this host."
}

foreach ($item in $hostPrep.GetEnumerator()) { Write-Log "  $($item.Key): $($item.Value)" }
$hostPrep | ConvertTo-Json -Depth 3 | Set-Content "$labRoot\hyperv-prep.json" -Encoding UTF8

# Collect the appliance download started in PHASE 2.
if ($applianceJob) {
    Write-Log "Waiting for the Azure Migrate appliance download to finish..."
    try {
        $applianceResult = Receive-Job -Job $applianceJob -Wait -ErrorAction Stop
        Write-Log "Appliance staging: $applianceResult"
    } catch {
        Write-Log "WARNING: the appliance download did not complete ($($_.Exception.Message))."
        Write-Log "         Module 1 section 3.3 downloads it by hand; nothing else is affected."
    } finally {
        Remove-Job -Job $applianceJob -Force -ErrorAction SilentlyContinue
    }
}

@{ CompletedUtc = (Get-Date).ToUniversalTime().ToString('o'); VMs = $allVMs; Workshop = $WorkshopTitle
   TrafficScript = $trafficScriptPath } |
    ConvertTo-Json | Set-Content "$labRoot\setup-complete.json" -Encoding UTF8
Write-Output 'LAB_WORKLOADS_READY'

} catch {
    Write-Error ('Host setup failed: ' + $_.Exception.Message) -ErrorAction Continue
    exit 1
}
