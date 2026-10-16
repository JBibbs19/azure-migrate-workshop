# Optional · Lab traffic mesh

**TD SYNNEX | Cloud Enablement Services**

**Audience:** Operator/instructor. This guide covers optional generator installation and
control; student learning and manual observations remain in Module 0.

Initial deployment already provisions Contoso Order Desk on Tomcat 10.1/OpenJDK 17, its shared
SQL login, lab aliases and Nginx 8080 desk/API proxy. Port-80 IIS/Nginx sites remain unchanged.
The optional instructor generators add low-rate requests; they are not app prerequisites.
CPU simulation is a separate, independent opt-in on the four existing 2-vCPU source guests:
Windows Server 2022 on `OnPrem-Web` / `OnPrem-SQL` and Ubuntu 24.04 on
`OnPrem-Linux-Web` / `OnPrem-Linux-App`. It adds local calculation work, not a network
dependency. The existing network generator remains on Linux-App; no generator relocation,
customer/employee profile or load-balancing extension is included.

| Edge | Protocol | Driven by |
|---|---|---|
| OnPrem-Web → OnPrem-SQL | TDS 1433 | LabOrderDeskTraffic scheduled task reads existing orders |
| OnPrem-Web → OnPrem-Linux-App | HTTP 3000 | The same task calls health |
| OnPrem-Linux-App → OnPrem-Linux-Web | HTTP 8080 | contoso-orderdesk-traffic Python HTTP generator |
| OnPrem-Linux-Web → OnPrem-Linux-App | HTTP 3000 | Existing Nginx desk/API reverse proxy |
| OnPrem-Linux-App → OnPrem-SQL | TDS 1433 | Actual Tomcat Java process reads/inserts through bounded JDBC pool |

Python never connects directly to SQL and contains no SQL password. It performs health,
orders read and at most one sample order insert per cycle through Nginx. Default interval is
30 seconds; allowed range 20–600 seconds. This is not a production load/sizing benchmark.
The real JVM keeps initial/min idle 1 and maxActive 4 JDBC connections after readiness;
no arbitrary sockets are opened merely to affect dependency polling.

## Final Step 1 offer (instructor opt-in)

Only after Step 1 verifies the project and freshly confirms all four workload VMs are
Running does it print WHAT TO DO NEXT, then offer **network traffic first**:

> Would you like to initiate lab traffic as part of the immediate continuation of the lab? [y/N]

It then separately offers **optional CPU simulation**, also defaulting to **No/Enter**:

> Would you like to turn on optional CPU Simulation? [y/N]

Before the CPU choice it explains the 24-hour default (configurable 1–168 hours), the
collection period and normal ongoing lab charges. Declining either offer leaves that
component unchanged, including any already-running generator; declining network traffic
does not opt into or prevent CPU simulation. An accepted component uses the staged script
on the **selected** host, not an arbitrary local Hyper-V installation, and privately
obtains the existing deployment password when required. Step 2 independently verifies
workload power before appliance work.

The network offer warns that enabling traffic causes ongoing **background sample order creation**.
Network generators survive console closure and resume after reboot while enabled. Keep them running
through the lab only if wanted; there is **no automatic lab-completed detector or stop timer**.
Completing a script or the lab alone does not stop them. Explicitly run the stop command on
the host, or stop/remove VMs as part of teardown; enabled tasks resume if VMs are restarted.

Step 1 network controls:

- `-LabTraffic Skip`: never prompt/start; existing generators remain unchanged.
- `-LabTraffic Prompt`: explicitly request the `[y/N]` prompt even with supplied environment inputs.
- `-LabTraffic Start`: explicit opt-in without the Yes/No question; still requires all prerequisites.
- `-LabTrafficPassword`: optional SecureString, otherwise privately prompted after opt-in.
  Never supply a plaintext password in command-line arguments.

Separate Step 1 CPU controls:

- `-CpuSimulation Prompt|Start|Skip`: default `Prompt`; default prompting is interactive
  only. Supplying all environment inputs skips the default offer; explicit `Start` opts in
  for automation. Network opt-in never implies CPU opt-in.
