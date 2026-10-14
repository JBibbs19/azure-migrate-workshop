# Module 1: Discovery & Assessment — The Foundation of Every Successful Migration

> **Cloud Adoption Framework Phase:** Assess · **Prerequisite:** [Module 0: Setup](Module-0-Setup.md) completed

## Module Overview

Discovery establishes what you have, how it is connected, and what must be addressed before migration. Assessment turns that inventory into Azure readiness, sizing, and cost information. Together they provide the evidence for a migration plan rather than a list of servers to move.

In this module, you will manually create an Azure Migrate project, import and register its Hyper-V discovery appliance, discover four workload VMs, and create an **Azure VM assessment**. You will then examine application dependencies and plan a coordinated migration group.

A thorough discovery reveals:

- **Workload inventory** — server names, operating systems, resources, and installed software.
- **Dependencies** — the connections that must remain available when workloads move.
- **Readiness conditions** — configurations that need investigation before replication.
- **Cost estimates** — target-region estimates whose assumptions you can explain.

The Hyper-V appliance used here performs **discovery and assessment only**. Host-based replication is configured separately in Module 2. Neither this module nor the Hyper-V migration path requires a Mobility Service inside the workload guests.

---

## Learning Objectives

By the end of this module, you will be able to:

- Explain the Azure Migrate project, discovery appliance, and Hyper-V host roles.
- Create a project and distinguish metadata geography from migration target region.
- Download, verify, import, and network the published Hyper-V appliance.
- Confirm host access, register the appliance, add credentials, and start discovery.
- Validate the four workload records rather than relying on an inventory count.
- Create and interpret a four-server Azure VM assessment.
- Explain collection limitations, readiness findings, and pricing assumptions.
- Use observed and known dependencies to plan one coordinated four-VM cutover.

---

## Concepts — Azure Migrate Architecture

### Azure Migrate Hub

Azure Migrate provides a project in which discovery, assessment, and migration information is organized. Portal navigation can appear under **Explore / Decide / Execute** or **Servers, databases and web apps**. The steps below name the operation to perform; the exact navigation text may differ in your portal.

### Discovery Appliance

The Windows-based appliance queries the **Hyper-V host** for VM configuration and performance information. With appropriate guest credentials, it can also connect to Windows guests through PowerShell remoting and Linux guests through SSH for supported software inventory and dependency features.

| Component | Role in this module |
|---|---|
| Azure Migrate project | Holds discovery and assessment information in Azure |
| HyperVHost, `192.168.0.1` | Supplies Hyper-V VM configuration and performance information |
| Discovery appliance, `192.168.0.20` | Collects information and sends discovery metadata to Azure |
| Four workload guests, `.10`–`.13` | Provide the applications being assessed |
| Host replication provider | Separate migration component introduced in Module 2 |

### Data Flow

```text
Four workload VMs (.10–.13)
        | VM configuration and performance information
        v
HyperVHost (192.168.0.1)
        ^
        | WinRM / Hyper-V management queries
        v
Azure Migrate appliance (192.168.0.20)
        | Outbound HTTPS 443: discovery metadata
        v
Azure Migrate project -> Azure VM assessment results

Appliance -> Windows guests: PowerShell remoting for supported guest discovery
Appliance -> Linux guests: SSH for supported guest discovery
```

**Discovery does not replicate VM disks or move the application database into Azure.** Replication is a later, separately authorized action. The appliance needs outbound connectivity to Azure; it does not need an internet-facing management port.

### The Lab Environment

The source is a Windows Server 2022 Hyper-V host: `Standard_E8s_v7`, Generation 2 with NVMe storage, eight vCPUs, and 64 GB RAM. Its internal switch, `intSwitch`, uses NAT for `192.168.0.0/24`; the host is `.1`. The appliance will use that same switch for host access and outbound internet connectivity.

| Workload VM | Source OS | Application | Source address |
|---|---|---|---|
| OnPrem-Web | Windows Server 2022 | IIS, HTTP 80 | 192.168.0.10 |
| OnPrem-SQL | Windows Server 2022 | SQL Server 2022 Express, `ContosoApp`, TCP 1433 | 192.168.0.11 |
| OnPrem-Linux-Web | Ubuntu 24.04 | Nginx, HTTP 80 and order-desk proxy on 8080 | 192.168.0.12 |
| OnPrem-Linux-App | Ubuntu 24.04 | Tomcat 10.1, Java 17, Contoso Order Desk on 3000 | 192.168.0.13 |

The Azure source VNet uses `10.0.0.0/16`. The migration target VNet uses `10.1.0.0/16`, and the isolated test VNet uses `10.2.0.0/16`. The migration target region must be **different from the actual source host region** in this lab.

### Assessment Types

