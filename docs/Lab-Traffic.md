# Optional · Lab traffic mesh

**TD SYNNEX | Cloud Enablement Services**

Initial deployment already provisions Contoso Order Desk on Tomcat 10.1/OpenJDK 17, its shared
SQL login, lab aliases and Nginx 8080 desk/API proxy. Port-80 IIS/Nginx sites remain unchanged.
The optional instructor generators add low-rate requests; they are not app prerequisites.

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
Running does it print WHAT TO DO NEXT, then ask:

> Would you like to initiate lab traffic as part of the immediate continuation of the lab? [y/N]

**No/Enter or an unrecognized answer makes no generator changes**, including no attempt to
stop any already-running generators. Yes privately prompts for the deployment password and
launches the staged traffic script on the **selected** host, not on an arbitrary local
Hyper-V installation. Step 2 independently verifies workload power before appliance work.

The offer warns that enabling traffic causes ongoing **background sample order creation**.
Generators survive console closure and resume after reboot while enabled. Keep them running
through the lab only if wanted; there is **no automatic lab-completed detector or stop timer**.
Completing a script or the lab alone does not stop them. Explicitly run the stop command on
the host, or stop/remove VMs as part of teardown; enabled tasks resume if VMs are restarted.

Step 1 controls:

- `-LabTraffic Skip`: never prompt/start; existing generators remain unchanged.
- `-LabTraffic Prompt`: explicitly request the `[y/N]` prompt even with supplied environment inputs.
- `-LabTraffic Start`: explicit opt-in without the Yes/No question; still requires all prerequisites.
- `-LabTrafficPassword`: optional SecureString, otherwise privately prompted after opt-in.
  Never supply a plaintext password in command-line arguments.

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

New deployments stage this refreshed script automatically. For an existing host, copy the
refreshed `scripts/enable-lab-traffic.ps1` from this package to
`C:\AzMigrateLab\enable-lab-traffic.ps1` **on that host**, retaining the deployment's existing
`lab-traffic.settings.json`. An older staged script is not silently used for remote execution.

Full startup requires the Windows task Running, Linux generator active and proxy readiness
markers. Partial/failed startup can leave generators running: inspect or explicitly stop
them before retrying. Step 1 checks managed execution state, exit code and exact full-start
marker, not just Azure provisioning success. Timeout/read/submission uncertainty is reported
as **UNKNOWN**, never as proof of no traffic; inspect the named managed Run Command and host.
Only a terminal managed command resource is cleaned up, and that cleanup does not stop traffic.
These results describe generator startup, not sustained app health or guaranteed appliance
collection. Readiness and order counts still need live verification below.

## Run on HyperVHost (instructor opt-in)

Deployment stages the script/settings, but never starts generators:

```powershell
C:\AzMigrateLab\enable-lab-traffic.ps1
# Or change the request interval:
C:\AzMigrateLab\enable-lab-traffic.ps1 -IntervalSeconds 30
# Stop generators only:
C:\AzMigrateLab\enable-lab-traffic.ps1 -Disable
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
Python service; no shared application prerequisite is removed.

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
Generators resume at boot if enabled; stop them before maintenance and re-enable explicitly
only after readiness. See [Module 3](Module-3-Agent-Based-Migration.md) and the
[application guide](../apps/contoso-orderdesk/README.md).

The existing private-network firewall rules permit these edges. No new broad public rule
is necessary; retain app-tier access from the intended Nginx/Windows clients only.