- `-CpuDurationHours 24`: CPU duration, allowed range 1–168 hours.

With all source/target/project/location inputs supplied, the default is **no traffic prompt**;
this preserves automation usability. No traffic option bypasses project or guest readiness.

From a workstation, Step 1 requires managed Run Command `ProtectedParameter` support in
Az.Compute, a refreshed staged script/settings, and already-installed OpenSSH **8.4+** on
the host. The password travels only as a protected parameter, never in the source script or
ordinary parameters. The host script's `-NonInteractive` mode forbids missing-credential/user
prompts, capability installation and Windows-only `SkipLinux` success; it preflights Linux
password/sudo access on both Linux guests before changing generators. Unsupported preflight
means this offer has **not initiated** traffic; use the elevated host-interactive command below.
An elevated local launch is used only after Azure instance metadata matches the selected
subscription, resource group, VM name and VM ID. Otherwise Step 1 takes the remote path.

**CPU-enabled runtime prerequisite:** This documentation-only overlay does not install
CPU support or update any scripts. Use the separately delivered
`azure-migrate-workshop-ubuntu2404-cpu-simulation.zip`, extracted as a complete CPU-enabled
checkout. An older workshop checkout or its scripts may not contain the feature; applying
these Markdown files alone is insufficient. Fresh deployments from the CPU-enabled package
stage the controller and CPU assets automatically.

For an **existing host**, refresh only the controller and CPU assets from that CPU-enabled
checkout. **Do not redeploy, rerun host setup, recreate/restart guests or restart replication
to enable this feature.** Preserve `C:\AzMigrateLab\lab-traffic.settings.json`.
From the CPU-enabled extracted checkout root in elevated PowerShell **on HyperVHost**,
verify the files are available, then copy them:

```powershell
Get-Item .\scripts\enable-lab-traffic.ps1, .\scripts\cpu-simulation\control.ps1, `
    .\scripts\cpu-simulation\windows-cpu.ps1, .\scripts\cpu-simulation\linux-cpu.py `
    -ErrorAction Stop
(Get-Command .\scripts\enable-lab-traffic.ps1).Parameters.Keys
```

Confirm that the controller exposes `Mode`, `Component`, `CpuSimulation`,
`CpuDurationHours` and `RenewCpu`; stop and obtain the CPU-enabled package if any file
or CPU control is missing. Then stage the verified files:

```powershell
Copy-Item .\scripts\enable-lab-traffic.ps1 C:\AzMigrateLab\enable-lab-traffic.ps1 -Force
Copy-Item .\scripts\cpu-simulation C:\AzMigrateLab -Recurse -Force
```

The second command stages `control.ps1`, `windows-cpu.ps1` and `linux-cpu.py` under
`C:\AzMigrateLab\cpu-simulation`. These copies do not start generators. Keep the
controller and all three assets together; an older staged controller or missing CPU
assets must be refreshed before using the new controls.

Full network startup requires the Windows task Running, Linux generator active and proxy readiness
markers. Partial/failed startup can leave generators running: inspect or explicitly stop
them before retrying. Step 1 checks managed execution state, exit code and exact full-start
marker, not just Azure provisioning success. Timeout/read/submission uncertainty is reported
as **UNKNOWN**, never as proof of no traffic; inspect the named managed Run Command and host.
Only a terminal managed command resource is cleaned up, and that cleanup does not stop traffic.
These results describe generator startup, not sustained app health or guaranteed appliance
collection. Readiness and order counts still need live verification below. CPU has a
separate outcome: `LAB_CPU_FULLY_STARTED` confirms all four CPU starts;
`LAB_CPU_PARTIAL_OR_FAILED` requires per-guest inspection and does not cancel confirmed
network startup. Neither marker proves the requested CPU percentage was achieved.

## Run on HyperVHost (instructor opt-in)

Deployment from the CPU-enabled package stages the script/settings and CPU assets,
but never starts generators. A bare interactive launch asks about network first, then
CPU independently; both questions default to No/Enter:

