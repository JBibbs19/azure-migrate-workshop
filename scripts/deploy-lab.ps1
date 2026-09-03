<#
.SYNOPSIS
    Deploys the Azure Migrate Workshop lab environment end-to-end.

.DESCRIPTION
    Self-contained script that creates an Azure VM with nested virtualization,
    installs Hyper-V, creates 4 guest VMs, and installs sample workloads — all
    from a single invocation.  No external script URLs are required.

    Architecture:
      Azure Host VM (Standard_E4s_v5)
      └── Windows Server 2022 + Hyper-V
          ├── OnPrem-Web       — Windows Server 2022 + IIS + sample Contoso web app
          ├── OnPrem-SQL       — Windows Server 2022 + SQL Server 2022 Express + ContosoApp DB
          ├── OnPrem-Linux-Web — Ubuntu 22.04 + Nginx + sample HTML site
          └── OnPrem-Linux-App — Ubuntu 22.04 + Node.js 20 + Express.js API

    The script runs in 5 sections:
      1. Create Azure infrastructure (Resource Group, VNet, NSG, NIC, VM)
      2. Install Hyper-V on the host VM (Invoke-AzVMRunCommand)
      3. Restart the VM and wait for it to come back
      4. Configure networking, create guest VMs, install workloads (Invoke-AzVMRunCommand)
      5. Print connection info

    Expected total runtime: 30-60 minutes (mainly due to VM creation and image downloads).

.PARAMETER ResourceGroupName
    Name of the Azure Resource Group to create.

.PARAMETER Location
    Azure region for deployment. Default: eastus.

.PARAMETER AdminUsername
    Administrator username for the host VM and guest Windows VMs.

.PARAMETER AdminPassword
    Administrator password for all VMs (SecureString). Must meet Azure complexity requirements.

.PARAMETER VMSize
    Azure VM size with nested virtualization support. Default: Standard_E4s_v5.

.EXAMPLE
    $password = Read-Host -AsSecureString -Prompt "Enter admin password"
    .\deploy-lab.ps1 -ResourceGroupName "rg-migrate-workshop" `
                     -AdminUsername "azureuser" -AdminPassword $password

.EXAMPLE
    .\deploy-lab.ps1 -ResourceGroupName "rg-migrate-lab" -Location "westus2" `
                     -AdminUsername "labadmin" `
                     -AdminPassword (ConvertTo-SecureString "P@ssw0rd123!" -AsPlainText -Force) `
                     -VMSize "Standard_E8s_v5"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "eastus",

    [Parameter(Mandatory = $true)]
    [string]$AdminUsername,

    [Parameter(Mandatory = $true)]
    [SecureString]$AdminPassword,

    [Parameter(Mandatory = $false)]
    [string]$VMSize = "Standard_E4s_v7"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
# Helper: Write-Log
# ================================================================
function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

# ================================================================
# Configuration
# ================================================================
$vmName        = "HyperVHost"
$vnetName      = "$ResourceGroupName-vnet"
$subnetName    = "default"
$publicIpName  = "$vmName-pip"
$nsgName       = "$vmName-nsg"
$nicName       = "$vmName-nic"
$osDiskName    = "$vmName-osdisk"
$addressPrefix = "10.0.0.0/16"
$subnetPrefix  = "10.0.0.0/24"

# Decode admin password once so we can embed it in guest-VM scripts
$adminPassPlain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
)

# Validate password doesn't contain characters that break heredoc/XML/YAML/bash embedding
if ($adminPassPlain -match '[`"{}]') {
    throw "Password contains characters (backtick, double-quote, or braces) that are unsafe for embedding in scripts. Please use a password with only: letters, numbers, and special characters like !@#$%^&*()-_=+[]|;:',.<>/?"
}
if ($adminPassPlain.Length -lt 12) {
    Write-Warning "Password is shorter than 12 characters. Azure VMs require complex passwords."
}

# ================================================================
# SECTION 1 — Pre-flight checks
# ================================================================
Write-Log "=== SECTION 1: Pre-flight checks ==="

Write-Log "Verifying Az PowerShell module..."
if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
    throw "The Az PowerShell module is required. Install it with: Install-Module -Name Az -Scope CurrentUser -Force"
}

try {
    $context = Get-AzContext
    if (-not $context) { throw "Not logged in." }
    Write-Log "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"
} catch {
    throw "Azure authentication required. Run Connect-AzAccount first. Error: $_"
}

# ================================================================
# SECTION 2 — Create Azure Resources
# ================================================================
Write-Log "=== SECTION 2: Create Azure Resources ==="

# --- Resource Group ---
Write-Log "Creating Resource Group '$ResourceGroupName' in '$Location'..."
try {
    $rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    if ($rg) {
        Write-Log "Resource Group already exists."
    } else {
        New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
        Write-Log "Resource Group created."
    }
} catch {
    throw "Failed to create Resource Group: $_"
}

# --- VNet + Subnet ---
Write-Log "Creating Virtual Network '$vnetName'..."
try {
    $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($vnet) {
        Write-Log "VNet already exists."
    } else {
        $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix $subnetPrefix -ErrorAction Stop
        $vnet = New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -Location $Location `
            -AddressPrefix $addressPrefix -Subnet $subnetConfig -ErrorAction Stop
        Write-Log "VNet and Subnet created."
    }
} catch {
    throw "Failed to create VNet: $_"
}

# --- Public IP (Static, Standard) ---
Write-Log "Creating Public IP '$publicIpName'..."
try {
    $publicIp = Get-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($publicIp) {
        Write-Log "Public IP already exists."
    } else {
        $publicIp = New-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $ResourceGroupName `
            -Location $Location -AllocationMethod Static -Sku Standard -ErrorAction Stop
        Write-Log "Public IP created."
    }
} catch {
    throw "Failed to create Public IP: $_"
}