This module uses an **Azure VM assessment** of the four servers. SQL and web application assessments address different target questions and are not required here. Software inventory is not a count of additional servers: a SQL instance or a discovered web application must not be added as an extra member of the four-server assessment.

---

## Step 1: Create an Azure Migrate Project

### 1.1 — Confirm the Source and Migration Scope

**Concept:** The project metadata geography, resource group location, source host region, and migration target region are distinct settings. A resource group's location does not establish where its VMs run.

#### Hands-On Steps

1. **Local workstation — Azure portal:** Sign in to the lab tenant and subscription. Open the existing **HyperVHost** Azure VM and record its actual **Location** from the VM overview.
2. **Azure portal:** Review the migration target region selected for the lab. Confirm that it differs from the source host's actual region and matches the intended target and test networks. If a target network already exists, check the VNet's own location, not just its resource group.
3. **Azure portal:** Check subscription access, suitable target VM availability, regional vCPU quota, VM-family quota, and VM count quota for the proposed target. Allow for test and migrated VMs that may exist together. Record the chosen region before continuing; review it again before migration setup locks the target in Module 2.
4. **Local workstation:** Connect by RDP to HyperVHost using the lab deployment credentials. Open **Hyper-V Manager** and confirm that these four VMs are present and **Running**: `OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web`, and `OnPrem-Linux-App`. Alternatively, inspect them in an elevated host PowerShell window:

   ```powershell
   Get-VM -Name OnPrem-Web,OnPrem-SQL,OnPrem-Linux-Web,OnPrem-Linux-App |
       Select-Object Name,State
   ```

5. **HyperVHost:** If a workload is stopped, start that named VM in Hyper-V Manager; resume it if paused. If a workload is missing, resolve the incomplete Module 0 setup before proceeding. Confirm that you can use the host console; you will check appliance-to-host reachability after importing the appliance.

**Expected Result:** You have access to the correct source host, all four workload VMs are Running, and you have recorded a reviewed migration target region distinct from the source region. No replication or cutover has started.

### 1.2 — Create the Project in the Portal

**Concept:** The project gives the appliance and assessment a common scope. Its geography controls discovery metadata residency; it does not choose the migration target region.

#### Hands-On Steps

1. **Local workstation or HyperVHost — Azure portal:** Search for **Azure Migrate** and open it.
2. Select the option to **create a project**. Choose the lab subscription and existing source resource group, then enter a learner-chosen project name, such as `MigrateWorkshopProject`.
3. Select an available project geography appropriate for the lab's metadata residency. Confirm your account has permission to create and manage the project and register an appliance in that subscription and resource group. Resolve an access restriction before proceeding.
4. Review the scope and create the project. Open the created project and locate its discovery and assessment area. If tools need to be selected, use **Azure Migrate: Discovery and assessment** for this module; server migration is used later.
5. Record the tenant, subscription, resource group, project name, metadata geography, and chosen migration target region in your private lab notes.

**Expected Result:** The project opens in the Azure portal and provides the Hyper-V discovery entry point. Your recorded target region remains a separate planning choice.

### Why This Matters — CSA Context

A project is a migration scope, not permission to move every machine it discovers. Keeping source identity, metadata residency, and target location separate prevents an assessment from being priced for one region while migration is configured for another.

---

## Step 2: Deploy the Azure Migrate Appliance

### 2.1 — Download and Verify the Appliance Archive

**Concept:** Import the published Hyper-V appliance export, rather than creating an empty Windows VM. The lab's **ApplianceStore** is a dedicated partition on the host OS disk, normally `E:`, not a separate managed data disk or the appliance's guest `C:` drive.

#### Hands-On Steps

1. **HyperVHost — Azure portal:** In your project, open **Discover** in the discovery and assessment area. Select **Hyper-V** as the virtualization source and the published **VHD** download option.
2. Enter an appliance registration name, such as `MigrateAppl`, and generate the project key. Use an alphanumeric name of no more than 14 characters. Copy the key into an approved private location for Step 3; keep it out of screenshots, shared notes, source control, and command output.
3. **HyperVHost — File Explorer or PowerShell:** Identify the volume labelled **ApplianceStore** and its actual drive letter. Use its `Appliance` folder for the archive, extraction, and imported VM files. Inspect available space:

   ```powershell
   Get-Volume -FileSystemLabel ApplianceStore |
       Select-Object DriveLetter,FileSystemLabel,Size,SizeRemaining
   ```

4. Confirm at least **30 GB free** before staging the download, and enough actual space for the archive, extracted export, copied VM disks, and working headroom. The minimum alone is not proof that a particular package and copy-import will fit. Stop if space is insufficient; do not delete workload disks to make room.
5. **HyperVHost — browser:** Download the published Hyper-V appliance ZIP using your project's download link into the actual store folder, normally `E:\Appliance`. Obtain the Microsoft-published **SHA256 for that Hyper-V appliance archive** from the verification information associated with the download, not a hash for an installer or preparation script.
6. **HyperVHost — PowerShell:** Calculate the downloaded archive's SHA256 once, supplying its actual full filename:

   ```powershell
   $archive = Read-Host 'Full path to the downloaded Hyper-V appliance ZIP'
   Get-FileHash -LiteralPath $archive -Algorithm SHA256
   ```

