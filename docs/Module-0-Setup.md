# Module 0 · Setup

**TD SYNNEX | Cloud Enablement Services**

In this module you build the on-premises environment that the rest of the workshop migrates: one Azure VM running Hyper-V, with four nested guest VMs standing in for a small business's servers. You run the deployment script, connect to the host, and verify the workloads yourself.

**Where to run:** Run the Azure commands in a **local PowerShell session on your workstation**, from the complete provided checkout. Run the Hyper-V commands in an **elevated Windows PowerShell session inside HyperVHost**.

---

## 1. Module Overview

**Concept**

Enterprise migration projects use Azure Landing Zones with management groups, policy-driven governance, hub-spoke networking and identity integration. That level of infrastructure is out of scope for this setup module.

Instead, this module deploys a **self-contained simulation of an on-premises datacenter** inside a single Azure VM using nested Hyper-V virtualization. The host VM, virtual networking and all four guest workloads are provisioned by `deploy-lab.ps1`. You do not create the four guests individually. You connect through RDP afterwards to complete the manual verification.

**Why this approach?** It gives every participant an isolated, reproducible "datacenter" with realistic workloads (IIS, SQL Server, Nginx, Tomcat) while keeping cost and complexity low. The trade-off is that it does not exercise subscription-level governance, which you would address through Azure Landing Zones in a production engagement.

This is the **source environment**, not the destination landing zone. You build the target network manually in Module 2, in a reviewed migration region different from the source region.

### What Gets Deployed

| VM Name | OS | Role | IP Address | Memory | vCPUs |
|---|---|---|---|---|---|
| OnPrem-Web | Windows Server 2022 | IIS static site on port 80 | 192.168.0.10 | 4 GB | 2 |
| OnPrem-SQL | Windows Server 2022 | SQL Server 2022 Express, `ContosoApp` database on port 1433 | 192.168.0.11 | 4 GB | 2 |
| OnPrem-Linux-Web | Ubuntu 24.04 LTS (Noble) | Nginx static site on port 80; order desk/API proxy on port 8080 | 192.168.0.12 | 2 GB | 2 |
| OnPrem-Linux-App | Ubuntu 24.04 LTS (Noble) | Tomcat 10.1 / OpenJDK 17, Java/JSP Contoso Order Desk on port 3000 | 192.168.0.13 | 2 GB | 2 |

All four guests run on an internal Hyper-V switch (`intSwitch`) with NAT on the `192.168.0.0/24` subnet. The host is reachable from the guests at `192.168.0.1`. Guest addresses are DHCP reservations, not static guest configuration, so their NICs can obtain Azure addresses after migration.

---

## 2. Architecture Decisions Record (ADR)

**Concept**

Every infrastructure choice in this lab was made deliberately. The table below documents the key decisions and their rationale — a practice you should carry into every production engagement.

| Decision | Choice | Rationale |
|---|---|---|
| **Host VM size** | `Standard_E8s_v7` | 8 enabled vCPUs and 64 GiB RAM provide room for the four workloads, host overhead and the 16 GB Azure Migrate appliance added in Module 1. A replacement must meet the same CPU and memory floor and support nested virtualization. |
| **Host image and security** | Windows Server 2022, x64 Gen 2, NVMe-compatible image, Standard security | Matches the default host's requirements for this nested Hyper-V lab. |
| **OS disk** | 512 GB Premium SSD | Holds the host OS, Hyper-V, base images, fixed workload VHDs and the appliance store partition. |
| **Guest disk type** | Fixed, not dynamic | Each Windows guest has a 40 GB VHD; each Linux guest has a 30 GB VHD. The 140 GB allocation is made during provisioning rather than growing as the workloads write. |
| **Guest memory** | Static: Windows 4 GB each; Linux 2 GB each | The four guests use 12 GB in total. Static memory gives the assessment a stable configuration to observe. |
| **Appliance storage** | 100 GB partition on the host OS disk, normally `E:` | This is an appliance store, not a separate managed data disk. Deployment selects the first free drive letter and creates an `Appliance` staging folder. |
| **Appliance delivery** | Import the published appliance in Module 1 | No appliance VM is created in this module. Retain the published Generation 1 appliance configuration unchanged; do not expand its disks manually. |
| **Guest network** | `192.168.0.0/24` with host NAT | Simulates an isolated on-premises network and provides guest outbound access through the host. This Hyper-V NAT is not an Azure NAT gateway. |
| **Azure network plan** | Source `10.0.0.0/16`; later target `10.1.0.0/16` and test `10.2.0.0/16` | Keeps source, target and test address spaces separate. No Azure NAT gateways are automatically built by the lab. |
| **Workload VM generation** | Gen 2 | The four source workloads use UEFI-based boot. Their generation is separate from the published Gen 1 appliance template. |
| **Deployment method** | PowerShell + managed Run Command | The script provisions the host and workloads through Azure's control plane. You then verify the results through the portal, Hyper-V Manager and application endpoints. |