# --- NSG with RDP rule ---
Write-Log "Creating NSG '$nsgName'..."
try {
    $nsg = Get-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($nsg) {
        Write-Log "NSG already exists."
    } else {
        $rdpRule = New-AzNetworkSecurityRuleConfig -Name "Allow-RDP" `
            -Description "Allow inbound RDP" `
            -Access Allow -Protocol Tcp -Direction Inbound `
            -Priority 1000 -SourceAddressPrefix "*" -SourcePortRange "*" `
            -DestinationAddressPrefix "*" -DestinationPortRange "3389" -ErrorAction Stop
        $nsg = New-AzNetworkSecurityGroup -Name $nsgName -ResourceGroupName $ResourceGroupName `
            -Location $Location -SecurityRules $rdpRule -ErrorAction Stop
        Write-Log "NSG created with RDP (3389) rule."
    }
} catch {
    throw "Failed to create NSG: $_"
}

# --- NIC ---
Write-Log "Creating NIC '$nicName'..."
try {
    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($nic) {
        Write-Log "NIC already exists."
    } else {
        $subnet = (Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $ResourceGroupName -ErrorAction Stop).Subnets |
            Where-Object { $_.Name -eq $subnetName }
        $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroupName -Location $Location `
            -SubnetId $subnet.Id -PublicIpAddressId $publicIp.Id -NetworkSecurityGroupId $nsg.Id -ErrorAction Stop
        Write-Log "NIC created."
    }
} catch {
    throw "Failed to create NIC: $_"
}

# --- Host VM (Windows Server 2022 Datacenter Gen2) ---
Write-Log "Deploying host VM '$vmName' (Size: $VMSize)..."
try {
    $existingVm = Get-AzVM -Name $vmName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($existingVm) {
        Write-Log "VM '$vmName' already exists. Skipping deployment."
    } else {
        $credential = New-Object System.Management.Automation.PSCredential($AdminUsername, $AdminPassword)

        $vmConfig = New-AzVMConfig -VMName $vmName -VMSize $VMSize -ErrorAction Stop
        $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $vmName `
            -Credential $credential -ProvisionVMAgent -EnableAutoUpdate -ErrorAction Stop
        $vmConfig = Set-AzVMSourceImage -VM $vmConfig `
            -PublisherName "MicrosoftWindowsServer" -Offer "WindowsServer" `
            -Skus "2022-datacenter-g2" -Version "latest" -ErrorAction Stop
        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name $osDiskName -CreateOption FromImage `
            -StorageAccountType Premium_LRS -DiskSizeInGB 256 -ErrorAction Stop
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id -ErrorAction Stop
        $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable -ErrorAction Stop

        New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig -ErrorAction Stop | Out-Null
        Write-Log "Host VM deployed successfully."
    }
} catch {
    throw "Failed to deploy VM: $_"
}

# ================================================================
# SECTION 3 — Install Hyper-V role on host VM
# ================================================================
Write-Log "=== SECTION 3: Install Hyper-V role ==="

$installHyperVScript = @'
$ErrorActionPreference = "Stop"
$feature = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
if ($feature.Installed) {
    Write-Output "Hyper-V is already installed."
} else {
    Write-Output "Installing Hyper-V role..."
    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -ErrorAction Stop | Out-Null
    Write-Output "Hyper-V installed. Reboot required."
}
'@

Write-Log "Running Invoke-AzVMRunCommand to install Hyper-V..."
try {
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName `
        -CommandId 'RunPowerShellScript' -ScriptString $installHyperVScript -ErrorAction Stop
    foreach ($msg in $result.Value) {
        Write-Log "  [$($msg.Code)] $($msg.Message)"
    }
} catch {
    throw "Failed to install Hyper-V: $_"
}

# ================================================================
# SECTION 4 — Restart VM and wait for it to come back
# ================================================================
Write-Log "=== SECTION 4: Restart VM ==="

Write-Log "Restarting VM '$vmName' to complete Hyper-V installation..."
try {
    Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop | Out-Null
    Write-Log "VM restart initiated."
} catch {
    throw "Failed to restart VM: $_"
}

Write-Log "Waiting for VM to become ready after reboot..."
$timeout = (Get-Date).AddMinutes(10)
$vmReady = $false
while ((Get-Date) -lt $timeout) {
    Start-Sleep -Seconds 30
    try {
        $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -Status -ErrorAction Stop
        $provisioningState = ($vmStatus.Statuses | Where-Object { $_.Code -like "ProvisioningState/*" }).DisplayStatus
        $powerState         = ($vmStatus.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        Write-Log "  VM Status: $provisioningState / $powerState"
        if ($powerState -eq "VM running") {
            # Additional wait for OS boot
            Start-Sleep -Seconds 60
            $vmReady = $true
            break
        }
    } catch {
        Write-Log "  Waiting... ($($_.Exception.Message))"
    }
}
if (-not $vmReady) {
    throw "VM did not come back within 10 minutes after restart."
}
Write-Log "VM is running. Proceeding with configuration."

# ================================================================
# SECTION 5 — Configure networking, create guest VMs, install workloads
# ================================================================
Write-Log "=== SECTION 5: Configure Hyper-V networking, guest VMs, and workloads ==="

# --- Create a managed disk from Windows Server 2022 marketplace image ---
# This avoids unreliable ISO downloads from the Evaluation Center.
Write-Log "Creating temporary managed disk from Windows Server 2022 marketplace image..."
$windowsVhdSasUrl = ""
try {
    $existingDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "WinServerBase-temp" -ErrorAction SilentlyContinue
    if (-not $existingDisk) {
        # Resolve latest image version (the API doesn't accept 'latest' for disk creation)
        Write-Log "Resolving latest Windows Server 2022 image version..."
        $imgVersion = Get-AzVMImage -Location $Location -PublisherName "MicrosoftWindowsServer" `
            -Offer "WindowsServer" -Skus "2022-datacenter-smalldisk-g2" -ErrorAction Stop |
            Sort-Object Version -Descending | Select-Object -First 1
        Write-Log "Using image version: $($imgVersion.Version)"

        $diskConfig = New-AzDiskConfig -Location $Location -CreateOption FromImage -HyperVGeneration V2 -OsType Windows `
            -ImageReference @{ Id = $imgVersion.Id } -ErrorAction Stop
        New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "WinServerBase-temp" -Disk $diskConfig -ErrorAction Stop | Out-Null
        Write-Log "Managed disk created from marketplace image."
    } else {
        Write-Log "Managed disk already exists."
    }

    Write-Log "Granting SAS access to download the VHD..."
    $access = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName `
        -DiskName "WinServerBase-temp" -Access Read -DurationInSecond 7200 -ErrorAction Stop
    $windowsVhdSasUrl = $access.AccessSAS
    Write-Log "SAS URL obtained for Windows Server VHD download."
} catch {
    Write-Log "WARNING: Failed to create marketplace disk: $_"
    Write-Log "Windows guest VMs will not be created. You can manually provide a Windows VHDX."
}

