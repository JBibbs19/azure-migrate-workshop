# Module 0 · Setup

**TD SYNNEX | Cloud Enablement Services**

In this module you build the on-premises environment that the rest of the workshop migrates: one Azure VM running Hyper-V, with four nested guest VMs standing in for a small business's servers. A single script provisions all of it, and you finish by verifying that every workload actually responds.

**Where to run:** Run the Azure commands from your own workstation or PowerShell Cloud Shell. Run the Hyper-V commands in an elevated Windows PowerShell session **inside HyperVHost**, the host VM you are about to create.

---

## 1. Module Overview

In a real migration engagement this phase corresponds to **preparing the landing zone** — the target Azure environment that will host migrated workloads. Enterprise projects use [Azure Landing Zones](https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/) with management groups, policy-driven governance, hub-spoke networking and identity integration. That level of infrastructure is out of scope for a hands-on migration lab.

Instead, this module deploys a **self-contained simulation of an on-premises datacenter** inside a single Azure VM using nested Hyper-V virtualization. `deploy-lab.ps1` provisions the host, virtual networking and **four workload guests**. You connect through RDP afterwards to verify the host and applications. Module 1 separately imports the discovery appliance; Modules 2 and 3 use the same Azure Migrate Hyper-V host provider for all four workload VMs.

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

Discovery **`MigrateAppl` at `192.168.0.20`** is imported manually in Module 1 for inventory and assessment, not disk replication. It is infrastructure, not a fifth workload or a traffic/CPU/backup target.

**Count the layers separately:** initial deployment creates **four nested workload VMs**. Importing `MigrateAppl` in Module 1 brings the nested total to **five**. Azure has **one source host VM and one persistent 512-GiB managed OS disk**; the nested disks and discovery `ApplianceStore` partition are backed by that host disk, not separate Azure managed-disk resources. The existing temporary `WinServerBase-temp` disk is used during image preparation and removed when setup termination is confirmed. These counts do not enumerate networking or later migration resources. Only **four workload identities** enter assessment, replication and coordinated cutover.

---

## 2. Architecture Decisions Record (ADR)

Every infrastructure choice in this lab was made deliberately. The table below documents the key decisions and their rationale — a practice you should carry into every production engagement.

| Decision | Choice | Rationale |
|---|---|---|
| **Host VM size** | `Standard_E8s_v7` | 8 vCPUs, 64 GiB RAM with nested virtualization. The four workloads retain 12 GiB total static memory and Module 1's discovery appliance needs 16 GiB; actual host overhead and available memory still require verification. A replacement host must meet the same 8-vCPU / 64-GiB floor and support nesting. |
| **Host image and security** | Windows Server 2022, x64 Gen 2, NVMe-compatible image, Standard security | Matches the default host's requirements for this nested Hyper-V lab. The Esv7 series requires an image that supports its NVMe disk controller. |
| **OS disk** | One 512-GiB Premium SSD, `Premium_LRS` | Holds the host OS, Hyper-V, base/tool files, unchanged 140 GB of fixed workload VHDs and the 100-GiB discovery partition. No additional Azure managed data disk is created. Deployment checks measured host usage, image-preparation overlap and free-space headroom before partitioning/provisioning and fails closed if insufficient; the nominal disk size alone does not prove capacity. Preserve at least 30 GiB measured free on host `C:` at final readiness, in addition to checking the discovery store separately. |
| **Guest disk type** | Fixed, not dynamic | Each guest VHD is allocated in full at creation: 40 GB for each Windows guest and 30 GB for each Linux guest, 140 GB in total. Host capacity is therefore known from the start and does not shift under the workshop as guests write. A dynamic disk also expands on write, and that write amplification appears as erratic disk I/O in the Module 1 performance-based assessment. The cost is deployment time — see Section 4. |
| **Guest memory** | Static, not dynamic | Fixed startup memory with dynamic memory disabled, for the same reason: the assessment should observe a stable machine, not one whose memory the hypervisor is resizing. The four guests use 12 GB in total. |
| **Appliance storage** | 100-GiB discovery `ApplianceStore` partition, first free drive letter (normally `E:`) | Contains the `Appliance` staging/import folder on the single host OS disk. It is not a separate managed disk or Azure temporary storage. Check the actual reported drive and enough space for the published archive, full extraction and any import copy; at least 30 GB free is required for download/extraction, and the current archive/layout may require more. |
| **Appliance delivery** | Discovery import in Module 1 | Import the published Generation 1 discovery appliance unchanged, with the optional recommended publisher SHA256 comparison. Deployment can optionally stage its download/extraction but does not import or register it. All workload migration uses the HyperVHost provider; discovery and replication remain separate roles. |
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