---

## 3. Prerequisites

### 3.1 — Subscription Governance

**Concept**

Use a non-production subscription such as Dev/Test or Sandbox. Azure Policy can block VM creation, Standard security, disk export or NSG modification. Resource deployment requires Contributor permissions at the resource group scope; creating the new group and registering resource providers also require the appropriate subscription-level permissions.

**Student actions**

1. Select an authorized training subscription in the Azure portal.
2. Review your permissions and applicable policy before deploying.
3. Choose a **new, dedicated source resource group name** for this lab. Do not use a group containing unrelated resources.

**Expected result**

You have an authorized subscription, the required permissions, and a dedicated name for the source group that the deployment script will create.

### 3.2 — Quota Verification

**Concept**

The default source host needs **8 Azure vCPUs**. The four nested workloads and the appliance added later consume the host's resources; they are not separate Azure VM allocations. Regional vCPU quota, the selected VM family's quota and VM-count quota all matter. Deallocating an Azure VM does not release its vCPU quota.

The later target sizes `B2s` / `B2ms` / `B1ms` / `B1ms` require **6 vCPUs** for a complete four-VM set. Selecting `Standard_D2as_v5` for all four requires **8 vCPUs**. If full target and test sets coexist, allow **12** or **16 vCPUs**, respectively. You select and review the actual target sizes in the portal in later modules.

**Student actions — Azure portal**

1. Open the selected subscription's **Usage + quotas** view.
2. Review current regional and VM-family usage for the source region and `Standard_E8s_v7`, leaving room for the 8-vCPU host.
3. Review the different migration region separately for the planned target and test VM sizes and counts.
4. Request a quota increase or select another eligible region if the required headroom is unavailable.

**Expected result**

The reviewed quotas have room for the planned allocations. Quota and SKU availability are **not guarantees of capacity**; missing or denied quota information must not be treated as unused quota.

### 3.3 — Region Selection

**Concept**

Choose a source region for the Hyper-V host and a **different migration region** for the later target and test VMs. East US (`eastus`) as source and West US 2 (`westus2`) as target are examples only, subject to subscription access, policy, quota, SKU restrictions and actual capacity.

| Criterion | Guidance |
|---|---|
| **Proximity** | Choose a source region that gives practical RDP latency. |
| **Host availability** | Review availability of `Standard_E8s_v7` in your subscription and source region. |
| **Nested virtualization** | Review the selected series' documented nesting support, not just its CPU count. |
| **Replacement host** | At least 8 enabled vCPUs and 64 GiB RAM; nested virtualization, x64 Gen 2 and Premium SSD support. The image must also match the host's disk controller requirements, including NVMe for Esv7. |
| **Cost** | Compare pricing for the actual Windows host and region; do not assume one region is always cheapest. |

**Student actions**

1. Record the reviewed source region and different migration region.
2. Confirm that the selected source host size meets the requirements above. A two-vCPU target size such as `Standard_D2as_v5` is not a suitable replacement host.
3. Use the chosen source region explicitly as `-Location` in the deployment command. If using a reviewed replacement host, supply its exact name with `-VMSize`.

**Expected result**

You have a source region and host size suitable for nested Hyper-V, plus a separately reviewed migration region. The deployment checks the host's CPU/memory floor and quota and does not silently substitute a different size.

