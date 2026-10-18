# Contoso Order Desk — integrated Tomcat workshop application

The initial workshop deployment now installs this original lightweight Java/JSP application
on **OnPrem-Linux-App**, Ubuntu 24.04, 2 GB / 2 vCPU. **Tomcat 10.1 + OpenJDK 17** serves the
named WAR on **3000**; Linux-Web remains a separate Nginx host with its original port-80 site
and a desk/API proxy on **8080**. The existing `ContosoApp` Customers/Orders schema and seeds
are unchanged. GET reads; POST inserts one order for an existing customer.

**Validation status:** deterministic WAR/runtime packaging and Python/static checks are
available. Java/JSP compilation, package installation, SQL connectivity, appliance discovery
and migration have not been exercised in the build environment. Tomcat compiles JSPs on the
target. Servlet signatures use `jakarta.servlet.http`; descriptor schema is Jakarta Servlet
6.0 / Pages 3.1. Java SE `javax.sql.DataSource` and `javax.naming` remain correct and unchanged.
Both installers verify installed Tomcat 10.1.x, use `/usr/share/tomcat10` and
`/etc/tomcat10/web.xml`, and force the Java 17 executable through the service's JAVA_HOME.
The stock `tomcat10.service` is disabled so only the bounded custom app service runs.
Complete target checks and fresh appliance OS/software/Java web-asset acceptance before
training release; WAR deployment/custom CATALINA_BASE are retained, not asserted to fix
any prior discovery issue. Noble Universe Tomcat security coverage must be reviewed
separately from standard Main maintenance; actual patch versions are recorded at install.

## Initial deployment — recommended

Use the full workshop checkout, not an app-only archive as a substitute for it.
The application lives at `apps/contoso-orderdesk/` in that checkout. Follow
[Module 0](../../docs/Module-0-Setup.md) for source deployment with
`scripts/deploy-lab.ps1`. No additional app setup or password prompt is required.

Deployment embeds the checkout's checksum-verified `dist/runtime.zip` into the host/cloud-init
payload. It never downloads source from a branch URL. Cloud-init installs Tomcat/OpenJDK from
Ubuntu and the pinned Microsoft JDBC **13.6.0.jre11** driver over HTTPS. It installs on 3000
and waits only for SQL-independent liveness. Host PHASE 5 creates the unchanged sample data,
prepares mixed mode and the shared `labapp` login with the protected deployment password,
and validates SQL readiness, actual orders/customers, the named page and the Nginx proxy
before marking success. PHASE 7 host discovery preparation remains unchanged.

The pinned publisher coordinate is:
`https://repo.maven.apache.org/maven2/com/microsoft/sqlserver/mssql-jdbc/13.6.0.jre11/mssql-jdbc-13.6.0.jre11.jar`.
Availability was not tested in the build environment. Downloads have bounded timeouts/retries;
JAR CRC, SQL driver class and Java compatibility are checked. These checks and HTTPS are
**not independent publisher signature/checksum authentication**. Actual installed package,
Java and driver versions/SHA256 are recorded at `/opt/contoso-orderdesk/installed-versions.txt`.
If that guest download is blocked, acquire the exact official JAR through an approved route
before deployment and supply **both** `-TomcatJdbcJar <local-path>` and
`-TomcatJdbcSha256 <reviewed-expected-SHA256>` to `deploy-lab.ps1`. The client verifies and
embeds the JAR; the guest verifies it again. No Maven/JDK is needed on the deployment client.

## Runtime, endpoints and discovery

Fresh deployment creates only `/usr/share/tomcat10/conf/server.xml` as a guarded symlink to
`/var/lib/contoso-orderdesk/conf/server.xml`, the one canonical server configuration; it does
not change an existing service. The legacy staged installer is unchanged. Local alias/readability
checks are not Azure Migrate acceptance: appliance discovery remains **pending**. The stock
`/etc/tomcat10/server.xml`, port 3000 and private JNDI descriptor are unchanged.

```text
Service       contoso-orderdesk (non-root user/group contoso-orderdesk)
CATALINA_HOME /usr/share/tomcat10
CATALINA_BASE /var/lib/contoso-orderdesk
WAR           /var/lib/contoso-orderdesk/webapps/ROOT.war
JDBC          /var/lib/contoso-orderdesk/lib/mssql-jdbc.jre11.jar
Private JNDI  /var/lib/contoso-orderdesk/conf/Catalina/localhost/ROOT.xml
```

| Endpoint | Contract |
|---|---|
| `/` | Named desk, counts, up to 20 recent orders, existing-customer form; 503 if DB unavailable |
| `/api/health` | SQL-independent `status: healthy`, `server: OnPrem-Linux-App`, ISO timestamp, app name |
| `/api/info` | App name and `javaVersion`; memory/uptime describe the JVM |
| `/api/ready` | 200 `ready` only when SQL probe succeeds; otherwise 503 `not_ready` |
| GET `/api/orders` | Customers, recent orders, counts from existing tables; no writes |
| POST `/api/orders` | Form-urlencoded customerId, productName, quantity, unitPrice; 201 with orderId |

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
CATALINA_HOME and CATALINA_BASE directories, plus sudo `netstat`/`ls`. The existing deployment
user has NOPASSWD sudo. Directory discovery permissions do not make the private descriptor
world-readable. Validate locally, then separately verify appliance SSH reachability and
credential mapping. Tomcat discovery/assessment support does not guarantee migration execution;
Nginx is software inventory, not a separately supported assessed web-app platform.

```bash
sudo bash /opt/contoso-orderdesk/scripts/validate.sh --credential-user <deployed-linux-username>
# Explicitly inserts one row, reads it back, and rejects invalid quantity:
sudo bash /opt/contoso-orderdesk/scripts/validate.sh --write
sudo ss -ntp | grep ':1433'    # The DB connection owner should be java.
```

HTTP through Nginx can be exercised with the instructor's staged `enable-lab-traffic.ps1`
on HyperVHost, or `sudo bash /opt/contoso-orderdesk/scripts/traffic.sh on 30` on Linux-App.
The Python generator performs low-rate HTTP reads/writes through `onprem-nginx:8080`; it has
no SQL driver/password. `traffic.sh off` and the integrated traffic script's `-Disable`
stop only generators: the required SQL login, hosts, proxy and app remain. Retain multiple
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

Also update Windows generator aliases or private DNS. Verify direct and proxy health,
readiness, orders and the named page; explicitly re-enable traffic only when desired.

## Target verification and troubleshooting

Use the included prebuilt WAR/runtime assets; no application rebuild is required for the
course. See the [initial-deployment reference](integration/FRESH-DEPLOYMENT.md) for the
application layout and required target checks, then follow the manual course modules for
migration rehearsal and acceptance. Diagnose liveness with service status/JSP compile
errors, readiness with SQL login/mode/1433/aliases, not password changes.

## References

- https://tomcat.apache.org/tomcat-10.1-doc/appdev/sample/
- https://learn.microsoft.com/en-us/sql/connect/jdbc/download-microsoft-jdbc-driver-for-sql-server?view=sql-server-ver17
- https://learn.microsoft.com/en-us/azure/migrate/migrate-support-matrix-hyper-v?view=migrate
- https://learn.microsoft.com/en-us/azure/migrate/concepts-dependency-visualization?view=migrate
