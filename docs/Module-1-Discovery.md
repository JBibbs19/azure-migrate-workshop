**TD SYNNEX | Cloud Enablement Services**

# Module 1: Discovery & Assessment — The Foundation of Every Successful Migration

> **Cloud Adoption Framework Phase:** Assess · **Prerequisite:** [Module 0: Setup](Module-0-Setup.md) completed

## Module Overview

Discovery establishes what you have, how it is connected, and what must be addressed before migration. A proper discovery phase ensures that the trajectory of migration project goes according to plan. A common pitfall in cloud migration projects is the skill gap required to assess a proposed environment and whether it will be compatible with the current system’s architecture. Azure Migrate’s discovery tools can perform this assessment for you. By highlight systems that need to be modernized before a ‘lift-and-shift’ transfer can happen and checking if there is an Azure service that can perform the same duty as a current solution in use by your organization, it simplifies some of the more complicated aspects of cloud migration.

This module walks you through discovery and assessment using Azure Migrate, but every step includes the "why" and "what you'd do differently at scale" context that separates a lab exercise from production readiness.

In this module, you will manually create an Azure Migrate project, import and register the Migrate Discovery appliance, discover four workload VMs from Module 0, and create an **Azure VM assessment**. You will then examine application dependencies and establish a Migration Wave Plan.

A thorough discovery reveals:

- **Workload inventory** — server names, operating systems, resources, and installed software.
- **Dependencies** — the connections that must remain available when workloads move.
- **Readiness conditions** — configurations that need investigation before replication.
- **Cost estimates** — target-region estimates whose assumptions you can explain.

The Hyper-V Migrate appliance used here performs **discovery and assessment only**. Host-based replication is configured separately in Module 2.

------------------------------------------------------------------------

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

------------------------------------------------------------------------

## Concepts — Azure Migrate Architecture

### Azure Migrate Hub

Azure Migrate provides a project in which discovery, assessment, and migration information is organized. Portal navigation appears under **Explore / Decide / Execute.** The steps below name the operation to perform; the exact navigation text may differ in your portal.

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

> **Key point for security-conscious customers:** Only metadata flows to Azure during discovery. No workload data, application data, or VM disks leave the on-premises environment until you explicitly begin replication in Module 2 or 3.

### The Lab Environment

The source is a Windows Server 2022 Hyper-V host: `Standard_E8s_v7`, Generation 2 with NVMe storage, eight vCPUs, and 64 GB RAM. Its internal switch, `intSwitch`, uses NAT for `192.168.0.0/24`; the host is `.1`. The appliance will use that same switch for host access and outbound internet connectivity.

| Workload VM | Source OS | Application | Source address |
|---|---|---|---|
| OnPrem-Web | Windows Server 2022 | IIS, HTTP 80 | 192.168.0.10 |
| OnPrem-SQL | Windows Server 2022 | SQL Server 2022 Express, `ContosoApp`, TCP 1433 | 192.168.0.11 |
| OnPrem-Linux-Web | Ubuntu 24.04 | Nginx, HTTP 80 and order-desk proxy on 8080 | 192.168.0.12 |
| OnPrem-Linux-App | Ubuntu 24.04 | Tomcat 10.1, Java 17, Contoso Order Desk on 3000 | 192.168.0.13 |

The Azure source VNet uses `10.0.0.0/16`. The migration target VNet uses `10.1.0.0/16`, and the isolated test VNet uses `10.2.0.0/16`. The migration target region must be **different from the actual source host region** in this lab. (i.e. The default region for the lab is **East US**. A suitable target region would be **West US 2**)

### Assessment Types

Azure Migrate supports multiple assessment targets — not just Azure VMs:

| Assessment Type | What It Evaluates | When to Use |
|---|---|---|
| **Azure VM** | IaaS lift-and-shift readiness | Default for most server workloads |
| **Azure SQL** | SQL Server → Azure SQL DB, MI, or SQL on VM | Database migration planning |
| **Azure App Service** | Web apps → Azure App Service | .NET/Java web app modernization |
| **Azure VMware Solution (AVS)** | VM → AVS node sizing | VMware-native migration path |

------------------------------------------------------------------------

## Step 1: Create an Azure Migrate Project

### 1.1 — Pre-Flight Check

Before you create the project, confirm that the environment you built in Module 0 is still in the state this module expects. The project metadata geography, resource group location, source host region, and migration target region are distinct settings. A resource group's location does not establish where its VMs run.

#### Hands-On Steps

**Local workstation — Azure portal:**

1.  Open the **HyperVHost** VM in the source resource group.

2.  Record its actual **Location** from the VM overview.

3.  Confirm that the migration region you recorded in Module 0, Section 3.3, is different from this location.

    You build the target network and its NSG in that region in Module 2; nothing needs to exist there yet.

4.  Confirm that your quota is still sufficient, using the checks in Module 0, Section 3.2.

**Local workstation — RDP client:**

5.  Connect to HyperVHost using the lab deployment credentials.

**HyperVHost — elevated PowerShell:**

6.  Confirm that the four workload VMs are present and **Running**.

    ```powershell
    Get-VM -Name OnPrem-Web,OnPrem-SQL,OnPrem-Linux-Web,OnPrem-Linux-App |
        Select-Object Name,State
    ```

7.  If a workload is stopped, start it; if it is paused, resume it.

    ```powershell
    Start-VM -Name '<stopped workload name>'
    Resume-VM -Name '<paused workload name>'
    ```

    If a workload is missing, resolve the incomplete Module 0 setup before proceeding.