### 3.4 — Local Tooling

**Concept**

| Requirement | Details |
|---|---|
| **PowerShell** | PowerShell 7+ is recommended; Windows PowerShell 5.1 also works. Host commands run in elevated Windows PowerShell. |
| **Az PowerShell module** | Required for deployment; install it if missing in Step 2 below. |
| **RDP client** | Use an RDP client available for your workstation's operating system. |
| **Complete checkout** | Use the provided full Ubuntu 24.04 workshop ZIP or specified Git revision, not an application-only archive. |

**Student actions**

1. Make PowerShell and an RDP client available on your workstation.
2. Obtain the provided complete workshop package or Git revision, following Step 1 below.

**Expected result**

Your workstation can run the deployment commands and connect to the Windows host afterwards.

### 3.5 — Network Requirements

**Concept**

Your local network must allow outbound TCP 3389 to the host's Azure public IP. Deployment restricts inbound RDP to the single public IPv4 address you supply. A VPN or corporate network may change that internet-facing address.

Setup also needs HTTPS access to the Windows image and package sources, Ubuntu cloud images and archives, and the application's JDBC package source. The host and the appliance need outbound HTTPS for the appliance download and registration in Module 1. A lab VNet must not be assumed to provide outbound internet merely because it exists.

**Student actions**

1. Identify your current internet-facing IPv4 address using your approved network method.
2. Confirm that your network permits RDP and the required setup downloads. If RDP is blocked, arrange an approved Bastion or VPN access path before deployment; these can add cost.
3. Confirm that your use of the Windows images and other software meets your organization's licensing requirements.

**Expected result**

You have a permitted management path and access to the setup downloads. You can supply one public IPv4 address, optionally with `/32`, for the host's RDP rule.

---

## 4. Deployment Steps

### Step 1: Obtain the Provided Checkout

**Concept**

The deployment uses files from the complete checkout, including the host payload and packaged Contoso Order Desk application. Keep that directory structure intact.

**Student actions — local PowerShell**

1. Extract the provided full Ubuntu 24.04 workshop ZIP, or obtain the supplied Git repository at the specified revision.
2. Change to the checkout root, replacing the path below with its actual location.
3. Confirm that the deployment script is present.

```powershell
Set-Location '<path-to-complete-checkout>'
Get-Item .\scripts\deploy-lab.ps1
```

**Expected result**

The command lists `deploy-lab.ps1` under the checkout's `scripts` directory. Run the remaining local commands from this root.

### Step 2: Install Az PowerShell Module if Missing

**Concept**

The Az module supplies the Azure cmdlets used by the deployment.

**Student actions — local PowerShell**

1. Check whether Az is already installed.

```powershell
Get-Module -Name Az -ListAvailable
```

2. If no Az module is listed, install it for your current user, then repeat the check.

```powershell
Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -AllowClobber
Get-Module -Name Az -ListAvailable
```

**Expected result**

An installed Az version is listed. You do not need to reinstall it if it is already available.

### Step 3: Authenticate and Select the Subscription

**Concept**

Azure commands act on the active subscription. Select it explicitly before creating any resources. Provider registration must also be complete before the deployment starts.

**Student actions — local PowerShell and Azure portal**

1. Sign in, enter the chosen subscription ID, and set the active context.

```powershell
Connect-AzAccount
$secureSubscriptionId = Read-Host 'Workshop subscription ID' -AsSecureString
$subscriptionId = [pscredential]::new('subscription', $secureSubscriptionId).GetNetworkCredential().Password
Set-AzContext -SubscriptionId $subscriptionId
Get-AzContext | Select-Object Account, Subscription, Tenant
```

2. Compare the displayed subscription with the one reviewed in Section 3.
3. In that subscription's **Resource providers** view, register any of the following that are not already registered: `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.Migrate`, `Microsoft.OffAzure`, `Microsoft.RecoveryServices`, `Microsoft.KeyVault`.
4. Wait until each required provider shows **Registered** before continuing.

**Expected result**

The active subscription is correct and the required providers are registered. The subscription prompt masks entry only; the subscription ID still appears in Azure context and resource IDs.

