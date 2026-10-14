# Module 1 · Discovery and assessment

**TD SYNNEX | Cloud Enablement Services**

In this module you discover the four workload VMs you built in Module 0 and produce an Azure VM assessment from them. Two different components are involved, and keeping them straight now will save confusion later: the **discovery appliance** you build here performs assessment, while the **host replication provider** introduced in Module 2 is what actually moves VM data.

## Before discovery: verify workload power and communication

The selected Azure Hyper-V host and **all four** workload VMs must be running:
`OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web`, `OnPrem-Linux-App`. `MigrateAppl` is a
separate appliance, not one of these workload prerequisites. On the correct host, inspect
`Get-VM -Name OnPrem-Web,OnPrem-SQL,OnPrem-Linux-Web,OnPrem-Linux-App | Select-Object Name,State`.
Manually repair stopped/saved guests with `Start-VM -Name '<reported workload name>'`, or
resume a paused guest with `Resume-VM`; missing guests require restoring the deployment.
A Running power state is **not** proof that the application/database is healthy or that
Hyper-V guest data exchange is communicating. Enabled integration services are not sufficient either.

Instructor Steps 1 and 2 independently read the selected host through Azure Run Command,
report each workload's state and stop on missing, non-running or unverifiable guests before
continuing. They never automatically start nested workloads. Step 1 rechecks before its
verified-project WHAT TO DO NEXT block and offers optional traffic only as its final action.
No/Enter leaves generators unchanged. See [lab traffic](Lab-Traffic.md) for background
order creation, credential handling and the explicit stop command.

## 1. Create the project

From the Azure portal, search for **Azure Migrate** and create a project in your **source resource group** — for example `ces-migrate-01`. Select the intended subscription and a permitted project geography, then record the resource names the service creates.

> **Note:** The project metadata location and the migration target region are separate settings. Do not assume one determines the other, and do not rely on a hard-coded geography mapping.

