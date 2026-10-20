# Module 0 · Setup

**TD SYNNEX | Cloud Enablement Services**

> **DRAFT PILOT—NOT LIVE VALIDATED · 2026-10-17.** Read [PILOT-README](../PILOT-README.md) first. This separate pilot teaches two replication methods and one planned four-VM final cutover. Existing labs, registered appliances, and protected VMs are not reusable pilot sources.

In this module you build the on-premises environment that the rest of the workshop migrates: one Azure VM running Hyper-V, with four nested guest VMs standing in for a small business's servers. A single script provisions all of it, and you finish by verifying that every workload actually responds.

**Where to run:** Run the Azure commands from your own workstation or PowerShell Cloud Shell. Run the Hyper-V commands in an elevated Windows PowerShell session **inside HyperVHost**, the host VM you are about to create.

---

## 1. Module Overview

In a real migration engagement this phase corresponds to **preparing the landing zone** — the target Azure environment that will host migrated workloads. Enterprise projects use [Azure Landing Zones](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/) with management groups, policy-driven governance, hub-spoke networking and identity integration. That level of infrastructure is out of scope for a hands-on migration lab.

Instead, this module deploys a **self-contained simulation of an on-premises datacenter** inside a single Azure VM using nested Hyper-V virtualization. The host VM, virtual networking and all four guest workloads are provisioned by `deploy-lab.ps1`. You do not create the four guests individually. You connect through RDP afterwards to complete the manual verification.

**Why this approach?** It gives every participant an isolated, reproducible "datacenter" with realistic workloads (IIS, SQL Server, Nginx, Tomcat) while keeping cost and complexity low. The trade-off is that it does not exercise subscription-level governance, which you would address through Azure Landing Zones in a production engagement.

This will serve as the **source environment**. You will build the destination landing zone, which will be our target network, manually in Module 2, in a migration region different from the source region.

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

Every infrastructure choice in this lab was made deliberately. The table below documents the key decisions and their rationale — a practice you should carry into every production engagement.

| Decision | Choice | Rationale |
|---|---|---|
| **Host VM size** | `Standard_E8s_v7` | 8 vCPUs, 64 GiB RAM. The Esv7 series is memory-optimized and supports nested virtualization. The four guests consume 12 GB, leaving room for the host OS, Hyper-V overhead, disk caching and the 16 GB Azure Migrate appliance added in Module 1. Smaller sizes such as `Standard_E4s_v7` support nesting but have only 32 GiB, which is too tight once the appliance is running. A replacement host must meet the same 8-vCPU / 64-GiB floor and support nested virtualization. |
| **Host image and security** | Windows Server 2022, x64 Gen 2, NVMe-compatible image, Standard security | Matches the default host's requirements for this nested Hyper-V lab. The Esv7 series requires an image that supports its NVMe disk controller. |
| **OS disk** | 512 GB Premium SSD | One disk holds the host OS, the Hyper-V role, the base images, 140 GB of fixed guest VHDs and a dedicated appliance partition. Premium SSD provides the IOPS needed when four guests perform simultaneous disk I/O; Standard SSD works but adds noticeable latency during guest provisioning and to the fixed-disk allocation below. |
| **Guest disk type** | Fixed, not dynamic | Each guest VHD is allocated in full at creation: 40 GB for each Windows guest and 30 GB for each Linux guest, 140 GB in total. Host capacity is therefore known from the start and does not shift under the workshop as guests write. A dynamic disk also expands on write, and that write amplification appears as erratic disk I/O in the Module 1 performance-based assessment. The cost is deployment time — see Section 4. |
| **Guest memory** | Static, not dynamic | Fixed startup memory with dynamic memory disabled, for the same reason: the assessment should observe a stable machine, not one whose memory the hypervisor is resizing. The four guests use 12 GB in total. |
| **Appliance storage** | Dedicated 100 GB partition on the OS disk, first free drive letter (normally `E:`) | A separate managed data disk would bill continuously — including while the VM is deallocated — for capacity the 512 GB OS disk already has spare. Deployment instead carves a 100 GB partition from that disk, which the guest VHDs never touch, so the appliance cannot be starved by guest growth and vice versa. Deployment also creates an `Appliance` staging folder on it. |
| **Appliance delivery** | Import the published appliance in Module 1 | Deployment does not pre-build an appliance VM. Microsoft publishes a ready-made appliance, so importing it is both closer to real practice and avoids provisioning a Windows guest that is immediately replaced. Retain the published Generation 1 appliance configuration unchanged; do not expand its disks manually. |
| **Guest network** | `192.168.0.0/24` with host NAT | Simulates an isolated on-premises network. NAT provides outbound internet access, required for package downloads during provisioning, without exposing guests to inbound traffic from the Azure VNet. This mirrors how many on-premises datacenters sit behind NAT with no direct internet-facing exposure. This Hyper-V NAT is not an Azure NAT gateway. |
| **Azure network plan** | Source `10.0.0.0/16`; later target `10.1.0.0/16` and test `10.2.0.0/16` | Keeps source, target and test address spaces separate. No Azure NAT gateways are automatically built by the lab. |
| **VM generation** | Gen 2 | UEFI boot, vTPM support and larger OS disk support. Gen 2 is required for several Azure features post-migration (Trusted Launch, Confidential VMs), so starting here avoids a generation conversion later. This applies to the four workloads; the published appliance template is Gen 1 and is a separate choice. |
| **Windows guest memory** | 4 GB | SQL Server 2022 Express recommends a minimum of 2 GB; with Windows Server overhead, 4 GB is the practical minimum. IIS is lighter, but keeping both Windows guests at 4 GB simplifies the configuration. |
| **Linux guest memory** | 2 GB | Nginx is lightweight. The Tomcat order desk uses a 384-MB maximum JVM heap, bounded request threads and JDBC pool, and a 900-MB service memory limit. 2 GB fits these sample workloads and keeps total guest memory within budget. |
| **Deployment method** | PowerShell + managed Run Command | No ARM templates or Bicep — the deployment is imperative PowerShell. Managed Run Command executes the host payload through the Azure VM agent over the secure control plane, which means no RDP session is needed during setup, and it supports long timeouts and protected parameters. You then verify the results through the portal, Hyper-V Manager and application endpoints. |
| **Guest firewall posture** | Trusted lab ranges | The nested subnet and the source, target and test VNets are treated as trusted so ping, validation and application traffic work without a rule per service. Linux `ufw` is disabled for the lab. These settings travel with migrated guests and are not a production firewall baseline; see Section 8. |