8.  Confirm the sample business traffic from Module 0, Section 6, is running: read the orders twice, a minute or two apart.

    ```powershell
    Invoke-RestMethod http://192.168.0.13:3000/api/orders
    ```

    If the number of orders does not increase, complete Module 0, Section 6, before continuing.

**Expected Result:** HyperVHost's location is recorded and differs from your migration region, quota is still sufficient, all four workload VMs are Running, and the sample traffic is adding orders. No replication or cutover has started.

### 1.2 — Create the Project in the Portal

The project gives the appliance and assessment a common scope. Its geography controls discovery metadata residency; it does not choose the migration target region.

#### Hands-On Steps

**HyperVHost — Azure portal:**

1.  Navigate to **Azure Migrate** using the search bar.

2.  Select **Create Project** beneath the **Decide and Plan** section.

3.  On the **Create Project** page, confirm that your subscription is filled in.

    1.  For the **Resource group**, select the source resource group.
    2.  Under **Project Details**, provide a name for your project (for example, `proj-az-mig`).
    3.  Leave the advanced options unmodified, with **Public Endpoint**.

4.  Create the project. It takes a few moments.

    Check the **Notifications** bell to see the progress of the project creation.

5.  Once complete, find the project in either of two places:

    1.  Under the resource group, as an **Azure Migrate** resource type.
    2.  On the **Azure Migrate** page, under **All Projects**.

6.  Open the created project.

7.  Select the **Start Discovery** dropdown on the project page.

8.  Select **Using Appliance**, and **For Azure** as the destination setting.

**Expected Result:** The project opens in the Azure portal and provides the Hyper-V discovery entry point.

### Why This Matters — CSA Context

A project is a migration scope, not permission to move every machine it discovers. Keeping source identity, metadata residency, and target location separate prevents an assessment from being priced for one region while migration is configured for another.

------------------------------------------------------------------------

## Step 2: Deploy the Azure Migrate Appliance

### 2.1 — Download and Verify the Appliance Archive

Import the published Hyper-V appliance export, rather than creating an empty Windows VM. The lab's **ApplianceStore** is a dedicated partition on the host OS disk, normally `E:`, not a separate managed data disk or the appliance's guest `C:` drive.

#### Hands-On Steps

**HyperVHost — Azure portal:**

1.  From the open project page, you should now be on a **Discover** page.

2.  Select **Hyper-V** as the virtualization source.

3.  Select the **.VHD** file as the download option.

4.  While waiting for the download to complete, enter an appliance registration name, such as `MigrateAppl`.

    Use an alphanumeric name of no more than 14 characters.

5.  Select **Generate key** to generate the project key.

6.  Copy the key into an approved private location for Step 3.

    Keep it out of screenshots, shared notes, source control, and command output.

**HyperVHost — File Explorer or PowerShell:**

