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

### 3.2 — Confirm the staging space

Before downloading anything, check that the folder deployment prepared for you is present and the host still has room:

```powershell
Get-Item C:\AzMigrateLab\Appliance
Get-Volume -DriveLetter C | Select-Object DriveLetter,SizeRemaining
```

**Expected result:** the folder exists, and `C:` reports at least 80 GB free.

> **Note:** The compressed download and the expanded VHD both have to fit, alongside four guest VHDs that grow as the workshop runs. Deployment checked this space before provisioning, but confirm it again here — the guests have been running since.

### 3.3 — Download and verify the archive

Download the appliance archive from the project's download link into `C:\AzMigrateLab\Appliance`. Then verify it against the hash Microsoft publishes for that exact file before you extract it:

```powershell
$archive = Get-ChildItem 'C:\AzMigrateLab\Appliance' -Filter *.zip | Select-Object -First 1
Get-FileHash -Path $archive.FullName -Algorithm SHA256 | Format-List
Expand-Archive -Path $archive.FullName -DestinationPath 'C:\AzMigrateLab\Appliance\Extracted'
```

Stop if the hash does not match. Keep the archive until the import succeeds; delete it afterwards only if you need the space back.

> **Tip:** Download directly onto the host with the Edge browser inside HyperVHost, rather than downloading to your workstation and copying a 10 GB file across an RDP session.

### 3.4 — Import the VHD as a VM

Create the appliance VM on the internal lab switch and reserve its address:

```powershell
$vhd = (Get-ChildItem 'C:\AzMigrateLab\Appliance\Extracted' -Recurse -Include *.vhd,*.vhdx | Select-Object -First 1).FullName
New-VM -Name MigrateAppl -MemoryStartupBytes 16GB -VHDPath $vhd -SwitchName intSwitch -Path 'C:\AzMigrateLab\Appliance\VMs' -Generation 1
Set-VMProcessor -VMName MigrateAppl -Count 8
Set-VMMemory -VMName MigrateAppl -DynamicMemoryEnabled $false
Set-VM -Name MigrateAppl -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
Set-VMNetworkAdapter -VMName MigrateAppl -StaticMacAddress '00155D000014'
Enable-VMIntegrationService -VMName MigrateAppl -Name 'Time Synchronization'
Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress 192.168.0.20 `
    -ClientId '00-15-5D-00-00-14' -Name MigrateAppl
Start-VM -Name MigrateAppl
```

The static MAC follows the same `00-15-5D-00-00-xx` scheme deployment used for the workloads, so the appliance picks up `192.168.0.20` from the host's DHCP scope automatically.

Time Synchronization is enabled by default on a new Hyper-V VM, so the line above is usually redundant. It is included because this VM comes from an imported configuration rather than one you created, and an import carries whatever the exported settings held. Confirm it took effect:

```powershell
# Time sync on MigrateAppl — expect Enabled True and PrimaryStatusDescription OK
Get-VMIntegrationService -VMName MigrateAppl -Name 'Time Synchronization'
```

> **Warning:** `-Generation 1` matches the `.vhd` Microsoft currently publishes. Confirm the generation and disk format in the current article rather than assuming — a Generation 2 VM will not boot a Generation 1 VHD, and the failure looks like a broken download.

### 3.5 — Complete first boot

Open the VM console in Hyper-V Manager, accept the appliance's first-boot prompts, and set its administrator password when asked. Then confirm the appliance has:

- Eight processors and 16 GB RAM
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
5. Add guest credentials only for the software inventory or dependency features you intend to demonstrate. Check their guest-side prerequisites in the support matrix first.
6. Return to the project and confirm the four workloads appear:

| Workload | Expected source OS | Expected address |
|---|---|---|
| OnPrem-Web | Windows Server 2022 | 192.168.0.10 |
| OnPrem-SQL | Windows Server 2022 | 192.168.0.11 |
| OnPrem-Linux-Web | Ubuntu 22.04 | 192.168.0.12 |
| OnPrem-Linux-App | Ubuntu 22.04 | 192.168.0.13 |

Check the **names**, OS details, CPU and memory — not just the count. A raw total of four machines is not proof, because the appliance itself can appear in inventory.

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

Deployment loads the required module and starts this daemon. If it reports anything other than `active`, work through the following on the affected guest, then restart discovery.

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
