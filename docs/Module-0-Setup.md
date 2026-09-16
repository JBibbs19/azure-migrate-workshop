# Module 0 · Setup

**TD SYNNEX | Cloud Enablement Services**

Prepare and verify the environment before participants start discovery. Run Azure commands on your workstation or in PowerShell Cloud Shell. Run Hyper-V commands in an elevated Windows PowerShell session **inside HyperVHost**.

Instructors can use the [rehearsal launcher](Automated-Rehearsal.md) from a persistent Windows workstation to execute scripted stages and record the interactive checkpoints in order. Learners can follow this module manually.

## 1. Instructor prerequisites

Use a dedicated training subscription or approved training resource groups. Confirm Contributor access for deployment; subscription provider registration and any role assignments require the corresponding permissions. Azure Policy must allow the selected VM size, Standard security, disk export and the outbound download destinations. Select an available region and verify quota; capacity and quota are different constraints.

| Item | Workshop setting |
|---|---|
| Host | Windows Server 2022 Datacenter Gen2, `Standard_E8s_v7` (8 vCPU, 64 GB), 512 GB OS disk plus a 128 GB appliance staging data disk |
| Alternative host | A region-available x64 size with at least 8 enabled vCPUs, 64 GiB RAM, Gen2 and Premium SSD support; confirm nested virtualization for its series |
| Host security | Explicit `Standard` for this nested lab; do not blindly change security on existing VMs |
| Windows guests | `OnPrem-Web`, `OnPrem-SQL`; 2 vCPU, 4 GB RAM, 40 GB disk each |
| Linux guests | Ubuntu 22.04; 2 vCPU, 2 GB RAM, 30 GB disk each |
| Appliance staging volume | Host data disk formatted as `L:` (`ApplianceStaging`) with `L:\Appliance`; deployment fails unless at least 30 GB is free for the Azure Migrate appliance VHD |
| Appliance VM | Not created by deployment. Module 1 imports Microsoft's appliance VHD as `MigrateAppl`; plan 8 vCPU, 16 GB RAM at `192.168.0.20` |
| Network | Host VNet `10.0.0.0/16`; nested `192.168.0.0/24`; host gateway `.1` |
| Guest addresses | DHCP reservations: web `.10`, SQL `.11`, Nginx `.12`, Node `.13`, appliance `.20` |
| Targets | Separate target `10.1.0.0/16` and test `10.2.0.0/16` VNets; no peering |

