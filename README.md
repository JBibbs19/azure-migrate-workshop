# TD SYNNEX | Azure Migrate Hyper-V Workshop

**Cloud Enablement Services** · Partner hands-on training

> **DRAFT PILOT—NOT LIVE VALIDATED · 2026-10-17.** Start with [START-HERE](START-HERE.md) and [PILOT-README](PILOT-README.md), then follow the manual Modules 0–5. After Module 0 source deployment, retained migration/helper commands are reference material, not alternate student steps: their host-provider workflow does not implement the SQL/App Mobility exercise. Verify resource associations, appliance hosting, exact kernel/storage support, capacity and a full isolated four-VM rehearsal before course delivery.

## Executive Summary

Cloud migration is a business and architecture decision, not just a server-copy exercise. This partner workshop gives Cloud Solution Architects and Infrastructure Engineers hands-on experience discovering, assessing and rehosting a small mixed Windows/Linux application portfolio with Azure Migrate. You will connect infrastructure choices to application dependencies, test the migrated workloads, plan a controlled cutover and review post-migration operations.

[Azure Migrate](https://learn.microsoft.com/en-us/azure/migrate/migrate-services-overview) unifies migration planning and execution: **Decide → Plan → Execute**. This workshop uses **one nested Hyper-V host and four workload VMs** to make that journey accessible without physical datacenter equipment. Deployment prepares the sample workloads; appliance registration, discovery, assessment, migration decisions and validation remain part of the learning experience.

The pilot scope is **four VM rehosts to Azure IaaS**, not automatic PaaS conversion. Web/Linux-Web use the **Hyper-V host provider**; SQL/App are treated **as physical servers**, using a **separate modern replication appliance and guest Mobility Service**. The independent discovery appliance does not replicate either group. Both methods prepare **one connected application**, with source service maintained during initial/delta replication and tests, then **one planned final maintenance window**. Current support and resource-association gates are explicit prerequisites, not claims of live validation.

**Audience:** intermediate-to-advanced infrastructure and cloud practitioners. Prepare the environment before the teaching session and allow time for downloads, discovery, data collection and replication. Duration depends on subscription capacity, connectivity and the environment; this is not a guaranteed four-hour exercise.

## Business Context

### Why Organizations Migrate to Azure

Organizations consider Azure to improve business agility, renew aging infrastructure, strengthen operational controls and create options for later modernization. Each outcome needs evidence:

- **Agility:** compare provisioning and change processes with the business's needs.
- **Cost management:** assess VM sizing, licensing and consumption rather than assuming cloud automatically costs less.
- **Security and governance:** plan identity, network access, monitoring and policy; a VM move alone does not establish compliance.
- **Resilience:** design and test backup, recovery and operating procedures rather than treating migration as disaster recovery.
- **Modernization:** use the discovered application portfolio to identify future platform opportunities after the initial move.

### Common Migration Strategy Options

This workshop practices **rehost**: move the four VMs to Azure IaaS while retaining their application stacks. A future modernization exercise could instead evaluate managed platforms or application changes. Base that decision on business value, dependencies, compatibility and operating requirements; some workloads may be better retained, replaced or retired. These are qualitative options, not a fixed-count strategy framework.

Tomcat-to-App-Service modernization uses [separate tooling](https://learn.microsoft.com/en-us/azure/app-service/app-service-java-migration). Database or other PaaS moves likewise require their own compatibility, support and operational review; they are not outputs promised by this Hyper-V VM lab.

### What This Workshop Simulates

The four VMs stand in for a small business's web, application and database tiers. Their mixed operating systems and real request/data paths let you discuss inventory, dependency groups, validation and cutover sequencing. The applications are deliberately small teaching samples, not production-equivalent implementations. The source is a **single Hyper-V host**, not a cluster, and the workshop does not implement a production Azure landing zone.

## Architecture Overview

### Lab Topology

```mermaid
flowchart LR
  subgraph Source["Source resource group · 10.0.0.0/16"]
    Host["HyperVHost · Windows Server 2022\nStandard_E8s_v7 · 8 vCPU / 64 GiB\n512 GB OS disk: C: guests · E: appliance store"]
    subgraph Nested["intSwitch · host NAT · 192.168.0.0/24"]
      IIS["OnPrem-Web · .10 · IIS"]
      SQL["OnPrem-SQL · .11 · SQL Server 2022 Express"]
      Nginx["OnPrem-Linux-Web · .12 · Nginx"]
      App["OnPrem-Linux-App · .13 · Tomcat 10.1 / OpenJDK 17"]
      Appliance["MigrateAppl · .20\nImported separately in Module 1"]
    end
    Project["Azure Migrate project"]
    Appliance -->|Discover and assess| Host
    Appliance -->|Metadata| Project
  end
  subgraph Destination["Target resource group · reviewed migration region"]
    Test["Isolated test VNet · 10.2.0.0/16"]
    Target["Target VNet · 10.1.0.0/16"]
  end
  Host -->|Host provider replication| Project
  Project --> Test
  Project --> Target
```

### Why Nested Virtualization?

Hyper-V inside an Azure VM gives each participant a self-contained source environment without physical hardware. You can observe host discovery, replication and guest behavior while keeping the portfolio small enough for a workshop. It is a lab adaptation, not proof that its networking, capacity or security reproduces a production datacenter.

The default [Esv7 host](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/memory-optimized/esv7-series) has 8 vCPUs and 64 GiB of memory and supports nested virtualization. It requires a Generation 2 image with NVMe support. Verify the selected SKU, subscription restrictions, regional/family quota and actual capacity before deployment.

### Network and Storage Topology

- The source Azure VNet is `10.0.0.0/16`. The nested `intSwitch` uses `192.168.0.0/24`; the host is `.1`, the four workloads are `.10`–`.13`, and the separately imported appliance uses `.20`.
- Nested guest addresses use DHCP reservations. Host-side NAT provides outbound connectivity for the source lab; it is not an Azure NAT Gateway resource or a production firewall design.
- Migration uses a target VNet (`10.1.0.0/16`) and a separate test VNet (`10.2.0.0/16`). Choose a migration target region different from the source host region, and keep project migration settings, assessments and target/test networks consistent. Verify the required routing, DNS and outbound connectivity; the scripts do **not** create Azure NAT gateways.
- The 512 GB host OS disk holds the guests on `C:` and a separate appliance-store partition, normally `E:`. That partition is not a separate managed data disk. Fixed workload disks are 40 GB per Windows VM and 30 GB per Linux VM.
- Module 1 downloads and imports Microsoft's appliance VHD separately. An instructor can opt into download/extraction during deployment; this does not create or register an appliance VM. Allow at least 30 GB free for download/extraction and check actual import-copy headroom on the reported store drive; free space depends on the current archive and existing contents.

### Workload Portfolio & Real-World Mapping

The portfolio is chosen for **mixed operating systems, distinct business roles and observable application dependencies**, not to assign different migration methods according to service type.

| Lab workload | Actual technology and role | Business analogy and learning purpose |
|---|---|---|
| **OnPrem-Web** · `192.168.0.10` | Windows Server 2022, IIS static site on port 80 | A Windows web-tier entry point. The sample page is not a full .NET application. Optional Windows activity reads SQL data and checks application health, illustrating dependencies beyond a web page. |
| **OnPrem-SQL** · `192.168.0.11` | Windows Server 2022, SQL Server 2022 Express on 1433; `ContosoApp` Customers/Orders | The relational data tier of an order-processing system. Compare real data before/after testing and cutover, plan write quiescence and recovery, and keep database consumers in the migration plan. It uses the same host replication path as the other VMs. |
| **OnPrem-Linux-Web** · `192.168.0.12` | Ubuntu 24.04 LTS, Nginx static site on 80 and desk/API reverse proxy on 8080 | A Linux frontend/reverse-proxy role. Validate the proxy-to-application dependency, addressing and cross-OS connectivity rather than only the port-80 page. |
| **OnPrem-Linux-App** · `192.168.0.13` | Ubuntu 24.04 LTS, Tomcat 10.1 / OpenJDK 17, Jakarta Servlet 6.0 / Pages 3.1; Contoso Order Desk Java/JSP on 3000 | An internal order-entry application tier. JDBC reads/writes real Customers/Orders data in SQL; HTTP through Nginx exercises a multi-tier request. This is a lightweight sample, not a production-scale application. |

Initial deployment installs the application, database prerequisites and Nginx proxy. Optional traffic is **not** an application-install step. The dependency exercise adds Windows SQL reads/HTTP health checks and Linux HTTP requests through Nginx → Tomcat → SQL, including real sample-order writes. Observe those relationships when selecting migration groups and acceptance checks.

## Workshop Learning Path — Cloud Adoption Framework Context

The [Cloud Adoption Framework](https://learn.microsoft.com/azure/cloud-adoption-framework/) provides wider strategy, planning, readiness, governance and operations context. This lab samples those concerns; **discovery and assessment are migration activities, not an additional CAF methodology named “Assess.”** The practical learning sequence below follows discovery, assessment, migration and operations for four VMs.

| Module | Exercise | Learning and completion evidence |
|---|---|---|
| 0 | [Setup](docs/Module-0-Setup.md) | Prepare the source simulation and verify all four workload VMs, applications and appliance-store space. |
| 1 | [Discovery and assessment](docs/Module-1-Discovery.md) | Discover exactly four workloads, review an Azure VM readiness/sizing/cost assessment and discuss dependencies; optionally use [sample traffic](docs/Lab-Traffic.md). |
| 2 | [Web-workload migration](docs/Module-2-Agentless-Migration.md) | Replicate Web/Linux-Web with the Hyper-V provider, test isolated static frontends, then **HOLD final cutover** for Module 3. |
| 3 | [Database/application workload migration](docs/Module-3-Agent-Based-Migration.md) | Use modern physical/Mobility replication for SQL/App, complete the full isolated four-VM test, and coordinate one shared final cutover. |
| 4 | [Azure Migrate vs. Site Recovery](docs/Module-4-ASR-Comparison.md) | Compare a one-time migration with ongoing disaster recovery and explain when each is appropriate. |
| 5 | [Post-migration operations](docs/Module-5-Post-Migration.md) | Verify application/network behavior, monitoring, optional backup/restore, security and cost controls. |
| Finish | [Costs and Cleanup](#costs-and-cleanup) | Account for test VMs, replication, source/target resources, retained backup data and registrations. |

The Module 2/3 filenames are retained, but this **manual pilot deliberately teaches two methods**. Their unchanged automation/script filters are baseline behavior, not a match for the new Mobility instructions. Do not run those helpers to satisfy either pilot method. Stateful data alone does not mandate an agent; the split is a comparison exercise, never two application cutover waves.

### Cloud Adoption Framework Flow

Use the wider business sequence **strategy and planning → environment readiness → migration execution → ongoing operation**, with governance and security throughout. Within the migration exercise, discover and assess first, group dependent workloads, test in isolation, authorize cutover, then validate and optimize. The two workload exercises group practice tasks; production migration waves must follow actual dependencies and business constraints.

## Prerequisites

### Azure Subscription Requirements

- Use an approved training subscription and new, dedicated lab resource groups. Confirm permissions to create the source/target resources and perform the selected project, replication, monitoring and backup tasks. Resource-provider registration and role assignment require their own permissions.
- Verify the resource providers listed in [Module 0](docs/Module-0-Setup.md), subscription policy, Windows/guest licensing, package-source access and budget approval.
- The default source host requires **8 vCPUs**, with sufficient regional and actual SKU-family quota. The four nested VMs and appliance consume host resources, not separate Azure VM allocations.
- Plan target/test quota separately in the migration region. Cost-ordered eligible B2/D2 targets use **2 vCPUs each**: **8 vCPUs** for one full four-VM target **or** test set, or **16 vCPUs** for full target-plus-test overlap; normal test cleanup precedes cutover. Step 1 checks the whole plan against actual regional SKU and family quota metadata, counting existing usage without double-counting it. These workshop sizes are not assessment recommendations.
- Quota is not capacity. A valid region or an advertised SKU does not guarantee allocation, policy approval or access.

### Tooling, Network and Knowledge

| Requirement | Preparation |
|---|---|
| PowerShell and Az | An open Windows PowerShell 5.1 or supported PowerShell 7 deployment session with the required Az modules; host-side commands use Windows PowerShell 5.1. Confirm the module/cmdlet prerequisites in Module 0. |
| Repository | The complete instructor-approved checkout, including application/runtime assets. Git is useful for recording the exact revision; obtain the actual repository URL and branch from the instructor. |
| Host access | An RDP client and outbound TCP 3389 to the host's public IP. Deployment restricts incoming RDP to your supplied public IPv4 address. Bastion/VPN would be separately planned options, not resources provisioned by this lab. |
| Downloads and guest connectivity | Approved access to Microsoft, Canonical/Ubuntu and the other package sources listed in Module 0; outbound connectivity for appliance registration and replication. |
| Background knowledge | Azure VMs/VNets/NSGs, subscriptions and RBAC, Hyper-V administration, Windows/Linux service checks and basic SQL/application dependencies. |

Use lab-only credentials. Keep expanded configuration and logs containing credentials private. Neither the simple sample application's authentication/TLS choices nor the lab's trusted network ranges are a production security baseline.

## Quick Start — Prepare the Source Lab

The deployment script prepares the source simulation; it is not a complete enterprise landing-zone deployment. Follow [Module 0](docs/Module-0-Setup.md) for prerequisites and verification, then [Module 1](docs/Module-1-Discovery.md) for the appliance and project workflow.

### 1. Obtain the Reviewed Checkout

Use the repository URL and branch supplied by your instructor, not a guessed public URL. If using Git, substitute those reviewed values and record the commit:

```bash
git clone --branch <reviewed-ubuntu2404-branch> <workshop-repository-url> azure-migrate-workshop
cd azure-migrate-workshop
git rev-parse HEAD
```

This checkout uses Ubuntu 24.04 LTS and Tomcat 10.1/OpenJDK 17. Extract it separately and build a fresh lab; it is not an in-place upgrade for an Ubuntu 22.04 lab.

### 2. Authenticate and Deploy

Run from the checkout root in PowerShell. Region and resource names below are examples; verify your actual subscription, approved source region, quotas and access first.

```powershell
Connect-AzAccount

# Masked at the prompt so they are not readable over a shared screen
$secureSubscriptionId = Read-Host 'Workshop subscription ID' -AsSecureString
$secureAdminCidr = Read-Host 'Your public IPv4 address' -AsSecureString
$password = Read-Host 'Lab-only administrator password' -AsSecureString

$sourceRg = 'rg-ces-source-01'
$location = 'eastus'

.\scripts\deploy-lab.ps1 -SubscriptionId $secureSubscriptionId `
    -ResourceGroupName $sourceRg -Location $location `
    -AdminUsername 'labadmin' -AdminPassword $password -AdminSourceCidr $secureAdminCidr
```

Supply your actual public IPv4 address when prompted; the script accepts it with or without `/32`. Do not use a shared training password in source files or command history. Appliance download/extraction is optional, default No; students normally obtain it through their project in Module 1. Opting in is for instructor preparation and does not automate appliance import, registration or discovery.

Use a **new dedicated source resource group** for a new lab. A recognized incomplete deployment can resume under its own checks; that is not permission to replay provisioning against a completed or migrated lab. Do not point this Ubuntu 24.04 checkout at an existing 22.04 host or upgrade those guests in place.

### 3. Connect and Begin the Student Exercises

Connect to HyperVHost using the deployment output and complete Module 0's guest/application checks. Create/register the Azure Migrate project and import the verified appliance through Module 1. Confirm exactly the four workload names in discovery, not the appliance as a fifth migration workload.

The required assessment is an **Azure VM assessment of four servers**. The Step 2 helper defaults to `-AssessmentMode Classic`; here “Classic” identifies the grouped assessment API, not a retired first-generation Azure Migrate project. Start with AsOnPremises/configuration-based sizing, the chosen migration target region and your actual offer/licensing settings. Separately compare a performance-based portal assessment after collecting sufficient data. [Assessment estimates depend on collected data](https://learn.microsoft.com/en-us/azure/migrate/review-assessment?view=migrate). [Assessments capture point-in-time inputs](https://learn.microsoft.com/en-us/azure/migrate/concepts-assessment-calculation?view=migrate-classic). For this lab, review the actual readiness, cost and sizing output; do not treat idle-sample measurements as production utilization or script defaults as automatically selected recommendations.

### Student Portal Path and Instructor Helpers

The module guides are the student path. Complete their portal actions and validation rather than treating a helper's final message as the learning objective. Module 2 includes target landing-zone preparation; Step 1 is an optional instructor shortcut for networking and project guidance, not automatic project creation.

Use an open PowerShell window for the interactive migration helpers. They can load their required Az modules, sign in as needed and prompt for omitted environment values. For example:

```powershell
Get-AzContext
.\scripts\migrate-step1-setup-project.ps1
.\scripts\migrate-step2-discover-assess.ps1 -SourceResourceGroup $sourceRg
```

The `migrate-step` scripts use the active Az subscription; verify `Get-AzContext` before running them. Select the actual host, project, source and target groups. Choose and verify the separate migration target region **before** portal Create resources / Finalize discovery locks it; keep the assessment and target/test networks aligned with that choice.

**Target VM sizing:** Steps 1 and 3 offer numbered B2/D2 menus for all four roles, filtered first by the signed-in Azure subscription's live regional eligibility and quota using `Get-AzComputeResourceSku` and `Get-AzVMUsage`. Known OS-specific USD/hour pay-as-you-go compute prices from the official Azure Retail Prices API sort ascending with deterministic ties; unpriced candidates appear separately as **Price unavailable**, with incomplete cost ranking. Rows show the SKU, RAM, actual family, regional/family quota headroom and exact Windows/Linux USD/hour prices when available. Each target has exactly 2 billable vCPUs, with minimum RAM of 4 GiB for Web, 8 GiB for SQL and 2 GiB for each Linux VM. Current B-series v2 and supported D-series v4/v5 candidates must support x64, Generation 2, SCSI and Premium SSD; ARM, 1-GiB, NVMe-only and retired sizes are excluded. Review guest/controller and migration-provider eligibility in the portal. The source `Standard_E8s_v7` host is unaffected. Choose each size explicitly: Enter has no cheapest/default choice, and blank input cancels before writes. Step 1 plans quota and landing-zone preparation only; it does not persist the choice, reserve cores or create target VMs. It prints the reusable map and Step 3 command below with your actual chosen SKUs. After completing Step 2, use Step 3 for prerequisite checks and manual portal guidance:

```powershell
.\scripts\migrate-step1-setup-project.ps1
# Copy Step 1's printed map with your actual chosen SKUs, not these placeholders.
$targetVmSizes = @{
    'OnPrem-Web' = '<chosen SKU>'
    'OnPrem-SQL' = '<chosen SKU>'
    'OnPrem-Linux-Web' = '<chosen SKU>'
    'OnPrem-Linux-App' = '<chosen SKU>'
}
# Complete Step 2 discovery and assessment before enabling replication.
.\scripts\migrate-step3-replicate.ps1 -Workload All -TargetVmSizes $targetVmSizes
```

Both helpers accept optional `-TargetVmSizes`: a hashtable with exactly `OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web` and `OnPrem-Linux-App` mapped to actual selected SKUs. Omitting it opens all four numbered selections; supplying it bypasses only the size prompts, not eligibility, RAM or combined regional/family quota checks. Step 3 revalidates the full map against the current live subscription and actual target VNet region; it never silently changes a previous choice or resizes existing replication. `-Workload Agentless|AgentBased` filters portal workflow only, not the all-four planned quota check. `-ForecastVmSizes` remains a separate, nonbinding quota forecast, not an explicit selection override.

The chosen plan supplies target-sizing guidance for the manual replication wizard, not an automated replication write, source-host change or allocation guarantee. Missing SKU metadata, subscription restrictions or unknown quota do not approve a size. Missing public prices alone do not block an explicit choice with verified eligibility and combined quota, but cost ranking is incomplete and no cheapest claim is valid; no third-party price fallback or static rates are used. Apply your recorded choices in the portal; live prices, eligibility and quota can change, and actual allocation can still fail for lack of capacity.

Step 3 uses explicit-version REST GETs in the current Az subscription, avoiding local `Get-AzResource` API-version-cache lookup; an empty legacy `Servers-Migration-ServerMigration` `vaultId` does not mean no vault exists. Vault provisioning `Succeeded`, provider `CurrentConnection = Connected` and healthy VM replication are separate checks. Without a trustworthy project-service vault reference, select an existing candidate from the `-SourceResourceGroup` scope by default (or `-VaultResourceGroup`), with optional `-VaultResourceId` / `-RecoveryServicesProviderId` for explicit identities. A name match proves no link: association source `StudentSelected` leaves project association `Unknown`, not `AzureVerified`. Review existing jobs/replication first; use manual portal Create resources only if genuinely needed after reviewing complete inspected-scope inventory and the migration-region lock, and register the host provider only if needed. Rerunning only rereads status, without resource creation or replication restart; the safe JSON report uses a unique default path or optional `-ReportPath` and is inventory, not readiness or completion.

**Step 3 checks prerequisites and guides portal replication only.** Its `-Workload All|Agentless|AgentBased` selection and cost-ordered target plan drive read-only checks, probes and instructions; the helper does **not** enable or monitor Hyper-V replication or complete these module sections. `ManualActionRequired` or `Blocked` is not Step 3 completion. Follow the [Hyper-V migration tutorial](https://learn.microsoft.com/en-us/azure/migrate/tutorial-migrate-hyper-v) and the module guides to register the host provider, perform the Replicate wizard actions and monitor replication in the portal. Test migration/cleanup and authorized cutover remain **separate manual portal stages**, including source shutdown at cutover:

| `-Workload` | Selected workloads | Manual portal replication and monitoring | Manual portal test and cleanup | Manual portal cutover |
|---|---|---|---|---|
| `Agentless` | OnPrem-Web, OnPrem-Linux-Web | Module 2 §5–§7; Step 3 supplies partial guidance only | Module 2 §8 | Module 2 §9 |
| `AgentBased` | OnPrem-SQL, OnPrem-Linux-App | Module 3 §8–§9; Step 3 supplies partial guidance only | Module 3 §10 | Module 3 §11 |
| `All` | All four workloads | Both groups' replication sections above | Both groups' test sections above | Both groups' cutover sections above |

Keep the same reviewed workloads, target region and sizes through the portal stages. These are teaching-group filters, not different replication architectures: all four use the Hyper-V host provider, and `AgentBased` does not require guest Mobility Service. **Steps 3, 4 and 5 are prerequisite-check/guidance helpers only for this implemented Hyper-V path.** Step 4 guides manual portal testing/cleanup; Step 5 guides separately authorized manual portal cutover. Their guards prevent the unverified VMwareCbt replication/test/migration calls from executing and do not report fake completion; `ManualActionRequired`/`Blocked` means action is still required. No ASR disaster-recovery workaround is substituted. Run `Get-Help .\scripts\migrate-step3-replicate.ps1 -Full` for the helper's partial coverage and parameters.

| Helper | Scope and operator responsibility |
|---|---|
| `deploy-lab.ps1` | Creates the billable source host, four guest VMs and sample workloads; prepares host discovery settings and the appliance-store partition. Verify the deployed guests in Module 0. |
| `migrate-step1-setup-project.ps1` | Optional target/test network preparation with region/quota preflight and portal project guidance. The student can instead follow the portal path in Module 2. |
| `migrate-step2-discover-assess.ps1` | Assists host/appliance preparation, discovery and four-server assessment. Project-key, appliance and credential actions still require the operator. |
| `migrate-step3-replicate.ps1` | Read-only prerequisite checks and partial manual-portal replication guidance for `-Workload All\|Agentless\|AgentBased`, with live cost-ordered eligible B2/D2 sizing guidance. Does not enable/monitor Hyper-V replication or resize existing replication. |
| `migrate-step4-test-migrate.ps1` | Guarded prerequisite/group checks and manual portal test/cleanup guidance only: Module 2 §8 / Module 3 §10. No automated Hyper-V test migration, cleanup or completed-state claim. |
| `migrate-step5-cutover.ps1` | Guarded prerequisite/group checks and separately authorized manual portal cutover guidance only: Module 2 §9 / Module 3 §11. No automated migration, source shutdown or completed-state claim. |
| `enable-lab-traffic.ps1` | Optional source-side sample activity staged on HyperVHost; follow [Lab Traffic](docs/Lab-Traffic.md). Stop with `-Disable` when no longer needed. |
| `post-migration-labtraffic.ps1` | Optional target-side Check/Prepare/Start/Status/Stop controller; use its [separate guide](docs/post-migration-labtraffic.md) and confirm target identities. |
| `migrate-step6-post-migration.ps1` | Configures post-migration monitoring, backup/security/cost controls; creates or changes Azure resources. Validate before and after its hardening. |
| `cleanup-lab.ps1` | Confirms and deletes one selected resource group, then reports retained/manual cleanup items. Review every deletion scope. |

## Migration Methodology

**Discover → Assess → Plan dependency groups → Replicate → Test → Authorize cutover → Validate and operate**

1. **Discover:** register the appliance, configure valid host/guest credentials and verify the four-server inventory. Host metadata alone is not proof that guest software and dependencies have been inventoried.
2. **Assess:** review Azure readiness, sizing assumptions, data coverage and estimated monthly cost. Document the selected target region and licensing assumptions. Treat idle-lab performance data as limited evidence, not production utilization.
3. **Plan:** identify the Nginx → Tomcat → SQL request path and any Windows reporting consumers. Decide how addressing, application writes, validation and rollback will work across a migration group. The two teaching groups do not prescribe production wave boundaries.
4. **Replicate and test:** enable host-based replication and test copies in an isolated non-production VNet. Isolate copies from source application connections **before first boot**; replicated generators and configuration may otherwise contact or write to the source.
5. **Cut over:** authorize a planned outage, quiesce application activity and shut down the relevant source VMs for the final synchronization. Check replication and validation results before accepting the migrated application. Do not promise zero downtime or automatic success.
6. **Validate and operate:** compare data and endpoints, confirm network dependencies, then review monitoring, backup, access and cost. Rehost is the start of Azure operations, not the end of application ownership.

### Optional Activity and Post-Migration Validation

Optional source traffic provides dependency observations; the Windows side reads SQL/checks HTTP, while Linux requests go through Nginx to Tomcat and can insert real sample orders into SQL. The applications work without starting generators. Source traffic can persist across consoles and reboots, so stop it explicitly when the runbook calls for it.

After cutover, follow [Post-migration lab traffic](docs/post-migration-labtraffic.md): **Check → Prepare → Check → optional Start → Status → Stop** on the confirmed target VMs. Prepare explicitly repoints approved aliases; Start produces real activity. Its default interval is 30 seconds and default duration 60 minutes, bounded and disabled on boot. Check network/application behavior **before Step 6 hardening**, then Check again afterward. For test copies, use the guide's pre-boot isolation and explicit `-TestMigration` workflow; do not substitute source connectivity for target validation.

## Key Architectural Decisions

| Decision | Lab choice and rationale |
|---|---|
| Hyper-V source | One nested host makes host discovery and migration observable without physical hardware. Other source platforms have different replication architectures; do not generalize this lab's host-provider model to every scenario. |
| Memory-optimized host | Standard_E8s_v7 provides 64 GiB for the Windows host, four small workload VMs and the separately imported appliance. Validate support and availability rather than assuming a smaller SKU has enough headroom. |
| Mixed OS and business tiers | IIS, Nginx, Tomcat and SQL expose cross-platform checks, real application/data dependencies and different operational concerns while remaining manageable in a teaching lab. |
| Fixed guest resources | Fixed 40/40/30/30 GB disks and static guest memory make the source allocation understandable. The sample workload's utilization does not predict production sizing. |
| Internal switch and host NAT | An isolated nested segment simplifies the source lab. It is not a statement of production network equivalence or an Azure NAT Gateway deployment. |
| Separate appliance import | Use the verified Microsoft appliance package in Module 1; distinguish appliance discovery/assessment from the host provider's replication work. |
| Test before cutover | Isolated copies let you validate addressing, application paths and SQL data before authorizing source shutdown. Plan for the final outage and recovery decisions. |

## Costs and Cleanup

Estimate the source host, 512 GB OS disk, target/test VMs, replicated disks/storage, public IPs, monitoring ingestion and any enabled backup/DR services using the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/). Separately added Bastion, gateways or other resources add costs; the workshop scripts do not deploy Azure NAT gateways. There is no verified fixed daily price or guaranteed saving.

Set a budget and review consumption during the workshop. Deallocating a VM stops its compute charge but does not remove persistent disks, retained backups or other billable resources, and does not release its quota allocation. Remove unneeded test copies before cutover according to the runbook.

Review the actual source and target resource groups before using the cleanup helper. Set `$targetRg` to the verified group; these commands are destructive and each run confirms one group:

```powershell
Get-AzContext
$targetRg = Read-Host 'Exact target resource group to delete'
.\scripts\cleanup-lab.ps1 -ResourceGroupName $targetRg
.\scripts\cleanup-lab.ps1 -ResourceGroupName $sourceRg
```

The script lists resources and asks for confirmation; `-Force` bypasses that prompt. Do not use it on shared resource groups. Account for Azure Migrate/replication artifacts, Recovery Services vault protection/retained backup data, key-vault soft deletion and the appliance's Microsoft Entra app registration. These can need separate cleanup or live in a different scope; deleting the two selected groups is not proof that every workshop artifact has gone. Confirm the final inventory and remaining charges.

## Repository Structure

```text
azure-migrate-workshop/
├── README.md                              # Student introduction and workload rationale
├── START-HERE.md                          # Student sequence and safety boundaries
├── PILOT-README.md                        # Course plan and execution gates
├── docs/
│   ├── Module-0-Setup.md
│   ├── Module-1-Discovery.md
│   ├── Module-2-Agentless-Migration.md
│   ├── Module-3-Agent-Based-Migration.md
│   ├── Module-4-ASR-Comparison.md
│   ├── Module-5-Post-Migration.md
│   ├── Lab-Traffic.md
│   └── post-migration-labtraffic.md
├── scripts/                               # Deployment and migration helpers
│   └── host/configure-host.ps1             # Host-side provisioning payload
└── apps/contoso-orderdesk/                 # Java/JSP application and runtime assets
```

## Contributing

Send workshop corrections and improvement suggestions through the upstream repository's contribution process. Include the reviewed revision, affected module and clear reproduction/validation evidence, without credentials or private subscription details. Preserve existing attribution notices and update related learner instructions when behavior changes.

## License and Third-Party Software

This supplied checkout has no LICENSE file. Confirm the upstream repository's licensing terms before redistribution and preserve its notices. Azure services, Windows guests, SQL Server and third-party packages have their own licensing/use terms; this README does not grant those rights.

## Additional Resources

| Microsoft Learn reference | Updated |
|---|---|
| [Azure Migrate overview](https://learn.microsoft.com/en-us/azure/migrate/migrate-services-overview) | 2026-05-18 |
| [Hyper-V migration](https://learn.microsoft.com/en-us/azure/migrate/tutorial-migrate-hyper-v) | 2026-10-10 |
| [Azure VM assessment](https://learn.microsoft.com/en-us/azure/migrate/review-assessment?view=migrate) | 2026-08-25 |
| [Classic assessment calculations](https://learn.microsoft.com/en-us/azure/migrate/concepts-assessment-calculation?view=migrate-classic) | 2026-02-26 |
| [Esv7 specifications](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/memory-optimized/esv7-series) | 2026-08-24 |
| [Java migration resources](https://learn.microsoft.com/en-us/azure/app-service/app-service-java-migration) | 2025-12-12 |

For student troubleshooting, use each module's troubleshooting section, the [application diagnostics](apps/contoso-orderdesk/README.md), and the [traffic operator guide](docs/Lab-Traffic.md).
