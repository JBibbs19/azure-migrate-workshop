# Two-method Azure Migrate workshop — isolated documentation pilot

**TD SYNNEX | Cloud Enablement Services**

> **DRAFT PILOT—NOT LIVE VALIDATED · 2026-10-17.** This course is **not ready for partner training** until the instructor verifies the execution gates and records a full live rehearsal.

## What this pilot teaches

The four source guests remain **OnPrem-Web, OnPrem-SQL, OnPrem-Linux-Web and OnPrem-Linux-App**, on a new, separate Hyper-V host with fresh VM IDs. They form **one application boundary**, not two independent application waves.

| Module | Student activity | Boundary / evidence |
|---|---|---|
| [0 — Setup](docs/Module-0-Setup.md) | Use the unchanged source deployment command; verify the four workloads and plan separate appliance capacity | Fresh source namespace and IDs; no reuse of a protected lab |
| [1 — Discovery and assessment](docs/Module-1-Discovery.md) | Manually import/register the independent discovery appliance, assess four servers, and record five dependencies | Required manual application boundary; optional preview Wave overview, no prerequisite |
| [2 — Agentless frontend replication](docs/Module-2-Agentless-Migration.md) | Hyper-V provider for **Web + Linux-Web only**; isolated port-80 tests and manual delta markers | **HOLD — no final frontend cutover**; static results do not prove the Order Desk chain |
| [3 — Agent-based SQL/App and shared cutover](docs/Module-3-Agent-Based-Migration.md) | Modern physical-server workflow, separate replication appliance and guest Mobility Service for **SQL + App**; full four-VM isolated test | Both engines, same approved isolated test VNet; **one planned final maintenance window** for all four |
| [4 — ASR comparison](docs/Module-4-ASR-Comparison.md) | Compare migration with future DR; optional separately approved review/cancel walkthrough | Do not protect the pilot machines again or re-register their components |
| [5 — Post-migration](docs/Module-5-Post-Migration.md) | Manual target health, AMA/DCR monitoring, backup/security/cost/update review | After shared acceptance only; distinguish configured resources from received telemetry/completed recovery evidence |

The target is **four Azure IaaS VM rehosts**. PaaS Preferred / PaaS Only export recommendations are conceptual discussion, not instructions to deploy App Service, AKS, SQL Managed Instance or SQL Database. A supplied export is not a capacity reservation. No complete VM-size redesign is included: historical B1/B2 examples are explicitly non-approved pilot examples, and actual per-role support/quota/capacity selection is a manual gate.

## Student route and reusable references

Follow **START-HERE → Modules 0–5**. After the Module 0 source deployment command, the teaching route uses portal/appliance actions and ordinary guest/host OS commands. Do not run `migrate-step1` through `migrate-step6`, traffic installers/controllers or other functional helpers to satisfy the Mobility exercise, testing, cutover or post-migration objectives.

The included deployment, application and traffic assets support the course environment. Retained migration helpers use a host-provider workflow and do **not** implement or validate the SQL/App physical/Mobility route. The README toolkit commands and traffic operator guides are reusable reference material, not an alternate student path or acceptance evidence. They are not instructions to bridge source/test/target environments or reactivate duplicate writers.

## Formal manual execution gates

All live items below are **UNKNOWN / DEFERRED until observed and approved**. Writing the guide does not clear them. Stop at the relevant gate; do not guess a value or weaken security to continue.

1. **Fresh identities and isolation:** new pilot resource groups/project/source host and pristine workload VM IDs. No reconfiguration of existing replication, dual protection of one VM, clone of a registered appliance, or unverified binding-clearing procedure. Keep the four guest names on their separate host; use a noncolliding namespace for Azure resources.

2. **Mixed-method resource associations:** before either protection group starts, the owner must verify current compatibility and the intended project/provider/appliance/Migrate-managed-vault associations. The execution overview lists both methods but is not shared-vault certification. Do not force one vault, declare the design unsupported, silently create separate projects, fill blank resource IDs, or patch scripts. Any architecture correction is separately approved owner work.

3. **Extra modern appliance:** a separate unreplicated, approved Windows Server 2022 machine, at least **8 CPUs / 16 GB RAM / 80-GB OS disk plus separate 620-GB data disk**, current language/Desktop Experience/prerequisites, licensing, connectivity and budget. The appliance OS must not carry the Hyper-V role. Modern Azure-VM or nested-Hyper-V hosting placement has **not been verified here**; that is not a blanket unsupported-platform claim. The existing **8-vCPU / 64-GB / 512-GB-OS** source host and its 100-GB discovery partition are not spare backing for 620 GB. No host resize, repartition, new host-script storage behavior or appliance reuse is authorized.

4. **Exact source support:** actual Ubuntu release, `uname -r`, architecture and selected/installed Mobility version; guest controller/driver, logical sectors, filesystem/LVM/encryption, root/boot/EFI, firmware/Secure Boot and free space for each source. Host NVMe is not guest NVMe evidence; Generation 2 and Azure VM assessment Ready are not complete compatibility proofs. Resolve source-security/target-security differences with the owner, not by disabling controls. No OS downgrade, guessed fixed kernel or unsupported agent installation is taught.

5. **Privileges and registration:** approved Windows administrator/Linux root credentials for current push, or current supported manual installation with the approved privilege model and machine-specific configuration. Separate discovery, appliance registration, source-agent registration and healthy replication checks. No execution-policy/certificate bypass, broad chmod, firewall disabling, invented installer URL/CLI or secret exposure.