7. Compare the full calculated hash with the published value for that archive. **If they differ, stop: do not extract, import, or bypass verification.** Resolve the download or archive selection before continuing.
8. **HyperVHost — File Explorer:** Only after the hash matches, extract the ZIP into a new folder under the actual appliance store, such as `E:\Appliance\Extracted`. Keep the published folder structure intact and do not overwrite an existing VM's files.

**Expected Result:** The published Hyper-V export is extracted on ApplianceStore, its archive hash matches the published SHA256, and sufficient space remains for the copy-import.

### 2.2 — Import the Published Appliance Configuration

**Concept:** The export contains the appliance VM configuration and its disk. Copy-import creates a new VM identity while preserving that configuration. The source host's Generation 2 setting does not change this **Generation 1 appliance**.

#### Hands-On Steps

1. **HyperVHost — Hyper-V Manager:** Select **Import Virtual Machine** and browse to the extracted export folder.
2. Select the appliance identified by the wizard. If the wizard cannot find the exported configuration, stop and check the extracted package; do not substitute a newly created empty VM or guess a disk.
3. Choose **Copy the virtual machine (create a new unique ID)**, not register in place.
4. Set the configuration, checkpoint, smart-paging, and virtual-disk destinations under the actual appliance store, for example `E:\Appliance\VMs`. Check available space against the physical source files before the copy. Do not accept default destinations on host `C:`.
5. Select **intSwitch** when asked to map the network, and complete the import. Optionally rename the Hyper-V display name to `MigrateAppl` so it is easy to identify; the display name is separate from project registration.
6. Before first boot, open **Settings** and confirm the imported Generation 1 configuration, **eight virtual processors**, and **16 GB static memory**. Retain the published disk and hardware configuration. Check the attached disk's capacity read-only against the appliance requirement of roughly 80 GB; stop if the package or capacity is inconsistent. Do not resize the disk, expand its partition, or rebuild the VM to work around a mismatch.
7. Confirm that the VM configuration and attached disks are on ApplianceStore, not among the four workload disks on host `C:`.

**Expected Result:** A new, still-off appliance VM appears in Hyper-V Manager with the published configuration, eight vCPUs, 16 GB static memory, and its files on ApplianceStore. The four workload VMs are unchanged.

### 2.3 — Configure Networking and Reserve the Appliance Address

**Concept:** This lab uses one appliance NIC on **intSwitch**. The internal switch provides host/guest access, DHCP, and outbound internet through host NAT. Do not add an external or Default Switch NIC for this lab.

#### Hands-On Steps

1. **HyperVHost — Hyper-V Manager:** Open the imported appliance's **Settings > Network Adapter** and confirm that it connects to **intSwitch**.
2. Open the adapter's **Advanced Features** and record its actual MAC address. If none is assigned yet, start this appliance to let Hyper-V allocate one, complete only the console first-boot prompts described in Step 2.4, then shut it down cleanly and return here. Confirm no other VM uses that MAC. Select **Static** and retain the actual address so it will not change after reservation; do not copy another VM's MAC or invent a shared value.
3. **HyperVHost — DHCP console:** Open **Server Manager > Tools > DHCP**, expand the host, then **IPv4 > Scope 192.168.0.0**. Inspect **Address Leases** and **Reservations**. Confirm `192.168.0.20` is not already allocated or reserved to a different client, and that the appliance MAC is not assigned to another reservation. Resolve a conflict before continuing; do not overwrite another client.
4. Under **Reservations**, choose **New Reservation**. Enter the appliance display name, IP address **192.168.0.20**, and the actual appliance NIC MAC from the previous step. Select DHCP as the supported client type and save the reservation.
5. Confirm the scope is active and its options provide gateway **192.168.0.1** and the lab's working DNS settings. Leave the appliance guest NIC configured to obtain its address through DHCP.

**Expected Result:** The appliance NIC is attached to intSwitch with a stable, unique MAC, and the host DHCP scope reserves `192.168.0.20` for that exact NIC.

### 2.4 — Start the Appliance and Complete First Boot

**Concept:** First boot establishes the appliance's local administrator password and network configuration. Accurate time and outbound connectivity are needed for Azure authentication and registration.

#### Hands-On Steps