### Step 4: Deploy the Lab Environment

**Concept**

Running `deploy-lab.ps1` is your deployment action. It creates the source host, networking and four workloads; you do not manually recreate those guests. The target landing zone is left for Module 2, and the appliance download and import are left for Module 1.

**Student actions — local PowerShell, checkout root**

1. Enter the new dedicated source resource group name and the reviewed source region.
2. Enter your public IPv4 address and a lab-only administrator password at the masked prompts.
3. Run the deployment command and follow its progress to completion.

```powershell
$sourceRg = Read-Host 'New dedicated source resource group name'
$location = Read-Host 'Reviewed source Azure region (for example eastus)'
$secureAdminCidr = Read-Host 'Your public IPv4 address, optionally with /32' -AsSecureString
$password = Read-Host 'Lab-only administrator password' -AsSecureString

.\scripts\deploy-lab.ps1 `
    -SubscriptionId $secureSubscriptionId `
    -ResourceGroupName $sourceRg `
    -Location $location `
    -AdminUsername 'labadmin' `
    -AdminPassword $password `
    -AdminSourceCidr $secureAdminCidr `
    -IncludeApplianceVhd No
```

> **Password requirements:** Use 12–72 characters with at least three of lowercase, uppercase, digit and symbol. Store the password securely for host and guest access. Never reuse a corporate password or put a password literal in the command.
>
> **RDP source:** Supply your current public IPv4 address as four decimal octets, optionally ending in `/32`. Wider ranges are refused. If your address later changes, update the existing NSG rule rather than redeploying.

#### What the Script Does

| Phase | What Happens |
|---|---|
| Infrastructure | Creates the source group, VNet, NSG, public IP, NIC and Windows HyperVHost. |
| Hyper-V installation | Installs Hyper-V and restarts the host. |
| Network setup | Creates `intSwitch`, host NAT and DHCP reservations for the guests. |
| Appliance storage | Creates the 100 GB appliance store partition on the host OS disk. No appliance VM is imported. |
| Guest provisioning | Creates the four fixed-disk guests and installs IIS, SQL Server, Nginx and the SQL-connected Tomcat order desk. |

**Expected result**

Deployment completes and prints the host's public IP. The source environment contains the four workloads listed in Section 1. Image downloads, fixed-disk allocation and workload installation can take substantial time; duration varies with network and Azure performance. Do not interrupt a progressing deployment merely because a stage is slow.

Detailed setup progress is recorded at `C:\AzMigrateLab\setup-log.txt` on the host. An interrupted, incomplete source build can sometimes be resumed as described in [Troubleshooting](#6-troubleshooting); this is not permission to replay setup after a completed build or cutover.

### Step 5: Connect to the Hyper-V Host

**Concept**

The script provisions the environment; your portal and RDP checks confirm that you can use it.

**Student actions — Azure portal, then RDP**

1. Open **HyperVHost** in the source resource group. Confirm that its power state is **Running** and obtain its public IP. This is your host power checkpoint.
2. Open your RDP client and connect to that IP on port 3389.
3. Sign in as **`labadmin`**, or the administrator name you supplied, using the password entered in Step 4.
4. Inside HyperVHost, open **Windows PowerShell as administrator** for the next section.

If you need to retrieve the public IP from your local PowerShell session instead:

```powershell
Get-AzPublicIpAddress -ResourceGroupName $sourceRg | Select-Object Name, IpAddress
```

**Expected result**

You have a working RDP session to the running host and an elevated PowerShell window inside it.

---

## 5. Verification

**Concept**

Verification goes beyond "can I ping it?" — confirm that the environment matches the intended architecture and that every workload is functional. Use the host for the private guest addresses below; they are not public endpoints.

### 5.1 — Verify Hyper-V Infrastructure

**Concept**

Hyper-V Manager shows the nested workload inventory. Check guest power state here rather than treating Azure host availability as proof that the guests are running.

**Student actions — inside HyperVHost**

1. Open **Hyper-V Manager** and confirm that all four workload guests are listed and running.
2. In elevated Windows PowerShell, display their state, processor count and assigned memory.

```powershell
Get-VM | Select-Object Name, State, ProcessorCount, MemoryAssigned
```

**Expected result**

| VM Name | Expected State | Memory | vCPUs |
|---|---|---|---|
| OnPrem-Web | Running | 4096 MB | 2 |
| OnPrem-SQL | Running | 4096 MB | 2 |
| OnPrem-Linux-Web | Running | 2048 MB | 2 |
| OnPrem-Linux-App | Running | 2048 MB | 2 |

`MemoryAssigned` is displayed in bytes. No appliance VM is expected yet.

If you need a guest console, use **Connect** in Hyper-V Manager. Windows guests use `Administrator`; Linux guests use the deployment username, normally `labadmin`. Both use the lab password supplied during deployment.

### 5.2 — Network and Appliance Storage

**Concept**

The host reaches the workloads over `intSwitch`. The separate appliance store partition reserves staging space for Module 1, but its nominal size does not guarantee that every appliance package and imported copy will fit.

**Student actions — elevated Windows PowerShell inside HyperVHost**

1. Find the appliance store and check its actual free space.

```powershell
Get-Volume -FileSystemLabel ApplianceStore |
    Select-Object DriveLetter, FileSystemLabel, Size, SizeRemaining