6. **Capacity, network and test peers:** actual per-role target sizes and disks, subscription/policy/region/family quota, real allocation, approved outbound/private management paths, and support for both engines creating uniquely identified peers in the same test VNet. Before any test boot: no peering/routes/source-or-final SQL DNS reachability; explicit source/final egress containment and only approved test peers. Generated test suffixes are not assumed; record job-produced IDs/names/NIC IPs. Stop/disarm copied Windows startup generators, Linux traffic units and local CPU workers on all four test copies; keep IIS/SQL/Tomcat/Nginx running.

7. **Data and single final write boundary:** all sources keep serving, including previously active synthetic orders, during initial/delta replication and nondisruptive tests. Test data is tied to captured committed IDs/lower bounds and recovery-point timing, not equality with a moving live source count. At final cutover only: freeze all manual/synthetic writers, drain work, retain an independent SQL backup and final IDs/count baseline, and manually set **AutomaticStartAction Nothing for exactly the four source VMs before shutdown**. Keep sources from resurrecting after a host reboot; never replay deployment/start helpers against retired sources.

8. **Observed final synchronization and acceptance:** the current physical tutorial offers planned shutdown/on-demand replication; do not invent a power-off-then-agent-upload fallback. Coordinate its SQL/App jobs and the Hyper-V frontend jobs in **one maintenance window**, not an atomic cross-engine job. Require successful final sync and actual source OFF state for all four, then target SQL integrity/final data comparison, all four aliases on all four targets, five dependency edges, SQL readiness, static pages and proxy. No interim hybrid service or user ingress. After read-only go/no-go, submit **one** uniquely marked form-urlencoded order, read it back in API/SQL, and release traffic only after acceptance. API `count` is total orders; the recent `orders` array is capped at 20. Never blindly retry an uncertain POST. Any target write—including that marker—requires reconciliation before a source rollback; never run two writable databases. Retain stopped sources for the agreed rollback period and never delete them on an unverified Complete action.

## Current official source register

Use these official Microsoft Learn references alongside the course. The listed **Last updated** dates were verified as of **2026-10-17**; they do not establish that the course environment has passed a rehearsal. UI wording can drift; record actual equivalent labels without guessing a different operation.

| Topic | Source and verified update | How it is used |
|---|---|---|
| Direct execution | [Execute server migrations](https://learn.microsoft.com/en-us/azure/migrate/execute-server-migrations?view=migrate) — 2026-07-02 | Execute → Migrations → Start execution; Servers/VMs → Azure VM; inventory/assessment/replication-source routes; Preparation/Testing/Completion |
| Hyper-V | [Hyper-V migration tutorial](https://learn.microsoft.com/en-us/azure/migrate/tutorial-migrate-hyper-v?view=migrate) — 2026-10-10 | Host provider/Recovery Services agent; registration, testing, planned migration and separate completion |
| Physical migration | [Physical/virtual machine migration tutorial](https://learn.microsoft.com/en-us/azure/migrate/tutorial-migrate-physical-virtual-machines?view=migrate) — 2026-06-27 | Separate replication appliance, Migrate registration, source-agent/push choices and planned shutdown/on-demand sync |
| Simplified experience | [Simplified Azure Migrate experience](https://learn.microsoft.com/en-us/azure/migrate/simplified-experience-for-azure-migrate?view=migrate) — 2026-07-20 | Classic agent-based appliance retired 2026-09-30; not Classic assessment retirement |
| Appliance requirements | [Modern replication appliance support matrix](https://learn.microsoft.com/en-us/azure/site-recovery/replication-appliance-support-matrix) — 2026-10-15 | Separate appliance OS, minimum resources and capacity review |
| Source OS/storage | [VMware/physical support matrix](https://learn.microsoft.com/en-us/azure/site-recovery/vmware-physical-azure-support-matrix) — 2026-10-15 | Exact running Linux kernel/Mobility tuple, guest-storage/boot/security review through the physical tutorial's referenced architecture |
| Modern deployment | [Deploy the modern replication appliance](https://learn.microsoft.com/en-us/azure/site-recovery/deploy-vmware-azure-replication-appliance-modernized) — 2026-09-21 | Provisioning prerequisites, no cloning; not blanket approval of unverified Azure/nested placement or a replacement for Migrate project registration |
| Replication data path | [Modern physical-server architecture](https://learn.microsoft.com/en-us/azure/site-recovery/physical-server-azure-architecture-modernized) — 2026-09-21 | Changed disk blocks; source → appliance 443 control / 9443 data; appliance → Azure 443; not a 9443 installer/management URL |
| Mobility installation | [Mobility Service overview](https://learn.microsoft.com/en-us/azure/site-recovery/vmware-physical-mobility-service-overview) — 2026-10-15 | Current matching push/manual installers and source-specific registration configuration |
| Optional Waves | [Execute and track waves](https://learn.microsoft.com/en-us/azure/migrate/how-to-execute-track-waves?view=migrate) — 2025-11-07 | Preview overview only; no CSV override or required wave |
| Manual application grouping | [Define and manage applications](https://learn.microsoft.com/en-us/azure/migrate/define-manage-applications?view=migrate) — 2026-06-15 | Manual boundary remains required even when observed dependency visualization is incomplete |

## Acceptance record for a later instructor rehearsal

Record **PASS / FAIL / DEFERRED**, evidence timestamps, actual source/appliance/project/target IDs and approvers for each gate. Never put secrets, credentials, appliance keys or full private configuration in that record. A static documentation check is not a live two-method acceptance result.
