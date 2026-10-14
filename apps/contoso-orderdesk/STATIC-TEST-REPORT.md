# Ubuntu 24.04 / Tomcat 10.1 static application report — 2026-10-07

## Performed

**14 application/helper tests and 16 full-checkout integration tests passed (30 total).**
No checks are substituted with Java/PowerShell runtime claims. Existing features and
negative cases are retained: routes/HTTP/error/input/SQL contracts, original schema/seeds,
private credential encoding/ownership, pool/JVM bounds, hosts/snapshot/service restoration,
traffic-only HTTP, Windows payload intent, runtime/source provenance and appliance guards.

Jakarta Servlet 6.0 descriptor/schema and JSP request signatures replace Java EE Servlet
4/Tomcat9 contracts. Java SE `javax.sql.DataSource`/`javax.naming` remain intact. Both
installers require Ubuntu 24.04, explicit Java17 layout and Tomcat 10.1.x; mocked package
versions reject 9, 10.0 and 11 while accepting an example Noble 10.1 update. All shell
scripts pass `bash -n`, Python source parses and JSP delimiters balance; rebuilt WAR entries
match source. **JSPs are compiled by target Tomcat, not by this build.**

Deterministic WAR: **7,346 bytes**, SHA256
`e92a3f1036e16641abf5bf726e865a4e54f1afdbda65ae7eecef8aa9e6caa554`.

Minimal runtime ZIP: **21,873 bytes**, SHA256
`c57322a70906260a1adf392d4f92f5ca8c678cb415748cc6cc9d6361b0fc5a92`. Runtime manifest and ZIP/WAR CRC are verified. Only target
scripts/WAR are embedded: no documentation, fake JDBC JAR, SQL credential or new helper file.
The full 60-file revision retains 57 native check definitions and adds 3 Ubuntu/Jakarta
contracts, but **the 60 native groups and Windows PowerShell AST parser/.NET packager were
not executed**. Seven private KVP shell-mock cases pass with no guest/service/package writes.

## Required target execution — not performed

No packages are installed in the build environment; no Java/javac/Maven/PowerShell,
Tomcat startup, real SQL/JDBC/SSH, Azure/Hyper-V, appliance discovery or migration is run.
Run the native parser/regressions on Windows PowerShell 5.1 and use a fresh separate lab,
not a 22.04 in-place upgrade or a coexisting same-name nested lab. Verify Noble OS/package
versions and actual 10.1/Java17 service layout, non-root runtime, protected 0640 JNDI, exact-
kernel KVP after reboot plus host communication gate, early SQL-independent liveness,
delayed SQL recovery, final data/page/proxy readiness, explicit write/read-back and invalid
quantity rejection, Java-owned SQL sockets, optional traffic on/off and persistence.

Appliance acceptance is separate: actual credential SSH/read-execute/sudo access, fresh
Ubuntu OS metadata, Tomcat/Java software inventory **and a visible Contoso Order Desk Java
web asset**. HTTP readiness is not discovery proof; compressed WAR/custom base are retained
without claiming to resolve earlier discovery problems. Test isolated alias repointing and
repeat health/data/write checks after migration. Review Noble Universe Tomcat security
coverage separately from standard Main maintenance through May 2029; record actual patches.

Optional legacy-app staging/rollback is **same-24.04 only**, never an OS or cross-version
Tomcat rollback. Fresh deployments have no previous app to restore. Local JDBC prerequisites
must use the exact pinned official JAR and reviewed SHA256 when required; structural checks
and HTTPS alone are not independent publisher signature authentication.

## Reproduce

From the application directory (optional maintainer Python tooling):

```bash
python3 -B build.py war
python3 -B build.py runtime
python3 -B build.py checksums
python3 -B tests/static_checks.py
```

From the complete checkout root:

```bash
python3 -B tests/integration_checks.py
```

Learner Windows deployment/migration has **no additional Python requirement**:

```powershell
.\scripts\check-lab-scripts.ps1
.\scripts\check-lab-scripts.ps1 -RunRegressionChecks
.\scripts\check-lab-scripts.ps1 -PackagePath '..\azure-migrate-workshop-ubuntu2404.zip'
```

Use an existing external parent folder; explicit `-OverwritePackage` is required to replace
that chosen ZIP. Native packaging does not rebuild app assets. See the root static report
for full scope, measured composed payload and current release gates.
