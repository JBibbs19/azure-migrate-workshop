# Contoso Order Desk — integrated Tomcat workshop application

The initial workshop deployment now installs this original lightweight Java/JSP application
on **OnPrem-Linux-App**, Ubuntu 24.04, 2 GB / 2 vCPU. **Tomcat 10.1 + OpenJDK 17** serves the
named WAR on **3000**; Linux-Web remains a separate Nginx host with its original port-80 site
and a desk/API proxy on **8080**. The existing `ContosoApp` Customers/Orders schema and seeds
are unchanged. GET reads; POST inserts one order for an existing customer.

Tomcat compiles JSPs on the target. Servlet signatures use `jakarta.servlet.http`;
the descriptor schema is Jakarta Servlet 6.0 / Pages 3.1. Java SE
`javax.sql.DataSource` and `javax.naming` remain correct and unchanged.
Fresh provisioning pins the official standalone Apache Tomcat **10.1.61** distribution,
with **CATALINA_HOME = CATALINA_BASE = /opt/tomcat**, and forces Java 17 through the service's
JAVA_HOME. There is no Ubuntu Tomcat package, split HOME/BASE tree or configuration alias.
Verify fresh appliance OS/software/Java web-asset discovery separately from local health;
the conventional layout alone does not establish discovery.
Review Apache Tomcat security releases separately from Ubuntu's Java/OS package maintenance.

## Initial deployment — recommended

Use the full workshop checkout, not an app-only archive as a substitute for it.
The application lives at `apps/contoso-orderdesk/` in that checkout. Follow
[Module 0](../../docs/Module-0-Setup.md) for source deployment with
`scripts/deploy-lab.ps1`. No additional app setup or password prompt is required.

Deployment embeds the checkout's checksum-verified `dist/runtime.zip` into the host/cloud-init
payload. It never downloads source from a branch URL or embeds the Tomcat binary in Run Command.
Cloud-init installs OpenJDK 17, CA certificates and discovery tools from Ubuntu. The fresh
installer fetches Apache Tomcat **10.1.61** and the pinned Microsoft JDBC **13.6.0.jre11** driver
over HTTPS. It installs on 3000
and waits only for SQL-independent liveness. Host PHASE 5 creates the unchanged sample data,
prepares mixed mode and the shared `labapp` login with the protected deployment password,
and validates SQL readiness, actual orders/customers, the named page and the Nginx proxy
before marking success. PHASE 7 host discovery preparation remains unchanged.

The pinned Tomcat publisher coordinate is:
`https://archive.apache.org/dist/tomcat/tomcat-10/v10.1.61/bin/apache-tomcat-10.1.61.tar.gz`.
The installer retrieves the same filename's official `.sha512` over bounded HTTPS, requires
exactly 128 hex digits and the exact filename when supplied, and verifies it **before** any
extraction. If needed, `downloads.apache.org` may supply only that same version and digest;
it never searches for latest. This is **publisher-checksum verification over TLS, not independent
PGP signature verification**. Failure to fetch or validate either artifact stops provisioning.
The archive is fully checked for bounded sizes, normalized paths, duplicate names and unsafe
types (all links are refused). The runtime version and the exact Tomcat JDBC pool factory class
are checked. Bundled ROOT/docs/examples/manager/host-manager webapps are omitted; Apache LICENSE
and NOTICE are retained. The deployed `webapps` contains only the lab's unchanged `ROOT.war`.

A successful fresh guest records the source URLs and actual publisher SHA512 in
`/opt/contoso-orderdesk/tomcat-source.json`.

The pinned JDBC publisher coordinate is:
`https://repo.maven.apache.org/maven2/com/microsoft/sqlserver/mssql-jdbc/13.6.0.jre11/mssql-jdbc-13.6.0.jre11.jar`.
Downloads have bounded timeouts/retries;
JAR CRC, SQL driver class and Java compatibility are checked. These checks and HTTPS are
**not independent publisher signature/checksum authentication**. Actual installed package,
Java and driver versions/SHA256 are recorded at `/opt/contoso-orderdesk/installed-versions.txt`.
If that guest download is blocked, acquire the exact official JAR through an approved route
before deployment and supply **both** `-TomcatJdbcJar <local-path>` and
`-TomcatJdbcSha256 <reviewed-expected-SHA256>` to `deploy-lab.ps1`. The client verifies and
embeds the JAR; the guest verifies it again. No Maven/JDK is needed on the deployment client.

## Runtime, endpoints and discovery