Portal labels vary as Azure Migrate rolls out its newer **Explore / Decide / Execute** experience. Follow the operation described here if the portal places it under a different heading. The classic equivalent is **Servers, databases and web apps**. [Create and manage projects](https://learn.microsoft.com/azure/migrate/create-manage-projects)

## 2. Prepare the Hyper-V host

Azure Migrate does not reach into a Hyper-V guest to discover it. It talks to the **host**, and
the host reports on the virtual machines it runs. So before anything is discovered, the host has
to be willing to answer — and in most organisations it is not, because nothing has ever needed
to ask it.

Whatever your organisation runs Hyper-V for — a few line-of-business servers in a branch office,
a consolidated rack in a datacentre, a lab that quietly became production — the appliance needs
the same five things to be true of every host holding workloads you intend to migrate. Microsoft
publishes a host-preparation script that configures them, described in its
[Hyper-V discovery tutorial](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v).
The script is signed; verify its signature or published hash before running it anywhere.

### 2.1 — What the script configures, and why the appliance needs it

| Step | What it does, and what fails without it |
|---|---|
| **WinRM service, ports 5985/5986** | Starts WinRM and opens its ports. The appliance collects each guest's configuration and performance metadata over a **CIM session** to the host. This is the channel that carries it — closed, nothing is discovered at all. |
| **PowerShell version check** | Confirms PowerShell 4.0 or later. The appliance issues PowerShell to the host, and older versions lack the cmdlets it calls. A check, not a change. |
| **Discovery account** | The appliance signs in to the host as this account. It must be a host administrator, or belong to **Remote Management Users** (permits the WinRM connection), **Hyper-V Administrators** (permits reading VM inventory and configuration) and **Performance Monitor Users** (permits reading the counters that drive right-sizing). In a domain environment this is usually the account you will be asked to justify to whoever owns the host. |
| **PowerShell remoting** | Runs `Enable-PSRemoting`. WinRM being open is not enough on its own — remoting is what lets the appliance *execute* on the host rather than merely connect to it. |
| **Hyper-V Integration Services** | Checks they are enabled on every guest. They supply each guest's **OS detail and IP address** to the host. Without them a guest is still discovered, but its operating system column stays blank and the assessment cannot size it properly. |
| **CredSSP delegation** | Needed only where guest disks sit on **remote SMB shares**, because the host must then pass your credentials onward to the file server. It is the one item on this list that is not a default, and it relays credentials — so it is worth knowing whether your estate actually requires it before enabling it anywhere. |

Run against a real estate, this script is often the point where a migration stalls: the host is
someone else's responsibility, the changes need a change record, and the discovery account needs
an owner. Budget for that conversation.

### 2.2 — In this environment

A successful new lab deployment prepares these prerequisites and now validates KVP
communication before completing. Read the recorded summary, but do not treat an old report
as a live check: Step 2 probes the selected host again. Two details differ from what the
Microsoft script would have done:

1. **WinRM is open to the nested lab subnet only.** The script opens 5985 and 5986 without a
   scope. Here they are restricted to `192.168.0.0/24`, which is the only network the appliance
   ever connects from. Narrower is better, and it is worth carrying that habit into a real
   engagement.
2. **The lab user is already a host administrator**, which satisfies the account requirement on
   its own. It is also a member of the three groups above, so the least-privilege path can be
   examined without rebuilding anything.

To see the state of each item:

```powershell
# Host preparation summary — expect PowerShellRemoting Enabled and CredSSP not enabled
Get-Content C:\AzMigrateLab\hyperv-prep.json | ConvertFrom-Json
```

> **Instructor note.** If the appliance later reports that it cannot reach the host, read this
> file first. Anything showing `Failed` or `NOT FOUND` should be applied by hand from the table
> above before troubleshooting anything else.

When you add host credentials later, use `HyperVHost\<AdminUsername>` with the actual
`-AdminUsername` supplied at deployment. The guest Windows credentials are different:
`Administrator`, with the lab password. Do not force WinRM HTTPS without a correctly
configured listener and certificate; validate the lab's existing WinRM path first.

### 2.3 — Communication is separate from health

`Get-VMIntegrationService` showing Enabled (or a healthy heartbeat) does not establish KVP
communication. Step 2 checks the live host CIM `Msvm_KvpExchangeComponent` for **all four**
VMs before project-key/appliance/discovery actions. EnabledState must be 2 and primary numeric
OperationalStatus must be 2 (normal). 13 means LostCommunication, 12 NoContact, 7 incompatible
protocol and 3 degraded; this lab stops on those or any unknown/read failure. The inherited
CommunicationStatus may be unimplemented/null, so it is not required to equal 2; known bad
values still block. The returned intrinsic OSName/OSVersion must be nonblank and match the
expected Windows or Linux/Ubuntu family. An old OS value cannot override bad live status.

On the selected Hyper-V host, this read-only inspection shows the numeric channel status:

```powershell
$vm = Get-VM -Name OnPrem-Linux-App -ErrorAction Stop # Use the reported failing VM
$cs = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_ComputerSystem `
    -Filter "Name='$($vm.Id)'" -ErrorAction Stop
Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_KvpExchangeComponent `
    -ErrorAction Stop | Select-Object EnabledState,OperationalStatus,CommunicationStatus
```

In the **named Linux guest**, inspect `uname -r`,
`systemctl status hv-kvp-daemon.service`, `journalctl -u hv-kvp-daemon.service` and
`test -x "/usr/lib/linux-tools/$(uname -r)/hv_kvp_daemon"`. A loaded hv_utils module and present
`/dev/vmbus/hv_kvp` can coexist with a failed daemon: `linux-cloud-tools-common` supplies the
unit/wrapper, not necessarily the binary for the running kernel. An enabled unit alone is
not evidence that the daemon is active.

For the missing-current-kernel-binary case, an instructor can repair **inside that guest**:

```bash
kernel="$(uname -r)"
sudo apt-get update &&
sudo apt-get install -y "linux-tools-$kernel" "linux-cloud-tools-$kernel" &&
test -x "/usr/lib/linux-tools/$kernel/hv_kvp_daemon" &&
sudo systemctl unmask hv-kvp-daemon.service &&
sudo systemctl enable --now hv-kvp-daemon.service
systemctl is-active hv-kvp-daemon.service
```

If matching packages are unavailable, **stop for repository/kernel support review**; do not
pretend `-virtual` tools cover an already running `-generic` kernel. This update neither
replaces the kernel nor upgrades Ubuntu. Follow the journal for device/service errors instead
of assuming hv_utils is missing. Reboot only when needed and safe, confirm daemon status
again, then rerun Step 2 for fresh host communication/OS metadata. Its probe installs nothing,
starts no VM and asks for no guest password; WinRM repair cannot waive a KVP failure.

For new builds, provisioning validates the exact binary, deliberately keeps KVP stopped
until the scheduled cloud-init reboot and masks it on critical installation failure. The
host must observe stable normal communication **and** application readiness before setup
can complete. `hyperv-prep.json` records the last numeric statuses and OS fields, not a direct
post-reboot systemctl result. Keep logs/credentials private. Do not redeploy a completed host
to repair one guest.

This is a **local transport/OS metadata** gate, not confirmation that Azure Migrate's OS
classifier error or software/web inventory has been resolved. After repair, validate appliance
credentials/SSH access and fresh discovery separately. See
[Microsoft's KVP component contract](https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/msvm-kvpexchangecomponent).

## 3. Download, extract and import the appliance VHD

The Azure Migrate appliance is a lightweight Windows Server VM that performs agentless discovery of your Hyper-V environment. Deployment did not create it — it created the four workloads and reserved host capacity for the appliance, as listed in [Module 0, section 3.7](Module-0-Setup.md#37--azure-migrate-appliance-requirements). You build the appliance here, from Microsoft's published VHD.

Work inside HyperVHost in an elevated Windows PowerShell session.

### 3.1 — Generate the project key

1. In your Azure Migrate project, open discovery and select **Hyper-V** as the source.
2. Choose the **VHD** download option rather than the installer script.
3. Enter the appliance name `MigrateAppl` and generate the project key.

> **Note:** Azure Migrate accepts **letters and digits only, 14 characters or fewer** for this name, which is stricter than what Hyper-V allows for a VM name. This lab uses `MigrateAppl` for both the registration name and the Hyper-V VM name, so there is one name to remember.
4. **Copy the key and keep it somewhere safe** — you need it during registration, and it must stay out of Git, screenshots and chat.

### 3.2 — Confirm the appliance store

Find the actual host volume; deployment chooses the first free drive letter, normally `E:`.
The roughly 100 GB **host-side** `ApplianceStore` is distinct from the appliance guest's
virtual disk and guest `C:`. The four workload disks stay on host `C:`. Do not stage the
appliance there or assume the store's free space guarantees sufficient guest capacity.

```powershell
$stores = @(Get-Volume -FileSystemLabel ApplianceStore | Where-Object { $_.DriveLetter })
if ($stores.Count -ne 1) { throw 'Expected exactly one ApplianceStore volume.' }
$store = $stores[0]
$applianceRoot = "$($store.DriveLetter):\Appliance"
$store | Select-Object DriveLetter,FileSystemLabel,Size,SizeRemaining
Get-Item -LiteralPath $applianceRoot
```

Keep this elevated host session open for the next steps. All archive, extraction,
configuration and imported-disk destinations must use this actual store.

### 3.3 — Download and verify the archive

Download the **Hyper-V VHD ZIP** from the project's download link into `$applianceRoot`.
If deployment's optional pre-download was enabled, it normally staged `MigrateAppl.zip`.
Explicitly select the **one full ZIP path** you intend to use; do not select the first ZIP in
a directory. A renamed ZIP is fine. Paste the current expected SHA256 from the **Hyper-V
ZIP** row of Microsoft's [Verify security table](https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance?view=migrate#verify-security), not the installer ZIP or host-preparation script row.

```powershell
# Enter the actual full filename, e.g. E:\Appliance\MigrateAppl.zip (letter/name may differ)
$archive = (Read-Host 'Full path to the downloaded Hyper-V appliance ZIP').Trim()
$item = Get-Item -LiteralPath $archive -ErrorAction Stop
$rootPrefix = [IO.Path]::GetFullPath($applianceRoot).TrimEnd('\') + '\'
if ($item.PSIsContainer -or $item.Extension -ne '.zip' -or
    -not $item.FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Select one ZIP file inside the actual ApplianceStore folder.'
}
$archive = $item.FullName
$expected = (Read-Host 'Current official Hyper-V ZIP SHA256').Trim().ToUpperInvariant()
if ($expected -notmatch '^[0-9A-F]{64}$') { throw 'Expected SHA256 must have 64 hex characters.' }
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
$item | Select-Object FullName,Length
Write-Host "Actual SHA256: $actual"
if ($actual -ne $expected) { throw 'SHA256 mismatch. STOP: do not extract, import or bypass verification.' }
```

Reference only, checked against the article on **2026-10-05**:
`AD3C72FB21037B10969548228B4F651BF5A79CD0A34D608CD470B75329A24A24`.
Always use the current official row for the downloaded artifact. A mismatch is not by
itself proof of corruption: record the exact full filename, byte length, actual and expected
hashes, and download source (without exposing a signed URL). Check artifact type/version
and source with the instructor; do not force a match or delete existing VM disks.

Renaming or copying a file without changing its bytes leaves SHA256 unchanged. Extracting
an archive does not modify the source ZIP. Renaming a file **inside** it or recompressing it
changes ZIP bytes. Booting, resizing, converting, or mounting a VHD for writes can change
the **VHD**, not the untouched source ZIP. Never compare a VHD's hash to the published ZIP
hash. `download-complete.json` is a historical record and can become stale if a ZIP is
replaced manually; neither its cached hash nor `Verified` flag substitutes for hashing the
file now. A verified ZIP also does not prove an old extracted VHD still matches it.

Only after the check succeeds, extract to a **new** folder so no existing VM disk is overwritten:

```powershell
# Read-only estimate of extracted bytes from ZIP entries; not virtual disk capacity
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($archive)
try { $expandedBytes = ($zip.Entries | Measure-Object Length -Sum).Sum }
finally { $zip.Dispose() }
$freeBytes = (Get-Volume -DriveLetter $store.DriveLetter).SizeRemaining
# Extraction plus the later copy-import needs two sets of files and working headroom
if ($freeBytes -lt (2 * $expandedBytes + 10GB)) {
    throw 'Insufficient store space for extraction, copy-import and 10 GB headroom. Stop for instructor review.'
}
$extracted = Join-Path $applianceRoot ('Extracted-' + [guid]::NewGuid().ToString('N'))
Expand-Archive -LiteralPath $archive -DestinationPath $extracted
```

The headroom is a lab planning margin, not a Microsoft guarantee of future disk growth.
Keep the ZIP for re-verification. Do not automatically delete archives or extracted folders
to make room; an instructor must first identify which files are not used by any VM.

### 3.4 — Import the published VM configuration

Follow Microsoft's [Hyper-V appliance tutorial](https://learn.microsoft.com/en-us/azure/migrate/tutorial-discover-hyper-v?view=migrate), **Create appliance** section:

1. Open **Hyper-V Manager > Import Virtual Machine** and select `$extracted`. Microsoft's
   documented export has three folders. If this package has no exported VM configuration
   or the wizard cannot identify exactly one appliance, stop and check the current official
   route; do not guess a disk or create a replacement VM with an assumed generation.
2. Select **Copy the virtual machine (create a new unique ID)**. Preserve the generation
   and firmware from the exported configuration: `.vhdx` alone does not tell you the boot generation.
3. Set **every** destination (configuration, checkpoints, smart paging and virtual disks)
   under `$applianceRoot\VMs`, not Hyper-V's defaults on host `C:`. Before copying, use
   `Get-VHD -Path '<exact exported disk path>'` to inspect `FileSize` and `Size`, and check
   the actual store's remaining space. Allow at least the source files' physical byte sizes
   plus working headroom for the extra copy; ZIP size is not copy size and dynamic disk
   maximum capacity is not current physical file size. Stop for instructor review if it will
   not fit. Do not convert the disk or automatically remove the source folders.
4. Choose `intSwitch` for this nested NAT/DHCP lab. It provides host reachability and internet
   egress; Microsoft's external-switch production prerequisite is not replaced by this lab adaptation.
5. **Before starting**, rename the imported Hyper-V VM to `MigrateAppl` in Hyper-V Manager.
   This is separate from the Azure Migrate registration name (alphanumeric, at most 14 characters).
   Do not reuse a VM already registered to a different project.

Then configure the documented Hyper-V tutorial's **16 GB static memory and eight vCPUs**,
and reserve `.20` before first boot. Use this only for the just-imported, still-off VM:

```powershell
$vm = Get-VM -Name MigrateAppl -ErrorAction Stop
if ($vm.State -ne 'Off') { throw 'Configure the newly imported appliance before starting it.' }
$nics = @(Get-VMNetworkAdapter -VMName MigrateAppl)
if ($nics.Count -ne 1) { throw 'Unexpected appliance NIC count: stop for instructor review.' }
$reservations = @(Get-DhcpServerv4Reservation -ScopeId 192.168.0.0)
$client = '00155D000014'
$conflicts = @($reservations | Where-Object {
    ($_.IPAddress.ToString() -eq '192.168.0.20' -and ($_.ClientId -replace '[-:]','') -ne $client) -or
    (($_.ClientId -replace '[-:]','') -eq $client -and $_.IPAddress.ToString() -ne '192.168.0.20')
})
if ($conflicts.Count) { throw 'DHCP reservation conflict: do not overwrite another client.' }
$leases = @(Get-DhcpServerv4Lease -ScopeId 192.168.0.0 | Where-Object {
    $_.IPAddress.ToString() -eq '192.168.0.20' -and ($_.ClientId -replace '[-:]','') -ne $client
})
if ($leases.Count) { throw '192.168.0.20 is leased to another client: stop for instructor review.' }
$otherNics = @(Get-VM | Where-Object { $_.Id -ne $vm.Id } | Get-VMNetworkAdapter |
    Where-Object { $_.MacAddress -eq $client })
if ($otherNics.Count) { throw 'The appliance MAC is already used by another VM.' }
Set-VMProcessor -VMName MigrateAppl -Count 8
Set-VMMemory -VMName MigrateAppl -StartupBytes 16GB -DynamicMemoryEnabled $false
Set-VM -Name MigrateAppl -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
Connect-VMNetworkAdapter -VMName MigrateAppl -SwitchName intSwitch
Set-VMNetworkAdapter -VMName MigrateAppl -StaticMacAddress $client
Enable-VMIntegrationService -VMName MigrateAppl -Name 'Time Synchronization'
if (-not @($reservations | Where-Object { $_.IPAddress.ToString() -eq '192.168.0.20' }).Count) {
    Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress 192.168.0.20 `
        -ClientId '00-15-5D-00-00-14' -Name MigrateAppl
}
# Read-only capacity check: retain the verified template's disk without resizing
Get-VMHardDiskDrive -VMName MigrateAppl | ForEach-Object { Get-VHD -Path $_.Path } |
    Select-Object Path,VhdType,@{N='FileGB';E={[math]::Round($_.FileSize/1GB,1)}},@{N='CapacityGB';E={[math]::Round($_.Size/1GB,1)}}
Get-Volume -DriveLetter $store.DriveLetter | Select-Object SizeRemaining
```

Microsoft still documents **roughly 80 GB of appliance disk**. Removing learner expansion
steps does not remove that requirement or prove the current template satisfies it. If the
verified template reports less, **stop for instructor review of the current package and
requirements**; do not ask learners to resize the VHD or guest partition. Check the current
Hyper-V tutorial for memory too: the generic appliance article includes differing 16/32 GB
statements, so do not generalize this lab's tutorial-specific setting to every appliance type.

After the capacity and placement checks pass, run `Start-VM -Name MigrateAppl`.
Confirm it is running and **every** disk/configuration path is on the actual store.
Time Synchronization being enabled/OK is not proof that the guest has accurate UTC or a
working NTP source; check inside the guest next.

### 3.5 — Complete first boot

Open the VM console, accept first-boot prompts and set the appliance administrator password.
Do **not** expand the guest partition. Inside `MigrateAppl`, perform read-only checks:

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version
Get-Disk | Select-Object Number,Size,LargestFreeExtent
Get-Volume -DriveLetter C | Select-Object DriveLetter,Size,SizeRemaining
Get-NetIPConfiguration
[DateTime]::UtcNow
Get-TimeZone
w32tm /query /status
w32tm /query /source
Test-NetConnection 192.168.0.1 -Port 5985
Resolve-DnsName login.microsoftonline.com
Test-NetConnection login.microsoftonline.com -Port 443
```

Verify the supported Windows Server **2022/2025** guest OS directly, not from a filename.
Confirm `.20`, gateway `.1`, working DNS and HTTPS access to the required Azure endpoints
(the single endpoint check above is a first check, not the complete allowlist). Check the
virtual disk capacity and usable guest `C:` against current requirements; unresolved
capacity discrepancies go to the instructor, not a learner resizing command.

The **UTC clock must be accurate regardless of time zone**. Compare `[DateTime]::UtcNow`
with a trusted current source and the host; changing the display time zone is not a fix for
clock skew. If needed, repair the host/guest time source and run `w32tm /resync /force`, then
recheck offset/source. A different time zone alone does not cause empty discovery, and an
empty inventory alone does not identify a clock problem.

The appliance software is already in the template. Do not run `AzureMigrateInstaller.ps1`
on this appliance, HyperVHost, or any Tomcat/workload guest. Do not reuse an appliance
registered to another project. Validate the nested switch/NAT path end to end; it is not a
production support claim.

## 4. Register and discover

Once the appliance has finished its first boot, open the appliance configuration manager — the shortcut inside `MigrateAppl`, or `https://192.168.0.20:44368` from a browser on the host.

> **Warning:** Use HTTPS on port 44368. The configuration manager does not respond on HTTP. You will see a certificate prompt on first connection; confirm you are connecting to your own appliance before accepting it.

Work through the configuration manager in order:

1. Complete the connectivity, time and update checks.
2. Paste the project key and sign in to the correct Azure tenant and subscription.
3. Add the Hyper-V host credentials and the host address `192.168.0.1`. Use `HyperVHost\<AdminUsername>` with the deployed host username — the guest Windows credentials are different.
4. Validate the source, resolve every failed prerequisite, then start discovery.
5. **Add guest credentials.** In *Manage credentials and discovery sources*, step 3, add credentials for the guests themselves. These are separate from the Hyper-V host credentials added in the previous step, and without them the appliance discovers the VMs but never looks inside them. The credential **type** you pick from the dropdown matters as much as the username — see the table below.
6. Return to the project and confirm the four workloads appear:

| Workload | Expected source OS | Expected address |
|---|---|---|
| OnPrem-Web | Windows Server 2022 | 192.168.0.10 |
| OnPrem-SQL | Windows Server 2022 | 192.168.0.11 |
| OnPrem-Linux-Web | Ubuntu 24.04 | 192.168.0.12 |
| OnPrem-Linux-App | Ubuntu 24.04 | 192.168.0.13 |

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
| HyperVHost | your actual `AdminUsername` | The `-AdminUsername` you passed to `deploy-lab.ps1`; this is the Azure VM's administrator |
| `OnPrem-Web`, `OnPrem-SQL` | `Administrator` | The **built-in** Windows account. Unattended setup sets its password to the lab password; no new account is created |
| `OnPrem-Linux-Web`, `OnPrem-Linux-App` | your actual `AdminUsername` | Created by cloud-init using the same `-AdminUsername`, so it matches the host account |

So there is no separate Linux-only account. The Linux guests and the host share one username; only the Windows guests differ, because they reuse the built-in `Administrator` rather than creating a second account.

Deployment records the name it actually used, so you never have to guess:

```powershell
# On HyperVHost — the LinuxUsername field is the account on both Linux guests
Get-Content C:\AzMigrateLab\lab-traffic.settings.json
```

> **Note:** Use the actual `-AdminUsername` everywhere a host/Linux account is requested — including SSH and appliance credentials; do not assume a default username.

> **Note on the SQL credential.** Software inventory finds the SQL instance; a **separate SQL credential** is what lets the appliance connect to it and read database detail. Use Windows authentication with the guest `Administrator` account, which is sysadmin on the Express instance. Do not use the `labapp` SQL login created during the initial Tomcat/SQL deployment — it holds only `db_datareader` and `db_datawriter` on `ContosoApp`, and SQL discovery needs server-level read permissions such as `VIEW SERVER STATE`.

> **Note on privilege.** Microsoft's support matrix asks for different levels depending on the feature: software inventory needs only a guest user on Windows and a standard non-sudo user on Linux, while **agentless dependency analysis** needs a Windows account with administrator rights and a Linux sudo account with `NOPASSWD` for `ls` and `netstat`. This lab uses `Administrator` and the deployed Linux user — which already has passwordless sudo — so both levels are satisfied by one credential each. In a customer environment, prefer the lowest privilege that covers the features you are demonstrating.

### Linux prerequisites for full visibility

Deployment configures all of these. Confirm them on each Linux guest before blaming discovery for an empty result:

| Requirement | Check | Expected |
|---|---|---|
| SSH reachable from the appliance | `Test-NetConnection 192.168.0.12 -Port 22` from `MigrateAppl` | `TcpTestSucceeded: True` |
| Account has sudo, no password prompt | `sudo -n true && echo SUDO_OK` | `SUDO_OK` — cloud-init grants the deployed Linux user `ALL=(ALL) NOPASSWD:ALL` |
| Commands dependency analysis runs | `for c in ls netstat ss getcap locate; do command -v $c >/dev/null \|\| echo "MISSING $c"; done` | no output |
| Guest daemons running | `systemctl is-active hv-kvp-daemon` | `active` |
| Distribution/version | `cat /etc/os-release` | Ubuntu 24.04; review the current feature-specific support matrix before replication |

Provisioning records the same facts, so you can check without opening a session:

```powershell
# On HyperVHost — expect LAB_SUDO_NOPASSWD_OK, LAB_DEPENDENCY_COMMANDS_OK, LAB_SSH_ACTIVE
Get-Content C:\AzMigrateLab\setup-log.txt | Select-String 'LAB_SUDO|LAB_DEPENDENCY|LAB_SSH|LAB_KVP'
```

> **Note:** `netstat`, `ss`, `getcap` and `locate` come from `net-tools`, `iproute2`, `libcap2-bin` and `plocate`. Ubuntu cloud images ship none of them reliably, so our lab environment installs all four. In your own estate, confirm they are present before relying on dependency analysis. A missing `getcap` is the easiest to overlook — it appears in Microsoft's dependency-analysis command list but not in most base images.

Then open the **Software inventory** column on the Discovered servers page. You should see:

| Guest | Expected inventory |
|---|---|
| OnPrem-Web | IIS web server role, ASP.NET 4.5 |
| OnPrem-SQL | SQL Server 2022 Express, with the `ContosoApp` database under SQL discovery |
| OnPrem-Linux-Web | Nginx |
| OnPrem-Linux-App | Tomcat 10.1, OpenJDK 17, Contoso Order Desk WAR and `contoso-orderdesk` service |

**Tomcat discovery prerequisites:** map the actual SSH guest credential on the appliance.
It needs recursive read + execute on directories under `/usr/share/tomcat10` (CATALINA_HOME)
and `/var/lib/contoso-orderdesk` (CATALINA_BASE), and sudo `netstat` and `ls`. The deployment
user retains the existing NOPASSWD sudo. Keep `ROOT.xml` root:runtime 0640; do not make
credentials world-readable. Run `sudo bash /opt/contoso-orderdesk/scripts/validate.sh
--credential-user <deployed-linux-username>` as one command to check local access, then
validate appliance SSH separately. Tomcat 8+ Linux web-app discovery/assessment support is
not proof of migration execution; Nginx remains separate software inventory, not an assessed
web-app platform. Allow multiple five-minute TCP polling windows; uploads can take six hours
and web-app configuration discovery 24 hours.


> **Warning:** An empty Software inventory column can reflect missing/invalid guest credentials, permissions, connectivity or collection/upload delay; it does not prove the guests have no applications. VM inventory comes through the Hyper-V host; software inventory connects **directly to each guest** over PowerShell remoting on Windows and SSH on Linux, using the credentials from step 5. No credentials, no applications — and no error message either.

If the column stays empty after adding credentials and rerunning discovery, check the connection the appliance actually uses:

```powershell
# From MigrateAppl — expect TcpTestSucceeded True for both Windows guests
Test-NetConnection 192.168.0.10 -Port 5985
Test-NetConnection 192.168.0.11 -Port 5985
```

```bash
# From MigrateAppl or the host — expect a version string from both Linux guests
ssh <deployed-linux-username>@192.168.0.12 'command -v locate && nginx -v'
ssh <deployed-linux-username>@192.168.0.13 'command -v locate && java -version && sudo -n systemctl is-active contoso-orderdesk'
```

Deployment enables PowerShell remoting on the Windows guests and installs `plocate` on the Linux guests, because software inventory runs `locate` to find installed applications and Ubuntu cloud images omit it. If either check fails, that prerequisite did not take.

> **Note:** Software inventory and the Azure VM assessment are different things. Applications appear under **Discovered servers → Software inventory**; the assessment reports sizing, readiness and cost, and never lists applications.

> **Tip:** Discovery runs continuously and takes time, so a short wait and a refresh are normal. But if host validation is failing, waiting longer will not fix it — diagnose the validation error first. [Hyper-V assessment support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v)

**If no servers appear at all,** work through these in order before waiting any longer:

| Check | Where | Expectation |
|---|---|---|
| Appliance clock | `[DateTime]::UtcNow` in `MigrateAppl` | Accurate UTC against a trusted source, irrespective of display time zone; diagnose clock and connectivity separately. |
| Host reachability | `Test-NetConnection 192.168.0.1 -Port 5985` in `MigrateAppl` | `TcpTestSucceeded: True` |
| PowerShell remoting | `Enter-PSSession -ComputerName 192.168.0.1 -Credential HyperVHost\<AdminUsername>` in `MigrateAppl` | A session opens. Run `Exit-PSSession` afterwards. |
| Host inventory | `Get-VM` on HyperVHost | The four named workloads running; the appliance may also be present |
| Host validation | Appliance configuration manager, discovery source panel | Validation succeeded, with no error text |

Integration Services is worth ruling in or out correctly here: it governs whether the host can report a guest's **operating system details**, not whether the VM is discovered at all. Missing Integration Services shows up as servers listed with blank OS information — not as an empty inventory.

If the **Linux** servers appear with missing OS details, check the Data Exchange (KVP) daemon on each of them:

```powershell
# KVP daemon on the Linux guests — expect active
ssh <deployed-linux-username>@192.168.0.12 'systemctl is-active hv-kvp-daemon'
ssh <deployed-linux-username>@192.168.0.13 'systemctl is-active hv-kvp-daemon'
```

New provisioning installs `linux-cloud-tools-common` plus both exact-running-kernel
`linux-tools-$kernel` / `linux-cloud-tools-$kernel` packages. It validates the executable,
enables but deliberately stops KVP until the scheduled post-cloud-init reboot, and masks
it on any critical installation failure. An enabled service, one reboot or functioning
network/disk does not prove KVP works; the host's all-four communication/app gate is final.

If a guest is not active, use the diagnostics and **exact-kernel** repair in section 2.3.
Inspect `lsmod | grep hv_`, `ls -l /dev/vmbus/`, `uname -r` and the service journal. If
`hv_utils` is missing, an instructor may try `sudo modprobe hv_utils`; do not assume every
cloud-image/kernel flavour lacks it, or that the reported dependency failure has only
one cause. If the module/device or matching binary remains unavailable, stop for kernel,
repository and udev/service support review. Never silently install virtual tools for a
running generic kernel, replace the kernel to bypass this gate or waive failed CIM status.
After a reviewed kernel update, the **new running kernel's** tools must be present and KVP
active after reboot before Step 2 proceeds. Use sudo under the deployed guest account;
cloud images leave root locked, and the lab account has passwordless sudo.

When you plan migration waves later, exclude `MigrateAppl` from the workloads you move. The appliance is lab infrastructure, not a workload.

## 5. Create the assessment

### 5.1 — Instructor Step 2 API errors and recovery

The required workshop uses **Classic Azure VM assessment by default** on both maintained
branches: `-AssessmentMode Classic`. Classic names the grouped `MachineAssessment`
2024-01-15 API, not a retired first-generation Azure Migrate project. Keep the original
four-server lift-and-shift module. Modern API work is deferred until further information;
PaaS/application architecture questions do not change runtime apps, SQL or migration steps.

The isolated Classic export showed **four assessed / four Ready**. That is live evidence
for the standalone test, **not an end-to-end test of this newly merged full script**.
Group readiness and missing-resource handling below were ported with the restored default;
a default flag alone would not have fixed the earlier group stop.

1. **Verify the actual backend and IDs.** Resolve the assessment project from the selected
   Migrate project's solution reference, not its display name. Verify identity/type and
   Active/Succeeded state. If the reference is not verifiable, list all existing same-scope
   backends read-only and stop for explicit `-AssessmentProjectName <existing-name>`.
   Never silently select a candidate or create a replacement. Map all four OffAzure Hyper-V
   IDs through `discoveryMachineArmId` to unique assessment machine IDs across every page;
   names alone and the appliance's inventory row do not establish workload scope.
2. **Keep endpoint-specific APIs and context.** Parent assessmentProjects LIST/GET uses
   provider-advertised 2023-03-15; inventory/groups/grouped Classic assessment/results use
   2024-01-15; solution GET uses 2018-09-01-preview and provider GET 2021-04-01. Normalized
   relevant metadata merges harmless duplicates; unused rows cannot block the selected
   workflow. Registered namespace/implemented parent version remain mandatory. Sparse
   optional child rows warn and require the same fixed read-only endpoint checks, not
   latest-version guessing. Pin account/tenant/subscription/cloud and use Az-owned token
   acquisition through `Invoke-AzRestMethod -DefaultProfile`; never unwrap/display tokens.
3. **Create only the minimal new group.** PUT contains only `properties.groupType=Default`.
   A freshly empty group can return Completed, `supportedAssessmentTypes=[Unknown]`, count
   zero and no provisioningState; that observed shape is not an unsupported API verdict.
   Group readiness accepts absent/null provisioning only when groupStatus is Completed.
   Created/Updated require explicit Succeeded; Running/Accepted/HTTP 202 are pending.
   Returned failed/canceled/deleting, malformed or unknown states remain blockers, even if
   groupStatus says Completed. Console diagnostics report the actual fields and count.
4. **Add only to a group owned by this run.** After proving a fresh empty idle group, one
   `updateMachines` POST uses `operationType=Add` and exactly four assessment-namespace IDs.
   Bounded reads then verify exact inventory membership, count four, ready status and idle
   state. Do not require MachineAssessment capability before adding members: Unknown is
   normal on the fresh empty group. Explicit Unknown/nonmatching capability after membership
   remains pending through bounded reads; absent optional capability is logged and the
   assessment response must establish the requested contract. Empty/singleton/multiple
   arrays retain their shape in Windows PowerShell 5.1; malformed scalar arrays stop.
5. **Preserve existing work.** Reuse only exact-four groups and matching assessments without
   membership changes or overwrite/recompute PUT. Preserve empty/partial/extra-member
   existing groups, stale/invalid/conflicting assessments and unrelated active assessments.
   Prior failed attempts are not proof of ownership. Inspect conflicts and explicitly select
   unused `-AssessmentGroupName` / `-AssessmentName` values, or supply the actual verified
   group/assessment names. No deletion, member removal, wildcard eTag or automatic repair.
6. **Distinguish missing resources from failures.** HTTP 404 `GroupNotFound` means expected
   absence only on the actual group GET; `AssessmentNotFound` only on the corresponding
   Classic/Modern assessment resource GET. Wrong resource/list/parent/write paths or other
   HTTP statuses cannot become permission to create. Parent/scope, API, schema, authorization
   and conflict errors stop at their reported stage. Reads do not promise write permission.
7. **Confirm results before replication.** Acceptance or a successful creation PUT alone
   never establishes readiness. Classic requires status=Completed (not the review-stage
   field) on nonpending assessment GETs. Optional provisioningState may be absent, null or
   blank; a populated value must be Succeeded. Provisioning/Updating/Accepted remain pending;
   failed/canceled/deleting/unknown or nonstring metadata block handoff. One Classic helper
   gates both initial and final GETs; it does not change Modern or the shared response adapter.
   Exactly four unique fully paginated source-linked results, verified identity/settings,
   an idle group, exact membership, stable source mappings and an unchanged update timestamp
   remain required. This supersedes the earlier mandatory-Succeeded assessment assumption.
   Failed/pending work cannot authorize replication; accepted or matching work enters bounded
   checks without a second continuation prompt. Only a transient GET is retried once, never
   a write. Pagination cannot change cloud/scope/API.

For a running lab, refresh the full checkout **of the same OS/Tomcat branch** and rerun
Step 2 with the **same verified group/Classic assessment names and existing settings**.
Keep the host, four guests, appliance and discovery. This completion-field correction
requires no new assessment, VM rebuild, Migrate project recreation or Ubuntu upgrade.
Set the variables below to the existing verified resource names:

```powershell
.\scripts\migrate-step2-discover-assess.ps1 -SourceResourceGroup $sourceRg `
    -MigrateProjectName $projectName -Location $migrationTargetRegion `
    -AssessmentMode Classic -AssessmentGroupName $existingGroupName `
    -AssessmentName $existingAssessmentName
```

Matching groups/assessments are reused without membership writes or overwrite. The same
exact IDs, settings and final results remain required. Only separately inspected conflicts
call for deliberate unused names; optional provisioning alone is not such a conflict.
Do not concurrently edit them. A reported 401/authentication failure needs the original
sign-in/context restored; reconnecting does not repair 403/RBAC, 400/schema, missing parents
or conflicting state. Inspect an unverified write outcome before retrying it.

**Modern is optional experimental code only.** Explicit `-AssessmentMode Modern` keeps the
retained top-level 2024-03-03-preview profile, provider/version gate, source-link checks and
ManualReview. It is not full application assessment and cannot silently switch modes.
The isolated Modern PUT returned HTTP 400 MalformedRequestBody, so it did not create an
assessment. Further API evidence is needed before using it in the required module. Do not
infer a service-compatible 2025 schema, invent an ARG scope or retry as another mode.
The full script merge, native checker and complete lab run remain unverified live here.

For the required Classic/manual IaaS exercise, create an **Azure VM** assessment for a group containing exactly the four workload VMs. Use
the **migration target region** selected in step 1 / Module 2 §4.1, different from the actual
source Hyper-V host region; do not inherit the source RG location or project data geography.
Choose it and check subscription/regional/family quotas before assessment and before portal
Create resources locks the migration target. Use the currency/pricing agreement that apply
to you, no commitment discounts for a lab this short, and no Azure Hybrid Benefit unless
entitlement has been confirmed.

For the script, pass `-Location $migrationTargetRegion` to
`migrate-step2-discover-assess.ps1`. Optional `-TargetResourceGroup $targetRg` derives/checks
the assessment target against that group's **actual target VNet**, not RG metadata. Without
that optional group, missing `-Location` explicitly prompts for a subscription-listed region.
Project data geography is unchanged; the assessment target must match subsequent migration
and test-network settings. Step 1's forecasts are planning only: recheck actual assessment/
portal SKU choices and counts before allocating test or target VMs.

On a freshly built lab, start with **as-on-premises** sizing. Then create a second, performance-based assessment once data has accumulated and compare the two.

Record for each machine: readiness, any unsupported configuration, the selected Azure size, OS disk, target network, and the estimated compute and storage cost. Resolve readiness warnings against the migration support matrix before you replicate anything in Module 2.

> **Warning:** Write down the collection period, the confidence rating, and the fact that these samples come from an idle lab. A few minutes of idle telemetry cannot justify a production right-sizing recommendation, and presenting it as though it can is the single most common way a good assessment loses a customer's trust. [Assess Hyper-V servers](https://learn.microsoft.com/azure/migrate/tutorial-assess-hyper-v)

### 5.2 — Optional portal application assessment (separate from instructor server automation)

Use the current [Create application assessment](https://learn.microsoft.com/en-us/azure/migrate/create-application-assessment?view=migrate)
portal procedure **after** guest/software/SQL/web discovery and dependency collection are
validated. Select actual discovered workload/application assets, not assumed counts or
fabricated Linux web objects. Nginx is software inventory, not a separately supported
assessed web-app platform; Tomcat, IIS and SQL assets depend on successful guest discovery.
Build/review application boundaries from observed dependencies (the SQL server is shared),
then compare suitable IaaS and available PaaS recommendations in the portal. Resolve missing
asset/credential/collection evidence first; application membership is not inferred from four
VM names alone.

This optional comparison is **not part of the required Classic server assessment**. Modern
and full mixed-application API work are deferred pending further information. Bundling assessment
ARM IDs through heterogeneousAssessments is not equivalent to discovering/assessing an
application; this script does not create bundles, waves, SQL or web assessment objects or
run arbitrary ARG queries. Record the portal's actual results without promising import,
Linux application visibility or production-quality right-sizing from idle lab telemetry.
Keep the four-VM lift-and-shift path as the required lab; this exploration is optional.

## 6. Interpret the dependency view

What you see here depends on whether the sample business traffic from [Module 0, section 6](Module-0-Setup.md#6-start-the-sample-business-traffic) is running.

**Without generators,** the Tomcat JVM already reads ContosoApp and retains a bounded pooled SQL connection after readiness. The Nginx proxy is installed, but idle HTTP edges may not appear. Interpret empty/partial polling evidence carefully; do not manufacture sustained sockets. `/api/health` is only liveness; `/api/ready` and `/api/orders` verify actual SQL access.

**With optional traffic,** Python performs low-rate HTTP through Nginx into Tomcat; the JVM reads/writes `ContosoApp` over TCP 1433, and an IIS-host scheduled task reads an internal SQL report and calls Tomcat health. Disabling generators leaves the SQL login, proxy, hosts and application intact. `OnPrem-SQL` therefore appears as a shared dependency of both application tiers — the finding that tells a customer the database cannot be moved on its own.

Either way, agentless dependency discovery needs supported guest credentials and time to collect observations.

> **Note:** Do not install the retired Microsoft Monitoring Agent to make a diagram appear.

> **Instructor note.** Start the traffic mesh before appliance registration if you want a populated map. Dependency analysis samples active connections on a polling interval rather than recording continuously, so traffic that begins a few minutes before you open the map may not be represented in it. Keep the generated load light — the same idle-telemetry caveat in section 5 cuts both ways, and a heavy generator produces sizing recommendations that are just as fictional as an idle lab's.

**Pass gate:** the appliance is registered, host validation succeeds, all four named workloads
are visible with fresh OS metadata (both Linux guests independently checked as Ubuntu 24.04),
and the assessment exists with reviewed readiness. Before releasing this rebuilt workshop,
require software inventory of Tomcat 10.1/OpenJDK 17 **and a visible Contoso Order Desk Java
web asset**; keep evidence of collection/credential state. HTTP liveness/readiness or a passed
host KVP gate is not this appliance acceptance. Retain the controlled ROOT.war/custom base
and protected JNDI; do not claim a discovery defect was fixed merely by the rebuild. Continue to [Module 2](Module-2-Agentless-Migration.md).