The default source host needs **8 Azure vCPUs**. The four nested workloads and Module 1's discovery appliance consume the host's resources; they are not separate Azure VM allocations. Regional vCPU quota, the selected VM family's quota and VM-count quota all matter. Deallocating an Azure VM does not release its vCPU quota.

The `B2s` / `B2ms` / `B1ms` / `B1ms` examples total **6 vCPUs**; an all-four two-vCPU example totals **8**. These are **not approved target-size selections**. In particular, all actual source guests have two vCPUs, so the one-vCPU Linux examples require manual support/downsize review. Calculate actual target/test quota from the approved per-role selections and overlap; do not infer them from script menus. Source host storage and actual memory are checked independently from target/test Azure quota; a quota result is not disk or memory readiness.

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

### 3.6 — Source Identities and Test Isolation

Deployment builds the four-workload source lab on one **512-GiB Premium SSD OS disk**, including its **100-GiB discovery `ApplianceStore` partition**. All four workload VMs use the **same Azure Migrate HyperVHost provider and source-host/project binding** in Modules 2–3. The discovery appliance is imported separately in Module 1; no additional replication VM or appliance disks are required. These instructions are for a fresh deployment, not a disk-shrink or in-place conversion procedure for an existing host.

#### Hands-On Steps

**Local workstation — lab register/worksheet:**

1.  Choose unique names for new source, project, target and test resources.

    Use `rg-ces-target-01`, `vnet-ces-target-01`, `nsg-ces-target-01`, `vnet-ces-test-01` and `nsg-ces-test-01` consistently in your register, substituting approved unique names where needed.

2.  Deploy a fresh source resource group and host using the command below, supplying your new source group name.

    Keep the four guest names exactly as listed in Section 1. Their VM IDs must be new. Do not reuse/clone previously protected source VMs or an already registered discovery appliance; do not assume existing replication bindings can be safely cleared.

3.  Record the new source host resource ID and the four new Hyper-V VM IDs before registration.

4.  After deployment completes, verify all four workload VMs, application readiness, measured host/discovery-store free space and the required network traffic through Sections 5–6. A failed or unconfirmed capacity/readiness result means stop for review, not repartition, shrink volumes or replay a completed deployment.