```

2. Record the actual drive letter and free space. Keep at least **30 GB free** for downloading and extracting the source archive, then review the actual additional import/copy headroom in Module 1 before importing.
3. Optionally, confirm the internal switch with this single check.

```powershell
Get-VMSwitch -Name intSwitch | Select-Object Name, SwitchType
```

**Expected result**

The appliance store is approximately 100 GB, normally `E:`, with the required staging space free. It is a partition on the OS disk, not an additional managed data disk. The optional switch check shows `intSwitch` with `SwitchType` **Internal**.

### 5.3 — Workload Readiness

**Concept**

The order desk is a Java/JSP application backed by SQL Server. `/api/health` proves Tomcat liveness only; `/api/ready` checks SQL access. `/api/orders` reads application data, while submitting an order writes to SQL.

**Student actions — browser and elevated Windows PowerShell inside HyperVHost**

1. Open each URL below in the host's browser and inspect the page.

| URL | Expected Page |
|---|---|
| `http://192.168.0.10` | IIS static sample site |
| `http://192.168.0.12` | Nginx static sample site |
| `http://192.168.0.13:3000` | Contoso Order Desk |

2. Check liveness, SQL readiness, one application-data read and the Nginx API proxy.

```powershell
Invoke-RestMethod http://192.168.0.13:3000/api/health
Invoke-RestMethod http://192.168.0.13:3000/api/ready
Invoke-RestMethod http://192.168.0.13:3000/api/orders
Invoke-RestMethod http://192.168.0.12:8080/api/ready
```

3. Observe the returned customers and recent orders. Do not require a fixed row count; activity can add orders.
4. Optionally, open `http://192.168.0.12:8080` in the browser, select an existing customer and submit one sample order using the form. Refresh the desk and compare the new order with what you observed before submitting it. This generates manual business activity without installing a background generator.

**Expected result**

The three pages load. The health endpoint returns `healthy`; both readiness requests return `ready`; the orders request returns existing application data. An optional submitted order appears in the desk. SQL readiness and the data read already exercise the database connection, so a separate SQL query is not required.

### 5.4 — Architecture Validation Checklist

**Concept**

Use your observations above to decide whether the source lab is ready for discovery. Do not repeat the checks solely to complete this checklist.

**Student actions**

1. Mark the results you have observed.

- [ ] HyperVHost is running and accessible through RDP.
- [ ] All four workload guests are running in Hyper-V Manager.
- [ ] The appliance store is available, its drive letter is recorded, and staging free space has been checked.
- [ ] IIS, Nginx and the Tomcat order desk respond.
- [ ] SQL readiness succeeds directly and through the Nginx proxy, and existing application data is readable.

**Expected result**

All items are complete before starting Module 1. The appliance itself is still to be imported there.

### 5.5 — Review Setup Logs if Needed

**Concept**

The setup log records provisioning progress and errors. It is a recovery aid, not an additional required audit after successful verification.