```powershell
C:\AzMigrateLab\enable-lab-traffic.ps1
# Or change the request interval:
C:\AzMigrateLab\enable-lab-traffic.ps1 -IntervalSeconds 30
# Stop both network and CPU generators only:
C:\AzMigrateLab\enable-lab-traffic.ps1 -Disable
# Stop network only, leaving CPU simulation unchanged:
C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Stop -Component Network
```

Supply the same existing lab password privately. LinuxUsername is read from
`C:\AzMigrateLab\lab-traffic.settings.json`, otherwise enter the confirmed deployment
username when prompted; an explicit parameter overrides settings. Windows configuration uses
PowerShell Direct. Linux configuration uses SSH; OpenSSH 8.4+ can reuse the initial password
prompt with askpass, older clients prompt per guest. `-SkipLinux` configures Windows only
and saves the Linux commands for console execution. `-SettingsPath` accepts an alternate
settings file; the normal file is deployment-generated. Do not run from your workstation.

Reruns update only optional generator tasks/configuration. SQL mixed mode/login preparation
belongs to initial PHASE 5, not this script. Nginx/hosts already exist; the traffic script
checks proxy readiness without replacing it. **Disable preserves the SQL login, proxy,
hosts, Tomcat and original sites**. It stops/removes the Windows task and disables the
Python service and stops/disarms CPU workers on all four guests; no shared application
prerequisite is removed. Explicit `-Component Network` leaves CPU unchanged.

## Optional CPU simulation

CPU simulation runs local, low-priority calculation workers on `OnPrem-Web`, `OnPrem-SQL`,
`OnPrem-Linux-Web` and `OnPrem-Linux-App`, not on HyperVHost or the appliance. The default
daily profile uses UTC (no daylight-saving adjustment or midday peak):

- **06:00–22:00 UTC:** 16-hour day, approximately **15% total guest CPU**.
- **22:00–06:00 UTC:** 8-hour night, approximately **2% total guest CPU**.

These are best-effort targets across both vCPUs, not extra load added to application CPU or
caps on real applications. The worker reduces its contribution as other activity rises and
rests when existing load meets/exceeds the target. It also rests if CPU measurement fails or
CPU reaches the **30% high-CPU guard**; resumption requires CPU below **20%** and a
**60-second cooldown**. OS activity and host contention can prevent an exact target.

The default run is **24 hours**, configurable from **1–168 hours**, with guest-local expiry
and **no reboot auto-resume**. Closing the launching console does not end a running worker.
Use these CPU-only commands in elevated PowerShell on HyperVHost:

```powershell
C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Start -Component Cpu -CpuDurationHours 24
C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Status -Component Cpu
C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Stop -Component Cpu
```

`-Mode` accepts `Start|Check|Status|Stop`; Check is a read-only alias of Status.
Start defaults to the Network component. Interactive Start without explicit `-Mode` or
`-Component` asks the network question. Explicit `-Mode Start` or `-Component Network` starts network traffic
without that question. `-Component Cpu` or `Both` explicitly opts into CPU; an explicit
`-CpuSimulation Skip` conflicts with either. With network startup,
`-CpuSimulation Prompt|Start|Skip` controls the separate CPU offer; `Prompt` skips CPU
in `-NonInteractive` use. Check/Status, Stop and `-Disable` default to both components
unless `-Component` is explicit. These controls do not add a network stop timer.

Repeating Start reuses a healthy active CPU run without extending its deadline. A
recorded stopped/expired deadline or unresolved run does not silently become a new run.
Inspect Status and use Stop as needed; `-RenewCpu` is the explicit choice to replace
the CPU session and deadline.