---

## 3. Prerequisites

### 3.1 — Subscription Governance

Use a non-production subscription such as Dev/Test or Sandbox. Azure Policy can block VM creation, Standard security, disk export or NSG modification. Resource deployment requires Contributor permissions at the resource group scope; creating the new group and registering resource providers also require the appropriate subscription-level permissions.

#### Hands-On Steps

**Local workstation — Azure portal:**

1.  Select an authorized training subscription.

2.  Review your permissions and applicable policy before deploying.

3.  Choose a **new, dedicated source resource group name** for this lab.

    Do not use a group containing unrelated resources.

**Expected Result:** You have an authorized subscription, the required permissions, and a dedicated name for the source group that the deployment script will create.

### 3.2 — Quota Verification

The default source host needs **8 Azure vCPUs**. The four nested workloads and the appliance added later consume the host's resources; they are not separate Azure VM allocations. Regional vCPU quota, the selected VM family's quota and VM-count quota all matter. Deallocating an Azure VM does not release its vCPU quota.

The inherited `B2s` / `B2ms` / `B1ms` / `B1ms` examples total **6 vCPUs**; an all-four two-vCPU example totals **8**. These are **not pilot-approved sizes**. In particular, all actual source guests have two vCPUs, so the one-vCPU Linux examples require manual support/downsize review. Calculate actual target/test quota from the approved per-role selections and overlap; do not infer them from the unchanged script menus. Plan the separately approved replication-appliance hosting allocation independently.

You can review quota in the portal or with PowerShell. Use either method.

#### Hands-On Steps

**Local workstation — Azure portal:**

1.  Open the selected subscription's **Usage + quotas** view.

2.  Review current regional and VM-family usage for the source region and `Standard_E8s_v7`.

    Leave room for the 8-vCPU host.

3.  Review the different migration region separately for the planned target and test VM sizes and counts.

4.  If the required headroom is unavailable, request a quota increase or select another eligible region.

**Local workstation — PowerShell (alternative to the portal view):**

This check requires the Az module and an Azure sign-in (Section 4, Steps 2 and 3).

5.  Run the regional vCPU check and enter the source region when prompted.

    ```powershell
    $quotaRegion = Read-Host 'Region to check (for example eastus)'
    Get-AzVMUsage -Location $quotaRegion |
        Where-Object { $_.Name.LocalizedValue -eq 'Total Regional vCPUs' } |
        Select-Object @{N='Quota';E={$_.Name.LocalizedValue}}, CurrentValue, Limit
    ```

6.  Run the same check again for the migration region.

7.  Subtract `CurrentValue` from `Limit` to find the regional vCPU headroom.

    Usage includes allocated and deallocated VMs.

**Expected Result:** The reviewed quotas have room for the planned allocations. Quota and SKU availability are **not guarantees of capacity**; missing or denied quota information must not be treated as unused quota.

### 3.3 — Region Selection

Choose a source region for the Hyper-V host and a **different migration region** for the later target and test VMs. East US (`eastus`) as source and West US 2 (`westus2`) as target are examples only, subject to subscription access, policy, quota, SKU restrictions and actual capacity.

| Criterion | Guidance |
|---|---|
| **Proximity** | Choose a source region that gives practical RDP latency. |
| **Host availability** | Review availability of `Standard_E8s_v7` in your subscription and source region. |
| **Nested virtualization** | Review the selected series' documented nesting support, not just its CPU count. |
| **Replacement host** | At least 8 enabled vCPUs and 64 GiB RAM; nested virtualization, x64 Gen 2 and Premium SSD support. The image must also match the host's disk controller requirements, including NVMe for Esv7. |
| **Cost** | Compare pricing for the actual Windows host and region; do not assume one region is always cheapest. |

#### Hands-On Steps

**Local workstation — lab notes:**

1.  Record the reviewed source region.

2.  Record the different migration region.