1. **HyperVHost — Hyper-V Manager:** Start the imported appliance and select **Connect** to open its console.
2. **Appliance console:** Complete the first-boot prompts and set its local administrator password. Store it privately; do not include it in lab evidence.
3. Sign in and inspect the NIC configuration. Confirm address **192.168.0.20**, subnet mask **255.255.255.0**, gateway **192.168.0.1**, and working DNS. If it received another address, correct the reservation/MAC match before continuing.
4. **Appliance — PowerShell:** Check the host WinRM path:

   ```powershell
   Test-NetConnection 192.168.0.1 -Port 5985
   ```

5. **HyperVHost — browser:** Open **https://192.168.0.20:44368**. Alternatively, open the configuration manager shortcut inside the appliance, or browse there to **https://localhost:44368**. Confirm the destination is your own appliance before accepting its local certificate warning.

**Expected Result:** The appliance is Running, you can sign in, and the configuration manager opens over HTTPS on port 44368. The host connectivity check should return `TcpTestSucceeded: True`; if it does not, complete the host configuration in Step 3.1 before discovery.

### Why This Matters — CSA Context

Verifying the archive is a stop/go security check, not an optional warning. Importing the published export also avoids silently changing the appliance generation or storage layout. DHCP reservation gives the lab a predictable source address while keeping the guest network configuration DHCP-based.

---

## Step 3: Configure the Appliance and Start Discovery

### 3.1 — Confirm and Configure Hyper-V Host Access

**Concept:** The appliance must be able to query the host over WinRM and read Hyper-V inventory and performance counters. Module 0 prepares this access, but you still need to confirm it and know how to configure it manually.

#### Hands-On Steps

1. **HyperVHost — elevated PowerShell:** Check the WinRM service:

   ```powershell
   Get-Service WinRM
   ```

2. If PowerShell remoting is not configured, confirm that **vEthernet (intSwitch)** is the trusted private lab connection and configure remoting locally:

   ```powershell
   Enable-PSRemoting -Force
   ```

3. **HyperVHost — Windows Defender Firewall with Advanced Security:** Inspect the inbound lab WinRM rule. Confirm it allows the appliance's nested subnet **192.168.0.0/24** to reach host TCP **5985**. If the rule is missing, create an inbound TCP 5985 allow rule for the private lab connection with that remote-address scope. Review any remoting rules created by the preceding command and narrow overlapping broad access to the same trusted lab range. Do not disable the firewall or expose WinRM to the internet; opening a port does not create an HTTPS listener.
4. **HyperVHost — Computer Management > Local Users and Groups:** Confirm that the host discovery account supplied by the lab deployment is a local administrator. Use the host-local lab administrator credential, not your personal Azure sign-in. A separate non-administrator discovery account would need **Remote Management Users**, **Hyper-V Administrators**, and **Performance Monitor Users** membership; do not add those memberships to unrelated accounts.
5. **Appliance — PowerShell:** Repeat `Test-NetConnection 192.168.0.1 -Port 5985` if the earlier check failed. Resolve host reachability before adding the discovery source.

**Expected Result:** WinRM is Running, remoting is configured, the discovery account has the required host permissions, and the appliance can reach host TCP 5985 through a scoped private lab rule.

> **Safety:** The workload disks are local to HyperVHost, not remote SMB shares. Do not enable CredSSP for this lab or set a wildcard TrustedHosts entry to bypass connection validation.

### 3.2 — Complete Appliance Prerequisites

**Concept:** The configuration manager checks the appliance's own connectivity, clock, and components before registration. Host connectivity and Azure connectivity are separate paths.

#### Hands-On Steps

1. **Appliance configuration manager — browser:** Review and accept the appliance setup terms as prompted, then run the prerequisite checks.
2. Confirm the appliance can reach the required Azure services through the lab NAT and DNS configuration. Configure a proxy only if your lab network requires one.
3. Check that the appliance's UTC time is accurate. Correct its time synchronization if required; changing only the display time zone does not correct clock skew.
4. Allow the appliance to check for and apply its updates. Refresh or reopen the configuration manager if prompted and rerun any failed prerequisite check.

**Expected Result:** The configuration manager shows successful prerequisite checks and allows Azure registration to proceed. Do not continue past an unresolved connectivity, time, or update failure.

### 3.3 — Register with Azure

**Concept:** The generated project key associates this appliance with your project. Browser authentication authorizes registration; it is not a host or guest credential.

#### Hands-On Steps

1. **Appliance configuration manager — browser:** Enter the project key you saved in Step 2.1 in the project registration area.
2. Select the Azure sign-in action when prompted. Complete browser authentication with an account authorized for the lab project, checking the tenant and subscription rather than accepting an unrelated signed-in account.
3. Return to the configuration manager, review the identified project and appliance name, and select **Register** when available.
4. Wait for the registration confirmation. Keep the project key and authentication details private; do not copy them into your results notes.

**Expected Result:** The appliance reports successful registration to your intended Azure Migrate project. An appliance already registered to another project is not reused for this exercise.

### 3.4 — Add Host and Guest Credentials

