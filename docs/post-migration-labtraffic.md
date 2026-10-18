# Post-migration lab traffic

Use `scripts/post-migration-labtraffic.ps1` after Step 5 cutover and **before Step 6
hardening**, then run Check again after Step 6. It works unchanged with both lab
OS/Tomcat branches; it does not install or upgrade any runtime. This is an ordinary
Windows PowerShell 5.1+ controller, not a Cloud Shell, Hyper-V Direct, WinRM or SSH
script. Existing generators may survive replication and already have inserted orders:
**inventory first is not prevention of inherited traffic**.

**Operator prerequisite:** Use `scripts/post-migration-labtraffic.ps1` from the separately
delivered CPU-enabled Ubuntu 24.04 package, not an older checkout. This documentation-only
overlay does not update the controller; an older script may lack CPU inventory/disarm.
See the [source operator guide](Lab-Traffic.md) for CPU-enabled asset verification and
existing-host refresh without redeployment or replication restart.

Source CPU simulation is independent of network/order traffic, locally bounded and has
no reboot auto-resume. Do not assume a copied worker is stopped merely because its
deadline is bounded. Check/Status inventory inherited CPU workers on all four guests
without changing them. Prepare/Start/Stop stop and disarm inherited CPU workers on the
confirmed running guests; an unreachable or powered-off guest remains unverified.
**Start here starts only bounded network traffic, never CPU simulation on test or
migrated VMs.** These actions leave SQL, Tomcat, Nginx and IIS intact.

## Prerequisites and target confirmation

- Existing Az.Accounts, Az.Resources, Az.Network and Az.Compute, including managed
  `Set/Get/Remove-AzVMRunCommand` and `ProtectedParameter` support. Working Azure VM
  agents, their required connectivity, and RBAC for network/VM reads and managed guest
  command execution are required. Guest commands run elevated; no guest admin password
  is required. Nothing automatically repairs agents, routes, firewalls or permissions.
- Select the intended subscription and exact target resource group. Omit
  `-TargetResourceGroup` to enter it at a prompt; strict validation still applies and
  no source/default group is inferred. Every invocation
  displays each VM's exact ARM identity, OS, single NIC/primary private IPv4, VNet/subnet
  and observed public-IP DNS FQDN. Type EACH exact VM name to confirm it, then confirm
  subscription/RG scope; no guest command is submitted until all four confirmations pass.
  Multiple NICs/IP configurations, duplicate IPs and mixed VNets are rejected rather
  than guessed. Guest IP/hostname and DNS-confirmed guest FQDN are observed separately;
  unavailable FQDN is reported, never invented. Lab aliases are **not** true DNS names.
- Default names are `OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web`,
  `OnPrem-Linux-App`. Explicit `-TestMigration` selects only their `-test` counterparts;
  it never falls back to cutover VMs. **Isolate test copies from source networks before
  their first boot**, including inherited application connections and generators. Stop
  source CPU simulation before migration testing or cutover, not just because initial
  replication begins; verify copied CPU workers are stopped/disarmed before testing.
- Even Check/Status create/remove Azure Run Command resources and need execution/write
  permission, not Reader alone. Default Check/Status are read-only in the guests:
  first-inventory/validation summaries are console-only, with no guest log/ACL writes,
  pause, repoint or start. `-VerifySampleOrder` is the explicit order-write exception.
  Prepare/Start/Stop retain protected Web summary logging.

## Ordinary PowerShell sequence

All entered names/IDs below are the operator's actual values, not fixed lab defaults:

```powershell
Connect-AzAccount
$subscriptionId = Read-Host 'Intended subscription ID'
Set-AzContext -SubscriptionId $subscriptionId
$targetRg = Read-Host 'Exact target resource group'
$controller = '.\scripts\post-migration-labtraffic.ps1'

& $controller -TargetResourceGroup $targetRg -SubscriptionId $subscriptionId  # Check: jobs first
& $controller -Mode Prepare -TargetResourceGroup $targetRg -SubscriptionId $subscriptionId
& $controller -Mode Check -TargetResourceGroup $targetRg -SubscriptionId $subscriptionId
& $controller -Mode Start -TargetResourceGroup $targetRg -SubscriptionId $subscriptionId `
    -IntervalSeconds 30 -DurationMinutes 60