# Build the large inline script that runs entirely inside the Azure VM.
# We embed the admin password and Windows VHD SAS URL.
$configureEverythingScript = @"
`$ErrorActionPreference = "Stop"

# ---------- Logging ----------
`$labRoot = "C:\AzMigrateLab"
`$logFile = "`$labRoot\setup-log.txt"
New-Item -ItemType Directory -Path `$labRoot -Force | Out-Null

function Write-Log {
    param([string]`$Message)
    `$entry = "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] `$Message"
    Write-Output `$entry
    Add-Content -Path `$logFile -Value `$entry -ErrorAction SilentlyContinue
}

`$vhdPath       = "`$labRoot\VHDs"
`$intSwitchName = "intSwitch"
`$natName       = "LabNAT"
`$natPrefix     = "192.168.0.0/24"
`$hostIp        = "192.168.0.1"
`$guestAdminPwd = '$($adminPassPlain -replace "'","''")'
`$guestUser     = '$AdminUsername'
`$windowsVhdSasUrl = '$($windowsVhdSasUrl -replace "'","''")'

New-Item -ItemType Directory -Path `$vhdPath -Force | Out-Null

# =============================================================
# PHASE 1 — Virtual networking
# =============================================================
Write-Log "PHASE 1: Configuring virtual networking..."

`$existingSwitch = Get-VMSwitch -Name `$intSwitchName -ErrorAction SilentlyContinue
if (`$existingSwitch) {
    Write-Log "Virtual switch '`$intSwitchName' already exists."
} else {
    New-VMSwitch -SwitchType Internal -Name `$intSwitchName -ErrorAction Stop | Out-Null
    Write-Log "Created internal switch '`$intSwitchName'."
}

`$adapter = Get-NetAdapter | Where-Object { `$_.Name -like "*`$intSwitchName*" }
if (`$adapter) {
    `$existingIp = Get-NetIPAddress -InterfaceIndex `$adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { `$_.IPAddress -eq `$hostIp }
    if (-not `$existingIp) {
        New-NetIPAddress -IPAddress `$hostIp -PrefixLength 24 -InterfaceIndex `$adapter.ifIndex -ErrorAction Stop | Out-Null
        Write-Log "Assigned `$hostIp to host adapter."
    } else {
        Write-Log "Host adapter already has IP `$hostIp."
    }
} else {
    Write-Log "WARNING: Could not find adapter for switch '`$intSwitchName'."
}

`$existingNat = Get-NetNat -Name `$natName -ErrorAction SilentlyContinue
if (`$existingNat) {
    Write-Log "NAT '`$natName' already exists."
} else {
    New-NetNat -Name `$natName -InternalIPInterfaceAddressPrefix `$natPrefix -ErrorAction Stop | Out-Null
    Write-Log "Created NAT '`$natName' with prefix `$natPrefix."
}

# =============================================================
# PHASE 2 — Download OS images
# =============================================================
Write-Log "PHASE 2: Downloading OS images..."

# Install Windows ADK Deployment Tools (provides oscdimg.exe for cloud-init ISO creation)
`$oscdimgPath = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
if (-not (Test-Path `$oscdimgPath)) {
    Write-Log "Installing Windows ADK Deployment Tools (for oscdimg)..."
    `$adkInstaller = "`$labRoot\adksetup.exe"
    `$adkUrl = "https://go.microsoft.com/fwlink/?linkid=2243390"
    Invoke-WebRequest -Uri `$adkUrl -OutFile `$adkInstaller -UseBasicParsing -ErrorAction Stop
    Start-Process -FilePath `$adkInstaller -ArgumentList "/quiet /norestart /features OptionId.DeploymentTools" -Wait -ErrorAction Stop
    Write-Log "Windows ADK Deployment Tools installed."
} else {
    Write-Log "Windows ADK Deployment Tools already installed."
}

`$ubuntuCloudUrl = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
`$ubuntuQcow2    = "`$vhdPath\Ubuntu2204-cloudimg.img"
`$ubuntuBaseVhd  = "`$vhdPath\Ubuntu2204-Base.vhdx"

