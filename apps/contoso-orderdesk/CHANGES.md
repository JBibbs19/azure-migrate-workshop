# Ubuntu 24.04 revision — 2026-10-07

Fresh separate lab: Ubuntu Noble, repository Tomcat 10.1.x with explicit OpenJDK 17,
Jakarta Servlet 6.0 / Pages 3.1. Installer, service, config, snapshots and validators use
Tomcat10 paths/service; optional legacy staging is scoped to an already-24.04 guest only.
Java SE JDBC/JNDI, protected credentials, endpoints, bounded resources and SQL bytes are
preserved. WAR/runtime are deterministically rebuilt; no old package/live guest is edited.
Tomcat/OS/web-asset discovery remains a mandatory live release gate, not a static claim.

## Earlier history (superseded Tomcat 9 runtime)

# Contoso Order Desk changes

## Integrated initial deployment

- Tomcat 9/OpenJDK 17 on port 3000 is the default Linux-App runtime, with the included original
  WAR and complete JSP source. No fresh Node installation or manual cutover is required.
- Initial SQL setup creates the shared restricted labapp login using the protected deployment
  password. Cloud-init waits for liveness only; final host validation requires SQL/data/proxy
  readiness before success. Nginx keeps its separate original port-80 site.
- Added deterministic minimal runtime ZIP, SHA256 guards, unattended root-only JSON seed input,
  bounded pinned JDBC retrieval and explicit locally checksum-verified prerequisite fallback.
- Optional HTTP-only traffic uses the real JVM JDBC pool for database work. Disable never
  removes the primary application's SQL login, proxy or hosts.
- Discovery validation checks both CATALINA_HOME/BASE directory read/execute and sudo ls/netstat.
  Personal account/session references and deferred-fresh-build instructions were removed.
- Existing-lab 3001 staging, explicit switch and captured-state rollback remain available as a
  fallback, not a step in a new deployment. No target runtime/discovery test is claimed here.