**Concept:** Host credentials supply VM-level inventory. Guest credentials allow supported software and dependency discovery. One does not replace the other.

#### Hands-On Steps

1. **Appliance configuration manager — browser:** Open the credential management area and add a clearly named host credential, such as `HyperVHostCreds`.
2. Select the Windows credential type appropriate for a non-domain host. Enter the deployment-provided local administrator account and password. Use the host-qualified account, such as `HyperVHost\Administrator` when the deployed account is `Administrator`; if deployment supplied a different local administrator name, use that exact name. Do not substitute your workstation or Azure username.
3. Add a **Windows guest** credential using the guests' built-in `Administrator` account and the lab deployment password, separate from the host credential.
4. Add a **Linux guest** credential using the actual Linux username and password supplied at deployment, selecting the Linux credential type. This account uses SSH and has the lab's configured sudo access for privileged inventory/dependency operations. Do not guess a default username or change the protected application configuration.
5. Save the credentials and use the available validation actions for the intended source or guests. If optional SQL database discovery requests a separate credential, use an approved discovery credential with the required SQL metadata permissions from the lab setup guidance; the application's limited database login is not a substitute. SQL database discovery is not required to create the server assessment.

**Expected Result:** Distinct host, Windows guest, and Linux guest credential entries are saved for their intended purposes, with validation completed where offered. No passwords appear in your notes or screenshots.

### 3.5 — Add the Hyper-V Host and Start Discovery

**Concept:** The discovery source is the host, **HyperVHost / 192.168.0.1**, not one of the four guests and not the appliance itself.

#### Hands-On Steps

1. **Appliance configuration manager — browser:** In the Hyper-V discovery-source area, select the action to add a host or cluster.
2. Enter **192.168.0.1** as the host address, or the actual resolvable HyperVHost name, and select the host credential created in Step 3.4.
3. Save the source and run its connection/credential validation. Resolve any reported address, account, permission, or network failure before starting discovery.
4. Confirm the saved guest credentials are available for the supported guest discovery features, then select **Start discovery**.
5. Check that the appliance reports discovery as started and the Hyper-V source as connected or successfully validated.

**Expected Result:** The registered appliance is discovering VMs from the intended host. This starts inventory collection, not replication.

### Why This Matters — CSA Context

The host and guest credential paths explain why VM records can appear before software inventory. A successful host connection does not prove that guest SSH or Windows remoting has succeeded. Resolving the reported connection at its source is more useful than repeatedly waiting for an inventory count to change.

---

## Step 4: Wait for Discovery and Validate Results

### Verify Discovery in the Azure Portal

**Concept:** VM inventory, software inventory, and performance collection progress separately. Initial records may appear before guest inventory is complete. A short idle-lab collection period is not representative production telemetry.

#### Hands-On Steps

1. **Local workstation or HyperVHost — Azure portal:** Open your Azure Migrate project and its **Discovered servers** view in the discovery and assessment area.
2. Refresh after the appliance has had time to upload inventory. Find the four workload names individually; do not treat the headline server count as proof of scope. The appliance itself may also appear.
3. Open each workload record and compare its name, source host, OS, address, CPU, and memory with the lab inventory and Hyper-V Manager. Confirm both Linux records identify **Ubuntu 24.04**, and both Windows records identify **Windows Server 2022**.
4. Inspect the available **Discovery status**, latest discovery information, or appliance status for fresh successful collection from your connected host. If a record is missing or its OS information is incomplete, return to the appliance's source/credential validation and resolve the reported issue before assessing it. Do not substitute the appliance record for a missing workload.
5. Open **Software inventory** where available. Look for IIS, SQL Server, Nginx, and Tomcat/Java on their respective servers as guest discovery becomes available. Record pending or missing guest inventory honestly; it is not evidence that no application is installed.
6. Record the four server names, OS values, source host, and discovery status in your lab notes. Keep the appliance out of your workload assessment selection.

**Expected Result:** The portal contains fresh records for all four named workloads from the correct Hyper-V host, with the expected operating systems and configuration. Any additional appliance record remains outside the workload scope.

| Server name | Expected OS | Expected source address |
|---|---|---|
| OnPrem-Web | Windows Server 2022 | 192.168.0.10 |
| OnPrem-SQL | Windows Server 2022 | 192.168.0.11 |
| OnPrem-Linux-Web | Ubuntu 24.04 | 192.168.0.12 |
| OnPrem-Linux-App | Ubuntu 24.04 | 192.168.0.13 |

> **Note:** Tomcat 10.1 appearing in software inventory does not guarantee a separately discovered web-application asset. Neither that asset nor a SQL assessment is a prerequisite for this module's four-server Azure VM assessment.

### Why This Matters — CSA Context

An assessment of the wrong four records can look complete while omitting a workload. Server identity and source details establish scope; software assets and raw inventory totals do not.