Fresh deployment creates a real standalone `/opt/tomcat` with actual `conf/server.xml`,
private `conf/Catalina/localhost/ROOT.xml`, `webapps/ROOT.war` and `lib/mssql-jdbc.jre11.jar`.
There is no HOME-conf compatibility symlink/helper. `/opt/contoso-orderdesk` holds only lab
support scripts, the source WAR and installation receipts, not CATALINA_BASE. Installation
refuses occupied deployment paths/accounts; it does not update an existing lab. The source
port 3000, root URL, SQL descriptor and Nginx ports remain unchanged. A service pre-start
check verifies the pinned real distribution on each start; final host checks still require
Java 17, SQL data/readiness, the named desk and Nginx proxy, not just a listening socket.
Verify appliance discovery independently on a fresh deployment.

```text
Service       contoso-orderdesk (non-root user/group contoso-orderdesk)
CATALINA_HOME /opt/tomcat
CATALINA_BASE /opt/tomcat
WAR           /opt/tomcat/webapps/ROOT.war
JDBC          /opt/tomcat/lib/mssql-jdbc.jre11.jar
Private JNDI  /opt/tomcat/conf/Catalina/localhost/ROOT.xml
```

| Endpoint | Contract |
|---|---|
| `/` | Named desk, global counts, newest 20 by default, 20–100 records/page dropdown, Next X older / Previous X newer GET controls, existing-customer form; 503 if DB unavailable |
| `/api/health` | SQL-independent `status: healthy`, `server: OnPrem-Linux-App`, ISO timestamp, app name |
| `/api/info` | App name and `javaVersion`; memory/uptime describe the JVM |
| `/api/ready` | 200 `ready` only when SQL probe succeeds; otherwise 503 `not_ready` |
| GET `/api/orders` | Customers, recent orders, counts from existing tables; no writes |
| GET `/api/order-options` | Up to 500 existing customers and 500 distinct products with earliest compatible price from full Orders history; read-only, no Products table |
| POST `/api/orders` | Form-urlencoded customerId, productName, quantity, unitPrice; 201 with orderId |

`pageSize` accepts **20, 40, 60, 80 or 100**, default **20**, on `/` and GET `/api/orders`. Initial reads choose the current maximum OrderID as `anchor` (0 if empty). Subsequent reads carry that anchor and exactly one positive `before` (older) or `after` (newer) cursor; positive values must be integers in 1–2147483647. Duplicate, unknown, mixed-direction, negative, overflow and invalid size parameters return 400. The separate page-size form's **Apply** button omits the old cursor/anchor, starting a fresh newest-first view. Controls are disabled at the bounds, partial final pages show their actual row count, and stale out-of-range cursors fall back to the corresponding surviving end. Deleted rows are omitted; no session or database changes are needed.

The default GET `/api/orders` retains **count, customerCount, orders, customers** with their original global-count/newest-20 semantics, adding a `pagination` object: **pageSize, anchor, hasNext, hasPrevious, nextBefore, previousAfter** (unused cursors are null). For example, begin with `/api/orders?pageSize=20`, then construct `/api/orders?pageSize=20&anchor=<anchor>&before=<nextBefore>` only if `hasNext` is true. UI/API share bound `TOP (?)`, anchor and directional keyset queries, never OFFSET; concurrent new inserts above the anchor do not move existing page boundaries. Refresh to see new inserts. Counts remain whole-table totals and paging never inserts.

POST requires an existing integer customer, a 1–100-character printable product, quantity
1–10 and price 0.01–1000.00 with at most two decimals. Prepared statements bind SQL values;
HTML/JSON output is escaped and browser cross-site submissions rejected. This lab has no
user authentication or production HTTPS; keep it on private networks.

The real Tomcat JVM owns a bounded JDBC pool: initial/minIdle 1, maxIdle 2, maxActive 4,
5-second borrow/query limits, 5-second login and 10-second socket timeout. Resource limits:
64-MB initial / 384-MB maximum heap, 192-MB metaspace, 900-MB service memory limit,
25 request threads. One meaningful idle SQL connection is retained after readiness/query
activity, not arbitrary fake sockets. SQL encryption trusts the lab self-signed certificate;
this is not production certificate validation.

The credential descriptor is **root:contoso-orderdesk 0640**; no SQL password is in the WAR,
source, process arguments or environment. Initial root-only cloud-init seed material uses the
existing lab credential model; the installer removes its seed files and the host detaches
and removes seed ISOs after readiness. Cloud-init retains root-only user-data: use lab-only
credentials and do not share expanded files or journals containing secrets.