3.  Confirm that the selected source host size meets the requirements above.

    A two-vCPU target size such as `Standard_D2as_v5` is not a suitable replacement host.

4.  Plan to use the chosen source region explicitly as `-Location` in the deployment command.

5.  If using a reviewed replacement host, plan to supply its exact name with `-VMSize`.

**Expected Result:** You have a source region and host size suitable for nested Hyper-V, plus a separately reviewed migration region. The deployment checks the host's CPU/memory floor and quota and does not silently substitute a different size.

### 3.4 — Local Tooling

| Requirement | Details |
|---|---|
| **PowerShell** | PowerShell 7+ is recommended; Windows PowerShell 5.1 also works. Host commands run in elevated Windows PowerShell. |
| **Az PowerShell module** | Required for deployment; install it if missing in Step 2 below. |
| **RDP client** | Use an RDP client available for your workstation's operating system. |
| **Complete checkout** | Use the provided full Ubuntu 24.04 workshop ZIP or specified Git revision, not an application-only archive. |

#### Hands-On Steps

**Local workstation:**

1.  Make PowerShell available on your workstation.

2.  Make an RDP client available on your workstation.

3.  Obtain the provided complete workshop package or Git revision, following Step 1 below.

**Expected Result:** Your workstation can run the deployment commands and connect to the Windows host afterwards.

### 3.5 — Network Requirements

Your local network must allow outbound TCP 3389 to the host's Azure public IP. Deployment restricts inbound RDP to the single public IPv4 address you supply. A VPN or corporate network may change that internet-facing address.

Setup also needs HTTPS access to the Windows image and package sources, Ubuntu cloud images and archives, and the application's JDBC package source. The host and the appliance need outbound HTTPS for the appliance download and registration in Module 1. A lab VNet must not be assumed to provide outbound internet merely because it exists.

#### Hands-On Steps

**Local workstation:**

1.  Identify your current internet-facing IPv4 address using your approved network method.

2.  Confirm that your network permits RDP.

    If RDP is blocked, arrange an approved Bastion or VPN access path before deployment; these can add cost.

3.  Confirm that your network permits the required setup downloads.

4.  Confirm that your use of the Windows images and other software meets your organization's licensing requirements.

**Expected Result:** You have a permitted management path and access to the setup downloads. You can supply one public IPv4 address, optionally with `/32`, for the host's RDP rule.

### 3.6 — Isolated Two-Method Pilot Gate

The unchanged deployment builds the source lab and reserves storage for the **Module 1 discovery appliance only**. It does not provide Module 3's additional modern replication appliance. The 8-vCPU / 64-GB host has a **512-GB OS disk**, including guests and its 100-GB ApplianceStore partition: that is not capacity for an additional appliance needing a separate 620-GB data disk. Do not resize the host, repartition it, shrink workload disks, or alter deployment scripts for this pilot.

#### Hands-On Steps

**Local workstation — student notes:**

1.  Choose a unique pilot namespace for new source, project, target, and test resources.

2.  Deploy a fresh source resource group and host using the unchanged command below, supplying your new source group name.

    Keep the four guest names exactly as listed in Section 1, on this separate host. Their VM IDs must be new. Do not reuse, clone, or dual-protect previously replicated source VMs, or clone an already registered discovery/replication appliance. Clearing existing bindings is not verified by this documentation; prefer a clean deployment instead.

3.  Record the new source host resource ID and the four new Hyper-V VM IDs before registration.

4.  Reserve separate, approved hosting for the **modern Windows Server 2022 replication appliance** in Module 3: at least 8 CPUs, 16 GB memory, 80-GB OS disk, and separate 620-GB data disk, subject to the current support and sizing review.

5.  Record its actual machine/hosting identity, storage free space, licensing, source-guest connectivity, outbound path, permissions, capacity, and cost approval.

    **STOP before Module 3 appliance deployment if any value is unverified.** Do not count the existing host partition twice, assume the minimum is a larger 16-CPU/32-GB tier, use `MigrateAppl`, or make a workload VM its own replication appliance. Additional capacity is separately reviewed and manually provisioned; this document does not deploy it.

6.  Review the actual target sizes and test/target overlap in Modules 2–3. Historical B1/B2 examples are not pilot-approved choices: all four sources have two vCPUs. Resolve any downsizing or support conflict manually; neither an assessment recommendation nor a script menu reserves capacity.

7.  Before **either** method enables protection, obtain owner verification of the intended project, provider/appliance registrations, Migrate-managed vault associations and **current mixed-method compatibility**.

    This is **UNKNOWN / STOP** in this documentation-only pilot. Do not force both methods into a shared vault, declare them incompatible, silently create separate projects, guess a blank vault ID, or patch bindings/scripts. Any required architecture change is separately approved owner work.

**Expected Result:** A separate pilot scope is recorded, and the extra appliance capacity is either explicitly approved or marked **DEFERRED / STOP**.

**CSA Why:** Two replication methods need separate supported components and identities; spare memory does not create the additional appliance's required disk capacity.

---

## 4. Deployment Steps

### Step 1: Obtain the Workshop Files

The deployment uses files from the complete checkout, including the host payload and packaged Contoso Order Desk application. Use **one** of the two options below to place the files on your workstation, and keep the directory structure intact.