---

## Step 5: Create and Interpret an Assessment

### 5.1 — Start the Assessment Wizard

**Concept:** The required exercise is the **Classic Azure VM server assessment**, which evaluates IaaS readiness, sizing, and cost for four servers. It is not an application or PaaS assessment.

#### Hands-On Steps

1. **Azure portal:** In your Azure Migrate project, open **Use Classic assessment tools > Assess > Azure VM** where that route is shown. If the portal places server assessments elsewhere, use the current **Azure VM assessment** entry for discovered servers.
2. Choose appliance-discovered server data if asked for the discovery source.
3. Enter a learner-chosen assessment name, such as `WorkshopAzureVM`, and open the assessment properties/settings.

**Expected Result:** You are configuring an Azure VM server assessment using the appliance's discovered inventory, not selecting SQL instances, IIS sites, or other application assets.

### 5.2 — Configure Assessment Settings

**Concept:** **As on-premises** sizing maps the allocated source resources to Azure. **Performance-based** sizing uses collected utilization and requires sufficient representative data. Start with as-on-premises for a newly discovered lab; compare performance-based sizing later if useful.

#### Hands-On Steps

1. **Azure portal — assessment settings:** Set the target location to the migration target region recorded in Step 1. Confirm it is not the source host region, the resource group location by assumption, or the project metadata geography by default.
2. Review and apply the following baseline settings, using the equivalent controls in your portal:

   | Setting | Baseline for this lab |
   |---|---|
   | Sizing criteria | **As on-premises** |
   | Target location | Your reviewed migration target region |
   | Currency | **USD** |
   | Pricing | **Pay-as-you-go** |
   | Reserved instances / commitment discounts | **None** |
   | Azure Hybrid Benefit | **No**, unless you have confirmed eligible entitlement |
   | Storage type | Automatic, or the lab's reviewed supported choice |
   | VM families | Suitable supported families available in the target subscription/region |

3. Record the selected settings and save them. If the available pricing agreement differs, record the actual agreement rather than presenting its estimate as the baseline above.

**Expected Result:** The assessment uses documented as-on-premises settings, the intended migration target region, and explicit pricing/licensing assumptions. No entitlement or commitment discount has been assumed.

### 5.3 — Select Servers to Assess

**Concept:** The assessment group must contain exactly the four workload **server records**. Additional software, SQL, web-application, or appliance records are outside this selection.

#### Hands-On Steps

1. **Azure portal — server selection:** Create a group with a learner-chosen name, such as `WorkshopFourServers`, or select an existing group only after checking its membership.
2. Select only **OnPrem-Web**, **OnPrem-SQL**, **OnPrem-Linux-Web**, and **OnPrem-Linux-App**, using the source details validated in Step 4.
3. Verify that the selection contains exactly those four servers and excludes `MigrateAppl` or any other appliance display name.
4. Continue to the review page. Check the group, four members, region, sizing method, and pricing settings, then select **Create assessment**.

**Expected Result:** An Azure VM assessment is created for a group containing exactly the four named workload servers. Creating an assessment has not started VM replication.

### 5.4 — Review Assessment Results

**Concept:** Creating an assessment is not the same as reviewing its results. Readiness is an assessment finding, not proof that the application has been tested or that migration capacity is reserved.

#### Hands-On Steps

1. **Azure portal:** Open the project's Azure VM assessments list and select your assessment. Refresh until the portal reports **Completed**, then **open the results**. If it fails, inspect the reported reason rather than proceeding on the basis that an assessment name exists.
2. Open the readiness summary and drill into each of the four servers. Read the actual readiness result and any explanation or recommended action. Do not assume all four will be Ready.
3. Review each proposed Azure VM size, disk recommendation, and compute/storage estimate. Check whether the recommended sizes are available and within quota in the target region before planning replication.
4. Record your actual findings in a table like this, including the assessment settings and collection period beside it:

   | Server | Actual readiness and conditions | Recommended Azure size | Estimated monthly compute / storage | Collection period / confidence, if shown |
   |---|---|---|---|---|
   | OnPrem-Web | Record portal result | Record portal result | Record portal estimate | Record available evidence |
   | OnPrem-SQL | Record portal result | Record portal result | Record portal estimate | Record available evidence |
   | OnPrem-Linux-Web | Record portal result | Record portal result | Record portal estimate | Record available evidence |
   | OnPrem-Linux-App | Record portal result | Record portal result | Record portal estimate | Record available evidence |

5. If useful, select the portal's **Export** action to download the assessment workbook (`.xlsx`) to your own lab storage. Export is optional; the reviewed results and settings are the required evidence.

**Expected Result:** You have opened the completed assessment and reviewed readiness, recommended sizes, and cost estimates for all four workloads. Any unresolved condition is recorded with its required follow-up; no fixed readiness or price is assumed.