CPU Status reports the actual task/unit and PID, heartbeat freshness/staleness, UTC
phase, target total CPU, measured total/baseline/worker CPU, guard/cooldown and expiry.
Windows uses the `LabCpuSimulation` scheduled task; Linux uses
`lab-cpu-simulation.service`. A healthy task/unit and fresh heartbeat prove the worker
is alive, **not that the target CPU percentage was achieved**. Inspect measured values
and reasons such as baseline-above-goal, measurement-invalid or high-CPU cooldown;
a worker can be alive while deliberately resting. Native Windows/Hyper-V calibration
and full four-guest acceptance have not been newly validated by this documentation merge.

Stop only the synthetic component; leave SQL, Tomcat, Nginx, IIS and application data
intact. Stop source CPU simulation **before migration testing or cutover**, or before
maintenance, not merely because initial replication starts. Isolate test copies from
source networks **before first boot** and verify inherited CPU workers are stopped and
disarmed. Never start CPU simulation on test or migrated VMs through the post-migration
controller; see the [post-migration operator guide](post-migration-labtraffic.md).

The purpose is a less-idle, daily **educational CPU history**, not a production capacity
benchmark or a simulation of memory, disk or network pressure. Start or explicitly renew the
CPU session once appliance performance collection is active so expiry covers the intended
capture. **Partial CPU history can appear earlier; at least 24 hours of collection is needed
to capture the complete 16-hour day/8-hour night cycle.** Before comparing assessments, allow
the full selected history window (longer if applicable), matching it to captured data.
Follow the existing [Module 1 optional portal comparison](Module-1-Discovery.md#56--optional-performance-comparison-and-business-case):
create a **second** performance-based assessment of the same four servers, keeping the
region/pricing assumptions the same and choosing history matching the captured window.
Recalculate that comparison after more collection if needed.
The required Step 2 **AsOnPremises/configuration-based** assessment does not use CPU history;
there is no performance-based switch on that helper. Do not expect immediate graphs or a
changed recommended SKU. See Microsoft's
[Hyper-V assessment tutorial](https://learn.microsoft.com/en-us/azure/migrate/tutorial-assess-hyper-v?view=migrate-classic).

No additional VM, VM-size change or paid service is created. On an existing fixed-price VM,
CPU use has no additional usage charge; keeping the lab running longer continues normal
compute/storage billing.

## Verify actual dependencies

```powershell
Invoke-RestMethod http://192.168.0.13:3000/api/ready
Invoke-RestMethod http://192.168.0.12:8080/api/ready
Invoke-RestMethod http://192.168.0.13:3000/api/orders
```

Counts should rise after generator cycles. The Windows log is `C:\LabTraffic\traffic.log`;
Linux uses `sudo journalctl -u contoso-orderdesk-traffic -n 15 --no-pager`. The generator has
no SQL secret. Windows traffic credentials remain in a root-equivalent administrator/SYSTEM
ACL-protected script; this is lab-only, not production secret storage. Do not share that file.
On Linux-App, `sudo ss -ntp | grep ':1433'` should attribute SQL sockets to **java**, not Python.
Disabling traffic must leave both direct and proxy readiness working.

## Discovery and migration

Without generators, HTTP edges may be idle; the Tomcat→SQL dependency still exists. An empty
or partial polling view is not evidence of no dependency. Use the appliance's actual guest
credential and validate SSH reachability, recursive CATALINA_HOME/BASE directory read/execute,
and sudo netstat/ls separately. Leave real traffic/pool activity across multiple five-minute
polling windows; dependency uploads can take six hours and web-app configuration 24 hours.
No local health test proves appliance discovery. Nginx is separate inventory, not a supported
assessed web-app platform.

After test migration/cutover, repoint only lab aliases/private DNS to **actual new private IPs**,
restart Tomcat to close the old pool and reload Nginx to resolve its new upstream. Update
Windows generator aliases too. Keep test dependencies isolated from source/production.
Network generators resume at boot if enabled; stop them before maintenance and re-enable explicitly
only after readiness. See [Module 3](Module-3-Agent-Based-Migration.md) and the
[application guide](../apps/contoso-orderdesk/README.md).

The existing private-network firewall rules permit these edges. No new broad public rule
is necessary; retain app-tier access from the intended Nginx/Windows clients only.