5.  Confirm the instructor-provided baseline qualification in the [README](../README.md#instructor-preparation--qualify-the-provided-baseline). Before replication, verify the actual supported Hyper-V host/source disk/boot configuration, Windows/Ubuntu versions and Azure target settings; an assessment Ready label alone is insufficient.

6.  Review actual target sizes and test/target overlap in Modules 2–3. All four sources have two vCPUs. Resolve any downsizing/support conflict manually; neither an assessment recommendation nor a script menu reserves capacity.

7.  Before enabling protection, verify the intended project, connected HyperVHost provider, source VM IDs and Migrate-managed migration-resource association. Module 3 **reuses the same registration** verified in Module 2. STOP on unknown or mismatched associations; do not re-register an already protected host, fill blank IDs or create a separate ASR DR relationship.

8.  Keep the test VNet isolated from source and final-target networks **before any test VM first boots**. Record actual test VM/NIC identities and permit only approved test peers; stop/disarm inherited network generators and CPU workers before functional tests.

**Expected Result:** The lab register identifies four fresh workload identities, a verified source environment and one host-provider path, with source/project association and pre-boot test isolation required before migration.

**CSA Why:** Explicit identities and one controlled application boundary prevent duplicate protection, wrong-host selection and copied writers reaching live data.

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

Running `deploy-lab.ps1` is your deployment action. It creates the source host, networking and four workloads; you do not manually recreate those guests. The target landing zone is left for Module 2. Appliance download/extraction can be selected during deployment; import and registration remain manual in Module 1.

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

    Module 1 downloads the appliance when it is needed. For instructor preparation, answer **Yes** (or use `-IncludeApplianceVhd Yes`) to stage it during deployment instead. Its background download/extraction starts in the OS image phase and overlaps ADK/QEMU and workload setup; deployment collects the staging result before final host readiness. **No** starts no appliance download or staging job.

    There is no end-of-deployment checksum prompt. The host still computes SHA256 and enforces `-ApplianceVhdSha256` if supplied; otherwise the archive is staged **unverified**, not publisher-verified. The recommended manual publisher check remains optional in Module 1 §2.1.

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
| Infrastructure | Creates the source group, VNet, NSG, public IP, NIC and Windows HyperVHost with one 512-GiB Premium SSD OS disk; no additional Azure managed data disk. |
| Hyper-V installation | Installs Hyper-V and restarts the host. |
| Network setup | Creates `intSwitch`, host NAT and DHCP reservations for the guests. |
| Appliance storage | Creates the 100 GB appliance store partition on the host OS disk. If selected, appliance download/extraction starts during image preparation and its result is collected before final readiness. No appliance VM is imported. |
| Guest provisioning | Creates the four unchanged fixed-disk workload guests and installs IIS, SQL Server, Nginx and the SQL-connected Tomcat order desk. Verifies host capacity and workload/application readiness; discovery import/registration and Azure Migrate host-provider registration remain later manual exercises. |
| Traffic generator | Always stages the controller, settings and CPU assets. After application readiness, deployment automatically installs/starts required source network traffic and confirms task/unit status, direct/proxy readiness and two increasing API total-order counts before completion. Only independent optional CPU simulation is offered after cleanup/timing, default No. |

**Expected Result:** Deployment completes and prints the host's public IP. Detailed setup progress is recorded at `C:\AzMigrateLab\setup-log.txt` on the host. Do not interrupt a progressing deployment merely because a stage is slow.

> **Wait before RDP:** Do not access HyperVHost while deployment is preparing it. Wait for the four-workload/application readiness and required network-traffic results, the selected discovery-appliance staging result, and the **Deployment process ended** timing message (cleanup included). A successful selected stage means download, extraction and recording finished before host readiness; a **NOT COMPLETE** warning means staging failed or could not be confirmed, not success. Let deployment finish first, then resolve staging through Module 1 §2.1 before manual import. An existing ZIP rehash alone does not verify previously extracted files.

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

**Expected Result:** All four workloads retain the memory/vCPUs above. `MemoryAssigned` is displayed in bytes. `MigrateAppl` is not expected yet; it is imported in Module 1. The main migration path does not add another nested VM.

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

**Expected Result:** All items are complete before you observe the automatically started required sample traffic in Section 6.

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

**Network lab traffic is required before discovery. CPU simulation is optional and independent.** Initial deployment already connects Tomcat to SQL and supplies the Nginx proxy, but dependency results will not appear correctly without the lab traffic that exercises those connections. An empty or partial map is not proof that no dependency exists. Azure Migrate still needs its collection/upload window; starting traffic does not produce an instant complete map.

The original five-minute network generator sends low-rate HTTP through Nginx → Tomcat → SQL, including real sample-order writes. A separate Linux-Web employee-order service reads a randomly selected 1–3 available 20-record order pages through local Nginx before each daytime order attempt, then picks existing full-history customers/products and quantity 1–3. It waits a random 2–20 minutes after each cycle during UTC 06–22 and sleeps overnight independently of CPU; empty/failed browsing skips the write and no new employee GET/POST starts overnight. The original generator continues overnight. The desk starts at the newest 20 records; choose 20, 40, 60, 80 or 100, then **Apply**. **Next X** browses older and **Previous X** newer records without writes, bounded at either end; concurrent new inserts appear when you refresh the snapshot. Extra Nginx → OnPrem-Linux-App:3000 reads increase observation opportunities, not guaranteed dependency capture. The Windows task reads SQL orders and checks application health. Python does not connect directly to SQL; Tomcat performs the application's database reads and writes.

> **Deployment starts and verifies required network traffic automatically; there is no network question.** Complete this observation section before Module 1 discovery. An incomplete/unknown network stage means deployment is not complete; inspect Status/Stop before an approved manual retry, never replay deployment.

#### Hands-On Steps

**HyperVHost — elevated Windows PowerShell, after deployment and Section 5 checks:**

1.  Confirm that deployment preparation, required network verification and cleanup have ended and that all Section 5 checks pass. Deployment confirms the network task/unit, direct/proxy readiness and increasing API total-order counts before its end/elapsed messages. Only independent **optional CPU Simulation [No]** follows; CPU may remain No. No Azure Migrate project or appliance download is needed for source startup.

2.  If deployment confirmed network startup, **do not repeat Start**; continue to Step 3. For an approved manual recovery only, after inspecting Status and stopping any partial/unknown generators as needed, use the staged source controller:

    ```powershell
    C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Start -Component Network -CpuSimulation Skip
    ```

    Enter the existing lab password privately at the controller's masked prompt. Do not put a password literal in the command. This starts network activity only, without starting or renewing CPU simulation. An unknown/partial deployment result may already have started generators: inspect Status and use Stop if needed **before any retry**. Do not rerun deployment or run this source controller on test/target VMs or retired sources.

3.  Inspect source network traffic without restarting it:

    ```powershell
    C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Status -Component Network
    ```

    Confirm the Windows network task is running and both Linux network generators are active; Linux-Web employee `night-sleep` with a fresh heartbeat/next UTC wake is healthy. If any is partial or unknown, resolve it before discovery; do not treat a controller exit message alone as sustained application health.

4.  Check direct and proxied readiness, then read the **total** order count:

    ```powershell
    Invoke-RestMethod http://192.168.0.13:3000/api/ready
    Invoke-RestMethod http://192.168.0.12:8080/api/ready
    $orders = Invoke-RestMethod http://192.168.0.13:3000/api/orders
    $orders | Select-Object count,customerCount
    ```

5.  Record the first total and timestamp, then wait one configured **baseline-generator interval** (default **300 seconds / five minutes**, configurable 20–600 seconds) and repeat Step 4. If the total has not risen, continue GET-only observations for up to two additional minutes of processing margin: **up to seven minutes total at 300 seconds, or twelve at 600**. Require readiness to remain `ready` and a later API `count` to exceed the first; record both totals and timestamps. Use API `count`, not `.orders.Count`: the returned `orders` array contains at most 20 recent rows. The employee service's random daytime cycle or overnight sleep is not the baseline timer. If growth is still unconfirmed, inspect Status/readiness and resolve the issue before discovery; do not submit a POST, repeat Start or restart a healthy service just to force the count upward.

6.  Only for an approved troubleshooting stop, stop network generators without stopping applications or changing CPU simulation:

    ```powershell
    C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Stop -Component Network
    ```

    SQL, Tomcat, Nginx, IIS and existing data remain in place. Restore and verify required source network traffic before continuing discovery.

**Expected Result:** Source network generators are active, direct/proxy readiness succeeds and two total-order reads demonstrate ongoing activity before Module 1. Keep the traffic running while Azure Migrate collects dependencies. See [README — Lab Traffic](../README.md#lab-traffic) for settings, credentials and detailed outcomes.

> **Traffic boundary:** Keep all four source workloads serving, including already enabled synthetic orders, during discovery and both methods' initial/delta replication and isolated tests. Stop/disarm **copied** generators, including `contoso-employee-orders.service` on Linux-Web, in test guests before functional traffic; do not leave a next-day/reboot restart armed. Freeze source manual and synthetic writes only at Module 3's final planned cutover boundary (or an explicitly approved troubleshooting stop), not because replication starts. Use Module 3's ordinary per-guest stop controls.

### Optional CPU Simulation

CPU simulation adds local calculation work, **not network dependencies**, and is not required for the dependency exercise. If wanted, use the following in **HyperVHost — elevated Windows PowerShell**; do not repeat a confirmed deployment CPU Start or renew it unintentionally:

Run only the action needed; these are not a sequence. Stop ends the CPU run.

```powershell
C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Start -Component Cpu -CpuDurationHours 24
C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Status -Component Cpu
C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Stop -Component Cpu
```

The default is 24 hours, with no reboot auto-resume. Stop source CPU simulation before migration testing or cutover. See [README — Optional CPU Simulation](../README.md#optional-cpu-simulation) for the UTC profile, guards, parameters, expiry and the full 24-hour collection guidance. Keeping the lab running longer continues normal compute/storage charges.

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

**Expected Result:** The staging status is understood. A successful deployment automatically starts and verifies required network traffic; after the Section 5 checks, observe it in Section 6 without repeating Start. Do not continue discovery with the controller absent or traffic unconfirmed; inspect Status/Stop and resolve the setup failure without replaying a completed deployment.

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
| OS disk | One 512-GiB Premium SSD, `Premium_LRS` | Billed while retained, including when the host is deallocated. Workload VHDs and the discovery partition share this disk; no additional managed data disk. Remove only through approved source-group cleanup after the workshop. |
| Public IP | Standard, static | May continue billing while retained. |
| Networking | Data transfer and any separately chosen access services | Depends on usage and access design. |
| Later migration resources | Target/test VMs, disks and migration storage | Additional to the source lab; include them in the overall budget. |

The four nested workloads and discovery appliance imported in Module 1 do not incur separate Azure VM compute charges. They share the source host's CPU, memory and single 512-GiB OS disk. Nested placement does not remove the host disk's persistent charge.

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
