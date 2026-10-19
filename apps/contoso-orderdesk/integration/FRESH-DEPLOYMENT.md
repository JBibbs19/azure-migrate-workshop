# Initial-deployment integration contract

This is implemented in the complete workshop checkout, not a proposal or manual post-provision
step. `scripts/deploy-lab.ps1` reads `apps/contoso-orderdesk/dist/runtime.zip` and its SHA256
before contacting Azure; embeds it with health/traffic helpers; and runs the real PowerShell
AST parser on the combined host source. It sends the existing AdminPassword only as a protected
managed Run Command parameter. No new app-password prompt is added.

## Fresh Ubuntu 24.04 scope

This full branch uses a fresh separate host and Noble QCOW2/base-image cache. Do not rerun
it against an existing lab or perform an in-place OS upgrade. The initial installer requires
Ubuntu 24.04, pinned standalone Apache Tomcat 10.1.61 and Java 17, with real HOME=BASE
`/opt/tomcat`; no stock Ubuntu Tomcat service or HOME-conf alias is installed. Servlet 6.0 / Pages 3.1 use
Jakarta imports, while Java SE JDBC/JNDI namespaces, SQL seeds and bounded pool remain intact.
Only a marked incomplete build of this revision may resume; older/unmarked hosts are refused.

## Provisioning sequence

1. Preserve the host, fixed disks, DHCP reservations, VM names, memory/CPU and appliance behavior.
2. Linux-Web cloud-init retains its original port-80 site and creates the desk proxy on 8080,
   with required lab aliases and the original port-bearing Host header.
3. Linux-App cloud-init installs Ubuntu OpenJDK 17, CA certificates and discovery tools. `write_files`
   stages a checksum-guarded runtime ZIP and JSON password seed as root:root 0600. Runtime
   verification checks the ZIP digest/CRC and every included script/WAR checksum.
4. The initial installer obtains the official Apache Tomcat 10.1.61 tarball and its pinned-version
   publisher SHA512 over bounded HTTPS. It fails closed before extraction on unavailable/invalid
   checksum, mismatch, unsafe member/type, duplicate path or excessive archive size. A same-version
   official fallback must match the already acquired digest. This is publisher-checksum verification,
   not independent PGP verification. It installs the real standalone tree, retains LICENSE/NOTICE,
   omits Apache bundled webapps and checks the exact JDBC pool factory class and runtime version.
   It obtains the pinned JDBC JAR using bounded HTTPS retries, or verifies
   the explicitly provided local JAR/checksum embedded by the deploy client. It creates the
   dedicated non-root service, private 0640 JNDI descriptor and bounded JDBC pool, and serves
   on 3000. Health performs no SQL work; only liveness is awaited in cloud-init. Secret staging
   files are removed on installer exit. No Node package/source/script is executed.
5. Host PHASE 5 installs/configures SQL Express and preserves the original ContosoApp schema
   and seed statement. It enables mixed mode before the existing SQL service restart and
   prepares/enables `labapp` using the existing protected lab password. Permissions remain
   db_datareader/db_datawriter in ContosoApp only.
6. Exact running-kernel tools/binary validation enables then stops KVP until the scheduled
   cloud-init reboot; critical failure masks it. Host joint polling requires three consecutive
   normal all-four KVP/OS metadata and app observations, plus a final completion recheck.
7. Host final workload validation waits for Tomcat health/info, SQL readiness, nonempty actual
   customer/order data, named page, SQL listener and Nginx proxy readiness. Only then are
   cloud-init seed ISOs detached/removed. PHASE 6 merely stages the optional traffic script;
   PHASE 7 still prepares the Hyper-V discovery host. Completion markers do not mean the
   appliance discovered/assessed the app or a migration was tested.

## Included application assets

The complete JSP source, prebuilt WAR, runtime ZIP and target scripts are included under
`apps/contoso-orderdesk/`; a new checkout needs no hidden workspace files or remote branch
download. The default JDBC is a target prerequisite fetched from a pinned publisher coordinate;
HTTPS/structural checks are not an independently verified signature. The optional local route
requires the exact pinned filename and an explicit reviewed expected SHA256 before deployment.

## Required target checks

Follow [Module 0](../../../docs/Module-0-Setup.md) to verify a fresh course lab:
package/download path, SQL-independent early health, delayed
SQL initialization/recovery, final readiness/data/page/proxy checks, one explicit order write,
root/runtime descriptor ownership, non-root JVM, actual java-owned SQL socket, discovery
credential directory read/execute and sudo ls/netstat, reboot behavior, optional traffic on/off,
and alias repointing in isolated test migration. Repeat using the local-JDBC prerequisite route
when required. Validate appliance SSH/credential mapping separately, fresh Ubuntu 24.04 OS
metadata, Tomcat 10.1/Java 17 inventory and a visible Contoso Order Desk Java web asset. A
local healthy endpoint is not appliance discovery acceptance. No such target execution
is claimed by static tests.