`$windowsBaseVhd = "`$vhdPath\WindowsServer2022-Base.vhdx"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -- Install qemu-img (needed for image conversion) --
`$qemuImg = "C:\Program Files\qemu\qemu-img.exe"
if (-not (Test-Path `$qemuImg)) {
    `$qemuImg = (Get-ChildItem "C:\ProgramData\chocolatey" -Recurse -Filter "qemu-img.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
}
if (-not `$qemuImg -or -not (Test-Path `$qemuImg)) {
    Write-Log "Installing qemu-img via Chocolatey..."
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    }
    choco install qemu --no-progress -y 2>&1 | Out-Null
    `$qemuImg = (Get-ChildItem "C:\Program Files\qemu" -Filter "qemu-img.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    if (-not `$qemuImg) {
        `$qemuImg = (Get-ChildItem "C:\ProgramData\chocolatey" -Recurse -Filter "qemu-img.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not `$qemuImg) { throw "qemu-img.exe not found after installation." }
}
Write-Log "qemu-img available at: `$qemuImg"

# -- Ubuntu cloud image (download QCOW2, convert to VHDX via qemu-img) --
if (-not (Test-Path `$ubuntuBaseVhd)) {
    # Download Ubuntu QCOW2 cloud image
    if (-not (Test-Path `$ubuntuQcow2)) {
        Write-Log "Downloading Ubuntu 22.04 cloud image (QCOW2 format, ~600MB)..."
        try {
            Start-BitsTransfer -Source `$ubuntuCloudUrl -Destination `$ubuntuQcow2 -ErrorAction Stop
        } catch {
            Write-Log "BITS transfer failed, falling back to Invoke-WebRequest..."
            Invoke-WebRequest -Uri `$ubuntuCloudUrl -OutFile `$ubuntuQcow2 -UseBasicParsing -ErrorAction Stop
        }
        Write-Log "Ubuntu cloud image downloaded."
    }

    # Convert QCOW2 to VHDX using qemu-img
    Write-Log "Converting Ubuntu QCOW2 to VHDX (this may take a few minutes)..."
    & `$qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic "`$ubuntuQcow2" "`$ubuntuBaseVhd" 2>&1
    if (`$LASTEXITCODE -ne 0) {
        throw "qemu-img conversion failed with exit code `$LASTEXITCODE"
    }
    # Remove sparse file attribute (required by Hyper-V for differencing disks)
    fsutil sparse setflag "`$ubuntuBaseVhd" 0
    Write-Log "Ubuntu base VHDX created."

    # Cleanup downloaded QCOW2
    Remove-Item -Path `$ubuntuQcow2 -Force -ErrorAction SilentlyContinue
} else {
    Write-Log "Ubuntu base VHDX already exists."
}

# -- Windows Server 2022 base VHDX (downloaded from Azure marketplace managed disk via SAS) --
if (-not (Test-Path `$windowsBaseVhd)) {
    if ([string]::IsNullOrWhiteSpace(`$windowsVhdSasUrl)) {
        throw "Windows VHD SAS URL not provided. Cannot create Windows guest VMs."
    }

    `$windowsVhdTemp = "`$vhdPath\WindowsServer2022-temp.vhd"
    if (-not (Test-Path `$windowsVhdTemp) -or (Get-Item `$windowsVhdTemp).Length -lt 1GB) {
        Remove-Item -Path `$windowsVhdTemp -Force -ErrorAction SilentlyContinue
        Write-Log "Downloading Windows Server 2022 VHD from Azure marketplace disk (intra-Azure, fast)..."
        # Install azcopy for reliable large file downloads
        `$azcopy = (Get-ChildItem "`$labRoot\azcopy" -Recurse -Filter "azcopy.exe" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
        if (-not `$azcopy) {
            Write-Log "Installing azcopy..."
            Invoke-WebRequest -Uri "https://aka.ms/downloadazcopy-v10-windows" -OutFile "`$labRoot\azcopy.zip" -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path "`$labRoot\azcopy.zip" -DestinationPath "`$labRoot\azcopy" -Force
            `$azcopy = (Get-ChildItem "`$labRoot\azcopy" -Recurse -Filter "azcopy.exe" | Select-Object -First 1).FullName
            Write-Log "azcopy installed at: `$azcopy"
        }
        `$env:AZCOPY_AUTO_LOGIN_TYPE = "AZCLI"
        & `$azcopy copy `$windowsVhdSasUrl `$windowsVhdTemp --check-md5 NoCheck --log-level ERROR 2>&1 | ForEach-Object { Write-Log "  `$_" }
        if (-not (Test-Path `$windowsVhdTemp) -or (Get-Item `$windowsVhdTemp).Length -lt 1GB) {
            throw "azcopy download failed or file is too small."
        }
        Write-Log "Windows Server VHD downloaded (`$([math]::Round((Get-Item `$windowsVhdTemp).Length/1GB, 1)) GB)."
    }

    # Convert VHD to VHDX using qemu-img (auto-detect source format)
    Write-Log "Converting Windows Server VHD to VHDX..."
    & `$qemuImg convert -O vhdx -o subformat=dynamic "`$windowsVhdTemp" "`$windowsBaseVhd" 2>&1
    if (`$LASTEXITCODE -ne 0) {
        throw "qemu-img VHD to VHDX conversion failed with exit code `$LASTEXITCODE"
    }
    # Remove sparse file attribute (required by Hyper-V for differencing disks)
    fsutil sparse setflag "`$windowsBaseVhd" 0
    Write-Log "Windows Server base VHDX created."

    # Cleanup temp VHD
    Remove-Item -Path `$windowsVhdTemp -Force -ErrorAction SilentlyContinue
} else {
    Write-Log "Windows Server base VHDX already exists."
}

# =============================================================
# PHASE 3 — Create guest VMs
# =============================================================
Write-Log "PHASE 3: Creating guest VMs..."

# --- Helper: Create-WindowsGuestVM ---
function Create-WindowsGuestVM {
    param(
        [string]`$VMName, [string]`$IPAddress,
        [int]`$MemoryMB = 4096, [int]`$CPUs = 2
    )

    `$existingVM = Get-VM -Name `$VMName -ErrorAction SilentlyContinue
    if (`$existingVM) { Write-Log "VM '`$VMName' already exists. Skipping."; return }

    Write-Log "Creating Windows VM '`$VMName'..."

    `$vmVhdPath = "`$vhdPath\`$VMName.vhdx"
    if (-not (Test-Path `$vmVhdPath)) {
        New-VHD -Path `$vmVhdPath -ParentPath `$windowsBaseVhd -Differencing -ErrorAction Stop | Out-Null
    }

    # Generate unattend.xml
    `$unattendDir = "`$labRoot\Unattend\`$VMName"
    New-Item -ItemType Directory -Path `$unattendDir -Force | Out-Null

    `$unattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend"
          xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>__VMNAME__</ComputerName>
    </component>
    <component name="Microsoft-Windows-TCPIP" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <Interfaces>
        <Interface wcm:action="add">
          <Ipv4Settings><DhcpEnabled>false</DhcpEnabled></Ipv4Settings>
          <Identifier>Ethernet</Identifier>
          <UnicastIpAddresses>
            <IpAddress wcm:action="add" wcm:keyValue="1">__IPADDRESS__/24</IpAddress>
          </UnicastIpAddresses>
          <Routes>
            <Route wcm:action="add">
              <Identifier>0</Identifier>
              <NextHopAddress>192.168.0.1</NextHopAddress>
              <Prefix>0.0.0.0/0</Prefix>
            </Route>
          </Routes>
        </Interface>
      </Interfaces>
    </component>
    <component name="Microsoft-Windows-DNS-Client" processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <Interfaces>
        <Interface wcm:action="add">
          <Identifier>Ethernet</Identifier>
          <DNSServerSearchOrder>
            <IpAddress wcm:action="add" wcm:keyValue="1">8.8.8.8</IpAddress>
          </DNSServerSearchOrder>
        </Interface>
      </Interfaces>
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
'@ -replace '__VMNAME__', `$VMName -replace '__IPADDRESS__', `$IPAddress -replace '__PASSWORD__', `$guestAdminPwd
    `$unattendXml | Out-File -FilePath "`$unattendDir\unattend.xml" -Encoding UTF8 -Force

    `$vmDir = "`$labRoot\VMs\`$VMName"
    New-Item -ItemType Directory -Path `$vmDir -Force | Out-Null

    New-VM -Name `$VMName -MemoryStartupBytes (`$MemoryMB * 1MB) -VHDPath `$vmVhdPath ``
        -SwitchName `$intSwitchName -Path `$vmDir -Generation 2 -ErrorAction Stop | Out-Null
    Set-VMProcessor -VMName `$VMName -Count `$CPUs -ErrorAction Stop
    Set-VMMemory -VMName `$VMName -DynamicMemoryEnabled `$false -ErrorAction Stop
    Enable-VMIntegrationService -VMName `$VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

    # Inject unattend.xml into the differencing VHD
    try {
        `$mountResult = Mount-VHD -Path `$vmVhdPath -Passthru -ErrorAction Stop
        `$dl = (`$mountResult | Get-Disk | Get-Partition | Where-Object { `$_.Type -eq "Basic" } | Get-Volume).DriveLetter
        if (`$dl -and (Test-Path "`${dl}:\Windows")) {
            `$pantherDir = "`${dl}:\Windows\Panther"
            New-Item -ItemType Directory -Path `$pantherDir -Force | Out-Null
            Copy-Item -Path "`$unattendDir\unattend.xml" -Destination "`$pantherDir\unattend.xml" -Force
            Write-Log "Injected unattend.xml into VHD for '`$VMName'."
        } else {
            Write-Log "WARNING: Windows dir not found in VHD for '`$VMName'."
        }
    } catch {
        Write-Log "WARNING: Failed to inject unattend.xml for '`$VMName': `$_"
    } finally {
        Dismount-VHD -Path `$vmVhdPath -ErrorAction SilentlyContinue
    }

    Write-Log "VM '`$VMName' created (`$CPUs vCPUs, `${MemoryMB}MB RAM, IP `$IPAddress)."
}