### 5.5 — Interpreting Readiness Categories

**Concept:** Use the wording and details shown in your portal. Typical categories distinguish ready servers, servers needing attention, unsupported configurations, and incomplete evidence.

| Readiness finding | Meaning for your plan |
|---|---|
| Ready | Assessment found no blocking configuration in the collected evidence; application testing is still required |
| Ready with conditions / Conditionally ready | Review each condition and resolve or explicitly account for it before proceeding |
| Not ready | Investigate the stated unsupported configuration or target limitation before replication |
| Unknown / Insufficient data | Obtain the missing discovery information and reassess rather than assuming readiness |

A readiness result is specific to its settings and evidence. It does not authorize source shutdown, guarantee a recommended SKU will be allocatable, or remove the need for isolated migration tests.

### 5.6 — Optional Performance Comparison and Business Case

**Concept:** Performance-based sizing can inform a comparison, but an idle lab does not establish production demand. Assessment estimates are not a complete total cost of ownership calculation.

#### Hands-On Steps — Optional

1. **Azure portal:** After more performance data has accumulated, create a second Azure VM assessment of the **same four servers** using **performance-based** sizing. Keep the target region and pricing assumptions the same for comparison.
2. Review its available history, percentile, comfort factor, and confidence/data coverage. Record the actual collection window; do not describe a short idle sample as representative business usage.
3. Compare the two assessments' sizes and estimates. Write a short summary of the four-server scope, actual readiness, outstanding conditions, monthly estimate, pricing assumptions, and limitations. Treat any reserved-capacity or licensing comparison as optional and dependent on real eligibility.

**Expected Result:** If you complete the comparison, you can explain why its recommendations differ and how limited collection affects confidence. Your summary distinguishes an Azure VM estimate from a full business case.

### Why This Matters — CSA Context

Assessment settings are business assumptions as well as technical inputs. A useful stakeholder summary explains what was assessed, what is ready, what remains unresolved, and how region, utilization evidence, and licensing affect the estimate. Unsupported savings percentages or guaranteed readiness weaken that summary.

---

## Step 6: Dependency Analysis

Dependency analysis answers **“What talks to what?”** An assessment can size a VM without identifying every connection needed for a working application.

### 6.1 — Check the Available Dependency Experience

**Concept:** Dependency visualization depends on the current feature, supported source, guest access, and observed connections. It is not guaranteed for every project or portal experience, and the core Azure VM assessment does not depend on a map being available.

#### Hands-On Steps

1. **Azure portal:** Open one of the four discovered servers and look for the available **Dependencies** or **Dependency analysis** experience. Review its prerequisites and collection status before enabling an offered appliance-based option.
2. **Appliance configuration manager — browser:** If that experience requests guest access, confirm the Windows guest administrator and Linux SSH/sudo credentials saved in Step 3.4, and validate them using the available controls. Host credentials alone do not provide guest dependency collection.
3. **Azure portal:** Enable or configure the available supported collection option if offered, and note its observation period. If no supported map is available for your source, record that limitation and continue with the known architecture and application observations in the following sections. **Do not install retired MMA/OMS or legacy Dependency Agent packages to make a map appear.**

**Expected Result:** You know whether supported dependency collection is available and configured, or have explicitly recorded its absence. You can continue the dependency exercise without installing retired monitoring agents.

### 6.2 — Generate Manual Application Activity

**Concept:** A dependency collector samples activity; it cannot reliably show an idle or brief HTTP connection. Use a small amount of real business activity, not a benchmark or background load generator.

#### Hands-On Steps

1. **HyperVHost — browser:** Open **http://192.168.0.12:8080** to use Contoso Order Desk through the Nginx proxy. Inspect the existing customer/order data.
2. Select an **existing customer** and create **one clearly identifiable sample order** using the application's order-entry controls. Record its identifier and confirm it appears in the order list. Do not delete seeded records, modify the database directly, or submit repeated orders for load.
3. Open **http://192.168.0.13:3000** to view the same application directly on Tomcat. Confirm the order remains visible. Return to the proxy page and perform a few normal page views as needed, without leaving a repeating process running.
4. If the order cannot be created or read, record the application failure and stop further writes. Do not alter SQL credentials, permissions, or application files as part of this exercise.

**Expected Result:** One sample order is stored and visible through the proxy and direct application paths, or an application issue is explicitly recorded without further writes. This activity exercises the source application; it is not a load or migration test.

### 6.3 — View and Interpret the Dependency Map

**Concept:** The application has proxy, callback, and shared-database dependencies. A partial observed map does not establish that the missing connections are unnecessary.

#### Hands-On Steps

