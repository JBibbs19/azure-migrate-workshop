# Changes from the supplied workshop

**TD SYNNEX | Cloud Enablement Services**

This file describes the **current state** of the changes in this folder, measured against the two
supplied sources: the original workshop (referred to below as the *unmodified* lab) and the
*Pull 12* revision. It is written as a description of what is now true, not as a history of the
revisions that got here, so it does not go stale as work continues.

Files in this folder replace their counterparts in a checkout. Everything not listed is unchanged.

| File | State |
|---|---|
| `scripts/deploy-lab.ps1` | Modified |
| `scripts/common.ps1` | **Deleted** — inlined into `deploy-lab.ps1` |
| `scripts/migrate-common.ps1` | **Deleted** — was never loaded by anything |
| `scripts/check-lab-scripts.ps1` | **New** |
| `scripts/health.ps1` | Modified |
| `scripts/enable-lab-traffic.ps1` | **New** |
| `scripts/host/configure-host.ps1` | Modified |
| `docs/Module-0-Setup.md` | Rewritten |
| `docs/Module-1-Discovery.md` | Rewritten |
| `docs/Lab-Traffic.md` | **New** |
| `README.md` | Modified |

---

## 1. The lab builds four workload VMs, not five

Pull 12 created a fifth nested VM, `MigrateAppl`, as a bare Windows Server guest that Module 1 then
installed the Azure Migrate appliance onto. That VM is no longer created.

The four workloads — `OnPrem-Web` (.10, IIS), `OnPrem-SQL` (.11, SQL Express), `OnPrem-Linux-Web`
(.12, Nginx) and `OnPrem-Linux-App` (.13, Node.js) — are built exactly as Pull 12 built them, using
the same creation methods that are known to work: managed Run Command with protected parameters, a
SAS-exported marketplace disk for the Windows base image, qemu-img conversion for the Ubuntu cloud
image, cloud-init for the Linux guests and `unattend.xml` injection for the Windows guests.

In `scripts/host/configure-host.ps1`:

- The `MigrateAppl` creation call is removed.
- `$allVMs` lists four VMs, so `setup-complete.json` records four.
- The post-boot partition-expansion loop and the unattend-cleanup loop cover `OnPrem-Web` and
  `OnPrem-SQL` only.
- The `192.168.0.20` address and the appliance's share of host memory are deliberately left free.

The appliance instead arrives as Microsoft's published VHD, downloaded and imported by the
instructor in Module 1.

## 2. Host size default is `Standard_E8s_v7`

`Standard_E8s_v5` was not available in the subscription this lab was built in. The default is now
`Standard_E8s_v7` — the same 8 vCPU / 64 GiB shape, Generation 2, Premium SSD, with nested
virtualization support.

`Get-LabHostSku` is unchanged and still validates whatever size is passed against the subscription's
regional SKU metadata and both the family and regional vCPU quotas. Only the default and the example
size names changed.

> Esv7 is a Generation 2 only series whose sizes require an OS image with NVMe support. The
> workshop's `2022-datacenter-g2` host image satisfies both. See *A note from the author* in the
> README.

## 3. Appliance staging uses the host OS disk, not a data disk

The 512 GB OS disk has ample spare capacity, so no additional managed data disk is attached. An
earlier revision of this work did attach a 128 GB `StandardSSD_LRS` data disk; it was removed
because a data disk bills continuously — including while the VM is deallocated — for space the lab
already owns. How that space is presented is described in 3b below.

## 3a. Guest disks and memory are statically allocated

The guest VHDs were dynamic, so 140 GB of declared capacity consumed far less at first and grew
unpredictably through the workshop. They are now **fixed**: `Convert-VHD -VHDType Fixed` in both the
Windows and Linux creation helpers, with a post-creation assertion that the resulting disk really is
`Fixed`. `Create-LinuxGuestVM` gains a `-DiskGB` parameter (default 30) so both helpers size their
disks the same way.

| Guest | Disk | Memory |
|---|---|---|
| `OnPrem-Web` | 40 GB fixed | 4 GB static |
| `OnPrem-SQL` | 40 GB fixed | 4 GB static |
| `OnPrem-Linux-Web` | 30 GB fixed | 2 GB static |
| `OnPrem-Linux-App` | 30 GB fixed | 2 GB static |
| **Total** | **140 GB** | **12 GB** |

Dynamic memory was already disabled on both guest types and is unchanged; the ADR now records it as
a deliberate decision rather than an implementation detail.

Two reasons, both about the assessment in Module 1. Host capacity is known from the start instead of
shifting as guests write, and a dynamic disk's expansion-on-write produces write amplification that
shows up as erratic disk I/O in performance-based sizing.

**The cost is deployment time.** Setup now writes all 140 GB during provisioning rather than
deferring it to first use, which adds roughly 20–40 minutes on a 512 GB Premium SSD. The estimate in
Module 0 moves from 30–60 minutes to **50–100 minutes**, and the conversion timeout rises from 1800
to 5400 seconds. A new troubleshooting entry records that slow guest disk creation is expected.

## 3b. The appliance gets its own partition

`-ApplianceStagingMinimumFreeGB` and the free-space check on `C:` are replaced by a dedicated
partition. A new step, **Create appliance store partition**, sizes `C:` and creates a 100 GB NTFS
volume labelled `ApplianceStore`, creates `E:\Appliance` and grants the lab administrator Modify on
it. New parameters `-ApplianceStoreSizeGB` (default 100) and `-ApplianceStoreDriveLetter` (unset by
default, meaning the first free letter). The marker becomes `APPLIANCE_STORE_READY`, still checked
by `Assert-LabRunResult`.

Because the guest disks are fixed, the two never compete: 140 GB is committed on `C:` and the
appliance has 100 GB that guest growth cannot reach.

> **Sizing works in both directions.** A first attempt assumed `C:` spanned the disk and had to be
> shrunk, and failed on a live run: Azure creates the OS disk at the requested 512 GB but leaves
> `C:` at the image's native size, with most of the disk unallocated. Subtracting the store from the
> *current* size of `C:` produced a target far below what Windows would allow. The step now targets
> `Get-PartitionSupportedSize -SizeMax` minus the store — `SizeMax` being the current size plus the
> adjacent free space — so a single `Resize-Partition` call extends `C:` into unallocated space or
> shrinks it, whichever the disk requires, and leaves exactly the store free. Both failure messages
> now report the current size of `C:`, the range it can occupy and the largest store that range
> permits.

> **Drive letter is chosen, not fixed.** A first attempt defaulted the partition to `D:` and failed
> on a live run: a host size with no local temporary disk leaves the letter after `C:` unused, so
> Windows assigns it to the **virtual DVD drive**. `D:` is occupied even though no disk is attached
> there. Rather than relocate the optical drive, the step now takes the **first unassigned letter**
> and reports it back to the client, which sets the appliance path from that value. On the default
> host size this is `E:`; a size with a temporary disk lands on `F:`. `-ApplianceStoreDriveLetter`
> remains as an explicit override and fails fast if the letter named is in use. Nothing existing is
> moved or reassigned, and the check runs before `C:` is resized, so a failure leaves the OS disk
> untouched.

Module 1 section 3 now downloads, extracts, imports and runs the appliance entirely on `E:`, and
adds an optional `Convert-VHD -VHDType Fixed` step for the appliance disk — guarded by a free-space
check, with a documented fallback if the expanded size does not fit.

## 3c. The appliance disk is grown to Microsoft's documented size

Microsoft publishes the Hyper-V appliance VHD at around 40 GB, while the documented requirement for
that appliance is **16 GB memory, eight vCPUs and roughly 80 GB of disk**. Importing the VHD as-is
therefore produces an under-provisioned appliance — observed on a live lab.

Module 1 section 3.4 now runs `Resize-VHD -SizeBytes 80GB` before first boot, and section 3.5 extends
the partition inside the guest with `Resize-Partition` so Windows actually sees the space. Growing
the virtual disk before Windows has booted from it is markedly simpler than afterwards.