The appliance's actual SSH guest credential needs recursive read/execute on **both**
CATALINA_HOME and CATALINA_BASE directories (the same real `/opt/tomcat` tree), plus sudo `netstat`/`ls`. The existing deployment
user has NOPASSWD sudo. Directory discovery permissions do not make the private descriptor
world-readable. Only `logs`, `work` and `temp` are runtime-owned; code/configuration remain root-owned. Validate locally, then separately verify appliance SSH reachability and
credential mapping. Tomcat discovery/assessment support does not guarantee migration execution;
Nginx is software inventory, not a separately supported assessed web-app platform.

```bash
sudo bash /opt/contoso-orderdesk/scripts/validate.sh --credential-user <deployed-linux-username>
# Explicitly inserts one row, reads it back, and rejects invalid quantity:
sudo bash /opt/contoso-orderdesk/scripts/validate.sh --write
sudo ss -ntp | grep ':1433'    # The DB connection owner should be java.
```

HTTP through Nginx can be exercised with the instructor's staged `enable-lab-traffic.ps1`
on HyperVHost, or `sudo bash /opt/contoso-orderdesk/scripts/traffic.sh on 300` on Linux-App.
The original Python generator defaults to one fixed demo order every 300 seconds (20–600 configurable), including overnight, through `onprem-nginx:8080`; it has
no SQL driver/password. `traffic.sh off` and the integrated traffic script's `-Disable`
stop only generators: the required SQL login, hosts, proxy and app remain. Fresh Linux-Web also has a separate `contoso-employee-orders.service`: root-owned Python/systemd, DynamicUser, HTTP only via local Nginx, browse a uniformly selected 1–3 available SQL-backed 20-record order pages before each order attempt (stop at the last page), random existing full-history product/customer, quantity 1–3, wait 2–20 minutes after the cycle, UTC 06–22 independent of CPU. Empty browsing or browse/options failures skip the write; no new GET/POST starts at night or after Stop. Extra proxied requests to OnPrem-Linux-App port 3000 improve observation opportunities, not guaranteed Azure dependency capture. Source network Start/Status/Stop includes both Linux units; a healthy night-sleep is not a failure. Invalid/empty options skip; uncertain POSTs are not retried. See [Lab Traffic](../../README.md#lab-traffic) for state/journal and schedule details. Retain multiple
five-minute dependency polling windows; uploads can take six hours and web-app configuration
24 hours. Do not confuse local checks with appliance-tested readiness.

## Test migration and cutover

Put all dependent test VMs on the same isolated test VNet. Repoint only the lab aliases to
actual new private IPs before judging SQL readiness, and reload Nginx/restart Tomcat so cached
connections resolve the new targets. Keep production/source addresses out of the test mesh:

```bash
# Linux-App at its NEW address (example addresses; replace all three):
sudo bash /opt/contoso-orderdesk/scripts/repoint.sh 10.1.0.11 10.1.0.13 10.1.0.12
# Linux-Web: update onprem-app/onprem-sql/onprem-nginx in /etc/hosts, preserve unrelated entries.
sudo nginx -t && sudo systemctl reload nginx
```

Before functional traffic, disable/stop `contoso-employee-orders.service` on Linux-Web and `contoso-orderdesk-traffic.service` on Linux-App (including inherited copies); keep the employee unit disabled on test/target unless separately authorized. Pre-boot source isolation is still mandatory. Also update Windows generator aliases or private DNS. Verify direct and proxy health,
readiness, orders and the named page; explicitly re-enable traffic only when desired.

## Target verification and troubleshooting

Use the included prebuilt WAR/runtime assets; no application rebuild is required for the
course. See the [initial-deployment reference](integration/FRESH-DEPLOYMENT.md) for the
application layout and required target checks, then follow the manual course modules for
migration testing and acceptance. Diagnose liveness with service status/JSP compile
errors, readiness with SQL login/mode/1433/aliases, not password changes.

## References

- https://tomcat.apache.org/tomcat-10.1-doc/appdev/sample/
- https://learn.microsoft.com/en-us/sql/connect/jdbc/download-microsoft-jdbc-driver-for-sql-server?view=sql-server-ver17
- https://learn.microsoft.com/en-us/azure/migrate/migrate-support-matrix-hyper-v?view=migrate
- https://learn.microsoft.com/en-us/azure/migrate/concepts-dependency-visualization?view=migrate