# Now complete Step 6 using its separate guide/script, then:
& $controller -Mode Check -TargetResourceGroup $targetRg -SubscriptionId $subscriptionId
& $controller -Mode Status -TargetResourceGroup $targetRg -SubscriptionId $subscriptionId
& $controller -Mode Stop -TargetResourceGroup $targetRg -SubscriptionId $subscriptionId
```

For isolated test copies add `-TestMigration` to **every** invocation and enter their
actual resource group. Start itself repeats inventory, Prepare and every required
Check before arming/launching either generator. Every mode inventories traffic on all
roles before mutations; Stop attempts inventory best-effort without requiring application
readiness. Powered-off targets are skipped/reported partial, while Stop continues on
other confirmed running targets; no VM is automatically booted. Prepare/Start explicitly authorize
pausing/disabling inherited jobs, backing up hosts files, replacing only
`onprem-web/sql/nginx/app` aliases on all four guests while preserving other names and
comments, restarting `contoso-orderdesk.service` and reloading Nginx. Existing SQL data,
JNDI credentials, application units and proxy configuration are preserved. No Private
DNS deployment or network modification occurs. Check reports stale aliases and skips
functional calls that could follow them. TCP probes use only verified target private IPs;
IP-only success cannot authorize Start.

Checks originate in the guests: Web→SQL:1433, Web→App:3000, App→SQL:1433,
App→Linux-Web:8080, Linux-Web→App:3000. Local IIS:80, SQL Express:1433,
Nginx:80/8080 and Tomcat:3000 services/listeners, expected pages, health/readiness,
authenticated SQL existing-order reads and HTTP existing-customer/order reads must
all pass. Readiness requires `status=ready`, `database=reachable` and the expected app.
Order totals use API `count` or SQL `COUNT_BIG`, not the up-to-20 recent rows. Controller
HTTP probes use no environment proxy and reject redirects; the installed generator
retains its no-environment-proxy implementation and fixed lab URL. Step 6 independently
maintains private-IP NSG rules for this graph; rerun Check after hardening. A failure
requires inspection of NSGs/routes/guest firewalls or workload state, not opening all
ports or assuming a live target was verified by this source revision.

## Writes, lifetime and credentials

Start uses the installed Linux HTTP generator's normal cycle (at most one order POST
per interval, **30 seconds minimum**, 60 minutes default; duration 1–120 minutes).
Tomcat Java, not Python, inserts into SQL. Windows performs SQL reports/count snapshots
and HTTP health calls, not inserts. Arming/launching consumes part of the shared duration;
very short durations can expire before launch and fail closed. Each guest independently
enforces a durable deadline plus a scheduler/systemd runtime limit. Linux reuses the
installed `contoso-orderdesk-traffic.service` unchanged: `DynamicUser=true`, original
`ExecStart`, strict filesystem/home protection, `NoNewPrivileges` and 64 MiB limit are
verified. Its drop-in overrides only `RuntimeMaxSec` and `Restart=no`; boot stays disabled.
A separate guest-local timer/root handler only stops traffic and updates expiry state;
it never generates HTTP traffic. No boot trigger, automatic restart or reboot auto-resume
is installed. Stop disables/stops only generators and expiry controls, leaving
application/SQL/proxy/aliases/data intact.

`-VerifySampleOrder` with Check, Prepare or Start is a separate **explicit WRITE**:
insert and read back one real sample order after all gates pass. Without this switch,
validation performs no order insertion (inherited jobs may still write). A lost POST
response can mean an order committed: do not retry it blindly.

Web reuses only the exact base64 literal password assignment from the protected migrated
`C:\LabTraffic\order-desk.ps1`; it never evaluates that script or prints the credential.
If unavailable, explicitly supply the existing **restricted `labapp` SQL login** password:
`$sqlPassword = Read-Host 'Existing labapp SQL password' -AsSecureString`, then add
`-SqlPassword $sqlPassword`. It is sent only as a managed **protected parameter** when
needed. Start stores a machine-DPAPI-protected copy under SYSTEM/Administrators-only ACLs.
SQL uses lab-only `TrustServerCertificate=true`; this is not production TLS guidance.

## Evidence and recovery

Web keeps protected `C:\LabTraffic\summary.log` and `native-traffic.log`, each rotated
at 1 MiB with two retained rotations, plus Application events from
`LabPostMigrationTraffic` and `post-migration-state.json` / config / expiry task.
Linux keeps `/var/lib/contoso-orderdesk/labtraffic/state.json` and config; inspect
`journalctl -u contoso-orderdesk-traffic.service` locally for individual insert IDs.
Linux journal retention follows the existing guest journal policy; bounded duration
limits this run's messages. **Linux detail is not merged into Web's summary**, and no
Azure Monitor/DCR collector is added. Status reports native/inherited Windows tasks,
both original/legacy Linux generators, the guest deadline timer/handler, and durable
state/deadline (an expired flag can remain with a last-written running phase after a kill).

The CPU observation reports `LabCpuSimulation` tasks on both Windows guests and
`lab-cpu-simulation.service` on both Linux guests, including actual PID, heartbeat
freshness/staleness, UTC phase, total target, measured total/baseline/worker CPU,
guard/cooldown and expiry when state is available. A live service/task and fresh
heartbeat do not prove the CPU target was achieved; a worker may be deliberately
resting. After Prepare/Start/Stop, verify the CPU task/unit is disarmed and its worker
PID is absent on every confirmed guest. Partial/unknown results require inspection,
not an assumption that expiry or controller completion stopped all copied workers.

ARM provisioning success is insufficient: every action needs Succeeded InstanceView,
exit code zero and one matching compact JSON marker. Polls are bounded, writes are not
retried, and errors/logs omit raw secret-bearing diagnostics. Unknown, failed or partial
Start must be inspected with Status/Run Command and **Stop before another Start**; a
controller crash cannot cancel the guest deadlines. An unreachable agent prevents remote
Stop too: use guest-local Task Scheduler/systemctl or wait for verified expiry. Do not
remove a still-running/unknown Run Command thinking that it stops the generators.

## Offline maintenance

`& $controller -SelfTest` runs native parser/encoding, safe credential-literal,
hosts-preservation, result-contract, subnet and fail-closed fixtures without Az/auth.
Embedded `LinuxPythonBody` and `LinuxDeadlineBody` also each expose `self_test()` (stdlib
mocks; no guest commands, SQL or network); maintainers can extract those here-strings,
compile/execute with `__name__='offline_fixture'`, and call that function. Check the
extracted `New-GuestSource` Linux wrapper with `bash -n`. These offline checks do not
prove Windows/Az cmdlet compatibility, VM-agent execution, SQL or live connectivity;
a real Windows PowerShell 5.1 self-test and isolated four-VM acceptance run are required.