> **Two different numbers, easily conflated.** The 100 GB `E:` partition is **host-side storage** for
> the appliance — the download, the extracted VHD and the running VM. The 80 GB is the **appliance's
> own virtual disk**. An 80 GB dynamic disk consumes only what the appliance writes, so it fits
> inside the 100 GB partition alongside the archive. The disk is deliberately left **dynamic**: the
> appliance is lab infrastructure rather than an assessment subject, so its I/O profile does not
> affect sizing data, and a fixed 80 GB disk plus the 40 GB source during conversion would not fit.
> The earlier optional fixed-conversion step is removed for that reason.

Module 0 section 3.7 now lists the appliance's disk, memory and vCPU requirements separately from
the host partition that stores it.

## 4. Lab firewall posture is configured, not left to the instructor

Previously, making a guest answer a ping required enabling the **File and Printer Sharing** group by
hand — which works only because ICMPv4 echo happens to live in that group, and which also opens SMB
and NetBIOS. `scripts/host/configure-host.ps1` now configures the posture directly.

On the Windows guests, in the existing per-guest loop:

| Rule | Scope |
|---|---|
| `LabTrustedIcmp4` — inbound ICMPv4 echo | `192.168.0.0/24`, `10.0.0.0/16`, `10.1.0.0/16`, `10.2.0.0/16` |
| `LabTrustedInbound` — inbound any protocol | the same four ranges |
| Connection profile set to `Private` | a DHCP NIC is frequently classified `Public` |

On **HyperVHost**, scoped to `192.168.0.0/24` only: `LabHostIcmp4`, `LabHostWinRM` (5985/5986) and
`LabHostSmb` (445). WinRM is the path the Azure Migrate appliance uses to reach the host for
Hyper-V discovery, and it was previously left entirely to the manual host-preparation step.

On the Linux guests, `ufw --force disable || true` is added to the shared cloud-init `runcmd`. It
ships inactive on Ubuntu cloud images; the explicit disable makes the posture deliberate.

The ICMP rule is kept separate from the any-protocol rule so ping survives if the broad rule is
later narrowed. Both are removed and recreated if present, so re-running is safe.

**Not changed:** the Azure NSG. The host's public NIC still permits RDP from the single `/32`
supplied at deployment.

## 4a. Hyper-V guest daemons on the Linux guests

Ubuntu cloud images ship the Hyper-V kernel modules but not the userspace daemons. Without the
Data Exchange (KVP) daemon the host cannot report a guest's operating system or IP address, and
because Azure Migrate reads guest OS details **through the host**, the two Linux guests are
discovered but listed with blank OS information. This was observed in a live run.

Two separate pieces are required, and an Ubuntu cloud image as provisioned has neither. The
`hv_utils` **kernel module** publishes `/dev/vmbus/hv_kvp`, and the daemon's systemd unit `Requires`
that device — so enabling the service before the module is loaded fails with *"A dependency job for
hv-kvp-daemon.service failed"*, which reads like a daemon fault but is not one. The **userspace
daemons** then have to be installed on top. Both failures were observed in a live run.

`configure-host.ps1` now provisions both, in order:

- `modprobe hv_utils`, followed by `/etc/modules-load.d/hyperv.conf` so it survives a reboot.
- `linux-cloud-tools-common` in the shared cloud-init package list — it supplies the systemd units
  and helper scripts.
- A `runcmd` install of `linux-cloud-tools-$(uname -r)`, matching the running kernel so no reboot is
  needed, falling back to the `linux-cloud-tools-virtual` / `linux-tools-virtual` meta-packages when
  that exact version is not in the archive. That fallback pulls a different kernel and does require
  a reboot to take effect.
- `udevadm settle`, so the device node is present before the services are enabled.
- `hv-kvp-daemon.service` and `hv-vss-daemon.service` enabled and started.
- An evidence block that echoes `LAB_KVP_DAEMON_RUNNING`, or `LAB_KVP_DAEMON_MISSING` plus a
  `LAB_KVP_CAUSE` line distinguishing a missing module, a missing device node and a missing binary —
  enough to diagnose from the cloud-init log without a live session.

**A reboot is required, and is now scheduled.** Installing the tools package also installs the udev
rules that create `/dev/vmbus/hv_kvp`. The daemon's systemd unit `Requires` that device, so the
service cannot start in the same boot that installed the package — enabling it succeeds, starting it
does not. This was confirmed on a live lab: both guests started the daemon correctly after a manual
reboot. Cloud-init now reloads and triggers the udev rules, enables the services, and ends with a
`power_state: reboot` so they come up on the next boot. The evidence marker distinguishes
`LAB_KVP_DAEMON_RUNNING` from `LAB_KVP_DAEMON_PENDING_REBOOT` so the log shows which path was taken.
Workload validation already retries for 20 minutes, which absorbs the restart.

**Packages for the full command set.** Microsoft's support matrix lists the commands Azure Migrate
executes over SSH for software inventory and agentless dependency analysis. Ubuntu cloud images do
not reliably ship four of them, so `net-tools` (netstat), `iproute2` (ss), `libcap2-bin` (getcap) and
`plocate` (locate) are all installed. `getcap` is the easiest to miss — it is in Microsoft's list but
in few base images.

**The Linux guest password was never actually set.** The cloud-config used the top-level
`password:` key, which cloud-init applies to the distro's **default user**. This file replaces
`users:` without including `default`, so no default user exists and the password was applied to
nobody; the per-user `plain_text_passwd` it also carried is deprecated. The password is now set
through `chpasswd.users`, which names the account explicitly:

```yaml
chpasswd:
  expire: false
  users:
    - name: labadmin
      password: <lab password>
      type: text
```

`lock_passwd: false` is retained so the account is not locked, and a `LAB_GUEST_PASSWORD_SET` /
`_LOCKED` / `_MISSING` marker records the result of `passwd -S` in the setup log.

> Fixing this exposed a second defect in the same block. `Expand-LabTextTemplate` substitutes tokens
> in a single pass and deliberately never rescans inserted text, so that a password cannot be
> reinterpreted as another token. A `__USER__` token placed inside a `runcmd` fragment is inserted
> after that pass and would have survived into the guest literally. The fragment now resolves its
> own tokens before being joined into the document.

**Account naming is stated explicitly.** The guest credential guidance listed `Administrator` for
the Windows guests and `labadmin` for the Linux guests without explaining why they differ, which
read as though the lab creates a separate Linux-only account. It does not: `configure-host.ps1` sets
`$guestUser = $AdminUsername`, so the Linux guests and HyperVHost share one username, and only the
Windows guests differ because they reuse the built-in `Administrator` rather than creating a second
account. Module 0 and Module 1 now both carry a short table giving the account per machine and where
it comes from, and point at `lab-traffic.settings.json` for the name actually used when
`-AdminUsername` was not the documented default.

**Prerequisites are verified during provisioning.** A new cloud-init block records
`LAB_SUDO_NOPASSWD_OK`, `LAB_DEPENDENCY_COMMANDS_OK` (or the exact commands missing) and
`LAB_SSH_ACTIVE` in the setup log, so a gap is visible immediately rather than as an empty inventory
days later. Cloud-init already granted the lab user `ALL=(ALL) NOPASSWD:ALL`; that is now confirmed
rather than assumed.

Every step is `|| true`, so a package-source or kernel-flavour problem degrades guest OS reporting
rather than failing the whole deployment. The Windows guests need nothing equivalent: Data Exchange
and Heartbeat are enabled by default, and `configure-host.ps1` additionally enables Guest Service
Interface.

Module 1 section 4 gains the matching checks and full remediation for an existing lab — module
first, then packages installed **separately**, because combining an unavailable versioned package
with an available one makes apt abort the whole transaction and install neither. It also records
that these commands need `sudo`: Ubuntu cloud images leave root locked by design, and `systemctl`
without `sudo` falls through to a polkit prompt for a root password that does not exist. Module 0
section 3.6 lists the extra package source.

