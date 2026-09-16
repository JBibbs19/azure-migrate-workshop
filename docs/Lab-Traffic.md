# Optional · Lab traffic mesh

**TD SYNNEX | Cloud Enablement Services**

By default the four workloads are independent samples, so Azure Migrate's application
dependency view is legitimately empty. This optional add-on wires them into one small-business
order desk that produces continuous TCP traffic between the guests, which gives dependency
analysis something real to observe and makes the performance-based assessment comparison in
Module 1 meaningful.

It is opt-in. A lab deployed without it behaves exactly as Modules 0–5 describe.

## What it creates

| Edge | Protocol | Driven by |
|---|---|---|
| `OnPrem-Web` → `OnPrem-SQL` | TDS 1433 | Scheduled task `LabOrderDeskTraffic` reads a recent-orders report |
| `OnPrem-Web` → `OnPrem-Linux-App` | HTTP 3000 | The same task calls `/api/health` as a batch job would |
| `OnPrem-Linux-App` → `OnPrem-SQL` | TDS 1433 | systemd unit `lab-traffic` inserts an order and counts the table |
| `OnPrem-Linux-App` → `OnPrem-Linux-Web` | HTTP 8080 | The same unit calls the proxy |
| `OnPrem-Linux-Web` → `OnPrem-Linux-App` | HTTP 3000 | Nginx `proxy_pass` on a new port 8080 server block |

`OnPrem-SQL` becomes a shared dependency of both application tiers, which is the discussion
the map should provoke: the database cannot be moved on its own.

Nothing deployment validates is replaced. The IIS site on `.10`, the Nginx root site on `.12`
and the Node service on port 3000 keep serving their original pages, so
`Assert-LabSourceWorkloads` still passes. The proxy listens on 8080 and the generators are
separate units.

## Run it

Deploy the lab first and wait for workload readiness. Then, inside HyperVHost in an elevated
Windows PowerShell session:

```powershell
$password = Read-Host 'Lab password' -AsSecureString
.\enable-lab-traffic.ps1 -AdminPassword $password
```

Windows guests are configured over PowerShell Direct, which needs no network path. The two
Linux guests are configured over SSH from the host; the script prompts for the `labadmin`
password once per guest. If no SSH client is present it tries to add the OpenSSH client
capability, and failing that writes each guest's script to `C:\AzMigrateLab\Traffic\` for the
instructor to run from the Hyper-V console.

Useful switches:

- `-IntervalSeconds 20` — seconds between request cycles. Keep it low-rate.
- `-SkipLinux` — configure the Windows guests only and write the Linux scripts to disk.
- `-Disable` — stop and remove the generators, the proxy and the lab SQL login.

## Verify

```powershell
Invoke-RestMethod http://192.168.0.12:8080/api/health
Invoke-Sqlcmd -ServerInstance 192.168.0.11 -TrustServerCertificate -Database ContosoApp `
    -Query 'SELECT COUNT(*) AS Orders FROM dbo.Orders'
```

The order count should climb between runs. Generator logs are at
`C:\LabTraffic\traffic.log` on `OnPrem-Web` and `journalctl -u lab-traffic` on
`OnPrem-Linux-App`.

Leave the mesh running for at least one full dependency collection interval before expecting
a populated map. Agentless dependency analysis samples active connections on a polling
interval rather than capturing continuously, so a short burst can be missed entirely. Confirm
the current interval and the guest-credential prerequisites in the
[support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v)
rather than assuming a value.

## Names, not addresses — on purpose

Every generator resolves `onprem-sql`, `onprem-app` and `onprem-nginx` through each guest's
hosts file. Hardcoded `192.168.0.x` addresses would silently break after cutover into
`10.1.0.0/16`, and the failure would look like a migration defect.

Because the generators start at boot, the migrated VMs resume the same traffic in Azure —
and it fails until the hosts entries are repointed. Treat that as a scheduled exercise in
Module 3, not an accident: rewriting hosts entries or moving to DNS is exactly the
remediation a customer performs after a real cutover.

## Keep the load light

Module 1 asks learners to record the collection period, confidence rating and idle nature of
the samples, because a few minutes of idle telemetry cannot justify a production right-sizing
recommendation. A steady trickle of requests improves that conversation. A CPU or network
stress tool would ruin it: the host has only 8 vCPUs shared across four guests, and the
resulting assessment recommendations would be fiction.

## What it changes on the guests

- **OnPrem-SQL** — SQL Server Express is switched to mixed-mode authentication and given one
  lab-only login, `labapp`, holding `db_datareader` and `db_datawriter` on `ContosoApp` only.
  The Linux generator cannot use Windows authentication, so this is required. `-Disable`
  removes the login; it does not revert the authentication mode.
- **OnPrem-Web** — `C:\LabTraffic\order-desk.ps1` plus the `LabOrderDeskTraffic` scheduled
  task, running as SYSTEM with an at-startup trigger.
- **OnPrem-Linux-App** — the `mssql` npm package, `/opt/contoso-app/lab-traffic.js`, the
  `lab-traffic` systemd unit and `/etc/lab-traffic.env` (mode 600, root-owned). The original
  `contoso-app` service and `server.js` are untouched.
- **OnPrem-Linux-Web** — `/etc/nginx/conf.d/lab-order-desk.conf` only. The default site is
  untouched.

Credentials are held in the systemd environment file and the scheduled task's script. Both
are readable by an administrator of the guest. Use lab-only credentials, as Module 0 requires.

## Firewall

The base deployment already permits this traffic between guests; see
[Module 0](Module-0-Setup.md#7-lab-firewall-posture). No additional rules are needed for the
mesh itself.
