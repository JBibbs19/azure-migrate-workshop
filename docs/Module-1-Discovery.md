# Module 1 · Discovery and assessment

**TD SYNNEX | Cloud Enablement Services**

In this module you discover the four workload VMs you built in Module 0 and produce an Azure VM assessment from them. Two different components are involved, and keeping them straight now will save confusion later: the **discovery appliance** you build here performs assessment, while the **host replication provider** introduced in Module 2 is what actually moves VM data.

## 1. Create the project

From the Azure portal, search for **Azure Migrate** and create a project in your **source resource group** — for example `ces-migrate-01`. Select the intended subscription and a permitted project geography, then record the resource names the service creates.

> **Note:** The project metadata location and the migration target region are separate settings. Do not assume one determines the other, and do not rely on a hard-coded geography mapping.

Portal labels vary as Azure Migrate rolls out its newer **Explore / Decide / Execute** experience. Follow the operation described here if the portal places it under a different heading. The classic equivalent is **Servers, databases and web apps**. [Create and manage projects](https://learn.microsoft.com/azure/migrate/create-manage-projects)

## 2. Prepare the Hyper-V host

Inside HyperVHost, run the host-preparation script linked from Microsoft's [Hyper-V discovery tutorial](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v) in an elevated Windows PowerShell session. Verify its currently published hash or signature before running it. Follow its prompts to configure the discovery account, PowerShell remoting and the required permissions.

Deployment has already opened WinRM to the nested subnet only, which is the path the appliance uses. Keep it that way — there is no reason to expose WinRM beyond the internal lab network.

When you add host credentials later, use `HyperVHost\labadmin` (or whichever host user you chose). The guest Windows credentials are different: `Administrator`, with the lab password.

> **Warning:** Do not enable CredSSP just because you see it in a cluster example. This lab stores guest disks locally, not on remote SMB shares, so it is not needed.

## 3. Download, extract and import the appliance VHD

The Azure Migrate appliance is a lightweight Windows Server VM that performs agentless discovery of your Hyper-V environment. Deployment did not create it — it created the four workloads and reserved host capacity for the appliance, as listed in [Module 0, section 3.7](Module-0-Setup.md#37--azure-migrate-appliance-requirements). You build the appliance here, from Microsoft's published VHD.

Work inside HyperVHost in an elevated Windows PowerShell session.

### 3.1 — Generate the project key

1. In your Azure Migrate project, open discovery and select **Hyper-V** as the source.
2. Choose the **VHD** download option rather than the installer script.
3. Enter the appliance name `MigrateAppl` and generate the project key.
4. **Copy the key and keep it somewhere safe** — you need it during registration, and it must stay out of Git, screenshots and chat.

### 3.2 — Confirm the appliance store

Deployment created a dedicated partition for the appliance. Everything in this section stays on it: the download, the extracted VHD and the running VM. Confirm it is present before downloading anything:

```powershell
# Appliance store on HyperVHost — expect label ApplianceStore, roughly 100 GB, nearly all free
Get-Volume -DriveLetter E | Select-Object DriveLetter,FileSystemLabel,Size,SizeRemaining
Get-Item E:\Appliance
```

**Expected result:** `E:` exists, is labelled `ApplianceStore`, and the `E:\Appliance` folder is present.

> **Note:** Deployment takes the first unassigned drive letter and reports it when it finishes — `E:` on the default host size, because `D:` holds the virtual DVD drive. If yours differs, substitute it in the commands below. `Get-Volume -FileSystemLabel ApplianceStore` finds it whatever the letter.

> **Note:** This partition is the appliance's own capacity. The four workload VHDs are fixed disks on `C:` and never grow into it, so the appliance cannot be starved by guest growth. Keep it that way — do not stage the download on `C:`.

### 3.3 — Download and verify the archive

Download the appliance archive from the project's download link into `E:\Appliance`. Then verify it against the hash Microsoft publishes for that exact file before you extract it:

```powershell
$archive = Get-ChildItem 'E:\Appliance' -Filter *.zip | Select-Object -First 1
Get-FileHash -Path $archive.FullName -Algorithm SHA256 | Format-List
Expand-Archive -Path $archive.FullName -DestinationPath 'E:\Appliance\Extracted'
```

Stop if the hash does not match. Keep the archive until the import succeeds, then delete it — the archive and the extracted VHD both sit on `E:`, and reclaiming roughly 11 GB gives the appliance disk room to grow.

> **Tip:** Download directly onto the host with the Edge browser inside HyperVHost, rather than downloading to your workstation and copying a 10 GB file across an RDP session.

### 3.4 — Import the VHD as a VM

Create the appliance VM on the internal lab switch and reserve its address:

```powershell
# Keep the VHD on E: — the VM must run from the appliance store, not from C:
$vhd = (Get-ChildItem 'E:\Appliance\Extracted' -Recurse -Include *.vhd,*.vhdx | Select-Object -First 1).FullName
New-VM -Name MigrateAppl -MemoryStartupBytes 16GB -VHDPath $vhd -SwitchName intSwitch -Path 'E:\Appliance\VMs' -Generation 1
Set-VMProcessor -VMName MigrateAppl -Count 8
Set-VMMemory -VMName MigrateAppl -DynamicMemoryEnabled $false
Set-VM -Name MigrateAppl -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
Set-VMNetworkAdapter -VMName MigrateAppl -StaticMacAddress '00155D000014'
Enable-VMIntegrationService -VMName MigrateAppl -Name 'Time Synchronization'
Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress 192.168.0.20 `
    -ClientId '00-15-5D-00-00-14' -Name MigrateAppl
```

**Expand the disk before first boot.** Microsoft's appliance VHD is published at around 40 GB, but the documented requirement for a Hyper-V appliance is **16 GB memory, 8 vCPUs and roughly 80 GB of disk**. The VM must be grown to meet it, and growing the virtual disk is far simpler before Windows has booted from it.

```powershell
# What the published VHD provides — expect MaxGB around 40
Get-VHD $vhd | Select-Object VhdType,@{N='CurrentGB';E={[math]::Round($_.FileSize/1GB,1)}},@{N='MaxGB';E={[math]::Round($_.Size/1GB,1)}}
Get-Volume -DriveLetter E | Select-Object SizeRemaining

# Grow it to the documented 80 GB
Resize-VHD -Path $vhd -SizeBytes 80GB
Get-VHD $vhd | Select-Object @{N='MaxGB';E={[math]::Round($_.Size/1GB,1)}}
```

**Expected result:** `MaxGB` is now 80.

Now start the VM:

```powershell
Start-VM -Name MigrateAppl
```

**Expected result:** `Get-VM MigrateAppl` shows the VM running, and `Get-VMHardDiskDrive -VMName MigrateAppl` shows its disk on `E:`.

> **Note:** `Resize-VHD` grows the **virtual disk**, not the partition inside it. Windows still sees roughly 40 GB until the partition is extended, which you do at first boot in section 3.5.

> **Note on the 100 GB partition.** `E:` is the host-side store that holds the download, the extracted VHD and the running VM — it is not the appliance's own disk. An 80 GB dynamic disk consumes only what the appliance actually writes, so it sits comfortably inside 100 GB alongside the archive. Leave this disk **dynamic**: unlike the four workload VMs, the appliance is lab infrastructure rather than an assessment subject, so its disk I/O profile does not affect the sizing data, and a fixed 80 GB disk plus the 40 GB source during conversion would not fit in the partition.

The static MAC follows the same `00-15-5D-00-00-xx` scheme deployment used for the workloads, so the appliance picks up `192.168.0.20` from the host's DHCP scope automatically.

Time Synchronization is enabled by default on a new Hyper-V VM, so the line above is usually redundant. It is included because this VM comes from an imported configuration rather than one you created, and an import carries whatever the exported settings held. Confirm it took effect:

```powershell
# Time sync on MigrateAppl — expect Enabled True and PrimaryStatusDescription OK
Get-VMIntegrationService -VMName MigrateAppl -Name 'Time Synchronization'
```

> **Warning:** `-Generation 1` matches the `.vhd` Microsoft currently publishes. Confirm the generation and disk format in the current article rather than assuming — a Generation 2 VM will not boot a Generation 1 VHD, and the failure looks like a broken download.

### 3.5 — Complete first boot

Open the VM console in Hyper-V Manager, accept the appliance's first-boot prompts, and set its administrator password when asked.

**Extend the partition to use the space you added.** Section 3.4 grew the virtual disk to 80 GB; Windows inside the appliance still sees the original partition until you extend it. In an elevated PowerShell session **inside `MigrateAppl`**:

```powershell
# Free space available to grow into — expect roughly 40 GB of unallocated space
Get-Disk | Select-Object Number,@{N='SizeGB';E={[math]::Round($_.Size/1GB)}},@{N='UnallocatedGB';E={[math]::Round($_.LargestFreeExtent/1GB)}}

# Extend C: into it
$max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
Resize-Partition -DriveLetter C -Size $max

# Confirm — expect roughly 80 GB
Get-Volume -DriveLetter C | Select-Object DriveLetter,@{N='SizeGB';E={[math]::Round($_.Size/1GB)}},@{N='FreeGB';E={[math]::Round($_.SizeRemaining/1GB)}}
```

Then confirm the appliance has:

- Eight processors and 16 GB RAM, with dynamic memory off
- Roughly 80 GB on `C:`, matching Microsoft's documented requirement
- Its virtual disk file on `E:`, not `C:`
- Address `192.168.0.20`, gateway `192.168.0.1`
- Working DNS and internet access
- A correct clock, checked in UTC

Check the clock explicitly, inside `MigrateAppl`:

```powershell
# Appliance clock on MigrateAppl — expect UTC within a minute or two of real time
[DateTime]::UtcNow

# Time zone on MigrateAppl — expect UTC, matching HyperVHost and the workload guests
Get-TimeZone
```

If the time zone is wrong, set it to match the rest of the lab and force a resynchronization:

```powershell
Set-TimeZone -Id 'UTC'
w32tm /resync /force
```

**Expected outcome:** `MigrateAppl` is running in Hyper-V Manager alongside the four workload VMs, with a UTC clock that agrees with the host.

> ⚠️ **Check the clock before you register.** Hyper-V time synchronization aligns the guest's **UTC clock** with the host's, but it does not set the guest's **time zone**, and it does not override a clock changed inside the guest after boot. An appliance whose clock has drifted or whose region was set during first-boot prompts will still register successfully and then discover nothing, because Azure rejects the timestamps on its requests. Discovery returning an empty inventory with no obvious error is the usual symptom.

> **Note:** The appliance software is already in Microsoft's VHD. Do not run `AzureMigrateInstaller.ps1` inside it, and never run it on HyperVHost itself.

> **Instructor note.** Microsoft's production prerequisites document an external switch. This nested lab uses one NIC with NAT and DHCP for both host reachability and egress, so validate that path end to end before teaching it, and do not present the nested topology as a supported production configuration. [Set up an appliance for Hyper-V](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v)

## 4. Register and discover

Once the appliance has finished its first boot, open the appliance configuration manager — the shortcut inside `MigrateAppl`, or `https://192.168.0.20:44368` from a browser on the host.

> **Warning:** Use HTTPS on port 44368. The configuration manager does not respond on HTTP. You will see a certificate prompt on first connection; confirm you are connecting to your own appliance before accepting it.

Work through the configuration manager in order:

1. Complete the connectivity, time and update checks.
2. Paste the project key and sign in to the correct Azure tenant and subscription.
3. Add the Hyper-V host credentials and the host address `192.168.0.1`. Use `HyperVHost\labadmin` — the guest Windows credentials are different.
4. Validate the source, resolve every failed prerequisite, then start discovery.
5. **Add guest credentials.** In *Manage credentials and discovery sources*, step 3, add credentials for the guests themselves. These are separate from the Hyper-V host credentials added in the previous step, and without them the appliance discovers the VMs but never looks inside them. The credential **type** you pick from the dropdown matters as much as the username — see the table below.
6. Return to the project and confirm the four workloads appear:

| Workload | Expected source OS | Expected address |
|---|---|---|
| OnPrem-Web | Windows Server 2022 | 192.168.0.10 |
| OnPrem-SQL | Windows Server 2022 | 192.168.0.11 |
| OnPrem-Linux-Web | Ubuntu 22.04 | 192.168.0.12 |
| OnPrem-Linux-App | Ubuntu 22.04 | 192.168.0.13 |

Check the **names**, OS details, CPU and memory — not just the count. A raw total of four machines is not proof, because the appliance itself can appear in inventory.

### Credentials this lab needs

Add these in the appliance configuration manager. One credential of each type covers both guests of that kind — the appliance maps credentials to servers itself, so you do not assign them per machine.

| Credential type | Username | Applies to | Enables |
|---|---|---|---|
| Windows (non-domain) | `HyperVHost\<lab user>` | HyperVHost, as the **discovery source** | VM inventory, configuration and performance metadata |
| Windows (non-domain) | `Administrator` | `OnPrem-Web`, `OnPrem-SQL` | Software inventory, ASP.NET web apps, agentless dependency analysis |
| Linux (non-domain) | `<lab user>` | `OnPrem-Linux-Web`, `OnPrem-Linux-App` | Software inventory, agentless dependency analysis |
| SQL Server authentication *or* Windows authentication | see note | `OnPrem-SQL` only | SQL Server instance and database discovery |

All four use the same lab password you supplied at deployment. The **usernames differ by platform**, which is worth being clear about before you start typing them in:

| Machine | Account | Where it comes from |
|---|---|---|
| HyperVHost | your lab user, e.g. `labadmin` | The `-AdminUsername` you passed to `deploy-lab.ps1`; this is the Azure VM's administrator |
| `OnPrem-Web`, `OnPrem-SQL` | `Administrator` | The **built-in** Windows account. Unattended setup sets its password to the lab password; no new account is created |
| `OnPrem-Linux-Web`, `OnPrem-Linux-App` | your lab user, e.g. `labadmin` | Created by cloud-init using the same `-AdminUsername`, so it matches the host account |

So there is no separate Linux-only account. The Linux guests and the host share one username; only the Windows guests differ, because they reuse the built-in `Administrator` rather than creating a second account.

Deployment records the name it actually used, so you never have to guess:

```powershell
# On HyperVHost — the LinuxUsername field is the account on both Linux guests
Get-Content C:\AzMigrateLab\lab-traffic.settings.json
```

> **Note:** If you deployed with `-AdminUsername` set to something other than `labadmin`, substitute that name everywhere this guide writes `labadmin` — including the SSH commands and the appliance credentials.

> **Note on the SQL credential.** Software inventory finds the SQL instance; a **separate SQL credential** is what lets the appliance connect to it and read database detail. Use Windows authentication with the guest `Administrator` account, which is sysadmin on the Express instance. Do not use the `labapp` SQL login created by the optional traffic mesh — it holds only `db_datareader` and `db_datawriter` on `ContosoApp`, and SQL discovery needs server-level read permissions such as `VIEW SERVER STATE`.

> **Note on privilege.** Microsoft's support matrix asks for different levels depending on the feature: software inventory needs only a guest user on Windows and a standard non-sudo user on Linux, while **agentless dependency analysis** needs a Windows account with administrator rights and a Linux sudo account with `NOPASSWD` for `ls` and `netstat`. This lab uses `Administrator` and `labadmin` — which already has passwordless sudo — so both levels are satisfied by one credential each. In a customer environment, prefer the lowest privilege that covers the features you are demonstrating.

### Linux prerequisites for full visibility

Deployment configures all of these. Confirm them on each Linux guest before blaming discovery for an empty result:

| Requirement | Check | Expected |
|---|---|---|
| SSH reachable from the appliance | `Test-NetConnection 192.168.0.12 -Port 22` from `MigrateAppl` | `TcpTestSucceeded: True` |
| Account has sudo, no password prompt | `sudo -n true && echo SUDO_OK` | `SUDO_OK` — cloud-init grants `labadmin` `ALL=(ALL) NOPASSWD:ALL` |
| Commands dependency analysis runs | `for c in ls netstat ss getcap locate; do command -v $c >/dev/null \|\| echo "MISSING $c"; done` | no output |
| Guest daemons running | `systemctl is-active hv-kvp-daemon` | `active` |
| Distribution supported | `lsb_release -d` | Ubuntu 22.04, within the support matrix |

Provisioning records the same facts, so you can check without opening a session:

```powershell
# On HyperVHost — expect LAB_SUDO_NOPASSWD_OK, LAB_DEPENDENCY_COMMANDS_OK, LAB_SSH_ACTIVE
Get-Content C:\AzMigrateLab\setup-log.txt | Select-String 'LAB_SUDO|LAB_DEPENDENCY|LAB_SSH|LAB_KVP'
```

> **Note:** `netstat`, `ss`, `getcap` and `locate` come from `net-tools`, `iproute2`, `libcap2-bin` and `plocate`. Ubuntu cloud images ship none of them reliably, so deployment installs all four. A missing `getcap` is the easiest to overlook — it appears in Microsoft's dependency-analysis command list but not in most base images.

Then open the **Software inventory** column on the Discovered servers page. You should see:

| Guest | Expected inventory |
|---|---|
| OnPrem-Web | IIS web server role, ASP.NET 4.5 |
| OnPrem-SQL | SQL Server 2022 Express, with the `ContosoApp` database under SQL discovery |
| OnPrem-Linux-Web | Nginx |
| OnPrem-Linux-App | Node.js, the `contoso-app` service |

> **Warning:** An empty Software inventory column almost always means guest credentials are missing, not that the guests have no applications. VM inventory comes through the Hyper-V host; software inventory connects **directly to each guest** over PowerShell remoting on Windows and SSH on Linux, using the credentials from step 5. No credentials, no applications — and no error message either.

If the column stays empty after adding credentials and rerunning discovery, check the connection the appliance actually uses:

```powershell
# From MigrateAppl — expect TcpTestSucceeded True for both Windows guests
Test-NetConnection 192.168.0.10 -Port 5985
Test-NetConnection 192.168.0.11 -Port 5985
```

```bash
# From MigrateAppl or the host — expect a version string from both Linux guests
ssh labadmin@192.168.0.12 'command -v locate && nginx -v'
ssh labadmin@192.168.0.13 'command -v locate && node --version'
```

Deployment enables PowerShell remoting on the Windows guests and installs `plocate` on the Linux guests, because software inventory runs `locate` to find installed applications and Ubuntu cloud images omit it. If either check fails, that prerequisite did not take.

> **Note:** Software inventory and the Azure VM assessment are different things. Applications appear under **Discovered servers → Software inventory**; the assessment reports sizing, readiness and cost, and never lists applications.

> **Tip:** Discovery runs continuously and takes time, so a short wait and a refresh are normal. But if host validation is failing, waiting longer will not fix it — diagnose the validation error first. [Hyper-V assessment support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v)

**If no servers appear at all,** work through these in order before waiting any longer:

| Check | Where | Expectation |
|---|---|---|
| Appliance clock | `[DateTime]::UtcNow` in `MigrateAppl` | UTC within a minute or two of real time. A skewed clock is the most common cause of an empty inventory. |
| Host reachability | `Test-NetConnection 192.168.0.1 -Port 5985` in `MigrateAppl` | `TcpTestSucceeded: True` |
| PowerShell remoting | `Enter-PSSession -ComputerName 192.168.0.1 -Credential HyperVHost\labadmin` in `MigrateAppl` | A session opens. Run `Exit-PSSession` afterwards. |
| Host inventory | `Get-VM` on HyperVHost | Four VMs, all `Running` |
| Host validation | Appliance configuration manager, discovery source panel | Validation succeeded, with no error text |

Integration Services is worth ruling in or out correctly here: it governs whether the host can report a guest's **operating system details**, not whether the VM is discovered at all. Missing Integration Services shows up as servers listed with blank OS information — not as an empty inventory.

If the **Linux** servers appear with missing OS details, check the Data Exchange (KVP) daemon on each of them:

```powershell
# KVP daemon on the Linux guests — expect active
ssh labadmin@192.168.0.12 'systemctl is-active hv-kvp-daemon'
ssh labadmin@192.168.0.13 'systemctl is-active hv-kvp-daemon'
```

Deployment installs the daemons, enables them and reboots each Linux guest once so they start. If one reports anything other than `active`, work through the following on the affected guest, then restart discovery.

> **Note:** The reboot is deliberate. The tools package installs the udev rules that create `/dev/vmbus/hv_kvp`, and the daemon's systemd unit requires that device — so the service cannot start in the same boot that installed it. On a lab built before this was added, a single `sudo reboot` on each Linux guest starts the enabled services.

First confirm the kernel module is loaded — the daemon's systemd unit requires the device node it creates:

```bash
# Hyper-V utilities module — expect hv_utils in the output
lsmod | grep hv_

# KVP device node — expect hv_kvp to exist
ls -l /dev/vmbus/
```

If the module or device is missing, load it and make it persistent:

```bash
sudo modprobe hv_utils
echo hv_utils | sudo tee /etc/modules-load.d/hyperv.conf
```

Then install the userspace daemons. Install the two packages **separately** — combined in one command, an unavailable versioned package causes apt to abort the whole transaction and install neither:

```bash
sudo apt-get update
sudo apt-get install -y linux-cloud-tools-common
sudo apt-get install -y "linux-cloud-tools-$(uname -r)" \
  || sudo apt-get install -y linux-cloud-tools-virtual linux-tools-virtual
sudo systemctl enable --now hv-kvp-daemon.service
systemctl is-active hv-kvp-daemon
```

> **Note:** Ubuntu cloud images carry the `hv_netvsc` and `hv_storvsc` modules but not `hv_utils`, and none of the userspace daemons. That is why a guest can have working network and disk while reporting nothing about itself to the host.

> **Warning:** `A dependency job for hv-kvp-daemon.service failed` means the unit's required device is absent, not that the daemon itself failed — load `hv_utils` before trying to start the service. If `modprobe hv_utils` reports no such module, the kernel flavour does not ship it; installing `linux-virtual` provides one that does, and that path needs a reboot.

> **Instructor note.** Run these commands with `sudo`. Ubuntu cloud images leave the root account locked by design, and `systemctl` without `sudo` falls through to a polkit prompt asking for a root password that does not exist. The lab user has passwordless sudo.

When you plan migration waves later, exclude `MigrateAppl` from the workloads you move. The appliance is lab infrastructure, not a workload.

## 5. Create the assessment

Create an **Azure VM** assessment for a group containing exactly the four workload VMs. Use the target region you chose in Module 0, the currency and pricing agreement that apply to you, no commitment discounts for a lab this short, and no Azure Hybrid Benefit unless entitlement has been confirmed.

On a freshly built lab, start with **as-on-premises** sizing. Then create a second, performance-based assessment once data has accumulated and compare the two.

Record for each machine: readiness, any unsupported configuration, the selected Azure size, OS disk, target network, and the estimated compute and storage cost. Resolve readiness warnings against the migration support matrix before you replicate anything in Module 2.

> **Warning:** Write down the collection period, the confidence rating, and the fact that these samples come from an idle lab. A few minutes of idle telemetry cannot justify a production right-sizing recommendation, and presenting it as though it can is the single most common way a good assessment loses a customer's trust. [Assess Hyper-V servers](https://learn.microsoft.com/azure/migrate/tutorial-assess-hyper-v)

## 6. Interpret the dependency view

What you see here depends on whether the sample business traffic from [Module 0, section 6](Module-0-Setup.md#6-start-the-sample-business-traffic) is running.

**Without it,** the IIS site, the Nginx site and the Node API are independent samples — none of them calls SQL or each other. An empty application dependency view is the correct result, and saying so is a more useful lesson than manufacturing a diagram. Do not go looking for a connection string or a `/api/products` endpoint; they do not exist in the base lab.

**With it,** the four workloads behave as one order desk: Nginx proxies to the Node API, the Node API reads and writes `ContosoApp` over TCP 1433, and the IIS server runs an internal order report against that same database. `OnPrem-SQL` therefore appears as a shared dependency of both application tiers — the finding that tells a customer the database cannot be moved on its own.

Either way, agentless dependency discovery needs supported guest credentials and time to collect observations.

> **Note:** Do not install the retired Microsoft Monitoring Agent to make a diagram appear.

> **Instructor note.** Start the traffic mesh before appliance registration if you want a populated map. Dependency analysis samples active connections on a polling interval rather than recording continuously, so traffic that begins a few minutes before you open the map may not be represented in it. Keep the generated load light — the same idle-telemetry caveat in section 5 cuts both ways, and a heavy generator produces sizing recommendations that are just as fictional as an idle lab's.

**Pass gate:** the appliance is registered, host validation succeeds, the four named workloads are visible, and the assessment exists with reviewed readiness. Continue to [Module 2](Module-2-HyperV-Migration.md).