## 4b. Software inventory prerequisites

An assessment run against a live lab returned **no applications**, despite IIS, ASP.NET, SQL Server
Express, Nginx and Node.js all being installed. Software inventory is a separate mechanism from VM
discovery: VM inventory arrives through the Hyper-V host, while software inventory connects
**directly to each guest** over PowerShell remoting on Windows and SSH on Linux, using guest
credentials added in the appliance configuration manager. Missing any of those produces an empty
column and no error.

Three causes were addressed:

- **Guest credentials.** Module 1 step 5 previously read *"Add guest credentials only for the
  software inventory or dependency features you intend to demonstrate,"* which reads as optional. It
  now states plainly that these are required, names the accounts to use, and distinguishes them from
  the Hyper-V host credentials added earlier in the same panel.
- **`locate` on the Linux guests.** Microsoft's support matrix lists `locate` among the commands
  software inventory runs, and Ubuntu cloud images omit it. `plocate` is added to the cloud-init
  package list and `updatedb` runs once during provisioning so the first inventory pass has a
  database to read.
- **PowerShell remoting on the Windows guests.** Windows Server enables WinRM by default, but a DHCP
  guest can classify its network as Public and refuse the listener. `configure-host.ps1` now runs
  `Enable-PSRemoting -Force -SkipNetworkProfileCheck` inside the existing per-guest loop and, after
  the guests are configured, tests port 5985 from the host and logs a warning naming the affected
  guest if it is unreachable.

Module 1 section 4 gains an expected-inventory table, a warning that an empty column means missing
credentials rather than missing applications, and the connection checks to run if it stays empty. It
also records that software inventory and the Azure VM assessment are different views — applications
never appear in the assessment.

## 4c. Subscription ID and admin address are masked at entry

`deploy-lab.ps1` takes `-SubscriptionId` and `-AdminSourceCidr` as **SecureString**, so neither is
visible while being typed — relevant when a delivery is screen-shared or recorded. New helpers
`ConvertFrom-LabSecureString` and `Assert-LabSubscriptionId` in `common.ps1` convert once, trim
surrounding whitespace, reject an empty entry and check the subscription GUID format before Azure is
contacted. Both plain values are cleared in the `finally` block alongside the password, and the
deployment banner no longer echoes the subscription ID.

The `/32` suffix on `-AdminSourceCidr` is now **optional**. The lab only ever permits a single
address, so the prefix carried no information while being easy to omit — and now that the value is
masked at entry, a missing or mistyped suffix is invisible until validation rejects it. A new
`Resolve-LabAdminSource` accepts a bare address, trims surrounding whitespace and returns the
normalised `/32` form, which deployment then uses for the NSG rule.

An explicitly supplied prefix is still **checked rather than overridden**: `203.0.113.14/24` is
refused, not silently narrowed to a single address the caller did not choose. Every rejection the
original validation made is preserved — abbreviated, hexadecimal, integer and leading-zero
notations, IPv6, `0.0.0.0` and non-dotted-quad input all still fail, because those forms resolve to
a different address than they appear to and would open RDP to the wrong host.

> This is screen hygiene, not secret storage. Both values still reach Azure and remain visible
> afterwards — the subscription ID in `Get-AzContext` and every resource ID, the address in the
> host's NSG rule.

**No other script needed the same change.** `migrate-step1` through `step6` and `cleanup-lab.ps1`
take **no subscription parameter at all** — they act on whichever subscription is active in the
session, read from `Get-AzContext`. `deploy-lab.ps1` is the only script in the lab that accepts one,
so it is the only one converted.

That check exposed two invocation examples that were carried over from a different revision of the
repository and would fail on first run:

- Module 0 step 2 and the README passed `-SubscriptionId` to `migrate-step1-setup-project.ps1`,
  which has no such parameter. PowerShell rejects an unknown parameter outright.
- The README and Module 0's cost table passed `-SubscriptionId`, an array of two group names, and
  `-WhatIf` to `cleanup-lab.ps1`. That script takes a single `[string]$ResourceGroupName` and a
  `-Force` switch, and its `[CmdletBinding()]` does not declare `SupportsShouldProcess`, so `-WhatIf`
  is not available either.

Both are corrected, and both documents now state that the migrate and cleanup scripts depend on the
active context rather than an explicit subscription.

## 4d. A failed deployment resumes instead of requiring a rebuild

Pull 12 replaced the original lab's "create if absent" pattern with hard refusals — an existing
resource group, a `setup-complete.json` marker, or an existing guest VM each threw. The intent was
to stop a re-run resurrecting retired source VMs after cutover. The effect during build-out was that
any failure, however trivial, cost a full teardown and another full deployment.

The guards now distinguish **incomplete** from **complete**:

| Check | Before | Now |
|---|---|---|
| Existing resource group | Always refused | Allowed when tagged as this workshop **and** its `ConfigureWorkshop` has not succeeded; refused otherwise |
| `setup-complete.json` on the host | Refused | Unchanged — a completed host is still refused |
| Existing guest VM | Refused | Removed and rebuilt, with its VHD, cloud-init ISO and DHCP reservation |

On a resumed run `deploy-lab.ps1` reuses the virtual network, public IP, NSG, NIC, host VM and image
disk when they already exist, and clears any Run Command left by the previous attempt before
resubmitting. On the host, the virtual switch, NAT, DHCP scope and downloaded base images were
already `if exists → skip`, so they are kept; only partly built guests are discarded, because a
half-provisioned guest cannot be trusted. The host logs that it is resuming.

The post-cutover protection is preserved: once guest setup has succeeded, the group is refused with
a message saying why.

## 4e. Lost monitoring no longer reads as failure

A live run ended with *"Setup status has been unavailable for 300 seconds"* at 21:34 UTC. The host
finished successfully at 21:59 UTC — the client had stopped watching 26 minutes early because its
Azure token expired. Guest setup is submitted with `-AsyncExecution`, so the client only observes it;
losing the observer never stops the work.

Three faults, all in `Wait-LabManagedSetup`:

- **The reason was discarded.** `catch { $readFailed = $true }` threw away the exception, so an
  expired token, a throttle and a network fault produced identical output. The message now carries
  the underlying Azure error.
- **Sign-in failure was waited out.** A failed token refresh does not heal with time. Auth failures
  are now identified and reported immediately, rather than after the full window.
- **The message implied the deployment had failed.** It now states plainly that setup runs
  asynchronously on the host and is probably still running, gives the `Get-AzVMRunCommand` reattach
  command, points at `setup-log.txt`, and says not to redeploy before confirming a real failure.

`StatusFailureSeconds` also rises from 300 to 900, which is safe now that the genuinely fatal case
is identified rather than waited on.

Module 0 gains a matching troubleshooting entry, including the two cleanup steps the client would
have performed had it still been watching — revoking and removing `WinServerBase-temp`, and removing
the completed Run Command.

## 4f. Progress reporting follows the host through its phases

The deployment reported 13 steps, of which the last — *Guest setup* — covered the entire host
payload. That is 40 to 80 minutes of the run, so the counter sat on `Step 13/13` for the majority of
a deployment while the detail line changed underneath it. Observed on a live run.

The host payload already emitted `LAB_STAGE` markers for each phase, and `Wait-LabManagedSetup`
already parsed them — but it passed the constant string `Guest setup` to `Write-LabHealth`, and the
step number is derived from that stage name. The phase was shown as detail text only.

The phase is now reported **as the stage**, and the phase names are entries in the step list, so the
counter advances through the host's work:

| Steps | Where they run |
|---|---|
| 1–12 | The deployment client: resource group through `Submit guest setup` |
| 13–22 | The host: starting, networking, images, nested VMs, first boot, workloads, IIS, SQL, validation, traffic generator |
| 23 | `Guest setup complete` |

`PHASE 6` in `configure-host.ps1` emitted no marker at all — it was added after the mapping was
written — so it now reports `traffic`, and `Staging the traffic generator` is a phase name and step.

