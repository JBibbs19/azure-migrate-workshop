# Branch-ready static validation — 2026-10-05

**26 checks passed**: 14 app/helper tests and 12 repository composition tests. Tests use Python
standard library and `bash -n`; no packages/runtimes were installed. Deterministic WAR/runtime
builds, archive CRC and per-file SHA256 checks are part of packaging verification.
See [app test details](apps/contoso-orderdesk/STATIC-TEST-REPORT.md).

## Exact baseline preservation

The supplied published tree contains **24 files**, including the old dated parser report.
This checkout retains 23 baseline files: **18 changed**, **5 byte-for-byte unchanged**.
The superseded `scripts/check-lab-scripts.092426.txt` report is omitted because it is not
parser evidence for this revision. Complete app source, WAR/runtime assets and tests are added.
`tests/baseline-manifest.json` records exact original/current hashes and added-file inventory;
`SHA256SUMS` covers current deliverable files. This is a full source tree, not a patch overlay.

Unchanged files:

- `docs/Module-4-ASR-Comparison.md`
- `scripts/check-lab-scripts.ps1`
- `scripts/cleanup-lab.ps1`
- `scripts/health.ps1`
- `scripts/migrate-step3a-agentless.ps1`

Original SQL schema/seed statement bytes, VM names, IPs, sizing, fixed disks, host/appliance
behavior and the instructor agentless shortcut are preserved. No Pull 12 modules are imported.

## Payload and artifact measurements

Default path, without a local JDBC JAR:

| Item | Bytes |
|---|---:|
| Baseline raw host source | 77,494 |
| Current raw host source | 78,776 |
| Baseline composed host source with health/traffic | 115,370 |
| Current composed host source with health/traffic/runtime | 143,609 |
| Additional composed source | 28,239 |
| Minimal runtime ZIP | 21,744 |
| Runtime Base64 insertion | 28,992 |
| JSP WAR | 7,338 |

Composition measurements model the source assembly with stdlib gzip/Base64; .NET gzip bytes
can differ slightly. No undocumented 64-KB limit is assumed. The runtime includes only required
target scripts/WAR and its manifest, not docs/tests or nested delivery packages. The optional
local prerequisite route adds the reviewed JDBC JAR, so its submitted source is larger.

WAR SHA256:
`25335c07f9588fa02f95bae9c3460c16a4e6e91d448475705885dbf666b06d6d`

Runtime ZIP SHA256:
`7bf0012db401688b0d423e0eb58a7041195714f2f5aac2376468cc3585494bf4`

## What remains a target-only check

**No PowerShell AST parser, JVM/JSP compilation, Tomcat/SQL execution, Azure/Hyper-V deployment,
appliance discovery/assessment or migration was run here.** Python lexical checks are not PS
parser or Java compiler evidence. No download availability or publisher signature was verified.
Before release, run `scripts/check-lab-scripts.ps1` on Windows PowerShell 5.1, then exercise a
fresh disposable lab through package installation, SQL-independent early health, delayed SQL
recovery, final data/page/proxy readiness, one explicit order write, non-root Java-owned SQL
sockets, actual 0640 descriptor permissions, discovery credential access, reboot and traffic
on/off. Test any required local-driver prerequisite route. Verify appliance SSH/mapping and
polling/discovery separately; static readiness is not appliance-tested readiness.

After test migration/cutover, repoint lab aliases to actual matching private SQL/app/Nginx
addresses, restart Tomcat/reload Nginx, and repeat readiness/data/write checks in isolation.
AgentBased remains the Module 3 workload grouping, not a Mobility Service implementation claim.

## Reproduce

From the complete checkout:

```bash
python3 apps/contoso-orderdesk/build.py war
python3 apps/contoso-orderdesk/build.py runtime
python3 apps/contoso-orderdesk/tests/static_checks.py
python3 tests/integration_checks.py
python3 apps/contoso-orderdesk/build.py checksums
python3 build.py zip --output ../azure-migrate-workshop-tomcat.zip
```

Then run the actual Windows parser maintenance tool before any deployment.