**Student actions — elevated Windows PowerShell inside HyperVHost, only if a check fails**

1. Read the recent setup entries and identify the failed workload or stage.

```powershell
Get-Content C:\AzMigrateLab\setup-log.txt -Tail 50
```

**Expected result**

You can identify the relevant setup stage or error before using the short recovery guidance below. Keep credentials and private configuration out of shared output.

---

## 6. Troubleshooting

### Quota or Host Size Rejected

**Concept:** Regional quota, family quota, SKU restrictions and host requirements are separate constraints. Deallocation does not release vCPU quota.

**Student actions**

1. Read the deployment error and compare it with the selected region, size and quotas from Section 3.
2. Request the needed quota or choose an eligible region and host meeting the 8-enabled-vCPU / 64-GiB floor and nested virtualization requirements.

**Expected result:** The reported pre-deployment constraint is resolved. No region or quota increase guarantees allocation capacity.

### Cannot RDP to HyperVHost

**Concept:** RDP requires an allowed client address, a permitted network path and the lab credentials.

**Student actions**

1. Check that you are using the public IP from Step 5 and the administrator credentials from deployment.
2. In the portal, review the existing **Allow-RDP** rule. If your public IPv4 address changed, update its source to your current single `/32`; do not broaden it to the internet.
3. If your network blocks RDP, use the approved access alternative from Section 3.5.

**Expected result:** You can open the host desktop without redeploying the lab.

### Workloads Not Ready or Setup Incomplete

**Concept:** A running guest is not proof that its application has finished provisioning. Readiness can also fail when SQL is unavailable.

**Student actions — inside HyperVHost**

1. Review the setup log and allow an active installation to finish before retrying the failed application check.
2. If a guest is off after setup has finished, select it in Hyper-V Manager and choose **Start**. If it cannot start, review host memory and disk space rather than creating a duplicate guest.
3. Only if SQL readiness fails, optionally test the database port from the host: `Test-NetConnection 192.168.0.11 -Port 1433`. A successful port test does not replace the application readiness check.
4. For a **confirmed failed, incomplete source deployment**, correct the reported cause before rerunning the same deployment command with the same source resource group. The script can reuse that incomplete build and rebuild unfinished guests. Do not rerun merely because client monitoring stopped, and never rerun deployment after successful provisioning or cutover.

**Expected result:** The original workloads run and the failed readiness or data-read check succeeds before you continue.

---

## 7. Security Baseline

**Concept**

This section documents the security posture of the lab environment and highlights what you would do differently in production.

### 7.1 — Network Security Group (NSG) Rules

Deployment creates the following inbound rule on the source host's NSG:

| Priority | Name | Direction | Protocol | Source | Destination | Port | Action |
|---|---|---|---|---|---|---|---|
| 100 | Allow-RDP | Inbound | TCP | Your single public IPv4 `/32` | `*` | 3389 | Allow |

The host still has a public management endpoint, even though its source is restricted. Do not change the source to `*`. The nested guests are behind host NAT rather than exposed directly to the internet.

Guest firewall settings trust the lab's nested, source, target and test ranges; Linux `ufw` is disabled for the lab. Those settings travel with migrated guests. They are not a production firewall baseline.

### 7.2 — Production Alternatives for Remote Access

| Approach | How It Works | When to Use |
|---|---|---|
| **Azure Bastion** | RDP/SSH over HTTPS without a public IP on the VM. | Private management access. |
| **JIT VM access** | Microsoft Defender for Cloud opens NSG ports on demand for a limited window. | Time-bounded direct management access. |
| **VPN gateway** | Site-to-site or point-to-site VPN, reaching VMs by private IP. | Persistent network-level connectivity. |
| **Restrict NSG source** | Allowlist a specific public address, as this lab does. | Direct access from a known client address. |

### 7.3 — Credential Management