The failure and status-unavailable paths also report against the current phase rather than a
constant, so a stall or an error now names the phase it stopped in instead of saying `Guest setup`
regardless of how far the run got.

## 5. Optional traffic mesh

`scripts/enable-lab-traffic.ps1` is new. It wires the four independent samples into one
small-business order desk so Azure Migrate dependency analysis has real connections to observe:

| Edge | Protocol | Driver |
|---|---|---|
| `OnPrem-Web` → `OnPrem-SQL` | TDS 1433 | scheduled task `LabOrderDeskTraffic`, recent-orders report |
| `OnPrem-Web` → `OnPrem-Linux-App` | HTTP 3000 | same task, `/api/health` batch call |
| `OnPrem-Linux-App` → `OnPrem-SQL` | TDS 1433 | systemd unit `lab-traffic`, inserts an order per cycle |
| `OnPrem-Linux-App` → `OnPrem-Linux-Web` | HTTP 8080 | same unit, proxy call |
| `OnPrem-Linux-Web` → `OnPrem-Linux-App` | HTTP 3000 | Nginx `proxy_pass` on a new 8080 server block |

`OnPrem-SQL` becomes a shared dependency of both application tiers.

**Deployment validation is untouched.** The IIS site, the Nginx root site on port 80 and the Node
service on 3000 keep their original content, so `Assert-LabSourceWorkloads` still passes. The proxy
listens on 8080, the generators are separate units, and `server.js` is not edited.

**It is delivered to the host by deployment.** `Read-LabHostConfiguration` reads the script, parses
it for syntax errors, gzip+base64 encodes it via the new `Compress-LabScript`, and substitutes it
into the `__LAB_TRAFFIC_PAYLOAD__` placeholder in the host payload. A new PHASE 6 in
`configure-host.ps1` decodes it after workload validation and writes two files — the script itself at
`C:\AzMigrateLab\enable-lab-traffic.ps1`, and `lab-traffic.settings.json` holding the lab user name,
guest addresses, SQL login and interval that deployment actually used. Nothing is executed.
`setup-complete.json` gains a `TrafficScript` path.

Running it on the host therefore needs no arguments beyond the lab password, which it prompts for.
Explicit parameters override the settings file; `-SettingsPath` points at a different one. The
password is deliberately **not** persisted — setup already deletes unattended-install password
material after first boot.

**Names, not addresses.** Generators resolve `onprem-sql`, `onprem-app` and `onprem-nginx` through
hosts entries written to all four guests. The generators start at boot, so migrated VMs resume the
same traffic in Azure and fail until those entries are repointed — documented as a deliberate
Module 3 exercise rather than a defect.

**`-Disable`** stops and removes the generators, the proxy and the lab SQL login. Every step is
idempotent, so a part-way failure can simply be re-run.

Guest changes: SQL Express switched to mixed-mode authentication with one lab-only login (`labapp`,
`db_datareader` + `db_datawriter` on `ContosoApp` only, required because the Linux generator cannot
use Windows authentication); `C:\LabTraffic\` and a scheduled task on `OnPrem-Web`; the `mssql` npm
package, `lab-traffic.js`, the `lab-traffic` systemd unit and `/etc/lab-traffic.env` (mode 600) on
`OnPrem-Linux-App`; one Nginx conf file on `OnPrem-Linux-Web`.

### Fix: ssh stderr aborted Linux configuration

`Invoke-LabLinuxPayload` sets `$ErrorActionPreference = 'Stop'`. Merging a native executable's
stderr with `2>&1` under `Stop` turns each stderr line into a terminating `NativeCommandError`, and
ssh writes its host-key notice to stderr on a *successful* connection — so a benign warning aborted
the run, every time, because `UserKnownHostsFile=NUL` means the key is never actually remembered.

The preference is now saved, set to `Continue` around the native call and restored in a `finally`
block; `$LASTEXITCODE` is captured immediately and used for the success test; `-o LogLevel=ERROR`
suppresses the notice; and output is flattened to a string before the marker match. The same
bracketing pattern already existed around the `oscdimg` call in `configure-host.ps1`.

## 6. Helper functions

- `Assert-LabResourceGroup` and `Assert-LabWorkloadNames` are removed from `common.ps1`. Their only
  callers were Pull 12's `cleanup-lab.ps1` and test scripts, neither of which is part of this lab.
- `Assert-LabManagedRunResult` moved from `common.ps1` to `health.ps1`, beside `Wait-LabManagedSetup`,
  its only caller. `health.ps1` is now self-contained, which removes an implicit dot-source ordering
  requirement in `deploy-lab.ps1` and — more importantly — fixes the embedded host payload, which
  receives `health.ps1` but never `common.ps1`.
- `Compress-LabScript` is added to `common.ps1` for the traffic-script payload.
- The `LAB_PROGRESS` marker machinery in `health.ps1` is retained: `Wait-LabManagedSetup` consumes it
  and `deploy-lab.ps1` calls that directly for live progress during guest setup.

## 7. Documentation

### `docs/Module-0-Setup.md`

Rewritten from the instructor to the student, following the unmodified lab's conventions: numbered
sub-steps, `> **Note:** / **Tip:** / **Warning:**` callouts, **Expected result** labels and direct
address. Instructor-only material is retained in annotated `> **Instructor note.**` callouts.

Structure, with the unmodified lab's sections reinstated:

| § | Section |
|---|---|
| 1 | Module Overview |
| 2 | Architecture Decisions Record |
| 3 | Prerequisites (3.1 governance · 3.2 quota · 3.3 region · 3.4 tooling · 3.5 network · 3.6 downloads · 3.7 appliance requirements) |
| 4 | Deployment Steps |
| 5 | Verify inside HyperVHost |
| 6 | Start the sample business traffic |
| 7 | Troubleshooting |
| 8 | Security Baseline (8.1 NSG · 8.2 lab firewall posture · 8.3 remote access · 8.4 credentials · 8.5 least privilege) |
| 9 | Cost Analysis |

Specific points:

- The ADR is updated for the decisions actually made: `Standard_E8s_v7`, the 512 GB OS disk, staging
  on that disk rather than a data disk, appliance-by-VHD-import, the trusted-range firewall posture
  and managed Run Command.
- Prerequisites are refreshed for Esv7 and four guests. **3.7** is where the appliance appears in
  Module 0 — stated once, as reserved capacity and a proxy requirement, with no build steps.
- Troubleshooting returns to the `**Symptom:** / **Cause:** / **Resolution:**` format, updated for
  the current environment and extended with the genuinely new cases (insufficient free space, guest
  will not answer a ping, traffic script not staged).
- Security Baseline's NSG table is corrected: this lab's rule is a single `/32`, not the unmodified
  lab's `*`, so the warning changes meaning. The firewall posture lives here as 8.2.
- Cost Analysis reinstated. The verified figure is the `Standard_E8s_v7` **Linux** PAYG rate; the
  Windows rate, disk and IP lines are marked *verify* rather than guessed, with the pricing
  calculator linked. A note records the data disk that was removed and why.
- Section 5 checks carry an inline `# <item> on <computer> — expect <result>` comment above each
  command, with the summary table kept below.
- The SQL check is a single query returning both counts as columns of one row, because
  `Invoke-Sqlcmd` surfaces only the first result set — two separate `SELECT COUNT(*)` statements
  silently discarded the Orders count.
- Image-catalog and disk-security implementation detail is removed; it was troubleshooting residue,
  not lab narrative. The behaviour is unchanged in the scripts and explained in the README note.

### `docs/Module-1-Discovery.md`

Rewritten to the same conventions. Section 3 is broken into 3.1–3.5 — generate the project key,
confirm staging space, download and verify the archive, import the VHD, complete first boot — and
creates `MigrateAppl` on `intSwitch` with 8 vCPU / 16 GB, a static `00-15-5D-00-00-14` MAC matching
the scheme deployment uses, and a DHCP reservation for `192.168.0.20`.