7.  Identify the volume labelled **ApplianceStore** and its drive letter (normally `E:\`).

    Use its `Appliance` folder for the archive, extraction, and imported VM files.

8.  Extract the ZIP into a new folder under the appliance store, `E:\Appliance\Extracted`.

    Keep the published folder structure intact and do not overwrite an existing VM's files.

**Expected Result:** The project key is stored privately, and the appliance package is extracted to `E:\Appliance\Extracted` on the appliance store.

### 2.2 — Prepare the Hyper-V Host

Azure Migrate does not reach into a Hyper-V guest to discover it. It talks to the **host**, and the host reports on the virtual machines it runs. So before anything is discovered, the host has to be willing to answer — and in most organisations it is not, because nothing has ever needed to ask it.

Whatever your organisation runs Hyper-V for — a few line-of-business servers in a branch office, a consolidated rack in a datacentre, a lab that quietly became production — the appliance needs the same things to be true of every host holding workloads you intend to migrate. Microsoft publishes a host-preparation script that configures them, described in its [Hyper-V discovery tutorial](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v). The script is signed; verify its signature or published hash before running it anywhere.

#### What the Script Configures, and Why the Appliance Needs It

| Step | What it does, and what fails without it |
|---|---|
| **WinRM service, ports 5985/5986** | Starts WinRM and opens its ports. The appliance collects each guest's configuration and performance metadata over a **CIM session** to the host. This is the channel that carries it — closed, nothing is discovered at all. |
| **PowerShell version check** | Confirms PowerShell 4.0 or later. The appliance issues PowerShell to the host, and older versions lack the cmdlets it calls. A check, not a change. |
| **Discovery account** | The appliance signs in to the host as this account. It must be a host administrator, or belong to **Remote Management Users** (permits the WinRM connection), **Hyper-V Administrators** (permits reading VM inventory and configuration) and **Performance Monitor Users** (permits reading the counters that drive right-sizing). In a domain environment this is usually the account you will be asked to justify to whoever owns the host. |
| **PowerShell remoting** | Runs `Enable-PSRemoting`. WinRM being open is not enough on its own — remoting is what lets the appliance *execute* on the host rather than merely connect to it. |
| **Hyper-V Integration Services** | Checks they are enabled on every guest. They supply each guest's **OS detail and IP address** to the host. Without them a guest is still discovered, but its operating system column stays blank and the assessment cannot size it properly. |
| **CredSSP delegation** | Needed only where guest disks sit on **remote SMB shares**, because the host must then pass your credentials onward to the file server. It is the one item on this list that is not a default, and it relays credentials — so it is worth knowing whether your estate actually requires it before enabling it anywhere. |

Run against a real estate, this script is often the point where a migration stalls: the host is someone else's responsibility, the changes need a change record, and the discovery account needs an owner. Budget for that conversation.

#### In This Environment

You do **not** run Microsoft's script in this lab. The Module 0 deployment already prepared HyperVHost for discovery and recorded the result. Two details differ from what the Microsoft script would have done:

1.  **WinRM is open to the nested lab subnet only.** The script opens 5985 and 5986 without a scope. Here they are restricted to `192.168.0.0/24`, which is the only network the appliance ever connects from. Narrower is better, and it is worth carrying that habit into a real engagement.
2.  **The lab user is already a host administrator**, which satisfies the account requirement on its own. It is also a member of the three groups above, so the least-privilege path can be examined without rebuilding anything.

CredSSP is not enabled, because the workload disks are local to HyperVHost. Step 3.1 shows how to confirm and, if needed, configure host access manually.

#### Hands-On Steps

**HyperVHost — elevated PowerShell:**

1.  Read the host-preparation summary that deployment recorded.

    ```powershell
    Get-Content C:\AzMigrateLab\hyperv-prep.json | ConvertFrom-Json
    ```

2.  Review each item against the table above.

    Anything showing `Failed` or `NOT FOUND` is applied by hand in Step 3.1 before discovery.

**Expected Result:** The summary shows PowerShell remoting enabled, WinRM allowed from `192.168.0.0/24` only, the discovery account prepared, and CredSSP not enabled. This is a recorded summary, not a live check; Step 3.1 confirms host access directly.

### 2.3 — Import the Published Appliance Configuration

The export contains the appliance VM configuration and its disk. Copy-import creates a new VM identity while preserving that configuration. The source host's Generation 2 setting does not change this **Generation 1 appliance**.

Choose **one** of the two options below. Option A uses the Hyper-V Manager import wizard, then a PowerShell command to apply this lab's appliance settings. Option B imports the appliance and applies the same settings entirely in PowerShell. Both options give the appliance eight vCPUs, 16 GB of static memory, a connection to `intSwitch`, a fixed MAC address, and a DHCP reservation for `192.168.0.20`.

#### Hands-On Steps — Option A: Import with Hyper-V Manager

**HyperVHost — Hyper-V Manager:**

1.  Select **Import Virtual Machine**.

2.  Select the folder that you extracted (usually named `AzureMigrateAppliance_v***`).

3.  Confirm that the wizard identifies the Azure Migrate appliance.

    If the wizard cannot find the exported configuration, stop and check the extracted package; do not substitute a newly created empty VM or guess a disk.

4.  Choose **Copy the virtual machine (create a new unique ID)**, not register in place.

5.  Set the configuration, checkpoint, smart-paging, and virtual-disk destinations under the actual appliance store, for example `E:\Appliance\VMs`.

    Check that there is enough free space for the physical source files before the copy.

    Do not accept the default destinations on host `C:\`.

6.  Leave all other settings as they are and complete the import.

    If the wizard asks you to choose a network connection, select **intSwitch**.

7.  Note the imported VM's display name in Hyper-V Manager.

    Optionally rename it to `MigrateAppl` so it is easy to identify; the display name is separate from project registration.

**HyperVHost — elevated PowerShell:**

8.  Before first boot, run the configuration command below.

    If your VM's display name is not `MigrateAppl`, change `$name` to match it.

    ```powershell
    $name = 'MigrateAppl'

    Set-VM -Name $name -ProcessorCount 8 -MemoryStartupBytes 16GB -StaticMemory `
        -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
    Connect-VMNetworkAdapter -VMName $name -SwitchName intSwitch
    Set-VMNetworkAdapter -VMName $name -StaticMacAddress '00155D000014'
    Enable-VMIntegrationService -VMName $name -Name 'Time Synchronization'

    Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress 192.168.0.20 `
        -ClientId '00-15-5D-00-00-14' -Name $name
    ```

    The MAC address `00-15-5D-00-00-14` follows the lab's addressing pattern (`14` is hexadecimal for `.20`) and is not used by the four workloads. If the reservation command reports that `192.168.0.20` is already reserved, stop and check the existing reservation rather than overwriting it.

**HyperVHost — Hyper-V Manager:**

9.  Confirm that the VM configuration and attached disks are on ApplianceStore, not among the four workload disks on host `C:\`.

#### Hands-On Steps — Option B: Import and Configure with PowerShell

**HyperVHost — elevated PowerShell:**

1.  Set the appliance name and store location, and find the exported configuration file.

    ```powershell
    $name  = 'MigrateAppl'
    $store = 'E:\Appliance'
    $vmcx  = @(Get-ChildItem "$store\Extracted" -Recurse -Filter *.vmcx)
    $vmcx | Select-Object FullName
    ```

    Exactly one `.vmcx` file should be listed. If none or more than one is listed, stop and use Option A.

2.  Check the import for problems, copying the VM into the appliance store with a new ID.

    ```powershell
    $report = Compare-VM -Path $vmcx[0].FullName -Copy -GenerateNewId `
        -VirtualMachinePath "$store\VMs" -SnapshotFilePath "$store\VMs" `
        -SmartPagingFilePath "$store\VMs" -VhdDestinationPath "$store\VMs\Virtual Hard Disks"
    $report.Incompatibilities | Select-Object MessageId, Message
    ```

3.  If the only problem listed is a missing network switch, connect the adapter to `intSwitch`.

    ```powershell
    $report.Incompatibilities | Where-Object MessageId -eq 33012 |
        ForEach-Object { $_.Source | Connect-VMNetworkAdapter -SwitchName intSwitch }
    ```

    If any other problem is listed, stop and use Option A.

4.  Import the appliance and give it the lab display name.

    ```powershell
    Import-VM -CompatibilityReport $report | Rename-VM -NewName $name
    ```

5.  Apply the lab's appliance settings and reserve its address. This is the same command as Option A, step 8.

    ```powershell
    Set-VM -Name $name -ProcessorCount 8 -MemoryStartupBytes 16GB -StaticMemory `
        -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
    Connect-VMNetworkAdapter -VMName $name -SwitchName intSwitch
    Set-VMNetworkAdapter -VMName $name -StaticMacAddress '00155D000014'
    Enable-VMIntegrationService -VMName $name -Name 'Time Synchronization'

    Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress 192.168.0.20 `
        -ClientId '00-15-5D-00-00-14' -Name $name
    ```

6.  Confirm the VM settings and that every disk is on the appliance store.

    ```powershell
    Get-VM -Name $name | Select-Object Name, State, ProcessorCount, MemoryStartup, DynamicMemoryEnabled
    Get-VMHardDiskDrive -VMName $name | Select-Object Path
    ```

**Expected Result:** A new, still-off appliance VM appears in Hyper-V Manager with the published configuration, eight vCPUs, 16 GB static memory, a fixed MAC on `intSwitch`, a DHCP reservation for `192.168.0.20`, and its files on ApplianceStore. The four workload VMs are unchanged.

### 2.4 — Configure Networking and Reserve the Appliance Address (Optional Manual Method)

This lab uses one appliance NIC on **intSwitch**. The internal switch provides host/guest access, DHCP, and outbound internet through host NAT. Do not add an external or Default Switch NIC for this lab.

The PowerShell command in Step 2.3 already completes this step. Use the steps below only if you want to see or perform the same configuration manually instead of running that command, or to confirm what it did.

#### Hands-On Steps — Optional

**HyperVHost — Hyper-V Manager:**

1.  Open the imported appliance's **Settings > Network Adapter**.

2.  Confirm that it connects to **intSwitch**.

3.  Open the adapter's **Advanced Features** and record its actual MAC address.

    1.  If none is assigned yet, start this appliance to let Hyper-V allocate one.
    2.  Complete only the console first-boot prompts described in Step 2.5.
    3.  Shut it down cleanly and return here.

4.  Confirm no other VM uses that MAC.

5.  Select **Static** and retain the actual address.

    That way, it will not change after reservation.

    Do not copy another VM's MAC or invent a shared value.

**HyperVHost — DHCP console:**

6.  Open **Server Manager > Tools > DHCP**, expand the host, then **IPv4 > Scope 192.168.0.0**.

7.  Inspect **Address Leases** and **Reservations**.

    Confirm `192.168.0.20` is not already allocated or reserved to a different client, and that the appliance MAC is not assigned to another reservation.

    Resolve a conflict before continuing; do not overwrite another client.

8.  Under **Reservations**, choose **New Reservation**.

9.  Enter the appliance display name, IP address **192.168.0.20**, and the actual appliance NIC MAC from the previous step.

10. Select **DHCP** as the supported client type.

11. Save the reservation.

12. Confirm the scope is active and its options provide gateway **192.168.0.1** and the lab's working DNS settings.

13. Leave the appliance guest NIC configured to obtain its address through DHCP.

**Expected Result:** The appliance NIC is attached to intSwitch with a stable, unique MAC, and the host DHCP scope reserves `192.168.0.20` for that exact NIC.

### 2.5 — Start the Appliance and Complete First Boot

First boot establishes the appliance's local administrator password and network configuration. Accurate time and outbound connectivity are needed for Azure authentication and registration.

#### Hands-On Steps

**HyperVHost — Hyper-V Manager:**

1.  Start the Migrate Appliance VM.

2.  Select **Connect** to open its console.

**Appliance — console:**

3.  Complete the first-boot prompts and set its local administrator password.

    It is best to use the lab password you established previously to make it easier to remember. If you choose a different password, be sure to record it.

4.  Sign in to the appliance VM.

**Appliance — PowerShell:**

5.  Inspect the NIC configuration.

    ```powershell
    ipconfig /all
    ```

    Confirm address **192.168.0.20**, subnet mask **255.255.255.0**, gateway **192.168.0.1**, and working DNS servers.

    If it received another address, correct the reservation/MAC match before continuing.

6.  Check the host WinRM path.

    ```powershell
    Test-NetConnection 192.168.0.1 -Port 5985
    ```

**Appliance — browser:**

7.  Wait for the Azure Migrate Configuration Manager to start automatically once the machine finishes setting up.

    Alternatively, open [**https://localhost:44368**](https://localhost:44368) in the appliance's browser, or open [**https://192.168.0.20:44368**](https://192.168.0.20:44368) from a browser on HyperVHost.

8.  Confirm the destination is your own appliance before accepting its local certificate warning.

**Expected Result:** The appliance is Running, you can sign in, and the configuration manager opens over HTTPS on port 44368. The host connectivity check should return `TcpTestSucceeded: True`; if it does not, complete the host configuration in Step 3.1 before discovery.

### Why This Matters — CSA Context

Verifying the archive is a stop/go security check, not an optional warning. Importing the published export also avoids silently changing the appliance generation or storage layout. DHCP reservation gives the lab a predictable source address while keeping the guest network configuration DHCP-based.

------------------------------------------------------------------------

## Step 3: Configure the Appliance and Start Discovery

### 3.1 — Confirm and Configure Hyper-V Host Access

The appliance must be able to query the host over WinRM and read Hyper-V inventory and performance counters. Module 0 prepares this access, but you still need to confirm it and know how to configure it manually.

#### Hands-On Steps

**HyperVHost — elevated PowerShell:**

1.  Check the WinRM service.

    ```powershell
    Get-Service WinRM
    ```

2.  If PowerShell remoting is not configured, confirm that **vEthernet (intSwitch)** is the trusted private lab connection.

3.  Configure remoting locally.

    ```powershell
    Enable-PSRemoting -Force
    ```

**HyperVHost — Windows Defender Firewall with Advanced Security:**

4.  Inspect the inbound lab WinRM rule.

    Confirm it allows the appliance's nested subnet **192.168.0.0/24** to reach host TCP **5985**.

5.  If the rule is missing, create an inbound TCP 5985 allow rule for the private lab connection with that remote-address scope.

6.  Review any remoting rules created by the preceding command and narrow overlapping broad access to the same trusted lab range.

    Do not disable the firewall or expose WinRM to the internet; opening a port does not create an HTTPS listener.

**HyperVHost — Computer Management > Local Users and Groups:**

7.  Confirm that the host discovery account supplied by the lab deployment is a local administrator.

    Use the host-local lab administrator credential, not your personal Azure sign-in. A separate non-administrator discovery account would need **Remote Management Users**, **Hyper-V Administrators**, and **Performance Monitor Users** membership; do not add those memberships to unrelated accounts.

**Appliance — PowerShell:**

8.  If the earlier check failed, repeat it.

    ```powershell
    Test-NetConnection 192.168.0.1 -Port 5985
    ```

    Resolve host reachability before adding the discovery source.

**Expected Result:** WinRM is Running, remoting is configured, the discovery account has the required host permissions, and the appliance can reach host TCP 5985 through a scoped private lab rule.

> **Safety:** The workload disks are local to HyperVHost, not remote SMB shares. Do not enable CredSSP for this lab or set a wildcard TrustedHosts entry to bypass connection validation.

### 3.2 — Complete Appliance Prerequisites

The configuration manager checks the appliance's own connectivity, clock, and components before registration. Host connectivity and Azure connectivity are separate paths.

#### Hands-On Steps

**Appliance — Appliance configuration manager (browser):**

1.  Review and accept the appliance setup terms as prompted.

2.  Run the prerequisite checks.

3.  Confirm the appliance can reach the required Azure services through the lab NAT and DNS configuration.

    The lab should not require a proxy. Configure one only if your lab network requires it.

4.  Check that the appliance's UTC time is accurate.

    Correct its time synchronization if required; changing only the display time zone does not correct clock skew.

5.  Allow the appliance to check for and apply its updates.

6.  Refresh or reopen the configuration manager if prompted.

7.  Rerun any failed prerequisite check.

**Expected Result:** The configuration manager shows successful prerequisite checks and allows Azure registration to proceed. Do not continue past an unresolved connectivity, time, or update failure.

### 3.3 — Register with Azure

The generated project key associates this appliance with your project. Browser authentication authorizes registration; it is not a host or guest credential.

#### Hands-On Steps

**Appliance — Appliance configuration manager (browser):**

1.  In the project registration area, enter the project key you saved in Step 2.1.

2.  Select the Azure sign-in action when prompted.

3.  Complete browser authentication with an account authorized for the lab project.

    Check the tenant and subscription rather than accepting an unrelated signed-in account.

4.  Return to the configuration manager and review the identified project and appliance name.

5.  Select **Register** when available.

6.  Wait for the registration confirmation.

    Keep the project key and authentication details private; do not copy them into your results notes.

**Expected Result:** The appliance reports successful registration to your intended Azure Migrate project. An appliance already registered to another project is not reused for this exercise.

### 3.4 — Add Host and Guest Credentials

Host credentials supply VM-level inventory. Guest credentials allow supported software and dependency discovery. One does not replace the other.

#### Hands-On Steps

**Appliance — Appliance configuration manager (browser):**

1.  Open the credential management area.

2.  Add a clearly named host credential, such as `HyperVHostCreds`.

3.  Select the Windows credential type appropriate for a non-domain host.

4.  Enter the deployment-provided local administrator account and password.

    Use the host-qualified account, such as `HyperVHost\labadmin` when the deployed account is `labadmin`; if deployment supplied a different local administrator name, use that exact name. Do not substitute your workstation or Azure username.

5.  Add a **Windows guest** credential using the guests' built-in `Administrator` account and the lab deployment password, separate from the host credential.

6.  Add a **Linux guest** credential, selecting the Linux credential type.

    Use the actual Linux username and password supplied at deployment. This account uses SSH and has the lab's configured sudo access for privileged inventory/dependency operations. Do not guess a default username or change the protected application configuration.

7.  Save the credentials.

8.  Use the available validation actions for the intended source or guests.

    If optional SQL database discovery requests a separate credential, use an approved discovery credential with the required SQL metadata permissions from the lab setup guidance; the application's limited database login is not a substitute. SQL database discovery is not required to create the server assessment.

**Expected Result:** Distinct host, Windows guest, and Linux guest credential entries are saved for their intended purposes, with validation completed where offered. No passwords appear in your notes or screenshots.

### 3.5 — Add the Hyper-V Host and Start Discovery

The discovery source is the host, **HyperVHost / 192.168.0.1**, not one of the four guests and not the appliance itself.

#### Hands-On Steps

**Appliance — Appliance configuration manager (browser):**

1.  In the Hyper-V discovery-source area, select the action to add a host or cluster.

2.  Enter **192.168.0.1** as the host address, or the actual resolvable HyperVHost name.

3.  Select the host credential created in Step 3.4.

4.  Save the source.

5.  Run its connection/credential validation.

    Resolve any reported address, account, permission, or network failure before starting discovery.

6.  Confirm the saved guest credentials are available for the supported guest discovery features.

7.  Select **Start discovery**.

8.  Check that the appliance reports discovery as started and the Hyper-V source as connected or successfully validated.

**Expected Result:** The registered appliance is discovering VMs from the intended host. This starts inventory collection, not replication.

### Why This Matters — CSA Context

The host and guest credential paths explain why VM records can appear before software inventory. A successful host connection does not prove that guest SSH or Windows remoting has succeeded. Resolving the reported connection at its source is more useful than repeatedly waiting for an inventory count to change.

------------------------------------------------------------------------

## Step 4: Wait for Discovery and Validate Results

### Verify Discovery in the Azure Portal

VM inventory, software inventory, and performance collection progress separately. Initial records may appear before guest inventory is complete. A short idle-lab collection period is not representative production telemetry.

#### Hands-On Steps

**Local workstation or HyperVHost — Azure portal:**

1.  Open your Azure Migrate project and its **Discovered servers** view in the discovery and assessment area.

2.  Refresh after the appliance has had time to upload inventory.

3.  Find the four workload names individually.

    Do not treat the headline server count as proof of scope. The appliance itself may also appear.

4.  Open each workload record and compare its name, source host, OS, address, CPU, and memory with the lab inventory and Hyper-V Manager.

5.  Confirm both Linux records identify **Ubuntu 24.04**, and both Windows records identify **Windows Server 2022**.

6.  Inspect the available **Discovery status**, latest discovery information, or appliance status for fresh successful collection from your connected host.

    If a record is missing or its OS information is incomplete, return to the appliance's source/credential validation and resolve the reported issue before assessing it. Do not substitute the appliance record for a missing workload.

7.  Open **Software inventory** where available.

8.  Look for IIS, SQL Server, Nginx, and Tomcat/Java on their respective servers as guest discovery becomes available.

    Record pending or missing guest inventory honestly; it is not evidence that no application is installed.

**Local workstation — lab notes:**

9.  Record the four server names, OS values, source host, and discovery status.

    Keep the appliance out of your workload assessment selection.

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

------------------------------------------------------------------------

## Step 5: Create and Interpret an Assessment

### 5.1 — Start the Assessment Wizard

The required exercise is the **Classic Azure VM server assessment**, which evaluates IaaS readiness, sizing, and cost for four servers. It is not an application or PaaS assessment.

#### Hands-On Steps

**Local workstation or HyperVHost — Azure portal:**

1.  In your Azure Migrate project, open **Use Classic assessment tools > Assess > Azure VM** where that route is shown.

    If the portal places server assessments elsewhere, use the current **Azure VM assessment** entry for discovered servers.

2.  Choose appliance-discovered server data if asked for the discovery source.

3.  Enter a learner-chosen assessment name, such as `WorkshopAzureVM`.

4.  Open the assessment properties/settings.

**Expected Result:** You are configuring an Azure VM server assessment using the appliance's discovered inventory, not selecting SQL instances, IIS sites, or other application assets.

### 5.2 — Configure Assessment Settings

**As on-premises** sizing maps the allocated source resources to Azure. **Performance-based** sizing uses collected utilization and requires sufficient representative data. Start with as-on-premises for a newly discovered lab; compare performance-based sizing later if useful.

#### Hands-On Steps

**Local workstation or HyperVHost — Azure portal (assessment settings):**

1.  Set the target location to the migration target region recorded in Step 1.

    Confirm it is not the source host region, the resource group location by assumption, or the project metadata geography by default.

2.  Review and apply the following baseline settings, using the equivalent controls in your portal.

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

3.  Save the settings.

**Local workstation — lab notes:**

4.  Record the selected settings.

    If the available pricing agreement differs, record the actual agreement rather than presenting its estimate as the baseline above.

**Expected Result:** The assessment uses documented as-on-premises settings, the intended migration target region, and explicit pricing/licensing assumptions. No entitlement or commitment discount has been assumed.

### 5.3 — Select Servers to Assess

The assessment group must contain exactly the four workload **server records**. Additional software, SQL, web-application, or appliance records are outside this selection.

#### Hands-On Steps

**Local workstation or HyperVHost — Azure portal (server selection):**

1.  Create a group with a learner-chosen name, such as `WorkshopFourServers`.

    Select an existing group only after checking its membership.

2.  Select only **OnPrem-Web**, **OnPrem-SQL**, **OnPrem-Linux-Web**, and **OnPrem-Linux-App**, using the source details validated in Step 4.

3.  Verify that the selection contains exactly those four servers and excludes `MigrateAppl` or any other appliance display name.

4.  Continue to the review page.

5.  Check the group, four members, region, sizing method, and pricing settings.

6.  Select **Create assessment**.

**Expected Result:** An Azure VM assessment is created for a group containing exactly the four named workload servers. Creating an assessment has not started VM replication.

### 5.4 — Review Assessment Results

Creating an assessment is not the same as reviewing its results. Readiness is an assessment finding, not proof that the application has been tested or that migration capacity is reserved.

#### Hands-On Steps

**Local workstation or HyperVHost — Azure portal:**

1.  Open the project's Azure VM assessments list and select your assessment.

2.  Refresh until the portal reports **Completed**.

    If it fails, inspect the reported reason rather than proceeding on the basis that an assessment name exists.

3.  Open the results.

4.  Open the readiness summary and drill into each of the four servers.

5.  Read the actual readiness result and any explanation or recommended action.

    Do not assume all four will be Ready.

6.  Review each proposed Azure VM size, disk recommendation, and compute/storage estimate.

7.  Check whether the recommended sizes are available and within quota in the target region before planning replication.

**Local workstation — lab notes:**

8.  Record your actual findings in a table like this, including the assessment settings and collection period beside it.

| Server | Actual readiness and conditions | Recommended Azure size | Estimated monthly compute / storage | Collection period / confidence, if shown |
|---|---|---|---|---|
| OnPrem-Web | Record portal result | Record portal result | Record portal estimate | Record available evidence |
| OnPrem-SQL | Record portal result | Record portal result | Record portal estimate | Record available evidence |
| OnPrem-Linux-Web | Record portal result | Record portal result | Record portal estimate | Record available evidence |
| OnPrem-Linux-App | Record portal result | Record portal result | Record portal estimate | Record available evidence |

**Local workstation or HyperVHost — Azure portal:**

9.  Optionally, select the portal's **Export** action to download the assessment workbook (`.xlsx`) to your own lab storage.

    Export is optional; the reviewed results and settings are the required evidence.

**Expected Result:** You have opened the completed assessment and reviewed readiness, recommended sizes, and cost estimates for all four workloads. Any unresolved condition is recorded with its required follow-up; no fixed readiness or price is assumed.

### 5.5 — Interpreting Readiness Categories

Use the wording and details shown in your portal. Typical categories distinguish ready servers, servers needing attention, unsupported configurations, and incomplete evidence.

| Readiness finding | Meaning for your plan |
|---|---|
| Ready | Assessment found no blocking configuration in the collected evidence; application testing is still required |
| Ready with conditions / Conditionally ready | Review each condition and resolve or explicitly account for it before proceeding |
| Not ready | Investigate the stated unsupported configuration or target limitation before replication |
| Unknown / Insufficient data | Obtain the missing discovery information and reassess rather than assuming readiness |

A readiness result is specific to its settings and evidence. It does not authorize source shutdown, guarantee a recommended SKU will be allocatable, or remove the need for isolated migration tests.

### 5.6 — Optional Performance Comparison and Business Case

Performance-based sizing can inform a comparison, but an idle lab does not establish production demand. Assessment estimates are not a complete total cost of ownership calculation.

#### Hands-On Steps — Optional

**Local workstation or HyperVHost — Azure portal:**

1.  After more performance data has accumulated, create a second Azure VM assessment of the **same four servers** using **performance-based** sizing.

    Keep the target region and pricing assumptions the same for comparison.

2.  Review its available history, percentile, comfort factor, and confidence/data coverage.

3.  Record the actual collection window.

    Do not describe a short idle sample as representative business usage.

4.  Compare the two assessments' sizes and estimates.

**Local workstation — lab notes:**

5.  Write a short summary of the four-server scope, actual readiness, outstanding conditions, monthly estimate, pricing assumptions, and limitations.

    Treat any reserved-capacity or licensing comparison as optional and dependent on real eligibility.

**Expected Result:** If you complete the comparison, you can explain why its recommendations differ and how limited collection affects confidence. Your summary distinguishes an Azure VM estimate from a full business case.

### Why This Matters — CSA Context

Assessment settings are business assumptions as well as technical inputs. A useful stakeholder summary explains what was assessed, what is ready, what remains unresolved, and how region, utilization evidence, and licensing affect the estimate. Unsupported savings percentages or guaranteed readiness weaken that summary.

------------------------------------------------------------------------

## Step 6: Dependency Analysis

Dependency analysis answers **"What talks to what?"** An assessment can size a VM without identifying every connection needed for a working application.

### 6.1 — Check the Available Dependency Experience

Dependency visualization depends on the current feature, supported source, guest access, and observed connections. It is not guaranteed for every project or portal experience, and the core Azure VM assessment does not depend on a map being available.

#### Hands-On Steps

**Local workstation or HyperVHost — Azure portal:**

1.  Open one of the four discovered servers.

2.  Look for the available **Dependencies** or **Dependency analysis** experience.

3.  Review its prerequisites and collection status before enabling an offered appliance-based option.

**Appliance — Appliance configuration manager (browser):**

4.  If that experience requests guest access, confirm the Windows guest administrator and Linux SSH/sudo credentials saved in Step 3.4.

5.  Validate them using the available controls.

    Host credentials alone do not provide guest dependency collection.

**Local workstation or HyperVHost — Azure portal:**

6.  Enable or configure the available supported collection option if offered.

7.  Note its observation period.

    If no supported map is available for your source, record that limitation and continue with the known architecture and application observations in the following sections. **Do not install retired MMA/OMS or legacy Dependency Agent packages to make a map appear.**

**Expected Result:** You know whether supported dependency collection is available and configured, or have explicitly recorded its absence. You can continue the dependency exercise without installing retired monitoring agents.

### 6.2 — Generate Manual Application Activity

A dependency collector samples activity; it cannot reliably show an idle or brief HTTP connection. The sample traffic you started in Module 0, Section 6, provides steady background activity. This step adds one order you create yourself, so you can follow it through the application.

#### Hands-On Steps

**HyperVHost — browser:**

1.  Open [**http://192.168.0.12:8080**](http://192.168.0.12:8080) to use Contoso Order Desk through the Nginx proxy.

2.  Inspect the existing customer/order data.

3.  Select an **existing customer**.

4.  Create **one clearly identifiable sample order** using the application's order-entry controls.

    Do not delete seeded records, modify the database directly, or submit repeated orders for load.

5.  Record its identifier and confirm it appears in the order list.

6.  Open [**http://192.168.0.13:3000**](http://192.168.0.13:3000) to view the same application directly on Tomcat.

7.  Confirm the order remains visible.

8.  Return to the proxy page and perform a few normal page views as needed.

9.  If the order cannot be created or read, record the application failure and stop further writes.

    Do not alter SQL credentials, permissions, or application files as part of this exercise.

**Expected Result:** One sample order is stored and visible through the proxy and direct application paths, or an application issue is explicitly recorded without further writes. This activity exercises the source application; it is not a load or migration test.

### 6.3 — View and Interpret the Dependency Map

The application has proxy, callback, and shared-database dependencies. A partial observed map does not establish that the missing connections are unnecessary.

#### Hands-On Steps

**Local workstation or HyperVHost — Azure portal:**

1.  If dependency collection is available, reopen the dependency view after collection has had time to observe the activity.

2.  Select a time range that includes it.

3.  Inspect the Linux web and application servers and the SQL server.

**Local workstation — lab notes:**

4.  Record observed source, destination, port, and process details where the feature provides them.

5.  Compare the observations with the known application connections below.

    The Windows-to-SQL reporting connections come from the sample traffic started in Module 0, Section 6.

6.  Record connections as **observed** or **known from architecture/application behavior**.

    If the map is unavailable or incomplete, use the lab architecture and the proxy/direct order responses as evidence, stating what was not observed. A successful response alone does not prove every edge was sampled.

**Expected Result:** Your dependency notes distinguish observed connections from known architectural dependencies and retain the application group even when the map is partial or unavailable.

| Connection | Port | Planning significance |
|---|---|---|
| OnPrem-Linux-Web (Nginx) → OnPrem-Linux-App (Tomcat) | TCP 3000 | The order-desk proxy needs the application backend |
| OnPrem-Linux-App → OnPrem-SQL | TCP 1433 | Tomcat reads and writes `ContosoApp` |
| OnPrem-Linux-App → OnPrem-Linux-Web | TCP 8080 | The application also uses the Nginx proxy path; web/app dependencies are not one-way |
| OnPrem-Web → OnPrem-SQL, where existing reporting activity is active | TCP 1433 | Windows reporting shares the SQL dependency; an idle map can omit it |

### Why This Matters — CSA Context

A live map is evidence about a collection window, not a complete application contract. The reverse proxy and application have cyclic connectivity, and SQL is stateful and shared. Splitting the servers into apparently independent cutover waves would risk connectivity failures and inconsistent application state.

------------------------------------------------------------------------

## Migration Wave Planning

### Concepts — Plan the Connected Application, Not Just the Teaching Pairs

The four workload VMs form a small connected migration group. Modules 2 and 3 teach work on different **pairs**, but those pairs are **not different Hyper-V replication types** and are **not safe independent cutover waves**. Hyper-V replication is host-based for both pairs.

| Planning stage | Scope | Boundary |
|---|---|---|
| Module 2 teaching pair | OnPrem-Web + OnPrem-Linux-Web | Prepare replication and isolated testing; hold frontend cutover |
| Module 3 teaching pair | OnPrem-SQL + OnPrem-Linux-App | Prepare replication and stateful application/database tests |
| Coordinated cutover group | All four workload VMs | Cut over only after all four and their connected application have been tested |

#### Hands-On Steps — Record Your Plan

**Local workstation — lab notes:**

1.  List all four workloads as **one coordinated cutover group**.

    Exclude the discovery appliance.

2.  Attach the assessment's actual readiness conditions and the dependency notes.

3.  Identify any unresolved item that must be cleared before migration testing or cutover.

4.  Record the reviewed target region, target VNet `10.1.0.0/16`, and isolated test VNet `10.2.0.0/16`.

5.  Plan validation of the proxy, direct Tomcat application, database-backed order read/write, and any active Windows reporting path in the test environment before production traffic changes.

6.  State that frontend cutover is held until the stateful application/database tests and the complete four-VM test are successful.

    Keep the source serving the lab during preparation; do not split application writes between source and target databases.

7.  Record the need for a single coordinated final synchronization/source shutdown and traffic-switch decision in the later migration modules, plus a rollback decision before target writes are accepted.

    Do not shut down, delete, or cut over any source VM in this module.

**Expected Result:** Your notes identify one connected four-VM cutover group, its readiness conditions, test coverage, and source/target write boundary. Teaching-pair sequencing has not been mistaken for independent migration waves.

### Discussion Questions

- Which dependency would be missed if you looked only at an idle HTTP map?
- Why does a Ready VM assessment not prove the order desk can be cut over independently?
- Which assessment assumptions would you revisit after observing representative business usage?
- What must be true of SQL data and application writes before switching the frontend?

------------------------------------------------------------------------

## Key Takeaways

- **Discovery establishes identity and scope.** Validate the four named workloads and their source details, not just a count.
- **The Hyper-V discovery appliance does not replicate workloads.** Host replication is a separate setup step in Module 2; no guest Mobility Service is needed.
- **Manual deployment has security boundaries.** Verify the published archive, preserve the exported configuration, scope host access, and keep project keys and credentials private.
- **Assessment results need interpretation.** Review completed results for all four servers and record region, readiness, sizing, pricing, and collection limitations.
- **Missing map edges are not proof of independence.** Combine current observations with known application behavior and architecture.
- **Coordinate the connected cutover.** The teaching pairs prepare one four-VM migration group; the frontends wait for successful stateful and full-application testing.

------------------------------------------------------------------------

## Next Steps

You have created and registered the discovery appliance, validated the four-server inventory, reviewed an Azure VM assessment, and recorded a dependency-aware migration plan. Keep the appliance and source workloads running for continued collection and the next module.

➡️ Continue to [**Module 2: Hyper-V Migration**](Module-2-Agentless-Migration.md) to configure the separate host replication components and begin migration preparation. Keep the frontend cutover on hold until the later stateful and coordinated application tests are complete.