#### Hands-On Steps — Option A: Clone the Repository (requires Git)

**Local workstation — PowerShell:**

1.  Clone the supplied repository, replacing `<repository-URL>` with the URL you were given.

    ```powershell
    git clone <repository-URL> azure-migrate-workshop
    ```

2.  Change to the cloned folder.

    ```powershell
    Set-Location .\azure-migrate-workshop
    ```

3.  If a specific revision was supplied, check it out.

    ```powershell
    git checkout <specified-revision>
    ```

#### Hands-On Steps — Option B: Download and Extract the ZIP

**Local workstation — browser:**

1.  Download the provided full Ubuntu 24.04 workshop ZIP to your workstation, or use the repository's **Download ZIP** option.

**Local workstation — PowerShell:**

2.  Extract the ZIP to a local folder, replacing the paths below with their actual locations.

    ```powershell
    Expand-Archive -Path '<path-to-downloaded-zip>' -DestinationPath '<path-to-extract-folder>'
    ```

3.  Change to the extracted checkout root.

    ```powershell
    Set-Location '<path-to-complete-checkout>'
    ```

#### Hands-On Steps — Both Options

**Local workstation — PowerShell:**

1.  Confirm that the deployment script is present.

    ```powershell
    Get-Item .\scripts\deploy-lab.ps1
    ```

**Expected Result:** The command lists `deploy-lab.ps1` under the checkout's `scripts` directory. Run the remaining local commands from this root.

### Step 2: Install Az PowerShell Module if Missing

The Az module supplies the Azure cmdlets used by the deployment.

#### Hands-On Steps

**Local workstation — PowerShell:**

1.  Check whether Az is already installed.

    ```powershell
    Get-Module -Name Az -ListAvailable
    ```

2.  If no Az module is listed, install it for your current user.

    ```powershell
    Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -AllowClobber
    ```

3.  Repeat the check.

    ```powershell
    Get-Module -Name Az -ListAvailable
    ```

**Expected Result:** An installed Az version is listed. You do not need to reinstall it if it is already available.

### Step 3: Authenticate and Select the Subscription

Azure commands act on the active subscription. Select it explicitly before creating any resources. Provider registration must also be complete before the deployment starts.

#### Hands-On Steps

**Local workstation — PowerShell:**

1.  Sign in to Azure.

    ```powershell
    Connect-AzAccount
    ```

2.  Enter the chosen subscription ID at the masked prompt.

    ```powershell
    $secureSubscriptionId = Read-Host 'Workshop subscription ID' -AsSecureString
    $subscriptionId = [pscredential]::new('subscription', $secureSubscriptionId).GetNetworkCredential().Password
    ```

3.  Set the active context and display it.

    ```powershell
    Set-AzContext -SubscriptionId $subscriptionId
    Get-AzContext | Select-Object Account, Subscription, Tenant
    ```

4.  Compare the displayed subscription with the one reviewed in Section 3.

**Local workstation — Azure portal:**

5.  Open the subscription's **Resource providers** view.

6.  Register any of the following that are not already registered: `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.Migrate`, `Microsoft.OffAzure`, `Microsoft.RecoveryServices` and `Microsoft.KeyVault`.

7.  Wait until each required provider shows **Registered**.

**Expected Result:** The active subscription is correct and the required providers are registered. The subscription prompt masks entry only; the subscription ID still appears in Azure context and resource IDs.

### Step 4: Deploy the Lab Environment

Running `deploy-lab.ps1` is your deployment action. It creates the source host, networking and four workloads; you do not manually recreate those guests. The target landing zone is left for Module 2, and the appliance download and import are left for Module 1.

#### Values You Decide in This Step

| Variable | Lab example | Script parameter | What it is used for |
|---|---|---|---|
| `$sourceRg` | `rg-ces-source-01` | `-ResourceGroupName` | The new, dedicated **source** resource group. Deployment creates it and places HyperVHost, its VNet, NSG, public IP and NIC in it. In Module 1 you also create the Azure Migrate project in this group. |
| `$targetRg` | `rg-ces-target-01` | None — not used by the deployment script | The name of the **target** resource group for the destination landing zone. Record it now; you create it in the portal in Module 2, in your migration region, and the migrated VMs are placed in it. |
| `$location` | `eastus` | `-Location` | The reviewed **source** Azure region from Section 3.3, where HyperVHost runs. It must differ from your migration region. If not supplied, the script uses `eastus`. |
| `$secureAdminCidr` | `203.0.113.14` (documentation example address) | `-AdminSourceCidr` | Your current public IPv4 address. Deployment allows inbound RDP to HyperVHost from this single address only. |
| `$password` | None — choose your own lab-only password | `-AdminPassword` | The administrator password for HyperVHost and all four guest VMs. |
| Administrator username (fixed) | `labadmin` | `-AdminUsername` | The sign-in name for HyperVHost and the Linux guests. Windows guests use `Administrator` with the same password. |

You enter these values either at the script's own prompts (Option A) or as variables passed to the script (Option B). Admin username is not a variable in Option B; the command supplies `labadmin` directly.

> **Password requirements:** Use 12–72 characters with at least three of lowercase, uppercase, digit and symbol. Store the password securely for host and guest access. Never reuse a corporate password or put a password literal in the command.