Section 4 is an ordered registration walkthrough with the HTTPS-port warning and the "check names,
not the count" point called out. Section 6, *Interpret the dependency view*, tells the student what
to expect both with and without the traffic mesh, rather than instructing the instructor what not to
ask.

> The appliance VHD Microsoft publishes for Hyper-V is Generation 1, so the import specifies
> `-Generation 1`. The document tells the reader to confirm this against the current article rather
> than assume it.

**Appliance clock checks.** Section 3.4 explicitly enables the Time Synchronization integration
service on the imported VM and verifies it, because an imported VM carries whatever its exported
configuration held rather than the Hyper-V default. Section 3.5 adds a UTC clock and time-zone check
at first boot, and section 4 adds an ordered "no servers appear at all" table.

> Hyper-V time synchronization aligns the guest's UTC clock with the host's; it does not set the
> guest's time zone, and it does not override a clock changed inside the guest after boot. An
> appliance with a skewed clock registers successfully and then discovers nothing, because Azure
> rejects the timestamps on its requests — an empty inventory with no obvious error. This was
> observed in a live run. The same table records that Integration Services governs whether a guest's
> **OS details** can be read, not whether the VM is discovered, so it is not the cause of an empty
> inventory.

### `docs/Lab-Traffic.md`

New. What the mesh creates, how to run and verify it from the staged copy, the names-not-addresses
rationale, load guidance, and the exact per-guest changes.

### `README.md`

Diagram, module table and script table updated. Adds **A note from the author**, recording the
compatibility findings met while building this lab — the v5 → v7 change, the Esv7 Gen2/NVMe
constraint, why the catalog API is pinned and Standard disk security forced, the Generation 1
appliance VHD, and the staging-disk removal — framed as observations from one subscription and one
region, closing with an invitation for feedback from anyone who meets a different problem.

---

## 8. Lab-wide consistency reconciliation

Modules 2-5 and `migrate-step1` through `migrate-step6` were still carrying values from
the lab they were forked from. They now agree with Modules 0 and 1.

**Resource groups.** Three naming schemes were in play: the step scripts defaulted to
`nazli-onprem`/`nazli-oncloud`, Modules 2-5 and `cleanup-lab.ps1` used
`rg-migrate-workshop`, and Modules 0-1 used `rg-ces-source-01`/`rg-ces-target-01`.
All of them now use the Module 0 pair.

**Project name.** `migrate-step1`, `step2` and `step3` defaulted to
`MigrateProject-Workshop` while `step4` and `step5` defaulted to `nazli-migrate-project` -
so step 4 looked for a project step 1 never created. All six now default to
`ces-migrate-01`, matching the example in Module 1.

**Appliance identity.** `migrate-step2` called the appliance `AzMigrateAppliance` and put
it in `C:\AzMigrateAppliance`; Module 1 imports `MigrateAppl` into `E:\Appliance`. The
script now uses the Module 1 name and path.

**Appliance identity, continued.** `migrate-step2` step 3 downloads the appliance VHD and
creates the Hyper-V VM - the same work Module 1 walks the instructor through by hand. This is
deliberate: the step scripts are an automation track that reaches the same state as the manual
modules, so the two routes must produce the *same* artifact. Renaming was the only change made;
the download-and-import logic is untouched and still runs by default.

**Smaller corrections.**

- `migrate-step5` printed `ssh azureuser@<Public-IP>`; the lab user is `labadmin`.
- Module 3's machine table listed OnPrem-SQL as SQL Server 2019 Express; the lab installs 2022.
- 31 `../images/*.png` references across Modules 2-5 pointed at an `images/` folder that
  does not exist in this repository, so every one rendered as a broken image. They have been
  removed, which also matches Modules 0 and 1, where verification is written as
  **Expected result** text rather than screenshots.
- `README.md` linked to `Module-2-HyperV-Migration.md` and `Module-3-Stateful-Migration.md`,
  and Module 1 linked to `Module-2-HyperV-Migration.md`. None of those files exist here. The
  links now point at `Module-2-Agentless-Migration.md` and `Module-3-Agent-Based-Migration.md`,
  and the README module table describes what those modules actually cover (Module 2 is
  agentless for the two web servers, Module 3 is agent-based for SQL and the Linux app server).

**Checked and already correct.** The four workload names (`OnPrem-Web`, `OnPrem-SQL`,
`OnPrem-Linux-Web`, `OnPrem-Linux-App`), the `192.168.0.0/24` guest addressing, and the
cross-links among Modules 2-5 were consistent throughout and were not touched.

## 9. State-bridging scripts for Modules 2 and 3

The step scripts are an automation track that reaches the same state as the manual
modules. They were decomposed by PHASE (step 3 replicated all four VMs, step 4 tested all
four, step 5 cut over all four), but the modules are organised by WORKLOAD: Module 2 takes
OnPrem-Web and OnPrem-Linux-Web all the way through cutover, and Module 3 does the same for
OnPrem-SQL and OnPrem-Linux-App. Module 3's prerequisites list Module 1, not Module 2, so
the two are parallel branches rather than a sequence.

That mismatch meant there was no way to advance the lab one module at a time.

**`-Workload` filter on steps 3, 4 and 5.** A new parameter accepting `All` (default),
`Agentless` (the Module 2 pair) or `AgentBased` (the Module 3 pair) narrows each script to
one branch. The groups are disjoint and together cover all four VMs. The default preserves
the original behaviour exactly.

**Two new wrappers.**

- `migrate-step3a-agentless.ps1` - reaches the end state of Module 2.
- `migrate-step3b-agent-based.ps1` - reaches the end state of Module 3.

Each runs `migrate-step3` then `migrate-step4` then `migrate-step5` with the matching
`-Workload` value, so there is one command per module. No migration logic is duplicated -
the wrappers only sequence the existing scripts. Both prompt for confirmation before
starting, because cutover shuts down the matching source VMs on the Hyper-V host. Both
accept `-SkipTestMigration` to omit the test-migration stage, which shortens the run and
avoids creating temporary test VMs on a restricted training subscription, at the cost of
the validation that would catch a bad replica before cutover.

Because Modules 2 and 3 are parallel branches, a student who completed Module 2 by hand
runs `step3b` only. Running both, in order, leaves all four VMs migrated and the lab ready
for Module 5.

**Known limitation, documented in the script header.** Module 3 teaches agent-based
migration - replication appliance plus Mobility Service in each guest. `step3b` reaches the
same end state using the agentless path, because that is what `migrate-step3` implements.
This is correct for bypassing Module 3 to reach Module 5, since Module 5 only requires the
four VMs running in Azure. It will **not** reproduce a Mobility Service or replication
appliance fault, so an instructor troubleshooting those must work against the student's own
environment following Module 3 sections 5-7.

**Already tolerant of partial state.** `migrate-step6-post-migration.ps1` builds its VM list
from what actually exists in the target resource group and only fails if it finds none, so
Module 5 automation works against a half-migrated estate without modification.

## 10. Prompts find the resources instead of asking you to recall them

The first pass at interactive entry removed hard-coded defaults but still asked for every name
as free text. That reproduced the problem it was meant to solve: the learner had to know the
exact spelling of a resource group, project or VM before the script would move, and a typo
failed late.

The scripts now ask Azure. When a value is not supplied on the command line, the script queries
the signed-in subscription and presents what it found as a numbered list:

- **Resource groups** - from `Get-AzResourceGroup`.
- **Azure Migrate project** - from the source resource group, covering both resource types the
  service uses (`migrateProjects` and `assessmentProjects`).
- **Hyper-V host VM** - from the VMs in the source resource group.
- **Appliance VM** - from the VMs on the Hyper-V host itself, with the four lab workloads
  filtered out.
- **Workload group** - All, Agentless or AgentBased.

**The region is no longer asked for at all.** A resource group already carries a location, so it
is read from the group that was just chosen and reported rather than prompted.

**One candidate means no question.** Where the subscription holds exactly one match, it is
selected and reported. A list appears only when there is a real choice to make.