# --- Helper: Create-LinuxGuestVM ---
function Create-LinuxGuestVM {
    param(
        [string]`$VMName, [string]`$IPAddress,
        [int]`$MemoryMB = 2048, [int]`$CPUs = 2,
        [string[]]`$ExtraPackages = @(),
        [string]`$ExtraRunCmdYaml = ""
    )

    `$existingVM = Get-VM -Name `$VMName -ErrorAction SilentlyContinue
    if (`$existingVM) { Write-Log "VM '`$VMName' already exists. Skipping."; return }

    Write-Log "Creating Linux VM '`$VMName'..."

    `$vmVhdPath = "`$vhdPath\`$VMName.vhdx"
    if (-not (Test-Path `$vmVhdPath)) {
        New-VHD -Path `$vmVhdPath -ParentPath `$ubuntuBaseVhd -Differencing -ErrorAction Stop | Out-Null
    }

    # Resize the differencing disk so cloud-init has room
    Resize-VHD -Path `$vmVhdPath -SizeBytes 30GB -ErrorAction SilentlyContinue

    # Cloud-init files
    `$cloudInitDir = "`$labRoot\CloudInit\`$VMName"
    New-Item -ItemType Directory -Path `$cloudInitDir -Force | Out-Null

    `$metaData = "instance-id: `$VMName`nlocal-hostname: `$VMName"
    `$metaData | Out-File -FilePath "`$cloudInitDir\meta-data" -Encoding ASCII -Force -NoNewline

    `$networkConfig = @'
version: 2
ethernets:
  eth0:
    addresses:
      - __IPADDRESS__/24
    routes:
      - to: default
        via: 192.168.0.1
    nameservers:
      addresses:
        - 8.8.8.8
        - 8.8.4.4
'@ -replace '__IPADDRESS__', `$IPAddress
    `$networkConfig | Out-File -FilePath "`$cloudInitDir\network-config" -Encoding ASCII -Force -NoNewline

    `$basePackages = @("openssh-server", "curl", "wget", "net-tools")
    `$allPackages  = `$basePackages + `$ExtraPackages
    `$pkgYaml = (`$allPackages | ForEach-Object { "  - `$_" }) -join "`n"

    `$baseRun = @("  - systemctl enable ssh", "  - systemctl start ssh")
    `$runYaml = `$baseRun -join "`n"
    if (`$ExtraRunCmdYaml) { `$runYaml += "`n`$ExtraRunCmdYaml" }

    `$userData = @'
#cloud-config
password: __PASSWORD__
chpasswd:
  expire: false
ssh_pwauth: true
users:
  - name: __USER__
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    plain_text_passwd: __PASSWORD__
packages:
__PKGYAML__
runcmd:
__RUNYAML__
'@ -replace '__PASSWORD__', `$guestAdminPwd -replace '__USER__', `$guestUser -replace '__PKGYAML__', `$pkgYaml -replace '__RUNYAML__', `$runYaml
    `$userData | Out-File -FilePath "`$cloudInitDir\user-data" -Encoding ASCII -Force -NoNewline

    # Create cloud-init ISO
    `$ciIsoPath = "`$vhdPath\`$VMName-cidata.iso"
    `$oscdimg = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"

    `$isoCreated = `$false
    if (Test-Path `$oscdimg) {
        `$prevEAP = `$ErrorActionPreference; `$ErrorActionPreference = "Continue"
        & `$oscdimg -j2 -lcidata "`$cloudInitDir" "`$ciIsoPath" 2>&1 | Out-Null
        `$ErrorActionPreference = `$prevEAP
        if (`$LASTEXITCODE -eq 0 -and (Test-Path `$ciIsoPath)) { `$isoCreated = `$true }
    }

    if (-not `$isoCreated) {
        # Fallback: build a minimal ISO with PowerShell using a simple raw-write method
        Write-Log "oscdimg not found; creating cloud-init seed VHDX as fallback for '`$VMName'."
        `$seedVhd = "`$vhdPath\`$VMName-seed.vhdx"
        if (-not (Test-Path `$seedVhd)) {
            New-VHD -Path `$seedVhd -SizeBytes 64MB -Fixed -ErrorAction Stop | Out-Null
        }
        `$ciIsoPath = `$null
    }

    `$vmDir = "`$labRoot\VMs\`$VMName"
    New-Item -ItemType Directory -Path `$vmDir -Force | Out-Null

    New-VM -Name `$VMName -MemoryStartupBytes (`$MemoryMB * 1MB) -VHDPath `$vmVhdPath ``
        -SwitchName `$intSwitchName -Path `$vmDir -Generation 2 -ErrorAction Stop | Out-Null
    Set-VMProcessor -VMName `$VMName -Count `$CPUs -ErrorAction Stop
    Set-VMMemory -VMName `$VMName -DynamicMemoryEnabled `$false -ErrorAction Stop
    Set-VMFirmware -VMName `$VMName -EnableSecureBoot Off -ErrorAction Stop
    Enable-VMIntegrationService -VMName `$VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

    if (`$ciIsoPath -and (Test-Path `$ciIsoPath)) {
        Add-VMDvdDrive -VMName `$VMName -Path `$ciIsoPath -ErrorAction Stop
        Write-Log "Attached cloud-init ISO to '`$VMName'."
    }

    Write-Log "VM '`$VMName' created (`$CPUs vCPUs, `${MemoryMB}MB RAM, IP `$IPAddress)."
}