Choose **one** of the two options below.

#### Hands-On Steps — Option A: Run the Script and Answer Its Prompts

**Local workstation — PowerShell, checkout root:**

1.  Run the deployment script without parameters.

    ```powershell
    .\scripts\deploy-lab.ps1
    ```

2.  When PowerShell displays **Supply values for the following parameters:**, answer each prompt in the order below.

    Masked prompts do not show what you type, so check each entry before pressing Enter.

> **Region:** Option A does not prompt for the region. Without `-Location`, the script deploys to `eastus`. If your reviewed source region is different, run `.\scripts\deploy-lab.ps1 -Location <your-source-region>` instead; the remaining prompts are the same.

##### Prompt 1: SubscriptionId

3.  Enter the workshop subscription ID reviewed in Section 3.

    The entry is masked.

##### Prompt 2: ResourceGroupName

4.  Enter the new dedicated source resource group name, for example `rg-ces-source-01`.

##### Prompt 3: AdminUsername

5.  Enter `labadmin`.

##### Prompt 4: AdminPassword

6.  Enter a lab-only password that meets the password requirements above.

    The entry is masked.

##### Prompt 5: AdminSourceCidr

7.  Enter your public IPv4 address.

    The entry is masked.

> **RDP source:** Supply your current public IPv4 address as four decimal octets, optionally ending in `/32`. Wider ranges are refused. If your address later changes, update the existing NSG rule rather than redeploying.

##### Prompt 6: Stage the Azure Migrate Appliance VHD

8.  When asked **Stage the Azure Migrate appliance VHD on the host during deployment?**, answer **No** or press Enter.

    Module 1 downloads the appliance when it is needed.

9.  Follow the deployment's progress to completion.

#### Hands-On Steps — Option B: Run the Script with Trailing Parameters

Instead of answering the prompts, you can set the values as variables first and pass them to the script as parameters. This also lets you set the source region with `-Location` and answers the appliance VHD question with `-IncludeApplianceVhd No`. `$secureSubscriptionId` was created in Step 3 and is reused here.

**Local workstation — PowerShell, checkout root:**

1.  Set the variables, entering the values from the table above.

    ```powershell
    $sourceRg = Read-Host 'New dedicated source resource group name'
    $location = Read-Host 'Reviewed source Azure region (for example eastus)'
    $secureAdminCidr = Read-Host 'Your public IPv4 address, optionally with /32' -AsSecureString
    $password = Read-Host 'Lab-only administrator password' -AsSecureString
    ```

2.  Run the deployment command.

    ```powershell
    .\scripts\deploy-lab.ps1 `
        -SubscriptionId $secureSubscriptionId `
        -ResourceGroupName $sourceRg `
        -Location $location `
        -AdminUsername 'labadmin' `
        -AdminPassword $password `
        -AdminSourceCidr $secureAdminCidr `
        -IncludeApplianceVhd No
    ```

3.  Follow its progress to completion.

#### What the Script Does

| Phase | What Happens |
|---|---|
| Infrastructure | Creates the source group, VNet, NSG, public IP, NIC and Windows HyperVHost. |
| Hyper-V installation | Installs Hyper-V and restarts the host. |
| Network setup | Creates `intSwitch`, host NAT and DHCP reservations for the guests. |
| Appliance storage | Creates the 100 GB appliance store partition on the host OS disk. No appliance VM is imported. |
| Guest provisioning | Creates the four fixed-disk guests and installs IIS, SQL Server, Nginx and the SQL-connected Tomcat order desk. |
| Traffic generator | Places the optional sample-traffic script on the host for Section 6. Nothing starts it. |

**Expected Result:** Deployment completes and prints the host's public IP. Detailed setup progress is recorded at `C:\AzMigrateLab\setup-log.txt` on the host. Do not interrupt a progressing deployment merely because a stage is slow.

### Step 5: Connect to the Hyper-V Host

#### Hands-On Steps

**Local workstation — Azure portal:**

1.  Open **HyperVHost** in the source resource group.

2.  Confirm it is **Running**.

3.  Record its public IP.

    If you need to retrieve the public IP from your local PowerShell session instead:

    ```powershell
    Get-AzPublicIpAddress -ResourceGroupName $sourceRg | Select-Object Name, IpAddress
    ```

**Local workstation — RDP client:**

4.  Connect to the public IP on port 3389.

5.  Sign in as **`labadmin`**, or the supplied administrator name.

**HyperVHost — Start menu:**

6.  Open **Windows PowerShell as administrator**.

**Expected Result:** You have a working RDP session to the running host and an elevated PowerShell window inside it.

---

## 5. Verification

Verification goes beyond "can I ping it?" — confirm that the environment matches the intended architecture and that every workload is functional. Use the host for the private guest addresses below; they are not public endpoints.

### 5.1 — Verify Hyper-V Infrastructure

#### Hands-On Steps

**HyperVHost — Hyper-V Manager:**

1.  Open **Hyper-V Manager**.

2.  Confirm that all four workload guests are listed and running.

**HyperVHost — elevated PowerShell:**

3.  Display their state, processor count and assigned memory.

    ```powershell
    Get-VM | Select-Object Name, State, ProcessorCount, MemoryAssigned
    ```

| VM Name | Expected State | Memory | vCPUs |
|---|---|---|---|
| OnPrem-Web | Running | 4096 MB | 2 |
| OnPrem-SQL | Running | 4096 MB | 2 |
| OnPrem-Linux-Web | Running | 2048 MB | 2 |
| OnPrem-Linux-App | Running | 2048 MB | 2 |

**Expected Result:** All four guests are Running with the memory and vCPUs above. `MemoryAssigned` is displayed in bytes. No appliance VM is expected yet.

If you need a guest console, use **Connect** in Hyper-V Manager. Windows guests use `Administrator`; Linux guests use the deployment username, normally `labadmin`. Both use the lab password.

### 5.2 — Network and Appliance Storage

#### Hands-On Steps

**HyperVHost — elevated PowerShell:**

1.  Find the appliance store.

    ```powershell
    Get-Volume -FileSystemLabel ApplianceStore |
        Select-Object DriveLetter, FileSystemLabel, Size, SizeRemaining
    ```

2.  Record the actual drive letter and free space.

    Keep at least **30 GB free** for downloading and extracting the source archive.

3.  Optionally, confirm the internal switch.

    ```powershell
    Get-VMSwitch -Name intSwitch | Select-Object Name, SwitchType
    ```

**Expected Result:** The appliance store is approximately 100 GB, normally `E:`, with the required staging space free. It is a partition on the OS disk. The switch check shows `intSwitch` with `SwitchType` **Internal**.

### 5.3 — Workload Readiness

#### Hands-On Steps

**HyperVHost — browser:**

1.  Open each URL below and inspect the page.

| URL | Expected Page |
|---|---|
| `http://192.168.0.10` | IIS static sample site |
| `http://192.168.0.12` | Nginx static sample site |
| `http://192.168.0.13:3000` | Contoso Order Desk |