**Resources this script creates are still named by you.** In `migrate-step1-setup-project.ps1`
the target resource group and the Azure Migrate project offer the existing ones plus a final
entry for typing a new name, so the same prompt covers reuse and creation. Values that are not
Azure resources - assessment currency, offer code, auto-shutdown time and time zone, backup
retention - remain typed, because nothing can look them up.

**Trailing parameters still work.** A value passed on the command line is used as before; it is
only checked against what the subscription actually contains, and a name that does not exist is
rejected with the list of names that do.

## 11. Appliance naming reverted to a single parameter

The previous round split the appliance name into `-ApplianceVMName` and `-ApplianceProjectName`.
That added a prompt without adding information, since the lab uses one name for both. It has
been reverted to a single `-ApplianceVMName`, now chosen from the VMs actually present on the
Hyper-V host.

The underlying constraint is still handled: Azure Migrate accepts only alphanumeric names of 14
characters or fewer under *Generate project key*, while Hyper-V allows longer names with
hyphens. The script checks the chosen name against that rule and asks for a separate
registration name **only when the check fails**. With `MigrateAppl` it never fires.

Because the appliance is chosen from the host's own inventory, an appliance imported through
Microsoft's documented route - Hyper-V Manager > *Import Virtual Machine*, which keeps the name
from Microsoft's exported configuration and offers no rename step - appears in the list under
whatever name it carries. If it is not there yet, the final list entry names it and the script
downloads and imports it as before.

## 12. Parameter entry across the migrate-step scripts

All eight scripts take no value silently, and prompts validate before accepting. Pressing Enter
does not accept the example shown in a prompt. Subscription and tenant IDs are masked wherever
these scripts write to the console.

Two consistency items were resolved:

- `migrate-step3a` and `migrate-step3b` did not set `Set-StrictMode -Version Latest`; the other
  six did. They now match.
- `migrate-common.ps1` is dot-sourced by nothing - every step script inlines its own copy of the
  helpers so it can run standalone - and its copy had drifted. It has been resynchronised and
  its header now states that nothing loads it at run time and that it is the copy to edit first.
  An unused file that looks authoritative is worse than no file at all.

## 13. Each migrate-step script now starts on its own

`migrate-step2-discover-assess.ps1` could not be run bare from the scripts folder. It failed
before showing a single prompt, and the reason was the startup sequence rather than the prompts:

```
trap { ... }
$context = Get-LabAzContext      <-- three hard stops live in here
... prompts ...
```

`Get-LabAzContext` refused the run outright in three cases: the Az modules were not loadable in
that session, the session was not signed in, or the session had no subscription selected. All
three threw with instructions to go and fix it by hand, so the script never reached the point
where it asks anything.

`deploy-lab.ps1` does not behave this way. It imports the modules it needs itself, and its
`[Parameter(Mandatory)]` declarations make PowerShell prompt before the body runs. That is why
it works from the folder and the migrate-step scripts did not.

The startup is now self-sufficient in all eight:

- **Modules are loaded, not merely checked.** Each script declares what it needs.
  `Az.Accounts` and `Az.Resources` are required everywhere, plus `Az.Compute` and `Az.Network`
  where they are used. `Az.Migrate` -- and `Az.Monitor`, `Az.OperationalInsights` and
  `Az.RecoveryServices` in step 6 -- are optional: a missing one produces a warning, not a
  refusal, because those steps already fall back to portal instructions.
- **Sign-in is offered, not demanded.** With no Azure sign-in in the session the script runs
  `Connect-AzAccount` instead of telling you to.
- **The subscription is chosen from the ones the account can see.** When the context has no
  subscription, the enabled ones are listed and selected with `Set-AzContext`. A single
  subscription is taken without asking. A subscription already chosen with `Set-AzContext` is
  used as it stands -- an existing session is never second-guessed.

`.\scripts\migrate-step2-discover-assess.ps1` with no arguments now signs in, selects a
subscription and asks its questions. The README Start-here block no longer sets the context by
hand before running them.

## 14. Failures are recorded to a file and the window stays open

A failure was unreadable when the script was launched by double-click or *Run with PowerShell*:
the trap ended with `exit 1`, the console closed on the spot, and the error went with it.

The trap now writes the whole failure to `migrate-step<N>-error-<timestamp>.log` beside the
script - falling back to the temp folder when that location is not writable - and then waits for
Enter before exiting. The report carries the message, exception type, category, the failing line
and its number, the script stack trace, and the loaded Az module versions. It passes through the
same masking as the screen output, so subscription and tenant IDs are truncated in the file too.
Set `LAB_NO_PAUSE=1` to skip the pause for an unattended run.

## 15. Module loading is best-effort again

Section 13 changed the module check from `Get-Command Get-AzContext` to
`Import-Module <module> -ErrorAction Stop` for a list of required modules. That was too strict:
any module that would not import - a partial Az installation, a version conflict, a module
present but not importable in that session - stopped the script at startup, before any prompt,
even though the cmdlets it needed were callable.

Modules are now imported best-effort. What is actually verified is that `Get-AzContext` and
`Get-AzResourceGroup` resolve, which is also how PowerShell auto-loads them on first use. A
module that fails to import produces a warning naming it, not a refusal. Only a genuinely
missing cmdlet stops the run.

## 16. The actual cause: a parse error in migrate-step2

`migrate-step2-discover-assess.ps1` could not run at all, with or without parameters. Its
section 4 instruction block contained:

```
"4. Check the clock inside $ApplianceVMName: [DateTime]::UtcNow and Get-TimeZone (expect UTC)."
```

Inside a double-quoted string PowerShell reads `$Name:` as a drive-qualified variable reference,
the same form as `$env:PATH`. With a space after the colon there is no drive name to find, so
the file fails to parse:

```
Variable reference is not valid. ':' was not followed by a valid variable name character.
```

A PowerShell script is parsed in full before its first line executes. So this stopped the script
before `Set-StrictMode`, before the sign-in, before the prompts, and before the error trap that
would have reported it. Launched with *Run with PowerShell* it looked like a window opening and
closing with nothing in it.

The fix is `${ApplianceVMName}:`, which delimits the name and ends the reference before the
colon. A scan of every lab script found this to be the only instance of the pattern.

This was the failure behind every "step 2 fails before prompting" report, including the ones
attributed earlier to the sign-in sequence and to module loading. Those two were real weaknesses
and the changes to them stand on their own, but neither was the cause here.

## 17. A parse check that runs nothing

`scripts/check-lab-scripts.ps1` runs the PowerShell parser over every `.ps1` beside it and
reports the file, line, column and message for anything that will not parse. It executes no
script, signs in to nothing and changes nothing.

A syntax error is invisible to every safeguard inside a script, because none of them have run
yet. This catches that class in a second, and it would have caught the fault above immediately.
Worth running after editing any lab script, and before a workshop.

## 18. Resource groups are typed, not listed

Listing every resource group in the subscription was the wrong shape for a training
subscription, which can hold a great many groups belonging to other people. The learner knows
which group is theirs.

Both resource-group prompts now take a typed name. The name is checked against Azure as soon as
it is entered and re-asked when it is not found, so a typo is caught at the prompt rather than
part way through the run. A name passed on the command line that does not exist fails
immediately with the same check.

In `migrate-step1-setup-project.ps1` the target group is the one the script creates, so that
prompt carries `-AllowNew`: a name that does not exist is offered for creation instead of
refused. Every other script needs the target group to exist already and says which script
creates it when it does not.

Narrow, script-generated lists are unchanged, because they are not subscription-wide and the
names are not ones a learner is expected to memorise: the Azure Migrate project in the chosen
source group, the VMs in that group, the appliance VM from the Hyper-V host's own inventory, the
workload group, and the subscription when none is current.

## 19. Step 2 no longer asks for a target resource group

Every use of `-TargetResourceGroup` in `migrate-step2-discover-assess.ps1` was traced: a
pre-flight existence check, and reading the group's region for `Resolve-LabLocation`. Nothing
else. Discovery and assessment never write to the landing zone.

