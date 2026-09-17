# Module 0 · Setup

**TD SYNNEX | Cloud Enablement Services**

In this module you build the on-premises environment the rest of the workshop migrates: one Azure VM running Hyper-V, with four nested guest VMs standing in for a small business's servers. A single script provisions all of it, and you finish by verifying that every workload actually responds.

Run the Azure commands from your own workstation or PowerShell Cloud Shell. Run the Hyper-V commands in an elevated Windows PowerShell session **inside HyperVHost**, the host VM you are about to create.

> **Instructor note.** You can drive this module from the [rehearsal launcher](Automated-Rehearsal.md) on a persistent Windows workstation, which runs the scripted stages in order and records the interactive checkpoints. Learners follow the manual path below.

## 1. Before you deploy

Use a dedicated training subscription or an approved training resource group. You need Contributor access to deploy; registering resource providers and assigning roles require their own permissions. Azure Policy must allow the selected VM size, Standard security, disk export and the outbound download destinations. Choose an available region and verify quota — capacity and quota are separate constraints, and either can stop a deployment.

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

Nested vCPU allocation is deliberately oversubscribed: the appliance can be given eight virtual processors because the host has eight. Memory is not oversubscribed. Deployment assigns 12 GB across the four workloads, which leaves the host's remaining 64 GB to cover the appliance's 16 GB and Windows itself when you import it in Module 1. Nothing reserves that capacity for you — you confirm the sizing at import time. [Hyper-V appliance sizing](https://learn.microsoft.com/azure/migrate/deploy-appliance-script)

To use a different host size, set `VMSize` in `rehearsal.local.json` or pass `-VMSize` to `deploy-lab.ps1`. Deployment checks your choice against the subscription's regional SKU metadata and against both the family and regional vCPU quotas, then stops with an error naming the size and the unmet requirement. It never substitutes a different size behind your back. For example, `Standard_E16s_v7` meets the CPU and RAM requirements while `Standard_E4s_v7` has only 32 GiB of RAM — and neither is guaranteed to be available in your subscription. [Esv7 specifications](https://learn.microsoft.com/azure/virtual-machines/sizes/memory-optimized/esv7-series)

Before you commit to a size, confirm **Nested Virtualization: Supported** in Microsoft's documentation for that series. Hardware and availability metadata alone do not establish nested virtualization support, and they do not guarantee allocation capacity. See the default [Esv7 specifications](https://learn.microsoft.com/azure/virtual-machines/sizes/memory-optimized/esv7-series) and [nested virtualization setup](https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/nested-virtualization).

> **Note:** Esv7 is a Generation 2 only series, and its sizes require an OS image with NVMe support. The workshop's `2022-datacenter-g2` host image satisfies both conditions; a different image may not.

> **Instructor note.** Record the nested-virtualization source you relied on in the environment checkpoint. Reserve quota for four simultaneous test VMs and, later, four migrated VMs — separately from the host, which is already counted.

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

Module 1 adds one more large download, and you perform it yourself inside HyperVHost rather than through deployment: Microsoft's Azure Migrate appliance VHD for Hyper-V, extracted into `L:\Appliance`.

> **Instructor note.** Confirm the teaching environment allows that download before the session, and check that the staging volume reports at least 30 GB free. A proxy that permits the Azure portal but blocks the appliance download will strand learners at the start of Module 1.

These are online package sources, not a fully pinned offline distribution. Capture versions and archive approved artifacts for a repeatable course release. A proxy that allows Microsoft endpoints but blocks Canonical, Chocolatey, NodeSource or npm can break setup. Use approved lab-only credentials: Windows unattended setup and Linux cloud-init handle plaintext during first boot; protected Run Command parameters prevent placing them in the public script payload, but administrators of the host can access guest setup data. Never use corporate passwords here.

Confirm Windows image and nested guest use under your organization's licensing arrangements. The repository's MIT license does not license the guest operating systems, SQL or third-party packages. No software binaries are redistributed in this repository.

Estimate all resources listed in the [README](../README.md). NAT gateways and IPs continue to cost money when VMs are off. Set an appropriate budget alert before starting; an alert does not enforce a spending cap.

## 4. Deploy

Supply your current internet-facing IPv4 address with `/32`, including a VPN or corporate egress address if you are behind one. Write all four decimal octets without leading zeros — abbreviated, hexadecimal and integer address forms are rejected. The host's RDP rule permits that one address and nothing else, so if your address changes later, update the existing NSG rule rather than redeploying.

Keep the complete reviewed checkout together. Before it contacts Azure, deployment reads and parses `scripts/host/configure-host.ps1` and `scripts/enable-lab-traffic.ps1`; a missing, empty or syntactically invalid script stops setup before any resource is created. The resource group checks behave the same way — an authentication, permission or network failure stops deployment instead of being treated as "the group does not exist".

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

Deployment creates the four workload VMs and nothing else. Along the way it attaches the appliance staging disk to the host, formats it as `ApplianceStaging`, creates `L:\Appliance`, and stops with an error if fewer than 30 GB are free — all before any guest disk work begins, so you find out early rather than after an hour of provisioning. It also leaves the optional traffic generator on the host at `C:\AzMigrateLab\enable-lab-traffic.ps1` for section 6; nothing starts it.

Expect 30–60 minutes. Progress is printed as each stage completes, and no interaction is needed once it starts.

> **Tip:** Detailed logs are written to `C:\AzMigrateLab\setup-log.txt` on the host VM.

> **Instructor note.** Override the staging disk with `-ApplianceStagingDiskSizeGB`, `-ApplianceStagingDiskType` or `-ApplianceStagingDriveLetter` only when the defaults (128 GB, `StandardSSD_LRS`, drive `L`) conflict with local policy.

Deployment uses managed Run Command, which allows a longer setup timeout and protected parameters, and it reports workload readiness only after checking the real HTTP, API and SQL endpoints. [Managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)

The target and test NAT gateways provide explicit outbound access without public IPs on the workload VMs. New network behavior must not be assumed to provide automatic outbound internet. [Azure outbound access](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access)

## 5. Verify inside HyperVHost

Deployment reports readiness only after it has checked the real HTTP, API and SQL endpoints, but you should confirm the environment yourself before teaching from it.

RDP to the host's public IP — the address deployment printed when it finished — as `labadmin` with the password you chose. Open an elevated Windows PowerShell session and run:

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

**Expected results:**

| Check | What you should see |
|---|---|
| `Get-VM` | Four VMs, all `Running`: `OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web`, `OnPrem-Linux-App` |
| Both `Invoke-WebRequest` calls | `200` |
| `Invoke-RestMethod` | `status: healthy` |
| `Test-NetConnection` | `TcpTestSucceeded: True` |
| `Get-Volume -DriveLetter L` | Label `ApplianceStaging` with at least 30 GB remaining |

There is no appliance VM at this point, and that is expected. You build it in [Module 1](Module-1-Discovery.md) by importing Microsoft's appliance VHD into `L:\Appliance`, which is what the staging volume was created for.

> **Note:** A VM heartbeat or a successful ping does not prove an application works. That is why every check above targets an application-layer endpoint rather than ICMP.

Sign in to the guests when you want to look inside them. Windows guests use `Administrator` with the lab password; Linux guests use `labadmin` with the same password.

To confirm the sample database, sign in to `OnPrem-SQL` through Hyper-V Manager and run:

```powershell
Invoke-Sqlcmd -ServerInstance '.\SQLEXPRESS' -TrustServerCertificate -Database ContosoApp `
    -Query 'SELECT COUNT(*) AS Customers FROM dbo.Customers; SELECT COUNT(*) AS Orders FROM dbo.Orders;'
```

**Expected result:** five rows in each table on a fresh lab.

> **Note:** This sample uses a self-signed SQL certificate, so `TrustServerCertificate` is required here. It is confined to the lab and is not a pattern for production connection strings.

## 6. Start the sample business traffic

The four workloads are independent samples. Nothing connects them, so Azure Migrate has no application dependencies to find and the dependency map in Module 1 is legitimately empty.

This optional step wires them into one small-business order desk. Nginx proxies to the Node API, the Node API reads and writes the `ContosoApp` database, and the IIS server runs an internal order report against that same database. `OnPrem-SQL` then appears as a shared dependency of both application tiers — which is the conversation a customer needs to have before moving anything.

Run it after the checks in section 5 pass and before you build the appliance, so traffic is already flowing when discovery starts.

Deployment has already placed the script on the host. In your elevated PowerShell session:

```powershell
C:\AzMigrateLab\enable-lab-traffic.ps1
```

Enter the lab password when prompted. The lab user name and guest addresses come from `C:\AzMigrateLab\lab-traffic.settings.json`, which deployment wrote alongside the script, so no other values are needed.

The script configures the Windows guests through PowerShell Direct and the two Linux guests over SSH, prompting once per Linux guest for the `labadmin` password. It finishes by listing the traffic it started.

Confirm traffic is flowing:

```powershell
Invoke-RestMethod http://192.168.0.12:8080/api/health
Invoke-Sqlcmd -ServerInstance 192.168.0.11 -TrustServerCertificate -Database ContosoApp `
    -Query 'SELECT COUNT(*) AS Orders FROM dbo.Orders'
```

**Expected result:** the proxy returns a healthy response, and the order count increases each time you run the query.

> **Tip:** Start this before the appliance so connections accumulate while you work through appliance setup. Dependency analysis samples active connections on a polling interval rather than recording continuously, so traffic that starts minutes before you open the map may not appear in it.

> **Instructor note.** This step is optional, and the rest of the lab is written to work without it. Skip it if you want to teach why an empty dependency map can be a correct result; run it when you want a populated map to interpret. `-IntervalSeconds` adjusts the request rate and `-Disable` removes the mesh. Keep the load light — the host has 8 vCPUs shared across four guests, and a heavy generator would distort the performance-based sizing discussion in Module 1. Section 6 of [Lab traffic mesh](Lab-Traffic.md) lists exactly what changes on each guest, including the mixed-mode SQL login the Linux generator requires.

## 7. Troubleshoot before teaching

| Symptom | Check |
|---|---|
| Deployment refuses the group | The script requires a new dedicated group. Inspect/clean up the failed group; do not rerun provisioning after migration begins. |
| Group lookup cannot be verified | Check the exact subscription, current login, read permissions and Azure connectivity. A denied read is not a missing group. |
| Host configuration file missing or invalid | Obtain the complete reviewed repository revision; keep the `scripts/host` directory and `scripts/enable-lab-traffic.ps1` beside `deploy-lab.ps1`. |
| Hyper-V fails | VM family, security type, policy, available quota and vmms service after restart |
| Guest has no address | DHCP bound only to `vEthernet (intSwitch)`, scope active, reservation MAC matches guest NIC |
| Package installation fails | `C:\AzMigrateLab\setup-log.txt`; package source access; installer exit codes; free disk space |
| Guest will not answer a ping | Confirm `LabTrustedIcmp4` exists on the guest (`Get-NetFirewallRule -Name LabTrustedIcmp4`); read section 8 before enabling any built-in firewall group |
| Staging volume missing or too small | `Get-Disk`, `Get-Volume -DriveLetter L`; the data disk must be attached and RAW at first format; keep guest VHDs and the appliance download on separate volumes |
| Traffic script not on the host | `Get-Content C:\AzMigrateLab\setup-log.txt -Tail 20` for the PHASE 6 staging line; the script is written at the end of setup, so an interrupted deployment may not have reached it |
| Linux app missing | `sudo cloud-init status --long`, `/var/log/cloud-init-output.log`, `journalctl -u contoso-app` |
| SQL not listening | `MSSQL$SQLEXPRESS`, named instance TCP configuration and guest firewall; check locally before testing remotely |
| Setup interrupted | Retain logs, revoke/remove `WinServerBase-temp` if present, inspect managed Run Command; use a fresh lab after resolving the cause |

## 8. Lab firewall posture

This lab is an enclosed training environment: the guests sit on an internal Hyper-V switch behind NAT, with no inbound path from the internet. Deployment therefore treats the nested subnet, the host VNet and the target/test VNets as trusted, and configures that for you.

| Where | Rule | Why |
|---|---|---|
| Windows guests | `LabTrustedIcmp4` — inbound ICMPv4 echo from `192.168.0.0/24`, `10.0.0.0/16`, `10.1.0.0/16`, `10.2.0.0/16` | Ping works from HyperVHost and between guests without enabling **File and Printer Sharing**, which would also open SMB and NetBIOS |
| Windows guests | `LabTrustedInbound` — inbound any protocol from the same ranges | Lab traffic, remote management and validation work without adding a rule per service |
| Windows guests | Connection profile set to `Private` | A DHCP NIC is often classified `Public`, where the built-in rule groups behave unexpectedly |
| HyperVHost | `LabHostIcmp4`, `LabHostWinRM` (5985/5986) and `LabHostSmb` (445), all from `192.168.0.0/24` only | The Azure Migrate appliance reaches the host over WinRM for Hyper-V discovery, and ping works in both directions |
| Linux guests | `ufw` explicitly disabled | `ufw` ships inactive on Ubuntu cloud images; disabling it explicitly makes the posture deliberate rather than incidental |

If a guest does not answer a ping, you do **not** need to enable the **File and Printer Sharing** group. That group happens to contain the ICMPv4 echo rule, but it also opens SMB and NetBIOS to get you there. `LabTrustedIcmp4` covers the ping on its own.

> **Note:** These rules cover the nested network only. Inbound access to the host from the internet is still governed by the Azure NSG, which permits RDP from the single `/32` address you supplied at deployment.

> **Instructor note.** Guest firewall settings travel with the VM, so after cutover the migrated guests still trust `10.1.0.0/16` and `10.2.0.0/16`. That is appropriate for a disposable training subscription, and it is worth telling learners explicitly that it is not a pattern to carry into a customer landing zone.

Record the pass/fail evidence in the [instructor guide](Instructor-Guide.md), then continue to [Module 1](Module-1-Discovery.md).