**HyperVHost — elevated PowerShell:**

2.  Check liveness, SQL readiness, one application-data read and the Nginx API proxy.

    ```powershell
    Invoke-RestMethod http://192.168.0.13:3000/api/health
    Invoke-RestMethod http://192.168.0.13:3000/api/ready
    Invoke-RestMethod http://192.168.0.13:3000/api/orders
    Invoke-RestMethod http://192.168.0.12:8080/api/ready
    ```

3.  Observe the returned customers and recent orders.

    Do not require a fixed row count.

**HyperVHost — browser:**

4.  Optionally, submit one sample order through `http://192.168.0.12:8080`.

**Expected Result:** The three pages load. The health endpoint returns `healthy`; both readiness requests return `ready`; the orders request returns existing application data.

### 5.4 — Architecture Validation Checklist

- [ ] HyperVHost is running and accessible through RDP.
- [ ] All four workload guests are running in Hyper-V Manager.
- [ ] The appliance store is available, its drive letter is recorded, and staging free space has been checked.
- [ ] IIS, Nginx and the Tomcat order desk respond.
- [ ] SQL readiness succeeds directly and through the Nginx proxy, and existing application data is readable.

**Expected Result:** All items are complete before you start the sample traffic in Section 6.

### 5.5 — Review Setup Logs if Needed

Only if a check fails, read the recent setup entries and identify the failed workload or stage.

#### Hands-On Steps

**HyperVHost — elevated PowerShell:**

1.  Read the recent setup entries.

    ```powershell
    Get-Content C:\AzMigrateLab\setup-log.txt -Tail 50
    ```

2.  Identify the failed workload or stage.

**Expected Result:** You can identify the relevant setup stage or error before using the recovery guidance below. Keep credentials and private configuration out of shared output.

---

## 6. Start the Sample Business Traffic

Network sample traffic and CPU simulation are **independent, optional choices**. The
learning objective is to distinguish application dependencies from CPU utilization:
network activity can make connections easier to observe, while local CPU calculations
add no network dependency. You may decline either or both and continue the workshop.
Feature availability, installation and control are covered in the
[operator guide](Lab-Traffic.md); applying documentation alone does not install CPU support.

Initial deployment already connects the Tomcat order desk to SQL and supplies the Nginx proxy. Without traffic, most HTTP connections between the workloads are idle, and Azure Migrate's dependency analysis can miss them; an empty or partial map is not proof that no dependency exists.

The traffic script generates low-rate HTTP through Nginx into Tomcat and adds a scheduled task on `OnPrem-Web` that reads orders from SQL and calls the order desk's health check. Database reads and writes for the Linux application stay in the Tomcat application itself; the generator never connects directly to SQL. `OnPrem-SQL` then appears as a shared dependency of both application tiers — which is the conversation a customer needs to have before moving anything.

If you choose either optional component, use the startup steps below after the checks in Section 5 pass and before you begin Module 1. With network traffic enabled, requests can be flowing when discovery starts. Dependency analysis samples active connections on a polling interval rather than recording continuously, so traffic that starts minutes before you open the map may not appear in it.

#### Hands-On Steps

**HyperVHost — browser:**

1.  Open `http://192.168.0.12:8080/` and inspect the source Order Desk through Nginx.

2.  For an approved manual activity check, select an existing customer and submit **one** clearly identified sample order; record its ID and read it back.

    Do not repeatedly submit an uncertain result. This is a real SQL write, not a load-test tool.