Nested vCPU allocation is oversubscribed; the appliance can have eight virtual processors because the host has eight. Deployment assigns only 12 GB of guest memory across the four workloads, so the host's 64 GB keeps the appliance's 16 GB free for the Module 1 import alongside Windows. Appliance capacity is reserved, not pre-created: sizing is confirmed when the VHD is imported. [Hyper-V appliance sizing](https://learn.microsoft.com/azure/migrate/deploy-appliance-script)

Set `VMSize` in `rehearsal.local.json`, or pass `-VMSize` to `deploy-lab.ps1`. The selected size is checked against the subscription's regional SKU metadata and both family and regional vCPU quotas. Errors identify the selected size and the unmet requirement; the scripts do not silently substitute another size. For example, `Standard_E16s_v7` meets the CPU/RAM requirements while `Standard_E4s_v7` has only 32 GiB RAM. Neither example guarantees availability in your subscription. [Esv7 specifications](https://learn.microsoft.com/azure/virtual-machines/sizes/memory-optimized/esv7-series)

Confirm **Nested Virtualization: Supported** in Microsoft's documentation for the selected series and record that source in the instructor environment checkpoint. Hardware/availability metadata checks alone do not establish nested virtualization support or guarantee allocation capacity. See the default [Esv7 specifications](https://learn.microsoft.com/azure/virtual-machines/sizes/memory-optimized/esv7-series) and [nested virtualization setup](https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/nested-virtualization). Esv7 is a Generation 2 only series whose sizes require an OS image with NVMe support; the workshop's `2022-datacenter-g2` host image meets both conditions. Reserve quota for four simultaneous test VMs and, later, four migrated VMs separately from the host.

New deployments use publisher `MicrosoftWindowsServer`, offer `windowsserver2022`, with `2022-datacenter-g2` for the host and `2022-datacenter-smalldisk-g2` for the nested Windows base disk. Both images are resolved and checked as Windows x64 Gen2 before any resource group is created. Deployment uses those exact resolved versions and prints them for the rehearsal record. Microsoft directs users from the older `WindowsServer` offer to this replacement. [Windows Server image announcement](https://techcommunity.microsoft.com/blog/azurecompute/breaking-change-for-window-server-2022-image-users-with-net-6/4262423)

Image catalog requests explicitly use Compute API `2025-04-01`, independently of the installed Az.Compute SDK's default. The temporary base disk explicitly selects **Standard** security before creation, which avoids the disk cmdlet's automatic Trusted Launch image lookup and prepares the disk for export to the nested Hyper-V guests. Its configuration is checked before source resources are created. See Microsoft's [image catalog API](https://learn.microsoft.com/rest/api/compute/virtual-machine-images/get?view=rest-compute-2025-04-01) and [Standard disk security example](https://learn.microsoft.com/powershell/module/az.compute/set-azdisksecurityprofile#example-3-set-the-securitytype-to-standard-to-avoid-trustedlaunch-defaulting).

## 2. Install tools and select the subscription

Install current PowerShell and Az modules from the official distribution. This repository was parsed locally with PowerShell 7; the remote host scripts target Windows PowerShell 5.1. The live rehearsal must record the actual Az versions used.

```powershell
Install-Module Az -Scope CurrentUser -Repository PSGallery
Connect-AzAccount
$subscriptionId = Read-Host 'Workshop subscription ID'
Set-AzContext -SubscriptionId $subscriptionId
Get-AzContext | Select-Object Account,Subscription,Tenant

$providers = @('Microsoft.Compute','Microsoft.Network','Microsoft.Storage',
    'Microsoft.Migrate','Microsoft.OffAzure','Microsoft.RecoveryServices','Microsoft.KeyVault')
foreach ($provider in $providers) {
    Register-AzResourceProvider -ProviderNamespace $provider
}
# Wait until all required providers report Registered before deployment.
foreach ($provider in $providers) {
    Get-AzResourceProvider -ProviderNamespace $provider |
        Select-Object ProviderNamespace,RegistrationState -Unique
}
Get-AzVMUsage -Location eastus | Select-Object Name,CurrentValue,Limit
```

## 3. Review downloads and costs

Setup retrieves a Windows Server marketplace disk, an Ubuntu cloud image and SHA256 list, Windows ADK Deployment Tools, AzCopy, Chocolatey/QEMU, SQL Server 2022 Express, the SqlServer PowerShell module, NodeSource's Node.js 24 packages and Express 5.2.1 from npm. Endpoint availability and package policies must be checked in the teaching environment. ADK and SQL installers receive Authenticode checks. SQL setup also requires a SQL 2022 Express package that meets Microsoft's current bootstrapper minimum version; it prints the detected and required versions before installation. The image hash checks detect corruption; the Ubuntu hash list and image are both downloaded over HTTPS from Canonical.

Module 1 adds one more large download, performed inside HyperVHost rather than by deployment: Microsoft's Azure Migrate appliance VHD for Hyper-V, which is downloaded and extracted into `L:\Appliance`. Confirm the teaching environment allows that download and that the staging volume reports at least 30 GB free before the session.

These are online package sources, not a fully pinned offline distribution. Capture versions and archive approved artifacts for a repeatable course release. A proxy that allows Microsoft endpoints but blocks Canonical, Chocolatey, NodeSource or npm can break setup. Use approved lab-only credentials: Windows unattended setup and Linux cloud-init handle plaintext during first boot; protected Run Command parameters prevent placing them in the public script payload, but administrators of the host can access guest setup data. Never use corporate passwords here.

Confirm Windows image and nested guest use under your organization's licensing arrangements. The repository's MIT license does not license the guest operating systems, SQL or third-party packages. No software binaries are redistributed in this repository.

Estimate all resources listed in the [README](../README.md). NAT gateways and IPs continue to cost money when VMs are off. Set an appropriate budget alert before starting; an alert does not enforce a spending cap.

## 4. Deploy

Use your current internet-facing IPv4 address with `/32`, including any VPN/corporate egress address. Write all four decimal octets without leading zeros; abbreviated, hexadecimal and integer address forms are rejected. The RDP rule only permits that address. If your address changes, update the existing host NSG rule after verifying the new address.

Keep the complete reviewed checkout together. Deployment reads and parses `scripts/host/configure-host.ps1` before contacting Azure; a missing, empty or syntactically invalid host payload stops setup before resource creation. Source/target group existence checks also stop on authentication, permission or network failures instead of assuming the group is available.

```powershell
$sourceRg = 'rg-ces-source-01'
$targetRg = 'rg-ces-target-01'
$location = 'eastus'
$adminCidr = Read-Host 'Your public IPv4 address followed by /32'
$password = Read-Host 'Lab-only administrator password' -AsSecureString

.\scripts\deploy-lab.ps1 -SubscriptionId $subscriptionId `
    -ResourceGroupName $sourceRg -Location $location `
    -AdminUsername labadmin -AdminPassword $password -AdminSourceCidr $adminCidr

.\scripts\migrate-step1-setup-project.ps1 -SubscriptionId $subscriptionId `
    -SourceResourceGroup $sourceRg -TargetResourceGroup $targetRg -Location $location
```

Deployment creates the four workload VMs only. It attaches the appliance staging disk with the host, formats it as `ApplianceStaging`, creates `L:\Appliance` and stops with an error if fewer than 30 GB are free, before any guest disk work begins. Use `-ApplianceStagingDiskSizeGB`, `-ApplianceStagingDiskType` or `-ApplianceStagingDriveLetter` only when the defaults (128 GB, `StandardSSD_LRS`, `L`) conflict with local policy.

Managed Run Command allows a longer setup timeout and protected parameters. Deployment only reports workload readiness after checking the actual HTTP/API/SQL endpoints. [Managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)

The target and test NAT gateways provide explicit outbound access without public IPs on the workload VMs. New network behavior must not be assumed to provide automatic outbound internet. [Azure outbound access](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access)

## 5. Verify inside HyperVHost

RDP to the host's output public IP as `labadmin` with your chosen password. Open elevated Windows PowerShell:

```powershell
Get-VM | Select-Object Name,State,ProcessorCount,MemoryAssigned
Get-VMSwitch
Get-NetNat
Get-DhcpServerv4Scope
Get-DhcpServerv4Reservation -ScopeId 192.168.0.0
Get-DhcpServerv4Lease -ScopeId 192.168.0.0
Get-Content C:\AzMigrateLab\setup-complete.json
Get-Volume -DriveLetter L | Select-Object DriveLetter,FileSystemLabel,SizeRemaining

(Invoke-WebRequest http://192.168.0.10 -UseBasicParsing).StatusCode
(Invoke-WebRequest http://192.168.0.12 -UseBasicParsing).StatusCode
Invoke-RestMethod http://192.168.0.13:3000/api/health
Test-NetConnection 192.168.0.11 -Port 1433
```

Expect four running VMs, both HTTP responses `200`, API `status: healthy`, SQL `TcpTestSucceeded: True`, and `L:` labelled `ApplianceStaging` with at least 30 GB remaining. A VM heartbeat or ICMP ping does not prove an application works. Windows guests use `Administrator` and the supplied password; Linux guests use `labadmin`. No appliance VM exists yet: Module 1 downloads Microsoft's appliance VHD into `L:\Appliance` and imports it there.

On SQL, sign in through Hyper-V Manager and run:

```powershell
Invoke-Sqlcmd -ServerInstance '.\SQLEXPRESS' -TrustServerCertificate -Database ContosoApp `
    -Query 'SELECT COUNT(*) AS Customers FROM dbo.Customers; SELECT COUNT(*) AS Orders FROM dbo.Orders;'
```

Expect five rows in each table on a fresh lab. This local sample uses a self-signed SQL certificate; `TrustServerCertificate` is confined to the lab.

## 6. Troubleshoot before teaching

| Symptom | Check |
|---|---|
| Deployment refuses the group | The script requires a new dedicated group. Inspect/clean up the failed group; do not rerun provisioning after migration begins. |
| Group lookup cannot be verified | Check the exact subscription, current login, read permissions and Azure connectivity. A denied read is not a missing group. |
| Host configuration file missing or invalid | Obtain the complete reviewed repository revision; keep the `scripts/host` directory with `deploy-lab.ps1`. |
| Hyper-V fails | VM family, security type, policy, available quota and vmms service after restart |
| Guest has no address | DHCP bound only to `vEthernet (intSwitch)`, scope active, reservation MAC matches guest NIC |
| Package installation fails | `C:\AzMigrateLab\setup-log.txt`; package source access; installer exit codes; free disk space |
| Guest will not answer a ping | Confirm `LabTrustedIcmp4` exists on the guest (`Get-NetFirewallRule -Name LabTrustedIcmp4`); see section 7 before enabling any built-in firewall group |
| Staging volume missing or too small | `Get-Disk`, `Get-Volume -DriveLetter L`; the data disk must be attached and RAW at first format; keep guest VHDs and the appliance download on separate volumes |
| Linux app missing | `sudo cloud-init status --long`, `/var/log/cloud-init-output.log`, `journalctl -u contoso-app` |
| SQL not listening | `MSSQL$SQLEXPRESS`, named instance TCP configuration and guest firewall; check locally before testing remotely |
| Setup interrupted | Retain logs, revoke/remove `WinServerBase-temp` if present, inspect managed Run Command; use a fresh lab after resolving the cause |

## 7. Lab firewall posture

This is an enclosed training environment on an internal switch behind NAT. Deployment treats the nested subnet, the host VNet and the target/test VNets as trusted, and configures that explicitly rather than leaving instructors to enable Windows firewall groups by hand.

| Where | Rule | Why |
|---|---|---|
| Windows guests | `LabTrustedIcmp4` — inbound ICMPv4 echo from `192.168.0.0/24`, `10.0.0.0/16`, `10.1.0.0/16`, `10.2.0.0/16` | Ping works from HyperVHost and between guests without enabling **File and Printer Sharing**, which would also open SMB and NetBIOS |
| Windows guests | `LabTrustedInbound` — inbound any protocol from the same ranges | Lab traffic, remote management and validation work without a rule per service |
| Windows guests | Connection profile set to `Private` | A DHCP NIC is often classified `Public`, where the built-in groups behave unexpectedly |
| HyperVHost | `LabHostIcmp4`, `LabHostWinRM` (5985/5986) and `LabHostSmb` (445), all from `192.168.0.0/24` only | The Azure Migrate appliance reaches the host over WinRM for Hyper-V discovery; ping works in both directions |
| Linux guests | `ufw` explicitly disabled | `ufw` ships inactive on Ubuntu cloud images; the explicit disable makes the posture deliberate rather than incidental |

Enabling the **File and Printer Sharing** group on a guest is no longer necessary to make it answer a ping. If you previously ran `Enable-NetFirewallRule -DisplayGroup 'File and Printer Sharing'` on `OnPrem-Web`, you can leave it or disable it again; `LabTrustedIcmp4` covers the ping on its own.

Two limits worth stating plainly. The host's public NIC is **not** covered by these rules: inbound access from the internet is still governed by the Azure NSG, which permits RDP only from the single `/32` supplied at deployment. And guest firewall settings travel with the VM, so after cutover the migrated guests still trust `10.1.0.0/16` and `10.2.0.0/16`. That is appropriate for a disposable training subscription and is not a pattern to carry into a customer landing zone.

Record the pass/fail evidence in the [instructor guide](Instructor-Guide.md), then continue to [Module 1](Module-1-Discovery.md).