1. **Azure portal:** If dependency collection is available, reopen the dependency view after collection has had time to observe the manual activity. Select a time range that includes it.
2. Inspect the Linux web and application servers and the SQL server. Record observed source, destination, port, and process details where the feature provides them.
3. Compare the observations with the known application connections below. Note Windows-to-SQL reporting connections only if they are already active and observed; do not start an additional scheduled process to manufacture them.
4. Record connections as **observed** or **known from architecture/application behavior**. If the map is unavailable or incomplete, use the lab architecture and the proxy/direct order responses as evidence, stating what was not observed. A successful response alone does not prove every edge was sampled.

**Expected Result:** Your dependency notes distinguish observed connections from known architectural dependencies and retain the application group even when the map is partial or unavailable.

| Connection | Port | Planning significance |
|---|---|---|
| OnPrem-Linux-Web (Nginx) → OnPrem-Linux-App (Tomcat) | TCP 3000 | The order-desk proxy needs the application backend |
| OnPrem-Linux-App → OnPrem-SQL | TCP 1433 | Tomcat reads and writes `ContosoApp` |
| OnPrem-Linux-App → OnPrem-Linux-Web | TCP 8080 | The application also uses the Nginx proxy path; web/app dependencies are not one-way |
| OnPrem-Web → OnPrem-SQL, where existing reporting activity is active | TCP 1433 | Windows reporting shares the SQL dependency; an idle map can omit it |

### Why This Matters — CSA Context

A live map is evidence about a collection window, not a complete application contract. The reverse proxy and application have cyclic connectivity, and SQL is stateful and shared. Splitting the servers into apparently independent cutover waves would risk connectivity failures and inconsistent application state.

---

## Migration Wave Planning

### Concepts — Plan the Connected Application, Not Just the Teaching Pairs

The four workload VMs form a small connected migration group. Modules 2 and 3 teach work on different **pairs**, but those pairs are **not different Hyper-V replication types** and are **not safe independent cutover waves**. Hyper-V replication is host-based for both pairs.

| Planning stage | Scope | Boundary |
|---|---|---|
| Module 2 teaching pair | OnPrem-Web + OnPrem-Linux-Web | Prepare replication and isolated testing; hold frontend cutover |
| Module 3 teaching pair | OnPrem-SQL + OnPrem-Linux-App | Prepare replication and stateful application/database tests |
| Coordinated cutover group | All four workload VMs | Cut over only after all four and their connected application have been tested |

### Hands-On Steps — Record Your Plan

1. **Local workstation — lab notes:** List all four workloads as **one coordinated cutover group**. Exclude the discovery appliance.
2. Attach the assessment's actual readiness conditions and the dependency notes. Identify any unresolved item that must be cleared before migration testing or cutover.
3. Record the reviewed target region, target VNet `10.1.0.0/16`, and isolated test VNet `10.2.0.0/16`. Plan validation of the proxy, direct Tomcat application, database-backed order read/write, and any active Windows reporting path in the test environment before production traffic changes.
4. State that frontend cutover is held until the stateful application/database tests and the complete four-VM test are successful. Keep the source serving the lab during preparation; do not split application writes between source and target databases.
5. Record the need for a single coordinated final synchronization/source shutdown and traffic-switch decision in the later migration modules, plus a rollback decision before target writes are accepted. Do not shut down, delete, or cut over any source VM in this module.

**Expected Result:** Your notes identify one connected four-VM cutover group, its readiness conditions, test coverage, and source/target write boundary. Teaching-pair sequencing has not been mistaken for independent migration waves.

### Discussion Questions

- Which dependency would be missed if you looked only at an idle HTTP map?
- Why does a Ready VM assessment not prove the order desk can be cut over independently?
- Which assessment assumptions would you revisit after observing representative business usage?
- What must be true of SQL data and application writes before switching the frontend?

---

## Key Takeaways

- **Discovery establishes identity and scope.** Validate the four named workloads and their source details, not just a count.
- **The Hyper-V discovery appliance does not replicate workloads.** Host replication is a separate setup step in Module 2; no guest Mobility Service is needed.
- **Manual deployment has security boundaries.** Verify the published archive, preserve the exported configuration, scope host access, and keep project keys and credentials private.
- **Assessment results need interpretation.** Review completed results for all four servers and record region, readiness, sizing, pricing, and collection limitations.
- **Missing map edges are not proof of independence.** Combine current observations with known application behavior and architecture.
- **Coordinate the connected cutover.** The teaching pairs prepare one four-VM migration group; the frontends wait for successful stateful and full-application testing.

---

## Next Steps

You have created and registered the discovery appliance, validated the four-server inventory, reviewed an Azure VM assessment, and recorded a dependency-aware migration plan. Keep the appliance and source workloads running for continued collection and the next module.

➡️ Continue to **[Module 2: Hyper-V Migration](Module-2-Agentless-Migration.md)** to configure the separate host replication components and begin migration preparation. Keep the frontend cutover on hold until the later stateful and coordinated application tests are complete.