The assessment body confirms it - the field Azure Migrate consumes is `azureLocation`, a region,
not a resource group:

```
sizingCriterion       = "AsOnPremises"
azureLocation         = $Location
currency              = $AssessmentCurrency
reservedInstance      = "None"
azureOfferCode        = $AzureOfferCode
azureHybridUseBenefit = $AzureHybridBenefit
```

So step 2 was asking for a resource group in order to learn a region. The parameter, the prompt,
the pre-flight check and the `Assert-LabResources` argument are all removed, and the region is
read from the source resource group instead. `migrate-step3` onwards still ask for the target
group, because those genuinely deploy into it.

## 20. A default that Enter accepts, for lab-wide settings only

`Read-LabParameter` gained `-Default`. A prompt carrying one shows it in square brackets and
Enter accepts it:

```
Assessment currency [USD]:
Azure offer (pricing agreement) for the assessment [MS-AZR-0003P]:
```

This applies to the two assessment pricing settings, which the unmodified lab hardcoded to the
same values. They are properties of the workshop rather than of anyone's subscription, so a
learner confirming them is not inheriting someone else's environment.

The distinction is deliberate and the prompt header now states it: a value in `[brackets]` is a
lab default that Enter accepts; an `(example: ...)` is a hint that must be typed. **No resource
name carries a default** - resource groups, projects, VM names and the appliance name must all
be entered or chosen, because those differ per learner and a silently inherited name is the
failure this was built to prevent.

Azure Hybrid Benefit deliberately keeps its Yes/No question with no default. It changes the cost
figures the assessment reports, and answering it is part of the exercise.

Three assessment values remain hardcoded, as they were in the unmodified lab: `sizingCriterion`
is `AsOnPremises`, because performance-based sizing needs days of utilisation data this lab does
not produce; `reservedInstance` is `None`; and the group and assessment are named
`AllServers-Group` and `Workshop-Assessment`.

## 21. Appliance selection moved after the pre-flight

Moving the appliance question earlier (section 11) put it above the line that defines
`Invoke-HostScript`, so the call failed at run time:

```
Invoke-HostScript : The term 'Invoke-HostScript' is not recognized as the name of a cmdlet...
```

A PowerShell script runs top to bottom, and a function exists only once execution passes its
definition. The parser accepts the call without complaint, so `check-lab-scripts.ps1` did not
catch it either.

The block now sits between step 1 and step 2, which is where it belonged on its own merits: the
helper functions are defined, the pre-flight has confirmed the Hyper-V host exists and is
running, and the appliance name is settled before the project key that needs it. The earlier
placement also queried the host before anything had verified the host was up.

## 22. check-lab-scripts.ps1 now catches calls made before their definition

The parse check could not see the fault above, because it is not a syntax error. The checker now
walks each script's syntax tree, records the line that defines each function, and reports any
call to one of those functions made at script level on an earlier line. Calls inside another
function body are ignored: those run later, by which time every definition in the file has been
processed.

Output names the call site and the definition:

```
FAIL  migrate-step2-discover-assess.ps1  (1 call(s) before definition)
      line 741: 'Invoke-HostScript' is called here but not defined until line 811
```

## 23. A valid resource group reported as not found

A resource group that plainly exists could be rejected at the prompt. The lookup was correct;
where it looked was not.

`Get-LabAzContext` only offered a subscription when the session had **none** selected. A session
already pointing at a subscription was used as it stood - deliberately, so an existing
`Set-AzContext` was never second-guessed. The flaw is that an account with several subscriptions
is easily pointed at the wrong one, and the Azure portal spans every subscription: a group that
is obviously there in the portal can be genuinely absent from the one the script is querying.
`Get-AzResourceGroup` then returns nothing, correctly, and the prompt says not found.

Three changes:

**The subscription is confirmed at startup.** When the account has more than one enabled
subscription, the current one is named and confirmed before any prompt. Answer No and the
others are listed. An account with a single subscription is not asked.

**A failed lookup says where it looked.** The message now names the subscription rather than
saying "this subscription", so a wrong context is visible rather than inferred.

**A failed lookup offers to find the group.** It can search the account's other enabled
subscriptions for that name and, when it finds one, offer to switch to it - then re-check the
same name without asking for it again. The original context is restored if the search is
declined or finds nothing.

It also lists resource groups in the current subscription whose names resemble what was typed,
capped at eight, which catches a plain typo without printing the whole subscription.

## 24. Two more checks in check-lab-scripts.ps1

Alongside parse errors and calls made before their definition, the checker's companion scan now
also looks for `*-Lab*` helper functions that are called somewhere in a file but never defined
in it. Every migrate-step script inlines its own helpers, so a helper that exists only in
`common.ps1` resolves during development and fails at run time for a learner. That class would
otherwise reach a live run.

## 25. common.ps1 and migrate-common.ps1 are gone

Two shared files have been removed. Delete both from your checkout.

**`migrate-common.ps1` was never loaded by anything.** Every migrate-step script already carries
its own copy of the helpers, so the file was a reference document that looked like a dependency.
Its copy had drifted from the live ones twice during this work, which is the failure mode of a
file nobody executes: it reads as authoritative and is not.

**`common.ps1` had exactly one consumer.** Only `deploy-lab.ps1` dot-sourced it; `health.ps1`,
`cleanup-lab.ps1` and the migrate-step scripts never did. All fifteen of its functions are now
defined inside `deploy-lab.ps1`, under a banner marking where they came from. All fifteen were
needed: five are called by `deploy-lab.ps1` directly, and the rest are called by those five
(`Compress-LabScript` by `Read-LabHostConfiguration`, `Invoke-LabImageCatalogGet` by
`Get-LabWindowsImages`, and so on).

`deploy-lab.ps1` is longer for it. That is the trade asked for: one file to open instead of two
to keep in step.

**Two files are still read from disk, and have to be.** `host/configure-host.ps1` is the payload
that runs on the Hyper-V host, and `health.ps1` is spliced into that payload by
`Read-LabHostConfiguration` before it is sent. Inlining either would mean holding its text
inside `deploy-lab.ps1` *and* keeping the live functions as well, so the same code would exist
twice in one file. That is worse than two files, so they stay as they are.

Verified after the move: no function in `deploy-lab.ps1` is called before the line that defines
it, and the five helpers it takes from `health.ps1` are all used after the line that
dot-sources it.

## 26. migrate-step1 no longer creates an unusable Azure Migrate project

Generating a project key failed in the browser with:

```
TypeError: Cannot read properties of undefined (reading 'properties')
migrateProjectId: ".../providers/Microsoft.Migrate/migrateprojects/<project>"
```

That is portal JavaScript, not an Azure error. Nothing was ever submitted to Azure, which is
why the activity log shows nothing and why no policy or permission check finds anything wrong.

**Cause.** `New-AzMigrateProject` creates a bare `Microsoft.Migrate/migrateProjects` resource
and nothing else - its own documented output confirms the type. Creating the project **in the
portal** also registers the tool solutions the project needs:
`Servers-Discovery-ServerDiscovery`, `Servers-Assessment-ServerAssessment` and
`Servers-Migration-ServerMigration`.

Without those, the project exists and looks correct in the resource group, but the Generate key
blade reads the discovery solution, gets `undefined`, and throws before it can submit anything.

**Second consequence, same cause.** `migrate-step2`'s assessment stage writes to
`Microsoft.Migrate/assessmentProjects/<name>` - a resource created as part of tool registration,
not by `New-AzMigrateProject`. A project created in PowerShell would have failed there too, after
the appliance work was already done.

**This was inherited, not introduced.** The unmodified lab's `migrate-step1` called
`New-AzMigrateProject` the same way.

**Change.** `migrate-step1` no longer creates the project. When the named project is absent it
prints the portal steps - resource group, project name and the matching geography already filled
in - and says why, which is what Module 1 section 1 instructs anyway. An existing project is
still detected and used. A project that looks right and cannot be used is worse than no project.

