# Optional · Lab traffic mesh

**TD SYNNEX | Cloud Enablement Services**

Initial deployment already provisions Contoso Order Desk on Tomcat 9/OpenJDK 17, its shared
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