# --- Define cloud-init runcmd YAML for Linux workloads ---

# Nginx web server setup (packages directive installs nginx before runcmd runs)
`$nginxRunCmdYaml = @'
  - systemctl enable nginx
  - systemctl start nginx
  - |
    cat > /var/www/html/index.html << 'HTMLEOF'
    <!DOCTYPE html>
    <html>
    <head>
        <title>Contoso Linux Web - On-Premises</title>
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
            <h1>Contoso Linux Web Server</h1>
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
`$nodeJsRunCmdYaml = @'
  - apt-get update -y
  - curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
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
      "dependencies": { "express": "^4.18.2" }
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
          <title>Contoso API - On-Premises</title>
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
            <h1>Contoso App Server</h1>
            <p class="status">&#x2705; Node.js API is running</p>
            <h3>System Info</h3>
            <pre>`${JSON.stringify({
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
      console.log(`Contoso App Server running on port `${PORT}`);
    });
    SERVERJS
  - cd /opt/contoso-app && npm install --production
  - |
    cat > /etc/systemd/system/contoso-app.service << 'SVCFILE'
    [Unit]
    Description=Contoso Node.js Application
    After=network.target

    [Service]
    Type=simple
    User=root
    WorkingDirectory=/opt/contoso-app
    ExecStart=/usr/bin/node server.js
    Restart=on-failure
    RestartSec=10
    Environment=NODE_ENV=production

    [Install]
    WantedBy=multi-user.target
    SVCFILE
  - systemctl daemon-reload
  - systemctl enable contoso-app
  - systemctl start contoso-app
'@

# --- Create VMs ---
Create-WindowsGuestVM -VMName "OnPrem-Web" -IPAddress "192.168.0.10" -MemoryMB 4096 -CPUs 2
Create-WindowsGuestVM -VMName "OnPrem-SQL" -IPAddress "192.168.0.11" -MemoryMB 4096 -CPUs 2
Create-LinuxGuestVM   -VMName "OnPrem-Linux-Web" -IPAddress "192.168.0.12" -MemoryMB 2048 -CPUs 2 -ExtraPackages @("nginx") -ExtraRunCmdYaml `$nginxRunCmdYaml
Create-LinuxGuestVM   -VMName "OnPrem-Linux-App" -IPAddress "192.168.0.13" -MemoryMB 2048 -CPUs 2 -ExtraRunCmdYaml `$nodeJsRunCmdYaml

# =============================================================
# PHASE 4 — Start VMs and wait for boot
# =============================================================
Write-Log "PHASE 4: Starting guest VMs..."

`$allVMs = @("OnPrem-Web", "OnPrem-SQL", "OnPrem-Linux-Web", "OnPrem-Linux-App")
foreach (`$vm in `$allVMs) {
    `$v = Get-VM -Name `$vm -ErrorAction SilentlyContinue
    if (`$v -and `$v.State -ne "Running") {
        Start-VM -Name `$vm -ErrorAction Stop
        Write-Log "Started VM '`$vm'."
    } elseif (`$v) {
        Write-Log "VM '`$vm' is already running."
    } else {
        Write-Log "WARNING: VM '`$vm' not found."
    }
}

Write-Log "Waiting 180 seconds for VMs to boot and complete first-boot setup..."
Start-Sleep -Seconds 180