`Write-ManualAction` was only defined in `migrate-step2`; it has been added to `migrate-step1`
beside `Write-NextSteps`. The companion scan in `check-lab-scripts.ps1` catches exactly this.

**If you have a broken project,** it cannot be repaired from the portal UI - the blade that would
repair it is the one that fails. Delete it and create a replacement in the portal under the same
name, or use a new name.

## 27. Host preparation for discovery is automated (Module 1 section 2)

Deployment now applies Module 1 section 2 itself, as a new PHASE 7 in `configure-host.ps1`.
Microsoft's table of what its host-preparation script does maps to five items; four are applied,
one deliberately is not:

| Item | Applied | Why the appliance needs it |
|---|---|---|
| WinRM service, ports 5985/5986 | Yes | Carries the CIM session that collects guest metadata |
| PowerShell remoting | Yes | Lets the appliance run commands on the host, not merely connect |
| Discovery account | Yes | Host administrator, plus Remote Management Users, Hyper-V Administrators and Performance Monitor Users |
| Hyper-V Integration Services | Verified | Supplies each guest's OS detail and IP |
| CredSSP delegation | **No** | Only for guest disks on remote SMB shares. These are local, and CredSSP relays credentials to the host |

That confirms the reading that CredSSP is the only item that should be declined.

**Two deliberate differences from running the script by hand.** WinRM stays scoped to the nested
lab subnet - Microsoft's script opens 5985/5986 unscoped, and there is no reason to widen the
host. And the lab user is already a host administrator, which satisfies the account requirement
on its own; the three groups are added anyway so the least-privilege path can be demonstrated.

**Why the steps are applied directly rather than by driving the script.** The script is
interactive, and a Run Command session has no console. Answers cannot be piped to it either:
`Read-Host` reads the console, not the pipeline. So each item is applied directly and
idempotently, and Microsoft's script is then downloaded, **Authenticode-signature verified**
(more durable than a published hash, which changes each release) and run as a verifier inside a
job with a **300-second timeout**. Without that timeout an interactive prompt would hang the
whole deployment.

The script stopping at a prompt is expected and is logged as such, not as a failure. Its output
goes to `C:\AzMigrateLab\hyperv-prep-output.txt`; the state of every item goes to
`C:\AzMigrateLab\hyperv-prep.json`. Both are quoted in Module 1 section 2 as the first place to
look when the appliance cannot reach the host.

**Module 1 section 2 rewritten** with a per-option table: what each prompt does, and what breaks
if it is skipped. Sections 2.1 and 2.2 separate Microsoft's script from what deployment did
differently.

## 28. The appliance VHD downloads during deployment

The appliance VHD is published at a fixed link and does not depend on the project key - only
*registration* does. The ~11 GB download now starts as a background job at the beginning of
PHASE 2, so it runs alongside the OS image downloads instead of costing a separate wait in
Module 1, and is collected in PHASE 7.

The store partition already exists when `configure-host.ps1` starts - `deploy-lab.ps1` creates it
earlier in the run - so it is found by its `ApplianceStore` volume label rather than by assuming
a drive letter. The archive is downloaded, extracted, and its SHA256 recorded in
`E:\Appliance\download-complete.json`.

`curl.exe` is used rather than `Start-BitsTransfer`, because BITS fails in the non-interactive
SYSTEM context this script runs as. This matches what `migrate-step2` already does for the same
archive, including `--continue-at -` to resume a dropped transfer.

The whole thing is best-effort: nothing later depends on it, and Module 1 section 3.3 still works
unchanged if it did not run.

**One module change was unavoidable.** Section 3.3's `Expand-Archive` had no `-Force`, so it
would now fail on the pre-staged files. It has been added, along with a note that the archive is
usually already present and that the recorded SHA256 must still be compared against Microsoft's
published value - a hash is only worth something checked against the vendor's.

The import is **not** automated. Section 3.4 still builds the VM by hand, and `migrate-step2`
still imports it on the automated path.

## 29. Every script states which module steps it completes

The scripts and the modules are run separately, so a script that silently overlaps a module
step - or silently skips one - is a trap. Each script now carries a `MODULE COVERAGE` block in
its comment-based help, visible with `Get-Help <script> -Full`, and the README carries the same
mapping as a table.

Each block names the sections completed, and - more usefully - the ones NOT completed and why:

- `migrate-step1` does not create the project (section 26); it prints the portal steps.
- `migrate-step2` stops at Module 1 section 3.1: the project key is issued interactively.
  Registration in section 4 is a browser sign-in on the appliance and is printed, not driven.
- `migrate-step3b` reaches Module 3 sections 8 to 11 but does not perform sections 5 to 7 -
  the replication appliance and Mobility Service - because it gets there agentlessly.
- `migrate-step4` does not perform the in-guest validation those sections describe. It confirms
  the test VMs exist and are healthy; whether the application works is still yours to check.
- `migrate-step5` does not perform post-cutover validation, which is the point of the exercise.
- `migrate-step6` skips the discussion sections, and tolerates a partial estate.
- `cleanup-lab` leaves the Migrate project, key vault and recovery services vault behind. Those
  hold their names against a future lab, so they are worth removing by hand.
- Nothing automates Module 4: it is analysis, with no lab state to reach.

Every section number in these blocks was checked against the module files rather than written
from memory.

## 30. migrate-step2 checks host preparation as well as the appliance

**The appliance was already skipped.** `migrate-step2` lists the VMs on the Hyper-V host and
sets `$doImport` from whether the chosen name is among them. When `MigrateAppl` is already
there, the download, the SHA256 prompt, the extract and the import are all skipped, and the
script logs that it was not recreated. It then checks the existing VM against Module 1's
specification rather than trusting it: state, vCPUs, memory, dynamic memory off, disks on the
store drive, virtual disk size and virtual switch. A re-run against a prepared host is cheap.

**Host preparation was not checked at all.** That gap mattered more once deployment started
applying Module 1 section 2 itself, because the two tracks are run separately: a host built
another way, or one where PHASE 7 failed, would reach discovery and find nothing, with no
earlier signal.

`migrate-step2` now checks it, before the appliance download rather than after, so a problem
costs seconds instead of 11 GB:

- whether `hyperv-prep.json` exists, which tells you whether deployment applied section 2
- the Hyper-V role
- the WinRM service, status and start type
- PowerShell remoting, by looking for a WSMan listener
- Heartbeat and Key-Value Pair Exchange on each guest that is present

Everything found is logged. If WinRM or remoting is missing it offers to apply them; answering
No continues with a warning. A missing Hyper-V role is reported but not fixed - that needs a
restart, so it says so and tells you to rerun.

The guest group memberships are not re-checked here, because this script does not know which
account the lab was built with. `hyperv-prep.json` records it, which is why its presence is the
first line of the report.

## Not changed

`cleanup-lab.ps1` and `migrate-step1` through `migrate-step6` are the supplied versions. Modules 2
through 5 are unchanged. No rehearsal launcher is present in this lab; if one is wanted later it can
be modelled on Pull 12's `Start-LabRehearsal.ps1`, and all references to it have been removed from
the documentation rather than left pointing at absent files.

## Known open items

- **README links to `docs/Module-2-HyperV-Migration.md` and `docs/Module-3-Stateful-Migration.md`.**
  Those are Pull 12's filenames; this lab carries the supplied `Module-2-Agentless-Migration.md` and
  `Module-3-Agent-Based-Migration.md`. Deferred deliberately, to be handled with the Module 2/3 work.

## Verification status

Documentation links and heading anchors were checked programmatically, code fences balanced, and the
gzip+base64 traffic payload round-tripped byte-for-byte through the placeholder substitution that
`Read-LabHostConfiguration` performs. PowerShell brace balance, here-string pairing and
cross-file helper resolution were checked statically.

**The scripts have not been executed.** No live Azure or Hyper-V run has been performed against this
revision. The staging preflight, PHASE 6 payload decode, settings-file load and the Node, Nginx and
SQL portions of the traffic mesh in particular should be exercised in a training subscription before
partner delivery.
