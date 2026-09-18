# Module 0 · Setup

**TD SYNNEX | Cloud Enablement Services**

In this module you build the on-premises environment that the rest of the workshop migrates: one Azure VM running Hyper-V, with four nested guest VMs standing in for a small business's servers. A single script provisions all of it, and you finish by verifying that every workload actually responds.

Run the Azure commands from your own workstation or PowerShell Cloud Shell. Run the Hyper-V commands in an elevated Windows PowerShell session **inside HyperVHost**, the host VM you are about to create.

---

## 1. Module Overview

In a real migration engagement this phase corresponds to **preparing the landing zone** — the target Azure environment that will host migrated workloads. Enterprise projects use [Azure Landing Zones](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/) with management groups, policy-driven governance, hub-spoke networking and identity integration. That level of infrastructure is out of scope for a hands-on migration lab.

Instead, this module deploys a **self-contained simulation of an on-premises datacenter** inside a single Azure VM using nested Hyper-V virtualization. The host VM, virtual networking and all four guest workloads are provisioned by `deploy-lab.ps1` through managed Run Command. No RDP session is required during setup.

**Why this approach?** It gives every participant an isolated, reproducible "datacenter" with realistic workloads (IIS, SQL Server, Nginx, Node.js) while keeping cost and complexity low. The trade-off is that it does not exercise subscription-level governance, which you would address through Azure Landing Zones in a production engagement.

### What Gets Deployed

| VM Name | OS | Role | IP Address | Memory | vCPUs |
|---|---|---|---|---|---|
| OnPrem-Web | Windows Server 2022 | IIS web server | 192.168.0.10 | 4 GB | 2 |
| OnPrem-SQL | Windows Server 2022 | SQL Server 2022 Express | 192.168.0.11 | 4 GB | 2 |
| OnPrem-Linux-Web | Ubuntu 22.04 | Nginx web server | 192.168.0.12 | 2 GB | 2 |
| OnPrem-Linux-App | Ubuntu 22.04 | Node.js Express app | 192.168.0.13 | 2 GB | 2 |

All four guests run on an internal Hyper-V switch (`intSwitch`) with NAT on the `192.168.0.0/24` subnet. The host is reachable from the guests at `192.168.0.1`. Addresses are DHCP reservations, not static guest configuration, so the guests keep working when they are later copied into an Azure VNet.

---

## 2. Architecture Decisions Record (ADR)

Every infrastructure choice in this lab was made deliberately. The table below documents the key decisions and their rationale — a practice you should carry into every production engagement.