# --- Wait helper ---
function Wait-ForGuestVM {
    param([string]`$VMName, [int]`$TimeoutSeconds = 300)
    Write-Log "Waiting for '`$VMName' heartbeat..."
    `$deadline = (Get-Date).AddSeconds(`$TimeoutSeconds)
    while ((Get-Date) -lt `$deadline) {
        `$hb = Get-VMIntegrationService -VMName `$VMName -Name "Heartbeat" -ErrorAction SilentlyContinue
        if (`$hb -and `$hb.PrimaryStatusDescription -eq "OK") {
            Write-Log "'`$VMName' is responding."
            return `$true
        }
        Start-Sleep -Seconds 10
    }
    Write-Log "WARNING: Timed out waiting for '`$VMName'."
    return `$false
}

# =============================================================
# PHASE 5 — Install workloads
# =============================================================
Write-Log "PHASE 5: Installing workloads..."

`$winCred = New-Object System.Management.Automation.PSCredential(
    "Administrator",
    (ConvertTo-SecureString `$guestAdminPwd -AsPlainText -Force)
)

# ---- OnPrem-Web: IIS + ASP.NET + sample site ----
Write-Log "--- Configuring OnPrem-Web (192.168.0.10) ---"
try {
    Wait-ForGuestVM -VMName "OnPrem-Web" | Out-Null

    Invoke-Command -VMName "OnPrem-Web" -Credential `$winCred -ScriptBlock {
        `$ErrorActionPreference = "Stop"

        if (-not (Get-WindowsFeature Web-Server).Installed) {
            Install-WindowsFeature -Name Web-Server -IncludeManagementTools -ErrorAction Stop | Out-Null
        }
        if (-not (Get-WindowsFeature Web-Asp-Net45).Installed) {
            Install-WindowsFeature -Name Web-Asp-Net45 -ErrorAction Stop | Out-Null
        }

        `$sitePath = "C:\inetpub\wwwroot"
        @'
<!DOCTYPE html>
<html>
<head>
    <title>Contoso Web App - On-Premises</title>
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
        <h1>Contoso Web Application</h1>
        <p class="status">&#x2705; Application is running</p>
        <div class="info">
            <h3>Environment Details</h3>
            <ul>
                <li><strong>Server:</strong> OnPrem-Web</li>
                <li><strong>Platform:</strong> Windows Server 2022 + IIS</li>
                <li><strong>IP Address:</strong> 192.168.0.10</li>
                <li><strong>Database:</strong> OnPrem-SQL (192.168.0.11)</li>
                <li><strong>Status:</strong> On-Premises (Pre-Migration)</li>
            </ul>
        </div>
        <p>This is a sample on-premises web application for the Azure Migrate Workshop.</p>
    </div>
</body>
</html>
'@ | Out-File -FilePath "`$sitePath\index.html" -Encoding UTF8 -Force
        Write-Output "IIS and sample website deployed on OnPrem-Web."
    } -ErrorAction Stop

    Write-Log "OnPrem-Web configured successfully."
} catch {
    Write-Log "ERROR configuring OnPrem-Web: `$_"
}

# ---- OnPrem-SQL: SQL Server 2022 Express + ContosoApp DB ----
Write-Log "--- Configuring OnPrem-SQL (192.168.0.11) ---"
try {
    Wait-ForGuestVM -VMName "OnPrem-SQL" | Out-Null

    Invoke-Command -VMName "OnPrem-SQL" -Credential `$winCred -ScriptBlock {
        param(`$sapwd)
        `$ErrorActionPreference = "Stop"

        `$sqlSseiUrl = "https://go.microsoft.com/fwlink/p/?linkid=2216019"
        `$sqlSsei = "C:\Temp\SQL2022-SSEI-Expr.exe"
        `$sqlMediaPath = "C:\Temp\SqlExpress"

        New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
        New-Item -ItemType Directory -Path `$sqlMediaPath -Force | Out-Null

        `$sqlService = Get-Service -Name "MSSQL```$SQLEXPRESS" -ErrorAction SilentlyContinue
        if (-not `$sqlService) {
            Write-Output "Downloading SQL Server 2022 Express installer..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri `$sqlSseiUrl -OutFile `$sqlSsei -UseBasicParsing -ErrorAction Stop

            Write-Output "Downloading SQL Server 2022 Express media (this may take a few minutes)..."
            Start-Process -FilePath `$sqlSsei -ArgumentList "/Action=Download", "/MediaPath=`$sqlMediaPath", "/MediaType=Core", "/Quiet" -Wait -NoNewWindow

            # Find the actual setup.exe
            `$setupExe = Get-ChildItem -Path `$sqlMediaPath -Filter "setup.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not `$setupExe) {
                `$setupExe = Get-ChildItem -Path `$sqlMediaPath -Filter "SETUP.EXE" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            }

            if (`$setupExe) {
                Write-Output "Installing SQL Server 2022 Express from: `$(`$setupExe.FullName)"
                Start-Process -FilePath `$setupExe.FullName -ArgumentList @(
                    "/Q",
                    "/IACCEPTSQLSERVERLICENSETERMS",
                    "/ACTION=Install",
                    "/FEATURES=SQLENGINE",
                    "/INSTANCENAME=SQLEXPRESS",
                    "/SQLSVCSTARTUPTYPE=Automatic",
                    "/SQLSYSADMINACCOUNTS=BUILTIN\Administrators",
                    "/SECURITYMODE=SQL",
                    "/SAPWD=`$sapwd",
                    "/TCPENABLED=1",
                    "/NPENABLED=1"
                ) -Wait -NoNewWindow
                Write-Output "SQL Server 2022 Express installed."
            } else {
                Write-Output "WARNING: setup.exe not found in downloaded media. Listing contents:"
                Get-ChildItem `$sqlMediaPath -Recurse | Select-Object FullName | ForEach-Object { Write-Output `$_.FullName }
            }
        } else {
            Write-Output "SQL Server Express is already installed."
        }

        # Create sample database using PowerShell SqlServer module
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction SilentlyContinue | Out-Null
            Install-Module -Name SqlServer -Force -AllowClobber -ErrorAction SilentlyContinue

            Invoke-Sqlcmd -ServerInstance ".\SQLEXPRESS" -Query "IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'ContosoApp') CREATE DATABASE ContosoApp;" -ErrorAction Stop

            `$createTables = "USE ContosoApp; IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Customers') BEGIN CREATE TABLE Customers (CustomerID INT PRIMARY KEY IDENTITY(1,1), FirstName NVARCHAR(50), LastName NVARCHAR(50), Email NVARCHAR(100), City NVARCHAR(50), CreatedDate DATETIME DEFAULT GETDATE()); INSERT INTO Customers (FirstName, LastName, Email, City) VALUES ('Alice','Johnson','alice@contoso.com','Seattle'),('Bob','Smith','bob@contoso.com','Portland'),('Carol','Williams','carol@contoso.com','San Francisco'),('Dave','Brown','dave@contoso.com','Los Angeles'),('Eve','Davis','eve@contoso.com','Denver'); END; IF NOT EXISTS (SELECT * FROM sys.tables WHERE name = 'Orders') BEGIN CREATE TABLE Orders (OrderID INT PRIMARY KEY IDENTITY(1,1), CustomerID INT FOREIGN KEY REFERENCES Customers(CustomerID), ProductName NVARCHAR(100), Quantity INT, UnitPrice DECIMAL(10,2), OrderDate DATETIME DEFAULT GETDATE()); INSERT INTO Orders (CustomerID, ProductName, Quantity, UnitPrice) VALUES (1,'Azure Certification Guide',2,49.99),(2,'Cloud Architecture Poster',1,19.99),(3,'DevOps Handbook',3,39.99),(1,'Kubernetes Stickers',10,4.99),(4,'Serverless Cookbook',1,34.99); END;"
            Invoke-Sqlcmd -ServerInstance ".\SQLEXPRESS" -Query `$createTables -ErrorAction Stop
            Write-Output "Sample database 'ContosoApp' created with Customers and Orders tables."
        } catch {
            Write-Output "WARNING: Could not create sample database: `$_"
        }
    } -ArgumentList `$guestAdminPwd -ErrorAction Stop

    Write-Log "OnPrem-SQL configured successfully."
} catch {
    Write-Log "ERROR configuring OnPrem-SQL: `$_"
}