**Source OnPrem-Web — approved Windows PowerShell:**

3.  If the optional generator has already been provisioned under separate instructor approval, inspect its existing task:

    ```powershell
    Get-ScheduledTask -TaskName 'LabOrderDeskTraffic' -ErrorAction SilentlyContinue |
        Select-Object TaskName,State
    ```

4.  Only if that exact existing source task is approved and intended to run, use Task Scheduler to enable/start it. If absent, record **not provisioned**; do not install new generators or run workshop helpers to satisfy this pilot.

**Source OnPrem-Linux-App — SSH session:**

5.  Inspect the existing optional source traffic unit, if present:

    ```bash
    systemctl status contoso-orderdesk-traffic.service --no-pager
    ```

6.  Only if the exact installed unit and source aliases are verified and approved, use `sudo systemctl start contoso-orderdesk-traffic.service` for that existing source unit. If absent, record **not provisioned** and continue; no runtime retrofit is part of this exercise.

**HyperVHost — Windows PowerShell:**

7.  Read source readiness and the **total** order count:

    ```powershell
    Invoke-RestMethod http://192.168.0.12:8080/api/ready
    $orders = Invoke-RestMethod http://192.168.0.13:3000/api/orders
    $orders | Select-Object count,customerCount
    ```

8.  If synthetic orders are active, wait a minute or two and repeat the read. Use API `count`, not `.orders.Count`: the returned `orders` array contains at most 20 recent rows.

**Expected Result:** Manual source order entry works; any already-provisioned optional traffic is either verified active or honestly recorded absent/declined. No migration helper or new generator installation was used. The database and proxy remain available.

> **Traffic boundary:** Keep all four source workloads serving, including already enabled synthetic orders, during discovery and both methods' initial/delta replication and isolated tests. Stop/disarm **copied** generators in test guests before functional traffic. Freeze source manual and synthetic writes only at Module 3's final planned cutover boundary (or an explicitly approved troubleshooting stop), not because replication starts. Use Module 3's ordinary per-guest stop controls, not a workshop helper.

**Optional CPU observation:** In each Windows guest, open **Task Manager > Performance >
CPU**. In each Linux guest, use `top` and inspect the aggregate CPU summary, not an
individual process percentage. Observe over several minutes and note UTC time.
Across each existing two-vCPU guest, the approximate **total** CPU targets are **15%
from 06:00–22:00 UTC** (16 hours) and **2% from 22:00–06:00 UTC** (8 hours), with no
peak period. Existing application/OS activity can exceed these targets: synthetic work
then rests and cannot cap real application CPU.