| Lab Approach | Risk | Production Alternative |
|---|---|---|
| One lab password for the host and guests | Credential reuse across machines. | Unique credentials and managed rotation. |
| Masked `Read-Host` entry and a `SecureString` deployment parameter | Avoids a plaintext password literal in command history, but does not remove secrets from provisioning or the running environment. | Approved secret storage such as Azure Key Vault. |
| Windows unattended setup and Linux cloud-init | Privileged users can access sensitive provisioning material. | Managed identity and authentication designs appropriate to the platform. |
| Tomcat SQL credentials in protected JNDI configuration | The application still requires a database credential. | Managed or integrated authentication where supported. Do not dump the lab credential configuration or weaken its permissions. |

### 7.4 — Principle of Least Privilege

Use only the training permissions needed for this exercise. In production:

- Create custom RBAC roles scoped to required operations.
- Use managed identities rather than service principal secrets for automated deployments.
- Apply resource locks to protect critical resources from accidental deletion.

---

## 8. Cost Analysis

**Concept**

Understanding the cost profile is essential for planning a lab budget. Estimates vary by region, agreement, operating-system licensing and resource lifetime; use current pricing for your selected resources rather than a fixed workshop price.

### 8.1 — Cost Breakdown

| Resource | SKU / Tier | Cost Consideration |
|---|---|---|
| Host VM compute | `Standard_E8s_v7`, Windows Server | Charged while allocated; deallocation stops host compute charges. |
| OS disk | 512 GB Premium SSD | Billed while retained, including when the host is deallocated. The appliance store is part of this disk. |
| Public IP | Standard, static | May continue billing while retained. |
| Networking | Data transfer and any separately chosen access services | Depends on usage and access design. |
| Later migration resources | Target/test VMs, disks and migration storage | Additional to the source lab; include them in the overall budget. |

The four nested guests and the appliance imported in Module 1 do not incur separate Azure VM compute charges. They consume the source host's CPU, memory and OS-disk capacity.

### 8.2 — Cost Optimization Tips

**Concept**

Compute deallocation and resource deletion have different effects on the bill.

| Tip | Effect |
|---|---|
| **Deallocate when not in use.** | Stops host compute charges, but not retained disk or public-IP charges. |
| **Set auto-shutdown.** | Helps avoid leaving the host allocated overnight; choose a time that will not interrupt the lab. |
| **Use eligible Dev/Test pricing.** | May reduce Windows compute cost, depending on your agreement. |
| **Delete lab resources when finished.** | Remove only the dedicated resources you no longer need, following the later cleanup steps. |
| **Compare regions and set a budget alert.** | Makes costs visible; an alert is not a spending cap. |

**Student actions — Azure portal**

1. Review the estimated cost of the selected host, disk and access services, and set a lab budget alert.
2. If pausing rather than continuing to Module 1, save your work and stop/deallocate HyperVHost through the portal. Start it again before continuing the lab.

**Expected result**

You understand which resources keep billing during a pause. Deallocation is not deletion and does not release VM quota.

### 8.3 — Comparison to Real Migration Lab Costs

| Component | This Workshop | Production Migration Lab |
|---|---|---|
| Source environment | One Azure host with four nested workloads | Dedicated VMs or physical servers per workload |
| Azure Migrate appliance | Published appliance imported on the nested host in Module 1 | Appliance hosted on source infrastructure |
| Replication storage | Lab-scale migration storage | Storage sized for production replication and retention |
| Target VMs | Created during later migration modules | Sized for production workload requirements |
| Additional networking | No automatically deployed Azure NAT gateway | Explicit egress and management design, potentially including firewall, VPN or ExpressRoute |

---

## Next Steps

Your simulated on-premises datacenter is operational and verified. It represents a mixed-workload estate: Windows web and database servers, a Linux web server and a Linux Java application server.

Proceed to:

➡️ **[Module 1: Discovery and Assessment with Azure Migrate](Module-1-Discovery.md)** — import the published appliance, discover the workloads, confirm the discovered guest operating systems and generate migration readiness assessments.

### Further Reading

- [Azure Landing Zones](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/)
- [Esv7 series specifications](https://learn.microsoft.com/azure/virtual-machines/sizes/memory-optimized/esv7-series)
- [Azure VM quotas](https://learn.microsoft.com/en-us/azure/virtual-machines/quotas)
- [Azure Bastion overview](https://learn.microsoft.com/azure/bastion/bastion-overview)
- [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/)