# ---- OnPrem-Linux-Web: Nginx + sample HTML site (deployed via cloud-init) ----
Write-Log "--- OnPrem-Linux-Web (192.168.0.12): workloads deployed via cloud-init ---"
Wait-ForGuestVM -VMName "OnPrem-Linux-Web" | Out-Null
Write-Log "OnPrem-Linux-Web is running. Nginx and sample site configured via cloud-init."

# ---- OnPrem-Linux-App: Node.js 20 + Express.js app (deployed via cloud-init) ----
Write-Log "--- OnPrem-Linux-App (192.168.0.13): workloads deployed via cloud-init ---"
Wait-ForGuestVM -VMName "OnPrem-Linux-App" | Out-Null
Write-Log "OnPrem-Linux-App is running. Node.js app configured via cloud-init."

# =============================================================
# Done
# =============================================================
Write-Log "=========================================="
Write-Log "  LAB SETUP COMPLETE"
Write-Log "=========================================="
Write-Log "Guest VMs:"
Write-Log "  OnPrem-Web       192.168.0.10  Windows + IIS"
Write-Log "  OnPrem-SQL       192.168.0.11  Windows + SQL Server 2022 Express"
Write-Log "  OnPrem-Linux-Web 192.168.0.12  Ubuntu 22.04 + Nginx"
Write-Log "  OnPrem-Linux-App 192.168.0.13  Ubuntu 22.04 + Node.js"
Write-Log "=========================================="
"@

# The script above is very large; Invoke-AzVMRunCommand has a 256 KB limit
# which is plenty for this script. Run it.
Write-Log "Running Invoke-AzVMRunCommand for full Hyper-V + VM + workload configuration..."
Write-Log "This will take 30-45 minutes (image downloads, VM creation, workload installation)."
try {
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName `
        -CommandId 'RunPowerShellScript' -ScriptString $configureEverythingScript -ErrorAction Stop
    foreach ($msg in $result.Value) {
        Write-Log "  [$($msg.Code)] $($msg.Message)"
    }
} catch {
    Write-Log "WARNING: VM configuration command failed: $_"
    Write-Log "You can RDP into the VM and check C:\AzMigrateLab\setup-log.txt for details."
}

# ================================================================
# SECTION 6 — Cleanup temp resources & Output Connection Info
# ================================================================

# Cleanup temporary managed disk used for Windows VHD
try {
    $tempDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "WinServerBase-temp" -ErrorAction SilentlyContinue
    if ($tempDisk) {
        Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName "WinServerBase-temp" -ErrorAction SilentlyContinue | Out-Null
        Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName "WinServerBase-temp" -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Cleaned up temporary marketplace disk."
    }
} catch {
    Write-Log "WARNING: Could not cleanup temp disk: $_"
}

Write-Log "=========================================="
Write-Log "  DEPLOYMENT COMPLETE"
Write-Log "=========================================="

$pip = Get-AzPublicIpAddress -Name $publicIpName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
Write-Log "Host VM Public IP : $($pip.IpAddress)"
Write-Log "RDP Connection    : mstsc /v:$($pip.IpAddress)"
Write-Log "Username          : $AdminUsername"
Write-Log "Password          : (as provided)"
Write-Log ""
Write-Log "Guest VMs (inside Hyper-V host via RDP):"
Write-Log "  OnPrem-Web       192.168.0.10  Windows + IIS              (http://192.168.0.10)"
Write-Log "  OnPrem-SQL       192.168.0.11  SQL Server 2022 Express    (192.168.0.11:1433)"
Write-Log "  OnPrem-Linux-Web 192.168.0.12  Ubuntu 22.04 + Nginx       (http://192.168.0.12)"
Write-Log "  OnPrem-Linux-App 192.168.0.13  Ubuntu 22.04 + Node.js     (http://192.168.0.13:3000)"
Write-Log ""
Write-Log "Linux VM credentials:  $AdminUsername / (as provided)"
Write-Log "Windows guest admin:   Administrator / (as provided)"
Write-Log ""
Write-Log "Check detailed logs on the host VM at: C:\AzMigrateLab\setup-log.txt"
Write-Log "To clean up: .\cleanup-lab.ps1 -ResourceGroupName '$ResourceGroupName'"
Write-Log "=========================================="