| Decision | Choice | Rationale |
|---|---|---|
| **Host VM size** | `Standard_E8s_v7` | 8 vCPUs, 64 GB RAM. The Esv7 series is memory-optimized and supports nested virtualization. The four guests consume 12 GB, leaving room for the host OS, Hyper-V overhead, disk caching and the 16 GB Azure Migrate appliance added in Module 1. Smaller sizes such as `Standard_E4s_v7` support nesting but have only 32 GB, which is too tight once the appliance is running. |
| **OS disk** | 512 GB Premium SSD | The host OS, Hyper-V role, base images and all four guest VHDs share one disk, and the Module 1 appliance VHD is downloaded and expanded here too. Premium SSD provides the IOPS needed when four guests perform simultaneous disk I/O; Standard SSD works but adds noticeable latency during guest provisioning. |
| **Appliance staging** | Host OS disk, no data disk | An additional managed data disk would bill continuously — including while the VM is deallocated — for capacity the 512 GB OS disk already has spare. Deployment instead verifies free space and prepares `C:\AzMigrateLab\Appliance` before provisioning begins. |
| **Appliance delivery** | VHD import in Module 1 | Deployment does not pre-build an appliance VM. Microsoft publishes a ready-made appliance VHD, so importing it is both closer to real practice and avoids provisioning a Windows guest that is immediately replaced. |
| **Guest network** | `192.168.0.0/24` with NAT | Simulates an isolated on-premises network. NAT provides outbound internet access, required for package downloads during provisioning, without exposing guests to inbound traffic from the Azure VNet. This mirrors how many on-premises datacenters sit behind NAT with no direct internet-facing exposure. |
| **VM generation** | Gen 2 | UEFI boot, vTPM support and larger OS disk support. Gen 2 is required for several Azure features post-migration (Trusted Launch, Confidential VMs), so starting here avoids a generation conversion later. |
| **Windows guest memory** | 4 GB | SQL Server Express recommends a minimum of 2 GB; with Windows Server overhead, 4 GB is the practical minimum. IIS is lighter, but keeping both Windows guests at 4 GB simplifies the configuration. |
| **Linux guest memory** | 2 GB | Nginx and Node.js are lightweight. 2 GB is sufficient for the sample workloads and keeps total guest memory within budget. |
| **Deployment method** | PowerShell + managed Run Command | No ARM templates or Bicep — the deployment is imperative PowerShell. Managed Run Command executes the host payload through the Azure VM agent over the secure control plane, which means no public endpoint or RDP session during setup, and it supports long timeouts and protected parameters so credentials never appear in the script payload. |
| **Guest firewall posture** | Trusted lab ranges | The nested subnet and the host, target and test VNets are treated as trusted so ping, lab traffic and validation work without a rule per service. See [section 8](#8-security-baseline) for the exact rules and what changes in production. |

---

## 3. Prerequisites

### 3.1 — Subscription Governance

- **Subscription selection.** Use a dedicated training subscription or an approved training resource group — Dev/Test, Sandbox or Visual Studio Enterprise. Avoid subscriptions with restrictive Azure Policy assignments that may block VM creation, Standard security type, disk export or NSG modification.
- **RBAC requirements.** You need **Contributor** on the target resource group at minimum. Registering resource providers and assigning roles require their own permissions. Verify with:

```powershell
Get-AzRoleAssignment -SignInName (Get-AzContext).Account.Id | Select-Object RoleDefinitionName, Scope
```

- **Dedicated resource groups.** `deploy-lab.ps1` refuses an existing group by design — replaying setup after cutover could restart retired source VMs. Use a new group for each lab build.

### 3.2 — Quota Verification

The host requires 8 vCPUs from the `Standard_ESv7` family. Quota exhaustion is the most common cause of deployment failure. **Check before you deploy:**

```powershell
# Esv7 family quota in your target region
Get-AzVMUsage -Location "eastus" | Where-Object { $_.Name.Value -like "*StandardESv7*" } |
    Select-Object @{N='Family';E={$_.Name.LocalizedValue}}, CurrentValue, Limit
```

If `CurrentValue` is close to `Limit`, deallocate other VMs in that family, request a quota increase in the Azure portal, or choose a different region.

> **Note:** Capacity and quota are separate constraints. Available quota does not guarantee the region can allocate the size, and either can stop a deployment.

Reserve quota for four simultaneous test VMs and, later, four migrated VMs — separately from the host, which is already counted.

### 3.3 — Region Selection

| Criterion | Guidance |
|---|---|
| **Proximity** | Select a region close to you to minimize RDP latency. |
| **Esv7 availability** | Not all regions offer Esv7. Verify: `Get-AzComputeResourceSku -Location "eastus" \| Where-Object { $_.Name -eq "Standard_E8s_v7" }` |
| **Nested virtualization** | Confirm **Nested Virtualization: Supported** in the [Esv7 specifications](https://learn.microsoft.com/azure/virtual-machines/sizes/memory-optimized/esv7-series) before committing to a size. Hardware and availability metadata alone do not establish support. |
| **Cost** | Pricing varies by region. US regions are typically cost-effective. |
| **Fallback regions** | `eastus`, `westus2`, `westeurope`, `northeurope` are reliable choices. |

To use a different host size, pass `-VMSize` to `deploy-lab.ps1`. Deployment checks your choice against the subscription's regional SKU metadata and against both the family and regional vCPU quotas, then stops with an error naming the size and the unmet requirement. It never substitutes a different size silently.

### 3.4 — Local Tooling

| Requirement | Details |
|---|---|
| **PowerShell 7+** | Windows PowerShell 5.1 also works. The host-side scripts target Windows PowerShell 5.1 regardless. |
| **Az PowerShell module** | `Install-Module Az -Scope CurrentUser -Repository PSGallery`. Record the version you used. |
| **RDP client** | Built into Windows. On macOS use Microsoft Remote Desktop; on Linux use `xfreerdp` or Remmina. |

### 3.5 — Network Requirements

Your local network must allow **outbound TCP 3389** to Azure public IPs. If you are behind a corporate firewall that blocks RDP:

- **Option A:** Use [Azure Bastion](https://learn.microsoft.com/azure/bastion/bastion-overview) — browser-based RDP over HTTPS (443). Adds cost.
- **Option B:** Configure a site-to-site or point-to-site VPN.
- **Option C:** Ask your network team to allow outbound 3389 for the duration of the workshop.

You also need your current internet-facing IPv4 address as a `/32`, including any VPN or corporate egress address. Deployment opens RDP to that address alone.

### 3.6 — Downloads and Package Sources

Setup retrieves a Windows Server marketplace disk, an Ubuntu cloud image and its SHA256 list, Windows ADK Deployment Tools, AzCopy, Chocolatey and QEMU, SQL Server 2022 Express, the SqlServer PowerShell module, NodeSource's Node.js packages, and Express from npm.

ADK and SQL installers receive Authenticode checks, and the Ubuntu image is verified against Canonical's published hash. These are online package sources, not a pinned offline distribution — a proxy that allows Microsoft endpoints but blocks Canonical, Chocolatey, NodeSource or npm will break setup.

> **Instructor note.** Confirm endpoint availability and package policy in the teaching environment before the session. Capture versions and archive approved artifacts if you need a repeatable course release.

Confirm Windows image and nested guest use under your organization's licensing arrangements. The repository's MIT license does not license the guest operating systems, SQL Server or third-party packages, and no software binaries are redistributed here.

### 3.7 — Azure Migrate Appliance Requirements

You build the Azure Migrate appliance in Module 1, not here. Deployment leaves room for it, and these are the prerequisites it depends on:

| Requirement | Value |
|---|---|
| Host memory headroom | 16 GB, unallocated after the four guests take 12 GB |
| Host vCPU | 8 virtual processors, oversubscribed against the host's 8 |
| Free disk space on `C:` | 80 GB, verified during deployment and reserved for the appliance archive and its expanded VHD |
| Staging folder | `C:\AzMigrateLab\Appliance`, created and permissioned during deployment |
| Network | Outbound HTTPS from the host for the appliance download, and from the appliance itself for Azure registration |

> **Instructor note.** The appliance archive is a large download performed on the host during Module 1. Confirm your proxy permits it — one that allows the Azure portal but blocks the appliance download will strand learners at the start of the module.

---

## 4. Deployment Steps

### Step 1: Select the subscription and register providers

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
```

### Step 2: Deploy the lab environment

Keep the complete reviewed checkout together. Before it contacts Azure, deployment reads and parses `scripts/host/configure-host.ps1` and `scripts/enable-lab-traffic.ps1` — a missing, empty or syntactically invalid script stops setup before any resource is created.

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

> ⚠️ **Password requirements.** Use 12–72 characters with at least three of: lowercase, uppercase, digit, symbol. This password is used for the host and for every guest VM. Use approved lab-only credentials — Windows unattended setup and Linux cloud-init both handle it in plaintext during first boot, and any administrator of the host can read guest setup data. **Never use a corporate password here.**

Write all four decimal octets of `$adminCidr` without leading zeros; abbreviated, hexadecimal and integer address forms are rejected. If your address changes later, update the existing NSG rule rather than redeploying.

Before provisioning begins, deployment verifies the host has 80 GB free on `C:` and prepares `C:\AzMigrateLab\Appliance`, so a space problem surfaces immediately rather than an hour into setup. It also stages the optional traffic generator at `C:\AzMigrateLab\enable-lab-traffic.ps1` for section 6; nothing starts it.

> ⏱️ **Estimated time: 30–60 minutes.** Progress is printed as each stage completes. No interaction is needed once it starts.
>
> 💡 **Tip:** Detailed logs are written to `C:\AzMigrateLab\setup-log.txt` on the host VM.

Deployment uses managed Run Command, which allows a longer setup timeout and protected parameters, and it reports workload readiness only after checking the real HTTP, API and SQL endpoints. [Managed Run Command](https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed)

The target and test NAT gateways created by `migrate-step1-setup-project.ps1` provide explicit outbound access without public IPs on the workload VMs. Do not assume new networks provide automatic outbound internet. [Azure outbound access](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access)

### Step 3: Connect to the Hyper-V host

Deployment prints the host's public IP when it finishes.

1. Open your RDP client.
2. Connect to that public IP on port 3389.
3. Sign in as **`labadmin`** with the password from Step 2.

```powershell
# Retrieve the public IP if needed
Get-AzPublicIpAddress -ResourceGroupName $sourceRg | Select-Object Name, IpAddress
```

---

## 5. Verify inside HyperVHost

Verification goes beyond "can I ping it?" — confirm that the environment matches the intended architecture and that every workload is functional.

Open an elevated Windows PowerShell session on the host and run:

```powershell
# Guest inventory on HyperVHost — expect four VMs, all Running
Get-VM | Select-Object Name,State,ProcessorCount,MemoryAssigned

# Virtual switch on HyperVHost — expect intSwitch, SwitchType Internal
Get-VMSwitch

# NAT on HyperVHost — expect LabNAT on 192.168.0.0/24
Get-NetNat

# DHCP scope on HyperVHost — expect 192.168.0.0 Active
Get-DhcpServerv4Scope

# DHCP reservations on HyperVHost — expect four reservations, .10 through .13
Get-DhcpServerv4Reservation -ScopeId 192.168.0.0

# DHCP leases on HyperVHost — expect each guest holding its reserved address
Get-DhcpServerv4Lease -ScopeId 192.168.0.0

# Setup record on HyperVHost — expect the four VM names and a CompletedUtc timestamp
Get-Content C:\AzMigrateLab\setup-complete.json

# Free space on HyperVHost — expect 80 GB or more remaining on C:
Get-Volume -DriveLetter C | Select-Object DriveLetter,SizeRemaining

# IIS on OnPrem-Web — expect HTTP 200
(Invoke-WebRequest http://192.168.0.10 -UseBasicParsing).StatusCode

# Nginx on OnPrem-Linux-Web — expect HTTP 200
(Invoke-WebRequest http://192.168.0.12 -UseBasicParsing).StatusCode

# Node.js API on OnPrem-Linux-App — expect status healthy
Invoke-RestMethod http://192.168.0.13:3000/api/health

# SQL Server on OnPrem-SQL — expect TcpTestSucceeded True
Test-NetConnection 192.168.0.11 -Port 1433
```

**Expected results:**

| Check | What you should see |
|---|---|
| `Get-VM` | Four VMs, all `Running`: `OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web`, `OnPrem-Linux-App` |
| Both `Invoke-WebRequest` calls | `200` |
| `Invoke-RestMethod` | `status: healthy` |
| `Test-NetConnection` | `TcpTestSucceeded: True` |
| `Get-Volume -DriveLetter C` | At least 80 GB remaining |

> **Note:** A VM heartbeat or a successful ping does not prove an application works. That is why every workload check above targets an application-layer endpoint rather than ICMP.

Sign in to the guests when you want to look inside them. Windows guests use `Administrator` with the lab password; Linux guests use `labadmin` with the same password.

To confirm the sample database, sign in to `OnPrem-SQL` through Hyper-V Manager and run:

```powershell
# Sample database on OnPrem-SQL — expect Customers 5 and Orders 5 on a fresh lab
Invoke-Sqlcmd -ServerInstance '.\SQLEXPRESS' -TrustServerCertificate -Database ContosoApp `
    -Query 'SELECT (SELECT COUNT(*) FROM dbo.Customers) AS Customers,
            (SELECT COUNT(*) FROM dbo.Orders) AS Orders;'
```

**Expected result:** a single row reading `Customers 5`, `Orders 5`.

> **Note:** Both counts are returned as columns of one row on purpose. `Invoke-Sqlcmd` surfaces only the first result set, so two separate `SELECT COUNT(*)` statements would silently discard the Orders count.

> **Note:** This sample uses a self-signed SQL certificate, so `TrustServerCertificate` is required here. It is confined to the lab and is not a pattern for production connection strings.

If any check fails, review the deployment log before troubleshooting further:

```powershell
Get-Content C:\AzMigrateLab\setup-log.txt -Tail 50
```

---

## 6. Start the sample business traffic

The four workloads are independent samples. Nothing connects them, so Azure Migrate has no application dependencies to find and the dependency map in Module 1 is legitimately empty.

This optional step wires them into one small-business order desk. Nginx proxies to the Node API, the Node API reads and writes the `ContosoApp` database, and the IIS server runs an internal order report against that same database. `OnPrem-SQL` then appears as a shared dependency of both application tiers — which is the conversation a customer needs to have before moving anything.

Run it after the checks in section 5 pass and before you begin Module 1, so traffic is already flowing when discovery starts.

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

> 💡 **Tip:** Start this before Module 1 so connections accumulate while you work through discovery setup. Dependency analysis samples active connections on a polling interval rather than recording continuously, so traffic that starts minutes before you open the map may not appear in it.

> **Instructor note.** This step is optional, and the rest of the lab is written to work without it. Skip it if you want to teach why an empty dependency map can be a correct result; run it when you want a populated map to interpret. `-IntervalSeconds` adjusts the request rate and `-Disable` removes the mesh. Keep the load light — the host has 8 vCPUs shared across four guests, and a heavy generator would distort the performance-based sizing discussion in Module 1. [Lab traffic mesh](Lab-Traffic.md) lists exactly what changes on each guest, including the mixed-mode SQL login the Linux generator requires.

---

## 7. Troubleshooting

### Quota Exhaustion

**Symptom:** `deploy-lab.ps1` fails with `OperationNotAllowed` or `QuotaExceeded`.

**Resolution:**
1. Check current usage: `Get-AzVMUsage -Location "eastus" | Where-Object { $_.Name.Value -like "*StandardESv7*" }`
2. If at the limit, either deallocate unused VMs in the same family, request an increase via **Azure Portal → Subscriptions → Usage + quotas → Request increase**, or switch to a fallback region (see 3.3).

### Host Size Rejected Before Deployment

**Symptom:** Deployment stops with a message naming the selected size and an unmet requirement, before creating anything.

**Cause:** The size does not meet the lab's floor — 8 enabled vCPUs, 64 GiB RAM, x64, Gen 2 and Premium SSD support — or quota is insufficient.

**Resolution:** Choose a size that meets all of them and is available in your region. This check is deliberate; deployment never silently substitutes a different size.

### Nested Virtualization Not Supported

**Symptom:** The Hyper-V role fails to install, or guest VMs do not start.

**Cause:** The VM size does not support nested virtualization, or the region does not offer the SKU.

**Resolution:**
1. Verify SKU availability: `Get-AzComputeResourceSku -Location "eastus" | Where-Object { $_.Name -eq "Standard_E8s_v7" }`
2. Confirm **Nested Virtualization: Supported** in the series documentation before retrying.

### Region Fallback Strategy

| Priority | Region | Notes |
|---|---|---|
| 1 | `eastus` | Largest Azure region, broadest SKU availability |
| 2 | `westus2` | Good capacity, lower latency from the western US |
| 3 | `westeurope` | Primary European region |
| 4 | `northeurope` | European fallback |

### Insufficient Free Space on C:

**Symptom:** Deployment stops at the appliance staging check, reporting the observed free space.

**Cause:** The host OS disk does not have the required headroom for the Module 1 appliance download and its expanded VHD.

**Resolution:** Deploy with a larger OS disk, or lower the gate with `-ApplianceStagingMinimumFreeGB` only if you have confirmed the appliance will still fit. The guest VHDs are dynamic and grow during the workshop, so do not run the host close to full.

### Guest VM Not Starting

**Symptom:** One or more guest VMs show `Off` and fail to start.

**Cause:** Insufficient memory or disk space on the host.

**Resolution:**
1. Check available memory: `Get-Counter '\Memory\Available MBytes'`
2. Check disk space: `Get-PSDrive C`
3. Review the Hyper-V event log: `Get-WinEvent -LogName "Microsoft-Windows-Hyper-V-Worker-Admin" -MaxEvents 10`
4. Check `C:\AzMigrateLab\setup-log.txt` for provisioning errors.

### Cannot RDP to the Hyper-V Host

**Symptom:** The RDP connection times out or is refused.

**Resolution:**
1. Verify the VM is running: `Get-AzVM -ResourceGroupName $sourceRg -Status`
2. Verify the NSG permits your address: `Get-AzNetworkSecurityGroup -ResourceGroupName $sourceRg | Get-AzNetworkSecurityRuleConfig`
3. Test reachability: `Test-NetConnection -ComputerName <public-ip> -Port 3389`
4. If your address has changed since deployment, update the existing rule. If your network blocks RDP, deploy Azure Bastion (see 3.5).

### Guest Will Not Answer a Ping

**Symptom:** A Windows guest is running and serving its workload, but does not respond to ping from the host.

**Resolution:** Confirm the lab rule is present: `Get-NetFirewallRule -Name LabTrustedIcmp4`. Read [section 8](#8-security-baseline) before enabling any built-in firewall group — **File and Printer Sharing** would work, but it opens SMB and NetBIOS to obtain a ping.

### Guest Has No Address

**Symptom:** A guest boots but holds no IP address.

**Resolution:** Confirm DHCP is bound only to `vEthernet (intSwitch)`, the scope is active, and the reservation MAC matches the guest NIC.

### Network Connectivity Debugging

If guest VMs are running but unreachable:

```powershell
# Verify the virtual switch exists
Get-VMSwitch

# Verify NAT configuration
Get-NetNat

# Verify host IP on the internal switch
Get-NetIPAddress -InterfaceAlias "vEthernet (intSwitch)"

# Trace route from host to guest
Test-NetConnection -ComputerName 192.168.0.10 -TraceRoute

# Check whether a guest has an address assigned
Get-VM -Name "OnPrem-Web" | Get-VMNetworkAdapter | Select-Object IPAddresses
```

### Linux Workload Missing

**Symptom:** Nginx or the Node API does not respond, though the guest is running.

**Resolution:** From the guest, check `sudo cloud-init status --long`, `/var/log/cloud-init-output.log`, and `journalctl -u contoso-app`.

### SQL Not Listening

**Symptom:** `Test-NetConnection ... -Port 1433` returns `False`.

**Resolution:** Check the `MSSQL$SQLEXPRESS` service, the named instance's TCP configuration, and the guest firewall. Verify locally on the guest before testing across the network.

### Traffic Script Not on the Host

**Symptom:** `C:\AzMigrateLab\enable-lab-traffic.ps1` does not exist.

**Resolution:** Check `Get-Content C:\AzMigrateLab\setup-log.txt -Tail 20` for the staging phase. The script is written at the end of setup, so an interrupted deployment may not have reached it.

### Deployment Script Fails Midway

**Symptom:** The script fails after the host VM was created.

**Resolution:**
1. Identify the failed phase from the script output and `C:\AzMigrateLab\setup-log.txt`.
2. Retain the logs and revoke/remove `WinServerBase-temp` if it is still present.
3. Use a fresh resource group after resolving the cause. Deployment refuses existing groups, and it is not a repair command.

---

## 8. Security Baseline

This section documents the security posture of the lab environment and highlights what you would do differently in production.

### 8.1 — Network Security Group (NSG) Rules

Deployment creates a single NSG with one inbound rule:

| Priority | Name | Direction | Protocol | Source | Destination | Port | Action |
|---|---|---|---|---|---|---|---|
| 100 | Allow-RDP | Inbound | TCP | Your `/32` | `*` | 3389 | Allow |

The source is the exact address you supplied at deployment, not a wildcard. This is the one production-appropriate control in the lab, and it is worth pointing out to learners: a `/32` source is the difference between an exposed management port and a scoped one.

> ⚠️ **Lab-only configuration.** The host still has a public IP with RDP reachable from the internet, scoped or not. In production, prefer a design with no public management endpoint at all.

### 8.2 — Lab Firewall Posture

This lab is an enclosed training environment: the guests sit on an internal Hyper-V switch behind NAT with no inbound path from the internet. Deployment therefore treats the nested subnet and the host, target and test VNets as trusted, and configures that for you.

| Where | Rule | Why |
|---|---|---|
| Windows guests | `LabTrustedIcmp4` — inbound ICMPv4 echo from `192.168.0.0/24`, `10.0.0.0/16`, `10.1.0.0/16`, `10.2.0.0/16` | Ping works from the host and between guests without enabling **File and Printer Sharing**, which would also open SMB and NetBIOS |
| Windows guests | `LabTrustedInbound` — inbound any protocol from the same ranges | Lab traffic, remote management and validation work without adding a rule per service |
| Windows guests | Connection profile set to `Private` | A DHCP NIC is often classified `Public`, where the built-in rule groups behave unexpectedly |
| HyperVHost | `LabHostIcmp4`, `LabHostWinRM` (5985/5986) and `LabHostSmb` (445), all from `192.168.0.0/24` only | The Azure Migrate appliance reaches the host over WinRM for Hyper-V discovery, and ping works in both directions |
| Linux guests | `ufw` explicitly disabled | `ufw` ships inactive on Ubuntu cloud images; disabling it explicitly makes the posture deliberate rather than incidental |

> **Note:** These rules cover the nested network only. Inbound access to the host from the internet remains governed by the NSG in 8.1.

> **Instructor note.** Guest firewall settings travel with the VM, so after cutover the migrated guests still trust `10.1.0.0/16` and `10.2.0.0/16`. That is acceptable in a disposable training subscription, and it is worth telling learners explicitly that it is not a pattern to carry into a customer landing zone.

### 8.3 — Production Alternatives for Remote Access

| Approach | How it works | When to use |
|---|---|---|
| **Azure Bastion** | Browser-based RDP/SSH over HTTPS (443). No public IP on the VM. | Default recommendation for production VMs. |
| **JIT VM access** | Microsoft Defender for Cloud opens NSG ports on demand for a limited window. | When you need direct RDP but want time-bounded access. |
| **VPN gateway** | Site-to-site or point-to-site VPN; reach VMs by private IP. | When you need persistent network-level connectivity. |
| **Restrict NSG source** | Allowlist a specific public IP, as this lab does. | Quick hardening for known, static client addresses. |

### 8.4 — Credential Management

| Lab approach | Risk | Production alternative |
|---|---|---|
| One lab password for the host and every guest | Credential reuse — compromise of one VM exposes all. | Unique credentials per VM, rotated through Key Vault. |
| Password supplied as a `SecureString` parameter | Protected in the Run Command payload, but present in the deploying session. | Retrieve at deployment time with `Get-AzKeyVaultSecret`. |
| Windows guests provisioned via `unattend.xml` | Password in clear text inside the VHD during first boot. | Entra ID join or domain join with managed service accounts. Setup deletes the file after first boot. |
| Linux guests provisioned via cloud-init | Password present in user-data metadata. | SSH key pairs with password authentication disabled. |
| Optional traffic mesh adds a mixed-mode SQL login | A SQL login with read/write on `ContosoApp`, stored in a systemd environment file. | Managed identity or integrated authentication. See [Lab traffic mesh](Lab-Traffic.md). |

### 8.5 — Principle of Least Privilege

The lab uses **Contributor** at the resource group scope, which is broader than strictly necessary. In production:

- Create a **custom RBAC role** with only the permissions needed — VM creation, network management, disk operations.
- Use **managed identities** rather than service principal secrets for automated deployments.
- Apply **resource locks** on critical resources to prevent accidental deletion.

---

## 9. Cost Analysis

Understanding the cost profile is essential for planning workshops at scale and advising customers on migration lab budgets.

> **Note:** Rates below are pay-as-you-go and change over time and by region and agreement. Confirm the figures for your own subscription with the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) before quoting them. Cells marked *verify* are ones this guide does not state a figure for.

### 9.1 — Cost Breakdown

| Resource | SKU / Tier | Approx. cost (East US) | Notes |
|---|---|---|---|
| Host VM compute | `Standard_E8s_v7` | ~$0.695/hr **Linux** rate | This lab runs **Windows**, which adds a licensing surcharge on top of this figure — *verify* the Windows rate for your agreement. Deallocating stops compute charges. |
| OS disk | 512 GB Premium SSD | *verify* | Charged even while the VM is deallocated. |
| Public IP | Standard, static | *verify* | Charged while allocated. |
| Networking egress | Standard | Minimal | Small during setup; negligible ongoing. |

> **Note:** The four guest VMs run inside the host and incur **no separate Azure charges** — their compute and storage come from the host's resources. The same is true of the Azure Migrate appliance you add in Module 1.

> 💡 **A deliberate saving.** Earlier revisions of this lab attached a separate 128 GB managed data disk to stage the appliance VHD. It was removed: the 512 GB OS disk already has the capacity, and a data disk bills continuously — including while the VM is deallocated — for space the lab already owns.

### 9.2 — Cost Optimization Tips

| Tip | Savings impact |
|---|---|
| **Deallocate when not in use.** `Stop-AzVM -ResourceGroupName $sourceRg -Name HyperVHost -Force` | Eliminates host compute charges. Guest VMs stop with it. |
| **Set auto-shutdown.** Azure Portal → VM → Auto-shutdown. | Prevents overnight charges from a forgotten lab. |
| **Use Azure Dev/Test pricing.** If eligible. | Significant reduction on Windows compute. |
| **Delete when done.** `.\scripts\cleanup-lab.ps1 -SubscriptionId $subscriptionId -ResourceGroupName $targetRg,$sourceRg -WhatIf` first, then without `-WhatIf`. | Eliminates all charges, including the disk and IP charges that persist through deallocation. |
| **Choose a cost-effective region.** | Varies by region; US regions are generally lower. |

> ⚠️ **Deallocating is not deleting.** Stopping the VM ends compute charges but leaves disks, public IPs, NAT gateways and any retained backups billing. Set a budget alert before you start — an alert does not enforce a spending cap.

### 9.3 — Comparison to Real Migration Lab Costs

In a production migration engagement, the lab infrastructure is more substantial:

| Component | This workshop | Production migration lab |
|---|---|---|
| Source environment | 1 host VM with 4 nested guests | Dedicated VMs or physical servers per workload |
| Azure Migrate appliance | Imported VHD running as a nested VM, no separate charge | Dedicated VM on the source infrastructure |
| Replication storage | Workshop-scale, minimal | Premium storage accounts sized for replication data |
| Target VMs | Created during the migration modules | Sized to match production workloads |
| Additional networking | Two NAT gateways and their public IPs | Hub-spoke, ExpressRoute or VPN, firewalls |

Estimate every resource listed in the [README](../README.md) for your own region and agreement rather than reusing a figure from another engagement.

---

## Estimated Deployment Time

| Phase | Duration | Details |
|---|---|---|
| Azure VM provisioning | ~5–10 minutes | Resource group, networking, host VM creation |
| Hyper-V role installation and reboot | ~5–10 minutes | Feature installation, mandatory restart |
| Guest VM creation and workload configuration | ~20–40 minutes | Image downloads, VHD creation, OS provisioning, application installation |
| **Total** | **~30–60 minutes** | Fully automated — no manual steps required |

---

## Next Steps

Your simulated on-premises datacenter is operational and verified. The environment represents a typical mixed-workload estate: a Windows web tier, a Windows database tier, a Linux web server and a Linux application server — four of the most common patterns you will meet in enterprise migration engagements.

Proceed to:

➡️ **[Module 1: Discovery and assessment](Module-1-Discovery.md)** — where you build the Azure Migrate appliance, discover these workloads, and generate migration readiness assessments.