CPU simulation defaults to a bounded 24-hour run and does not resume after reboot,
unlike the network generator. For the full 16/8-hour profile, collect a complete
24 hours while appliance performance collection is active, and match the full selected
history window to captured data for the [optional second performance-based portal
assessment in Module 1](Module-1-Discovery.md#56--optional-performance-comparison-and-business-case).
Earlier data may be partial; the required **As on-premises** assessment does not use CPU
history. This is educational CPU history, not a production benchmark or RAM/I/O simulation.

No additional VM, resizing or paid service is created. CPU activity on the existing
fixed-price VM has no separate usage fee, but keeping the lab running longer continues
normal compute/storage charges.

---

## 7. Troubleshooting

### Quota or Host Size Rejected

Regional quota, family quota, SKU restrictions and host requirements are separate constraints. Deallocation does not release vCPU quota.

#### Hands-On Steps

**Local workstation — PowerShell and Azure portal:**

1.  Read the deployment error.

2.  Compare it with the selected region, size and quotas from Section 3.

3.  Request the needed quota, or choose an eligible region and host meeting the 8-enabled-vCPU / 64-GiB floor and nested virtualization requirements.

**Expected Result:** The reported pre-deployment constraint is resolved. No region or quota increase guarantees allocation capacity.

### Cannot RDP to HyperVHost

RDP requires an allowed client address, a permitted network path and the lab credentials.

#### Hands-On Steps

**Local workstation — RDP client:**

1.  Check that you are using the public IP from Step 5.

2.  Check that you are using the administrator credentials from deployment.

**Local workstation — Azure portal:**

3.  Review the existing **Allow-RDP** rule on the source NSG.

4.  If your public IPv4 address changed, update the rule's source to your current single `/32`.

    Do not broaden it to the internet.

5.  If your network blocks RDP, use the approved access alternative from Section 3.5.

**Expected Result:** You can open the host desktop without redeploying the lab.

### Workloads Not Ready or Setup Incomplete

A running guest is not proof that its application has finished provisioning. Readiness can also fail when SQL is unavailable.

#### Hands-On Steps

**HyperVHost — elevated PowerShell:**

1.  Review the setup log.

2.  Allow an active installation to finish before retrying the failed application check.

**HyperVHost — Hyper-V Manager:**

3.  If a guest is off after setup has finished, start it.

    If it cannot start, review host memory and disk space rather than creating a duplicate guest.

**HyperVHost — elevated PowerShell:**

4.  Only if SQL readiness fails, optionally test the database port from the host.

    ```powershell
    Test-NetConnection 192.168.0.11 -Port 1433
    ```

**Local workstation — PowerShell:**

5.  For a confirmed failed, incomplete source deployment, correct the cause.

6.  Rerun the same deployment command with the same source resource group.

    Never rerun deployment after successful provisioning or cutover.

**Expected Result:** The original workloads run and the failed readiness or data-read check succeeds before you continue.

### Traffic Script Not on the Host

`C:\AzMigrateLab\enable-lab-traffic.ps1` is written near the end of setup, so an interrupted deployment may not have reached it.

#### Hands-On Steps

**HyperVHost — elevated PowerShell:**

1.  Read the end of the setup log and look for the traffic staging phase.

    ```powershell
    Get-Content C:\AzMigrateLab\setup-log.txt -Tail 20
    ```

2.  If setup did not complete, follow **Workloads Not Ready or Setup Incomplete** above.

**Expected Result:** The baseline staging status is understood. This is not permission to run a traffic helper in the pilot; Section 6 uses manual activity and ordinary controls for already-provisioned generators, or records them absent.

---

## 8. Security Baseline

This section documents the security posture of the lab environment and highlights what you would do differently in production.

### 8.1 — Network Security Group (NSG) Rules

| Priority | Name | Direction | Protocol | Source | Destination | Port | Action |
|---|---|---|---|---|---|---|---|
| 100 | Allow-RDP | Inbound | TCP | Your single public IPv4 `/32` | `*` | 3389 | Allow |

The host still has a public management endpoint, even though its source is restricted. Do not change the source to `*`. The nested guests are behind host NAT rather than exposed directly to the internet.

### 8.2 — Production Alternatives for Remote Access

| Approach | How It Works | When to Use |
|---|---|---|
| **Azure Bastion** | RDP/SSH over HTTPS without a public IP on the VM. | Private management access. |
| **JIT VM access** | Microsoft Defender for Cloud opens NSG ports on demand for a limited window. | Time-bounded direct management access. |
| **VPN gateway** | Site-to-site or point-to-site VPN, reaching VMs by private IP. | Persistent network-level connectivity. |
| **Restrict NSG source** | Allowlist a specific public address, as this lab does. | Direct access from a known client address. |

### 8.3 — Credential Management

| Lab Approach | Risk | Production Alternative |
|---|---|---|
| One lab password for the host and guests | Credential reuse across machines. | Unique credentials and managed rotation. |
| Masked `Read-Host` entry and a `SecureString` deployment parameter | Avoids a plaintext password literal in command history, but does not remove secrets from provisioning or the running environment. | Approved secret storage such as Azure Key Vault. |
| Windows unattended setup and Linux cloud-init | Privileged users can access sensitive provisioning material. | Managed identity and authentication designs appropriate to the platform. |
| Tomcat SQL credentials in protected JNDI configuration | The application still requires a database credential. | Managed or integrated authentication where supported. |

### 8.4 — Principle of Least Privilege

Use only the training permissions needed for this exercise. In production:

- Create custom RBAC roles scoped to required operations.
- Use managed identities rather than service principal secrets for automated deployments.
- Apply resource locks to protect critical resources from accidental deletion.

---

## 9. Cost Analysis

Understanding the cost profile is essential for planning a lab budget. Estimates vary by region, agreement, operating-system licensing and resource lifetime; use current pricing for your selected resources rather than a fixed workshop price.

### 9.1 — Cost Breakdown

| Resource | SKU / Tier | Cost Consideration |
|---|---|---|
| Host VM compute | `Standard_E8s_v7`, Windows Server | Charged while allocated; deallocation stops host compute charges. |
| OS disk | 512 GB Premium SSD | Billed while retained, including when the host is deallocated. The appliance store is part of this disk. |
| Public IP | Standard, static | May continue billing while retained. |
| Networking | Data transfer and any separately chosen access services | Depends on usage and access design. |
| Later migration resources | Target/test VMs, disks and migration storage | Additional to the source lab; include them in the overall budget. |

The four nested guests and the appliance imported in Module 1 do not incur separate Azure VM compute charges. They consume the source host's CPU, memory and OS-disk capacity.

### 9.2 — Cost Optimization Tips

Compute deallocation and resource deletion have different effects on the bill.

| Tip | Effect |
|---|---|
| **Deallocate when not in use.** | Stops host compute charges, but not retained disk or public-IP charges. |
| **Set auto-shutdown.** | Helps avoid leaving the host allocated overnight; choose a time that will not interrupt the lab. |
| **Use eligible Dev/Test pricing.** | May reduce Windows compute cost, depending on your agreement. |
| **Delete lab resources when finished.** | Remove only the dedicated resources you no longer need, following the later cleanup steps. |
| **Compare regions and set a budget alert.** | Makes costs visible; an alert is not a spending cap. |

#### Hands-On Steps

**Local workstation — Azure portal:**

1.  Review the estimated cost of the selected host, disk and access services.

2.  Set a lab budget alert.

3.  If pausing rather than continuing to Module 1, save your work and stop/deallocate HyperVHost.

4.  Start HyperVHost again before continuing the lab.

**Expected Result:** You understand which resources keep billing during a pause. Deallocation is not deletion and does not release VM quota.

### 9.3 — Comparison to Real Migration Lab Costs

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
