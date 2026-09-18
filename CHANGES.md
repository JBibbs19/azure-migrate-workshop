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
| `scripts/common.ps1` | Modified |
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

## 3. Appliance staging uses the host OS disk

The 512 GB OS disk has ample spare capacity, so no additional managed data disk is attached. An
earlier revision of this work did attach a 128 GB `StandardSSD_LRS` data disk; it was removed
because a data disk bills continuously — including while the VM is deallocated — for space the lab
already owns.

`scripts/deploy-lab.ps1` instead adds a preflight step, **Check appliance staging space**, between
`Check Hyper-V readiness` and `Create guest image disk`. It:

- verifies free space on `C:` against `-ApplianceStagingMinimumFreeGB` (default **80**, covering the
  archive, its expanded VHD and headroom for the dynamic guest disks to grow);
- creates `C:\AzMigrateLab\Appliance`;
- grants the deployment's `-AdminUsername` Modify on that subfolder. `C:\AzMigrateLab` blocks
  inheritance and grants only SYSTEM and Administrators, and under UAC a non-elevated process such
  as a browser download holds Administrators as deny-only — without this grant the Module 1 download
  fails with access denied;
- prints observed free space and emits `APPLIANCE_STAGING_READY`, checked by the existing
  `Assert-LabRunResult`, matching the `HYPERV_INSTALLED` / `HYPERV_READY` pattern.

Running it before guest provisioning means a space problem surfaces immediately rather than an hour
into setup.

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
