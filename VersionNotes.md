# Version Notes

**TD SYNNEX | Cloud Enablement Services**

### Release status

**Release status:** rebuilt and statically verified; awaiting a Windows PowerShell 5.1 parser/regression run and full live Azure/Hyper-V/appliance acceptance. Validate the scripts end to end in a training subscription before partner delivery, and record the revision you used.

### Ubuntu 24.04 rebuild — fresh separate lab only

This full 60-file revision is staged as **azure-migrate-workshop-ubuntu2404.zip**,
separate from the earlier Tomcat update. Both Linux guests are Ubuntu **24.04 LTS (Noble)**;
Linux-App uses the Ubuntu **tomcat10** packages (Tomcat **10.1.x**), explicit **OpenJDK 17**,
and Jakarta Servlet **6.0** / Pages **3.1** JSP source. Java SE `javax.sql`/`javax.naming`
and the original database, HTTP routes and resource bounds are retained.

Extract the full archive into a new checkout and deploy a **new dedicated source resource
group/Hyper-V host**, then a reviewed separate target landing zone. Do not run it against
an existing 22.04 lab, upgrade a guest in place, or try to coexist with the same nested VM
names on one host. Provisioning rejects old/unmarked lab state; only an incomplete build
bearing this revision's marker can resume. No live host or old package is changed by delivery.

The source is Canonical's [Noble current QCOW2 image](https://cloud-images.ubuntu.com/noble/current/)
and exact-filename SHA256SUMS, checked even for cached QCOW2 before conversion. `current`
is moving, not a pinned image digest; a publication race requires a matching retry, not a
checksum bypass. Distinct Ubuntu2404 cache filenames prevent reusing the 22.04 base.
The installed running kernel/flavour is resolved with `uname -r`, never a hard-coded 5.15
or 6.8 patch; packages/tools must match before and after any later reviewed kernel update.
This build does not request an unattended distribution/kernel upgrade or use an Azure
kernel VHD as a substitute for the nested generic/virtual cloud image.

Ubuntu 24.04 standard maintenance extends to May 2029 for applicable Main packages;
Tomcat is in Universe, whose security coverage must be reviewed separately (including
Ubuntu Pro/ESM where applicable). Install current approved Noble repository updates and
record actual versions; do not freeze an old base Tomcat patch or assume all packages
share Main's coverage. See [Ubuntu lifecycle](https://ubuntu.com/about/release-cycle) and
[Tomcat 10.1 migration](https://tomcat.apache.org/migration-10.1.html).

### Classic Azure VM assessment — required four-server workshop path

Step 2 defaults to **`-AssessmentMode Classic`** on both maintained branches. The required
module remains discovery, an **Azure VM assessment of exactly four servers**, Hyper-V
replication, test migration and cutover. Classic here means the grouped
`MachineAssessment` assessment API, **not a retired first-generation Azure Migrate project**.
It does not turn the workshop into a PaaS/application-modernization project.

The isolated live Classic test produced an export with **four assessed servers and four
Ready results**. That proves creation/results for that test, not execution of this merged
full script. The restored workflow also incorporates the observed group behavior; merely
changing the default would have left the missing-provisioning/capability failure in place.
A full native checker and end-to-end lab run are still required before partner delivery.

#### Working group preparation and assessment safeguards

- Resolve the existing assessment backend from the selected Migrate project's solution
  reference; verify its actual ARM identity/type and Active/Succeeded state. Do not infer
  its name from the Migrate project name. If no verifiable link exists, list all same-scope
  backends read-only and stop for explicit `-AssessmentProjectName`; never silently select
  one or create a replacement project.
- Retain normalized relevant provider metadata and the endpoint-specific plan: parent
  assessmentProjects LIST/GET **2023-03-15**; machines, groups, grouped Classic assessment
  and results **2024-01-15**; solution GET 2018-09-01-preview; provider GET 2021-04-01.
  Registered namespace and implemented parent version are required. Sparse optional child
  catalog rows warn and still require fixed read-only checks; they are not an alias for a
  different assessment route. No latest-preview guessing or provider/feature registration.
- Map each of the four distinct OffAzure Hyper-V source IDs through inventory
  `discoveryMachineArmId` to the real assessment-namespace machine ID, across every page.
  Do not match by names alone or include the appliance as a fifth workload.
- Create a new group with **only `properties.groupType=Default`**. Capability metadata is
  service-populated, not forced in PUT. A fresh empty Default group can legitimately return
  `supportedAssessmentTypes=[Unknown]`, count zero and no `provisioningState`.
- Shared group readiness accepts missing/null provisioning **only with `groupStatus=Completed`**.
  Created/Updated require explicit Succeeded provisioning; Running/Accepted/HTTP 202 stay
  pending. Returned failed/canceled/deleting, malformed or unknown states are never overridden
  by Completed. Logs show actual status, provisioning presence, capability labels and count.
- Only a fresh, empty, idle group owned by this run receives one `updateMachines` POST
  (`operationType=Add`) containing exactly four validated assessment IDs. After Add, bounded
  reads require exact inventory membership, count four, a ready group and idle state. Unknown
  or explicitly nonmatching capability metadata remains pending after membership; it cannot
  cause premature rejection of an empty group or authorize an assessment. An absent optional
  capability field is reported, not invented; the assessment service response must establish
  the requested contract. Both completion modes use the same group-state helper.
- `GroupNotFound` is expected absence only for HTTP 404 on the actual group GET;
  `AssessmentNotFound` only for HTTP 404 on the matching Classic/Modern assessment GET.
  These codes on a parent, list, wrong resource, write or another HTTP status cannot authorize
  creation. Parent/scope errors, schema failures and RBAC failures stop at their actual stage.
- Existing exact-four groups and matching assessments are reused without membership writes,
  PUT overwrite or recomputation. Existing empty/partial/extra-member groups remain preserved,
  even if an earlier failed attempt created them. This run does not assume prior ownership.
  No DELETE, membership removal, wildcard eTag or atomic-concurrency claim is introduced.

Classic PUT/GET stays under `/assessmentProjects/<backend>/groups/<group>/assessments/<name>`.
Start with **AsOnPremises**, the actual migration target region, applicable offer/currency,
no reserved commitment and no Windows/Linux benefit without confirmed entitlement. The
friendly offer `MS-AZR-0003P` is sent as `MSAZR0003P`. No security/billing/PaaS resources are
created. For the student comparison, use a separate performance-based portal assessment
only after sufficient data collection; idle-lab NoData/confidence gaps are not installer failures.

Acceptance or a successful creation PUT is not completed computation. Classic handoff
requires **`status=Completed` on nonpending assessment GETs**. The assessment's optional
`provisioningState` may be absent, null or blank; when populated it must be Succeeded.
Provisioning/Updating/Accepted remain pending; failed, canceled, deleting, unknown and
nonstring metadata block handoff. The same helper checks initial and final GETs. Exactly
four fully paginated unique source-linked results, verified identity/settings, an idle
group, exact membership, stable source mappings and an unchanged update timestamp remain
mandatory. This corrects the earlier mandatory-Succeeded assessment-field assumption.
Step 6 reports failures immediately; Step 7 polls automatically only after accepted/matching
work. Only transient GETs receive a bounded retry, never writes; pagination stays pinned to
cloud/subscription/resource group/collection/API. Az owns tokens through pinned-context
`Invoke-AzRestMethod -DefaultProfile`; no token unwrapping or credential/header dump.

#### Continue a running lab without redeploying it

Refresh the complete checkout **of the same OS/Tomcat branch**, keep the host, four guests,
appliance and discovery, and rerun Step 2 with the **existing exact-four group and matching
Classic assessment names and settings**. This completion-field correction needs neither a
new assessment nor redeployment. Do not rerun deployment or upgrade the running guests.
Set the variables below to the existing verified resource names:

```powershell
.\scripts\migrate-step2-discover-assess.ps1 -SourceResourceGroup $sourceRg `
    -MigrateProjectName $projectName -Location $migrationTargetRegion `
    -AssessmentMode Classic -AssessmentGroupName $existingGroupName `
    -AssessmentName $existingAssessmentName
```

Reuse remains read-only for matching groups/assessments; identity, settings, membership and
result checks still apply. Only a separately inspected empty/conflicting group requires
explicit conflict resolution and deliberately chosen unused names. Reconnect only for an authentication rejection,
not to repair missing resources, RBAC or schema errors. See
[Module 1 recovery](docs/Module-1-Discovery.md#51--instructor-step-2-api-errors-and-recovery).

#### Modern API and advanced architecture exploration are deferred

`-AssessmentMode Modern` remains **explicit experimental opt-in**, not the core module or
a successful live integration claim. Its retained 2024-03-03-preview top-level profile still
requires its own provider advertisement, does not select an unimplemented 2025 version,
and retains source-linked result checks and ManualReview instead of automatic replication.
The isolated Modern request was rejected with HTTP 400 `MalformedRequestBody`; no Modern
assessment was created by that test. More API information is needed before curriculum use.
**Neither mode silently falls back to the other.** Optional portal application/PaaS comparisons
and a student's advanced architecture inquiry do not trigger app/SQL/container/PaaS code
changes, new assessment automation or changes to Steps 3–6.

### Current runtime and complete checkout

Initial deployment includes Tomcat 10.1/OpenJDK 17, the original named WAR, protected JNDI
credentials, SQL mixed mode/shared restricted login, lab aliases and Nginx desk/API proxy.
No manual app install, extra password prompt or traffic command is needed by students.
SQL-independent health precedes SQL setup; final success requires actual SQL readiness/data,
named UI and proxy readiness. Discovery credentials still need appliance-side validation.
The `AgentBased` filter remains the historical Module 3 workload-group name, not proof
of a Mobility Service migration path or a waiver of guest discovery permissions. All four
VMs use the Hyper-V host provider. Step 3 checks prerequisites and supplies **partial portal
guidance only** for `-Workload All|Agentless|AgentBased`; it does not enable or monitor
Hyper-V replication or complete the module. `ManualActionRequired`/`Blocked` is not
completion. Perform provider registration, replication wizard actions and monitoring in the
portal, then separately test/clean up and authorize cutover there. Steps 4/5 are also
retained as guarded prerequisite/group checks and manual portal guidance only; their guards
prevent the unverified VMwareCbt calls from executing in this implemented Hyper-V path.
None of Steps 3–5 automatically completes these stages or reports a fake completed state.
No ASR disaster-recovery write path is substituted.

Existing vault provisioning (`Succeeded`), provider `CurrentConnection = Connected` and healthy
VM replication are separate checks. Step 3 uses explicit-version REST GETs in the current Az
subscription, not the local `Get-AzResource` API-version cache; an empty legacy project
`vaultId` does not prove absence. Selecting an existing vault without a trustworthy service
link records association source `StudentSelected` with state `Unknown`, not `AzureVerified`;
name matching is not proof. Optional existing-vault/provider selectors and `-ReportPath` are
listed by `Get-Help .\scripts\migrate-step3-replicate.ps1 -Full`; reruns only reread status,
never create resources or restart replication.

Target sizing uses explicit numbered selection of live subscription-eligible B2/D2
candidates in Steps 1 and 3, known prices ascending and unpriced choices separately marked
**Price unavailable**. Optional `-TargetVmSizes` supplies the exact four-name SKU map
instead of size prompts, not instead of live eligibility, RAM or combined quota checks.
The source `Standard_E8s_v7` host is unchanged. Each target has 2 billable vCPUs; minimum RAM
is 4 GiB for Web, 8 GiB for SQL and 2 GiB for each Linux VM. The plan is not persisted or
assessment-derived. Apply your chosen sizes manually in the portal wizard; Step 1 plans
quota and landing-zone preparation only, and Step 3 remains read-only manual guidance,
not an automated replication write or an existing-replication resize. No profile flag,
allocation guarantee or direct-VM fallback retry is provided. See the
[README directions](README.md#student-portal-path-and-instructor-helpers).

The checkout contains all app source, WAR/runtime binary assets and rebuild/tests under
[apps/contoso-orderdesk](apps/contoso-orderdesk/README.md). A new checkout has no workspace
or output-folder dependency. Read the pinned JDBC/local-checksum prerequisite options there.
**Learner Windows deployment and migration need no Python on the learner/instructor machine.**
Region, project, workload-readiness and traffic controls are already inline PowerShell.
The recent offline regressions and full-checkout packager are now consolidated into the
existing checker; the three recent Python test files and root `build.py` are removed.
Earlier Linux guest helpers (including runtime extraction and HTTP traffic) still use Python
inside the Linux guests. The older optional maintainer integration/app tests and app rebuild
helper also retain Python; converting those would change the workload/platform, not simplify
Windows deployment.

From the checkout root in **Windows PowerShell 5.1**:

```powershell
.\scripts\check-lab-scripts.ps1                       # Parse only; no file writes.
.\scripts\check-lab-scripts.ps1 -RunRegressionChecks  # Offline; no Azure/VM actions.
.\scripts\check-lab-scripts.ps1 -PackagePath '..\azure-migrate-workshop-ubuntu2404.zip'
```

Packaging automatically requires parser/regression success, verifies the existing
`runtime.sha256`, refreshes `SHA256SUMS` and verifies ZIP CRC/per-file SHA256. It uses built-in
.NET, does not rebuild app assets, and requires an existing destination folder **outside the
checkout**. Use `-OverwritePackage` explicitly to replace that chosen ZIP; no implicit
packaging/writes occur by default. `-UpdateChecksums` refreshes only the manifest after checks.
The **176 defined check groups** include seven target-profile source/AST/helper cases,
the 11 Classic-completion regressions and retained communication, assessment/context, backend/provider, Modern, discovery,
Step 6/controller and lexical contracts. These are not live Azure/traffic tests. The native
checker, its PowerShell fixtures and native packager were **not executed in this environment**. Optional older maintainer checks remain
`python3 -B tests/integration_checks.py` and
`python3 -B apps/contoso-orderdesk/tests/static_checks.py`.
No Java/SQL/appliance test is claimed by the static validation report. Optional 3001 staging
is scoped to a reviewed older application on an **already-24.04** guest only; it is neither
an OS upgrade nor a path to update the existing 22.04 lab. New deployment needs no staging.

### Guest communication readiness (configure-host and Step 2)

VM power, app health and an **Enabled** integration service do not prove guest-to-host
communication. New deployment now requires all four guests' live Hyper-V KVP CIM component
(`Msvm_KvpExchangeComponent`) to be enabled, have numeric primary `OperationalStatus = 2`
and supply nonblank recognized-family `OSName`/`OSVersion`. LostCommunication (13), NoContact
(12), incompatible protocol (7), degraded (3), missing/unknown status or failed CIM reads
block completion. An unimplemented/null inherited `CommunicationStatus` is allowed; a known
bad value is not. Localized status text and HealthState are not readiness gates.

Linux provisioning installs **both running-kernel** `linux-tools-$(uname -r)` and
`linux-cloud-tools-$(uname -r)`, checks the exact executable and enables KVP. It intentionally
keeps KVP stopped until cloud-init's scheduled reboot. Critical installation failures are
recorded and KVP is masked so later runcmd items/reboot cannot hide them; no `-virtual`
fallback or kernel/OS upgrade is attempted. Joint application/KVP readiness retries for at
most 20 minutes, requires three consecutive observations, and is checked again immediately
before the completion marker. The existing host-preparation JSON gains numeric KVP/OS rows.

Step 2 separately probes the **selected Azure host** before prerequisites success, project
key, download/import or discovery/assessment. Complete, unique marked JSON and all four
expected VM identities are required; errors/unknowns stop rather than enter the WinRM repair
prompt. The probe is read-only and requires no Linux password from the learner. Updating this
package does **not** repair an already deployed guest; follow [Module 1 section 2](docs/Module-1-Discovery.md#2-prepare-the-hyper-v-host), then rerun Step 2. Do not rerun provisioning on a completed host.

For release acceptance, verify `/etc/os-release` reports 24.04 on both Linux guests and
that fresh appliance inventory shows their OS metadata plus Tomcat 10.1/Java 17 and a
visible Contoso Order Desk Java web asset. Local HTTP success cannot waive this check.
Do not promise that changing the OS or Servlet namespace fixes an appliance classifier
or compressed-WAR/custom-CATALINA_BASE discovery issue; that remains unproven.

These checks prove host-observed KVP transport and available OS metadata, **not** direct
post-reboot `systemctl` status, appliance-side OS classification or fresh software/web
inventory. Appliance credentials, SSH permissions and discovery remain separate checks.
This completion-field correction adds no delivered files; the current checkout contains
**60 files** after removal of the two sequencing wrappers.

### Workload power and optional traffic handoff

Instructor Steps 1 and 2 verify the selected Azure host and exactly four nested workloads
are Running through read-only Azure Run Command. Missing/off/saved/paused/unknown states
stop progress with manual host-side repair instructions; no nested VM is automatically
started. Running proves power state only, not app health. Step 1 rechecks before verified
project guidance, then offers optional background sample-order traffic **after WHAT TO DO
NEXT**, default No. An absent/unverified project receives no offer.

`-LabTraffic Skip` makes no generator changes. Fully supplied Step 1 environment inputs
also skip the traffic prompt by default; `-LabTraffic Prompt` explicitly requests the safe
`[y/N]` prompt, and `-LabTraffic Start` explicitly opts in. An optional
`-LabTrafficPassword` accepts a SecureString; otherwise the deployment password is prompted
privately after opt-in. Supported workstation launches use protected managed Run Command;
verified elevated on-host launches run the staged script interactively. Unsupported remote
prerequisites cause a clear not-initiated message and host-interactive fallback. Traffic
persists across consoles/reboots: lab completion does **not** stop it. Stop on the host with
`C:\AzMigrateLab\enable-lab-traffic.ps1 -Disable`, or stop/remove VMs during teardown.
See [traffic prerequisites and results](docs/Lab-Traffic.md). After cutover, use the
[native post-migration traffic controller](docs/post-migration-labtraffic.md) to inventory
inherited jobs, safely repoint aliases and run bounded traffic before Step 6; Check again
after hardening. Test copies require pre-boot source isolation and explicit `-TestMigration`.

### Separate source and migration regions: quota preflight

Step 1 now asks for a **migration target region different from the actual source Hyper-V
host region**, with no inherited source default. It validates names/display names against
`Get-AzLocation`. The host's actual VM region, project data geography and resource-group
metadata location are three different settings. Resource-group metadata does not bind child
resource regions; existing VNet/NSG regions do, and conflicts stop before provider/resource
writes. Networks cannot be moved: use a fresh landing zone if necessary.

Example only, **not** a promise of subscription access, SKU availability or capacity:

```powershell
$sourceRg = 'rg-ces-source-01' # Existing deployed source group.
$sourceRegion = 'eastus'       # Example only; the actual host region is read, not assumed.
$migrationTargetRegion = 'westus2'
$targetRg = 'rg-ces-target-01'
$projectName = 'ces-migrate-01'
.\scripts\migrate-step1-setup-project.ps1 -SourceResourceGroup $sourceRg `
    -TargetResourceGroup $targetRg -Location $migrationTargetRegion -MigrateProjectName $projectName
.\scripts\migrate-step2-discover-assess.ps1 -SourceResourceGroup $sourceRg `
    -TargetResourceGroup $targetRg -Location $migrationTargetRegion -MigrateProjectName $projectName
# Only after Step 2 completes; prerequisite checks/manual portal guidance only.
.\scripts\migrate-step3-replicate.ps1 -SourceResourceGroup $sourceRg `
    -TargetResourceGroup $targetRg -Location $migrationTargetRegion -MigrateProjectName $projectName `
    -Workload All
```

Step 1 needs `Az.Compute` as well as Accounts/Resources/Network. Its **read-only subscription
quota heads-up** shows a UTC timestamp, masked current subscription and both regions' actual
reported Total Regional vCPUs, relevant VM-family quotas and regional VM-count usage/limits/
remaining. Usage includes resources outside the workshop and VM scale sets. Both regional
and family vCPU quota must fit. Allocated and deallocated VMs count; deallocation is not a
quota-release strategy. The nested four workloads and `MigrateAppl` are not separate Azure
VMs: only their Azure Hyper-V host consumes source Azure VM quota, already included in usage.

Steps 1 and 3 filter current subscription-eligible regional B2/D2 candidates before
showing a numbered menu for each of the four roles. Known OS-specific USD/hour pay-as-you-go
compute prices from the official Azure Retail Prices API sort ascending with deterministic
ties; unpriced candidates appear separately as **Price unavailable**, with incomplete cost
ranking. Rows show SKU, RAM, actual family, regional/family quota headroom and exact
Windows/Linux USD/hour prices when available. Direct `Get-AzComputeResourceSku` metadata and
`Get-AzVMUsage` reads must confirm eligibility and quota. Each size requires exactly 2 billable
vCPUs, x64, Generation 2, SCSI and PremiumIO, plus minimum RAM of 4 GiB for Web, 8 GiB
for SQL and 2 GiB for each Linux VM. Candidates are current B-series v2 or supported D-series v4/v5,
subject to controller compatibility; ARM, 1-GiB, NVMe-only and retired sizes are
excluded. Guest drivers and migration-provider eligibility still require portal review.
One complete target **or** test set totals **8 vCPUs**; hypothetical full-target-plus-full-test
overlap totals **16 vCPUs** for eight new Azure VMs. The plan must fit aggregate quota for
all four workloads in each actual SKU family as well as the regional limit; metadata supplies
the vCPU totals and family keys, not a hard-coded family or one-workload quota check.

Step 1's selection is planning only: it is not persisted, does not reserve cores or create
target VMs. Enter never accepts a cheapest/default size; blank input cancels before writes.
Both helpers accept optional `-TargetVmSizes`, a hashtable with exactly `OnPrem-Web`,
`OnPrem-SQL`, `OnPrem-Linux-Web` and `OnPrem-Linux-App` mapped to actual chosen SKUs.
Omitting it opens all four numbered selections; supplying it bypasses only size prompts,
not live eligibility, RAM or combined quota checks. Step 1 prints the reusable
`$targetVmSizes` map and `migrate-step3-replicate.ps1 -Workload All -TargetVmSizes $targetVmSizes`
handoff. Step 3 revalidates the full map against the current subscription and actual target
VNet region, never silently changing a prior choice. Its `-Workload` pair filters portal
workflow only; the planned map still protects all-four aggregate quota. No named target
profile is required. Step 3 remains read-only and returns `ManualActionRequired` or `Blocked`;
apply chosen sizes manually in the portal replication wizard. Existing replication is not
resized and no direct VM-size fallback retry writes occur. Normally clean up portal test
copies before authorized portal cutover; replication disks do not reserve VM cores.
Existing target VMs are already in reported usage; do not add them again. Explicit
`-ForecastVmSizes` remains a separate nonbinding quota-only custom list, not an override
of selected sizes or a sizing change to Step 3 or the portal.

Missing public prices alone allow an explicit choice only with verified eligibility, RAM
and combined quota; label **Price unavailable**, report incomplete cost ranking and make no
cheapest claim. No third-party price fallback or static rates are used. Missing rows/SKU
metadata, unregistered Compute or denied/failed quota reads remain **Unknown** or **Blocked**,
not approved, never zero or assumed free capacity. Insufficiency, Unknown or applicable SKU
restrictions in the target planning baseline trigger `[1] Choose another target region` (recommended),
`[2] Continue NETWORK-ONLY despite warnings`,
or `[3] Cancel`. With supplied `-Location`, warnings stop before writes unless explicitly
acknowledged by `-AllowQuotaWarning`; that switch permits only step 1 networking and is **not**
an Azure quota bypass, VM allocation approval or region-conflict override. Fully supplied
source/target/project/location values avoid step 1's entry/pause questions; supply
`-HyperVHostVMName` too if source VM selection is ambiguous. Region validity alone does not
prove quota, policy, zone/SKU eligibility or physical capacity.

**Choose and verify the migration target before portal Create resources / Finalize discovery
locks that project's migration target.** All subsequent migrations/test networks must match.
The preflight does not verify that project/recovery lock; inspect existing resources in the
portal. It neither creates nor remaps the Azure Migrate project or its data geography.
Step 2's assessment uses the chosen target, not source metadata; without optional
`-TargetResourceGroup` it explicitly asks for the assessment target region. Steps 3–6 derive
location from the actual target VNet and reject an explicitly conflicting `-Location` before
writes; step 4 also checks an existing test VNet. Keep the same verified region across
replication, test migration and cutover.
See [VM quotas](https://learn.microsoft.com/en-us/azure/virtual-machines/quotas).

### A note from the author

These notes record environment issues met while building and running this lab, and why parts of the scripts look the way they do. They are observations from one subscription and one region, not a compatibility matrix.

**The host size default changed from `Standard_E8s_v5` to `Standard_E8s_v7`.** The v5 size was not available to the subscription this lab was built in. Esv7 offers the same 8 vCPU / 64 GB shape and reports nested virtualization support, so it became the default. `deploy-lab.ps1` validates whatever size you pass against your own subscription's SKU metadata and quota, so a different family works if it meets the lab's floor.

**Esv7 is a Generation 2 only series, and its sizes require an OS image with NVMe support.** The workshop's Windows Server 2022 Gen2 host image satisfies both. If you change the host image, check those two properties first.

**Deployment pins the image catalog API version and forces Standard security on the temporary guest disk.** Both are deliberate. Letting the installed Az.Compute module pick its own API version produced inconsistent results across machines, and the disk cmdlets will otherwise default a Trusted Launch image lookup that is incompatible with exporting the disk to nested Hyper-V guests.

**The Azure Migrate appliance VHD Microsoft publishes for Hyper-V is Generation 1.** Module 1 creates the appliance VM with `-Generation 1` for that reason. Confirm the current generation and disk format in Microsoft's article before you run it — a Generation 2 VM will not boot a Generation 1 VHD, and the failure looks like a corrupt download.

**The lab stages the appliance on the host's own OS disk.** An earlier revision attached a separate managed data disk for this. It was removed because the 512 GB OS disk already has the capacity and a data disk bills continuously, including while the VM is deallocated.

No attempt has been made to solve for environments beyond the one this was built in. If you hit a different compatibility problem — a region without the host size, a policy that blocks disk export, a proxy that blocks a package source — please open an issue with the error and your region and subscription type. Feedback of that kind is what turns one environment's findings into guidance that holds up more broadly.

### Maintenance and provenance

Parse every script with PowerShell before sharing changes, and confirm the documentation links resolve. The host-side scripts target Windows PowerShell 5.1; the deployment client works on either 5.1 or PowerShell 7.

Preserve upstream license/attribution notices when merging this reviewed source into the workshop repository. This supplied baseline does not include a LICENSE file; do not infer Microsoft-derived attribution or silently manufacture licensing metadata.

### Retained console-launch history

In an open window it also clears any leftover `Write-Host` / `Write-Warning` override left
behind by a `migrate-step` script run earlier in that session. Those scripts install console
overrides to mask subscription IDs, and a leftover one used to make `deploy-lab.ps1` fail on a
`Write-Host` line.

## Log of Changes

<strong style="color: red;">Not to be included in final distribution.</strong>

### Existing vault and provider checks; manual Hyper-V handoff retained (2026-10-15)

Step 3 now reads existing vault provisioning and provider `CurrentConnection` through typed,
explicit-version REST GETs in the current Az subscription, avoiding the local
`GetAzResourceApiVersionCache` lookup issue. An empty legacy `Servers-Migration-ServerMigration`
`vaultId` is not `NoVault`; vault provisioning `Succeeded`, provider `Connected` and healthy
replication remain separate observations.

Without a trustworthy project-service vault reference, the student may select an existing
candidate in the `-SourceResourceGroup` scope by default or optional `-VaultResourceGroup`;
`-VaultResourceId` and `-RecoveryServicesProviderId` identify existing resources explicitly.
Association source `StudentSelected` leaves project-association state `Unknown`; only service
evidence supports `AzureVerified`, never a similar name. Inventory existing jobs/replication
before manual actions to avoid duplicate writes. First-time portal Create resources requires
actual need and complete inspected-scope inventory, not a global absence claim or
authorization; review the migration-region lock first and register the host provider only
when needed.

Reruns only reread status: no resource creation/recreation, replication restart or migration
writes. Runtime JSON uses a unique default path or optional `-ReportPath` and allowlisted
inventory/status fields, not raw API bodies/errors or readiness/completion claims; starting a
job does not prove replication health. Native PowerShell and live end-to-end validation were not run for this
update. Observed vault and provider GETs verified one environment only, not general
acceptance.

### Numbered VM-size menu and direct subscription choice (2026-10-15)

Steps 1 and 3 now require an explicit choice from numbered, live subscription-filtered
B2/D2 candidates for all four roles, rather than automatically choosing the cheapest.
Known official OS-specific USD/hour PAYG prices sort ascending with deterministic ties;
unpriced choices are separate **Price unavailable** entries with incomplete cost ranking.
Missing public prices alone do not block a choice with verified eligibility, RAM and
combined regional/family quota; unknown eligibility or quota is never approval. No static
rates, third-party price fallback or allocation/capacity guarantee is introduced.

Optional `-TargetVmSizes` maps exactly `OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web` and
`OnPrem-Linux-App` to chosen SKUs on both helpers; it skips size prompts, not validation.
Blank menu input cancels before writes. Step 1 prints `$targetVmSizes` and the Step 3
`-Workload All -TargetVmSizes $targetVmSizes` handoff without a state file or new helper.
Step 3 revalidates the full plan in the actual target VNet region and current subscription;
workload-pair filters affect portal workflow, not combined application quota. No previous
choice is silently changed, existing replication is not resized and the source host is
unchanged. `-ForecastVmSizes` remains a separate nonbinding quota forecast. Student changes
are limited to choosing and recording eligible portal sizes; Module 0 formatting remains
unchanged. The preceding active directions supersede the earlier price-availability barrier;
prior dated entries below are retained unchanged.

### Cost-ordered regional B2/D2 target sizing (2026-10-15)

Replaced fixed target defaults and the named all-four fallback with live OS-specific
USD/hour PAYG cost ordering of subscription-eligible regional B2/D2 candidates. All four
targets require 2 vCPUs; minimum RAM is 4 GiB for Web, 8 GiB for SQL and 2 GiB per Linux VM.
Actual SKU metadata and aggregate family/regional quota constrain the plan; missing prices,
metadata or quota do not establish a cheapest eligible size. Portal guest/controller and
migration-provider review remains required, with no capacity guarantee.

Step 1 plans quota and landing-zone preparation only; Step 3 remains read-only manual
portal guidance with `ManualActionRequired`/`Blocked`, not replication, allocation or resize.
Removed the active target-profile flag/examples; earlier dated profile and 6/12-vCPU entries
below remain historical and are superseded by this entry. The source host, guarded Steps 4/5
and 60-file checkout are unchanged. Student edits are limited to sizing actions; no Module 0
formatting revision or outside verification is included.

### Module 0 learner edits and separate replication/test/cutover workflow (2026-10-14)

Merged all three edits from the user-edited OneDrive Ubuntu Module 0: removed the opening
revision/runtime/KVP development notes, added the East US → West US 2 regional example,
and allowed a qualified replacement source host. East US is an example, not a deployment
default; the instructor selects the source region, and the target remains subject to access,
policy, SKU restrictions, quota and capacity. Alternative hosts need at least 8 enabled
vCPUs, 64 GiB RAM, documented nested virtualization and compatible x64 Generation 2/Premium
SSD support; Esv7 additionally requires an NVMe-capable image. D2asV5 is not a source-host
replacement. Applied equivalent regional/host guidance to the Tomcat 9 branch; its learner
introduction was already clean. Each branch retains its own OS, Tomcat and Java versions;
Ubuntu fresh-build, runtime and KVP safeguards remain in the current notes and module checks.

Retired Step 3a/3b wrapper commands and options from the live README, current notes and
module guidance. Step 3 now supplies prerequisite checks, selected-workload/target-profile
probes and **partial guided portal handoff only**, not automatic Hyper-V replication
creation or monitoring. `ManualActionRequired`/`Blocked` must not report Step 3 complete.
`Agentless` selects Web/Linux-Web and guides Module 2 §5–§7; `AgentBased` selects
SQL/Linux-App and guides Module 3 §8–§9; `All` selects both groups for that same limited
purpose. Provider registration, Replicate wizard actions and replication monitoring remain
manual in the portal. Test migration/cleanup is a separate portal stage at Module 2 §8 /
Module 3 §10; authorized cutover, including source shutdown, is another at Module 2 §9 /
Module 3 §11. Steps 4/5 remain as prerequisite/group checks and manual portal handoff
only, with dominating guards preventing the unverified VMwareCbt test/migration calls from
executing in this Hyper-V path. These guards add no automated testing, cleanup, migration or
source shutdown and report ManualActionRequired/Blocked rather than fake completion. All
four VMs retain the host-provider architecture; AgentBased is only a historical group name.

The reviewed published Az.Migrate 2.10.0 New/Get server-replication surface uses the
VMwareCbt object model; that New implementation explicitly rejects Hyper-V sources.
Its use here was a contract mismatch. The current 3.x process body was not fully retrieved;
this is the verified contract boundary of our implemented path, not a claim that all
Hyper-V automation is universally unsupported. No native write contract is verified here. The Get
precheck's unguarded `vaultId` → `ResourceName` binding is a **likely** mechanism for the
reported empty-string error, not a confirmed missing property or root cause without the
actual stack. Record stage, module version and nonempty resource identities diagnostically;
do not claim a native automatic fix. The [Hyper-V migration tutorial](https://learn.microsoft.com/en-us/azure/migrate/tutorial-migrate-hyper-v),
updated 2026-10-10, documents the portal route. An ASR disaster-recovery enable path against
a Migrate-created vault is not verified and is not substituted for this migration workflow.

Retained default BSeries and explicit D2asV5 profiles, with `-TargetVmProfile` only on Step 1
planning and Step 3 prerequisite/wizard guidance, never Steps 4/5. Select reviewed sizes
manually in the portal; there is no automated replication write, existing-replication resize
or allocation guarantee. This supersedes wrapper-forwarding/automatic-replication directions
in the earlier D2as v5 entry below without rewriting it or other historical dated/numbered
bodies; their wrapper mentions are historical, not active options. The Classic safeguards
and three-primary-section Version Notes layout are unchanged. No native PowerShell or full
live Azure/Hyper-V replication, test or cutover acceptance is claimed by this documentation.

### Explicit D2as v5 target profile; B-series default retained (2026-10-14)

Added explicit `-TargetVmProfile BSeries|D2asV5` to Steps 1, 3, 3a and 3b on both
OS/Tomcat branches. BSeries retains B2s/B2ms/B1ms/B1ms; D2asV5 requests
`Standard_D2as_v5` for the same four workloads, not an extra VM or a source-host change.
Step 1 forecasts the selected plan using actual regional SKU vCPU/family metadata and
reports the full target/test overlap. The choice is not saved, a reservation or target-VM
creation; repeat it explicitly for new replication in Step 3. Existing replication is not
resized. Wrappers forward the profile only to Step 3; their Step 4/5 behavior, including
cutover/source shutdown, is retained. No silent fallback, capacity promise or automatic
assessment sizing is introduced.

Executable edits are confined to those four existing scripts. The fifth code file is the
existing checker, with seven new target-profile AST/source/helper cases per branch and all
prior registrations retained. No new helper/test file or Python test-source edit is added.
README/current notes document the option; release report, rename-aware manifest current
hashes and root checksums are refreshed while original/historical provenance is preserved.
Deployment/configure-host, source Standard_E8s_v7, Step 2, Steps 4–6, modules, traffic,
application assets/runtime and nested app CHANGES remain unchanged. The package still has
62 files. Full retained offline test results and frozen-code hashes are recorded in the
release report; native PowerShell/AST/fixtures and live Azure/Hyper-V allocation or complete
replication compatibility are not validated here. No runtime is installed or Azure action
performed for this release.

### Documentation-only README and Version Notes reorganization (2026-10-13)

Renamed the root `CHANGES.md` to `VersionNotes.md` and restored the student-facing
README introduction, business context, architecture/workload rationale, learning path,
prerequisites, quick start, migration methodology, architectural decisions, cost/cleanup,
repository structure and resource links. Moved the retained runtime, assessment,
communication, traffic, region/quota and maintainer notes here. Historical dated entries
and numbered troubleshooting sections are retained with their original dates and bodies;
only heading depth and section placement changed. Release integration updates exactly
four script comment/help filename references, the existing checker's moved-document
source contract and the Python manifest test's rename-aware path/inventory checks.
The original baseline hashes and historical provenance are retained with an explicit
root rename mapping; current hashes, release-validation metadata and root checksums
are refreshed. No executable deployment/migration behavior, workload or runtime changes.
Offline release verification is recorded in the static validation report (2026-10-14);
native PowerShell and full live lab acceptance remain outstanding.

#### Reference check for the student introduction

The supplied **Azure Migrate L300 Deck.PPTX** (slides 3–11 and 30–31) and
**Azure Migrate L300 FINAL.pptx** (slides 8, 9, 13, 16, 56, 57 and 60) informed the
central-hub, discovery/assessment, mixed-workload and Hyper-V host-replication explanation.
Their template appliance prerequisites and downtime language were not copied as current
support requirements. Sample workload analogies describe learning intent, not production
parity or verified PaaS suitability.

The following official Microsoft Learn articles had displayed update dates within
2025-10-13 through 2026-10-13 when checked for this edit. These dates establish source
recency, not successful execution of the workshop:

- [Azure Migrate overview](https://learn.microsoft.com/en-us/azure/migrate/migrate-services-overview) — updated 2026-05-18.
- [Hyper-V migration](https://learn.microsoft.com/en-us/azure/migrate/tutorial-migrate-hyper-v) — updated 2026-10-10.
- [Azure VM assessment](https://learn.microsoft.com/en-us/azure/migrate/review-assessment?view=migrate) — updated 2026-08-25.
- [Classic assessment calculations](https://learn.microsoft.com/en-us/azure/migrate/concepts-assessment-calculation?view=migrate-classic) — updated 2026-02-26.
- [Esv7 specifications](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/memory-optimized/esv7-series) — updated 2026-08-24.
- [Java migration resources](https://learn.microsoft.com/en-us/azure/app-service/app-service-java-migration) — updated 2025-12-12.

Article references are limited to concise product-level support, without quotations or
copied summaries. The lab implementation and workload explanations come from the supplied
workshop material and scripts. The classic-view reference does not establish automatic
Hyper-V PaaS assessment or migration compatibility.

The README's general Cloud Adoption Framework link is background context, not an
in-window article-update claim. No fixed-count “6 Rs” definition is asserted. Internal
switch/NAT and workload details describe the supplied implementation rather than a
Microsoft production-topology certification. Existing dated entries below describe their
own revisions, test counts and superseded decisions; they are not current acceptance claims.

### Changes from the supplied workshop

**TD SYNNEX | Cloud Enablement Services**

The first section records the Ubuntu 24.04 revision. **All earlier sections are historical
baseline notes**, including Tomcat 9/22.04, Node/traffic and older virtual-tools fallback
instructions. Those runtime/repair descriptions are superseded, not directions for this build.
The earlier comparison used the supplied original and Pull 12 revision; this integration uses
only the published baseline and does not import Pull 12 modules.

This is the complete branch-ready source, not a changes-only overlay. See
`tests/baseline-manifest.json` for exact changed/unchanged/omitted baseline files and
`SHA256SUMS` for current per-file integrity.

| File | State |
|---|---|
| `scripts/deploy-lab.ps1` | Modified |
| `scripts/common.ps1` | **Deleted** — inlined into `deploy-lab.ps1` |
| `scripts/migrate-common.ps1` | **Deleted** — was never loaded by anything |
| `scripts/check-lab-scripts.ps1` | **New** |
| `scripts/health.ps1` | Modified |
| `scripts/enable-lab-traffic.ps1` | **New** |
| `scripts/host/configure-host.ps1` | Modified |
| `docs/Module-0-Setup.md` | Rewritten |
| `docs/Module-1-Discovery.md` | Rewritten |
| `docs/Lab-Traffic.md` | **New** |
| `README.md` | Modified |

---

### Current: Classic assessment completion with optional provisioning metadata (2026-10-13)

Exactly **8 existing files changed, 0 added/deleted, 62 files per package**: Step 2,
the existing checker, README, Module 1, this log, static report, baseline manifest and
root SHA256SUMS. All **54 other files** remain byte-identical to the post-traffic release.
Runtime changes are restricted to new `Get-LabClassicAssessmentState` and its use in
`Get-LabAssessmentCompletion`; Modern, the shared response adapter, Step 3 options,
Steps 4-6, deployment, traffic and application/runtime assets are unchanged.

Classic requires nonpending GET computation `status=Completed`. Its optional
`provisioningState` may be absent, null or blank; a populated value must be Succeeded.
Provisioning/Updating/Accepted remain pending; failed/canceled/deleting/unknown and
nonstring values fail closed. The same helper gates initial and final reads. A successful
creation PUT alone never authorizes replication. Exact four source-linked results,
identity/settings, idle group, exact membership, mapping stability and unchanged update
timestamp remain mandatory. Matching existing group/assessment names and settings are
reused without overwrite/recomputation; apply the same branch and rerun Step 2, not deployment.
This supersedes earlier mandatory-Succeeded Classic assessment wording, not group rules.

Eleven checker groups were added; one retained Classic expectation was corrected.
**166 Tomcat / 169 Ubuntu groups are DEFINED, SOURCE-INSPECTED, NOT EXECUTED** here.
Normal retained suites passed **14 app + 16 integration per branch = 60 distinct tests**,
zero skips/errors/failures. Seventy-five literal source contracts per branch passed;
these are source inspection, not native PowerShell AST or mocked-runtime execution.
Original 24-file provenance and historical previous hashes are preserved. No new helper
is shipped, dependencies installed, Azure/Git actions taken or existing output overwritten.
Final deterministic staged archive/integrity evidence and native/live limits are recorded
in `STATIC-VALIDATION-REPORT.md`; publication is a separate delivery-owner action.

---

### Earlier: post-migration traffic and exact NSG application edges (2026-10-13)

Exactly two new files: `scripts/post-migration-labtraffic.ps1` and
`docs/post-migration-labtraffic.md`; eight existing-file updates (Step 6, existing native
checker, README, Module 5 Section 4 and four release-integrity metadata files), no deletion,
62 files per maintained package. Application/runtime, deployment, existing traffic,
Steps 1-5 and standalone assessment diagnostics are unchanged.

The separate Windows PowerShell 5.1+/Az managed Run Command controller explicitly selects
and confirms every target VM and subscription/resource-group scope; an omitted resource
group is prompted for, never inferred. Default Check/Status are guest-read-only, with
console-only summaries including validation failures (Run Command still needs execution/
write RBAC). Every mode first inventories inherited generators; Prepare/Start explicitly
pause/repoint only approved aliases, restart Tomcat/reload Nginx and validate the exact
five guest-to-guest application edges. Start adds bounded traffic using the installed
DynamicUser Linux generator without replacing its ExecStart/sandbox; lifetime-only
RuntimeMaxSec/Restart=no overrides, a stop-only guest deadline handler and disabled-on-boot
controls enforce expiry. Stop remains best-effort on confirmed unavailable guests.
Optional VerifySampleOrder explicitly authorizes one real order; no network/agent repair,
private-DNS creation or central collector is added. Detailed Linux insert logs remain local.

Step 6 preserves the five dependencies with verified dynamic peer/destination /32 rules,
keeps deny priority 4000 and prior public HTTP policy, fails closed for ambiguous/missing
identities or addresses, rejects shared/subnet NSGs and preserves unrelated rules with
collision guards. Module 5 Section 4 documents the same five edges and manual NSG sequence.
Seven offline checker groups were added: **155 Tomcat / 158 Ubuntu defined, not executed**
without PowerShell. See `STATIC-VALIDATION-REPORT.md` for actual offline verification and
explicit native/live-runtime limits; no live deployment/migration success is claimed.

---

### Current: explicit Hyper-V discovery in Step 3 (2026-10-08)

Matched minimal fix in both maintained branches: the existing
`Get-AzMigrateDiscoveredServer` call in `migrate-step3-replicate.ps1` now passes
`-SourceMachineType 'HyperV'`, as Step 2 already does. A comment explains this lab's
Hyper-V source inventory. This addresses the unspecified-inventory/VMware discovery
failure; it does **not** establish compatibility of subsequent replication commands or
prove end-to-end replication. No parameter was added to the different
`Get-AzMigrateServerReplication` or `New-AzMigrateServerReplication` cmdlets.

One native offline AST/contract case checks every Step 3 discovered-server call for an
explicit literal HyperV value, requires a positive call count, and checks the unchanged
3a/3b routes and workload filters. Existing Step 2 summary/runtime coverage is retained.
Native groups are **148 Tomcat / 151 Ubuntu, DEFINED, NOT EXECUTED**. The retained
14 app + 16 integration tests per branch ran: **60 passed across both**.

Exactly **6 existing files changed per branch, 0 added/deleted, 60 files per package;
54 unrelated files byte-identical**. Only Step 3, the existing checker, CHANGES, the static
report, baseline manifest and root SHA256SUMS changed. Step 2's Classic default, Modern
opt-in, standalone diagnostic, runtime/VM configurations, regional guards, disks/licenses/
network, replication commands and wrappers are unchanged. ZIPs and clean expanded trees
were CRC/SHA256/readback verified. No PowerShell/native mocks, Azure or live VM actions
were executed; no redeployment is required to replace this script in a running lab.

All earlier entries below describe their own revisions and validation limits.

### Earlier: restore the original Classic Azure VM module (2026-10-08)

Both maintained labs now default to **AssessmentMode Classic**, the grouped Azure VM
MachineAssessment 2024-01-15 path. Classic does not mean a retired first-generation Migrate
project. Modern remains explicit experimental opt-in, deferred pending more API information;
there is no silent fallback in either direction. The student PaaS/advanced architecture
inquiry does not change apps/SQL/containers or Steps 3–6. Begin the required four-server
exercise with AsOnPremises, then optionally compare a performance-based portal assessment
after sufficient collection; missing idle-lab performance data is not an installer failure.

This is more than a default flag: ported the live-observed minimal Default-only group PUT,
Completed groups with absent/null optional provisioning, fresh empty Unknown capabilities,
and resource-specific GroupNotFound/AssessmentNotFound 404 GET classification. Do not demand
MachineAssessment capability before owned-group Add. After Add, bounded reads verify exact
four assessment IDs/membership/count, idle state and requested capability; missing optional
capability is logged, not fabricated. Returned failed/canceled/deleting/malformed/unknown
states remain blockers. Both completion modes share the same group helper. The Classic
assessment's own Succeeded/Completed/four unique paginated source-result checks are retained.

Existing empty/partial/extra groups are preserved even after earlier failed attempts; no
prior ownership is guessed. Inspect and choose explicit unused names or verified exact-four
matching resources. No remove/DELETE/overwrite, registration, blind write retry or scope/
version change. Catalog normalization, backend mapping, pinned context and pagination remain.

Exactly **8 existing files modified, 0 added/deleted, 60 files per package; 52 unrelated files
byte-identical**. Distinct runtimes and app/WAR/source/SQL, KVP/network/power/traffic, quotas,
appliance and other steps are untouched. Both full ZIPs/clean expanded trees are refreshed;
legacy output, standalone diagnostic and instructor Word guide are unchanged.
Executed: **60 retained app/integration tests across both**, private static inspection and
deterministic ZIP/CRC/SHA256/readback. Native groups: **150 DEFINED, NOT EXECUTED**
(138 retained + 12 Classic-restoration); existing Modern coverage is explicit.
No PowerShell, Java/SQL, Azure sign-in/API or live VM execution is claimed after the merge.
The supplied isolated Classic export proves four assessed/four Ready for that test, not a
full-script run; the isolated Modern request was rejected and created no assessment.

Earlier entries below are historical. Their Modern-default and stricter group provisioning/
capability assumptions are superseded here; recorded tests/counts describe their revisions.

### Earlier: focused assessment provider-catalog normalization (2026-10-07)

Both maintained branches retain default Modern and their distinct runtimes. Step 2 now
normalizes only relevant exact resource types, merges harmless duplicate rows/version
strings and feeds that same catalog into profile selection. Unused catalog rows cannot
reject an assessment. Bounded unknown/non-date metadata tokens are never a license to
select an unimplemented version: parent 2023-03-15 and Modern 2024-03-03-preview remain
required, with no 2025 payload reuse, newest-version choice or automatic Classic fallback.
Namespace/Registered and array-shape guards remain. Required malformed fields stop with
safe canonical resource-type/field/index diagnostics, never raw values. Malformed optional
rows warn/are ignored; fixed documented read-only endpoint checks still gate their writes.
No API paths, payloads, group/server mapping, readiness/status/completion/context or retry
behavior changed. The previous generic catalog error does not reveal its exact offending
row/token; this is a bounded false-negative repair, not proof of that trigger or live success.

Exactly 8 existing files changed per branch; 0 added/deleted; 60 files each and 52 unrelated
files byte-identical against captured SHA256 inventories. Host/guests/runtime/WAR/source/SQL,
appliance/regions/KVP/traffic and all other steps are untouched. The legacy workshop is
untouched. Both complete ZIPs and matching expanded folders are refreshed, not overlaid.
Executed: 14 retained app + 16 integration checks per branch (60 tests across both), private
lexical/source-contract inspection and deterministic ZIP/CRC/all-entry SHA256/readback.
Native groups: **138 DEFINED, NOT EXECUTED** in this branch (8 added; the old blanket
malformed/duplicate rejection fixture is replaced by required-field rejection). No PowerShell
AST/native execution, Azure calls/sign-in, install, Git, Java/SQL or Office document changes.
Modern ServerGroupId service acceptance, actual result linkages and ManualReview for IaaS
remain live-unknown/unchanged; this fix cannot guarantee the remaining workflow succeeds.

Earlier entries below are historical revision evidence. Their blanket malformed/duplicate
catalog rejection policy and prior native group counts are superseded here; their recorded
executions and preservation results describe those earlier revisions, not this one.

### Earlier: Ubuntu 24.04-only Modern server assessment profile (2026-10-07)

Step 2 adds `-AssessmentMode Modern|Classic`, default **Modern on this branch only**.
The inline reviewed profile catalog intersects actual provider metadata with the documented
MachineAssessmentV2 **2024-03-03-preview** top-level assessment contract. Advertised 2025
preview contracts are skipped/logged as unverified, not chosen by date. Missing Modern
availability/metadata errors stop before group writes. Classic remains deliberate opt-in;
Modern errors never trigger Classic fallback or feature/provider registration.

Shared hardened exact-four server-group preparation is factored once. Modern assessment
GET/PUT and fully paginated assessedMachines GET omit the groups path segment and use only
the verified preview version. Modern writes contain nested scope/settings, ServerGroupId,
nested savingsSettings and integer scaling/discount; no readonly details, flat reserved
instance/offer, dynamic ARG query or unknown enum substitution. Existing scope/settings/
membership conflicts are preserved, as are pending/busy/invalid/stale resources.

Modern polling uses details.status and distinguishes acceptance/creation/completion. It
never requires provisioningState absent from the public GET example; an optional returned
state is checked. Results require four unique top-level resource identities/types and
linkages.armId mapping exactly one known source/assessment machine each. Unknown linkage
shapes stop as SourceUnverified without calling creation failed or redoing PUT. Actual
nested recommendation/readiness/SKU/cost details are shown without summing alternatives,
inventing monthly units or assuming classic flat fields. Completed source-verified results
require **ManualReview**, not automatic Step 3 guidance: this profile has no verified Azure
VM target/strategy selector. Step 3's planning sizes/quotas remain unchanged.

This is **modern server assessment**, not full mixed application-assessment automation.
Module 1 adds the separate optional portal exercise using actual assets/dependencies. Full
application creation, composite/wave/PaaS/SQL/web automation and the unverified 2025 schema
remain deferred. Classic ServerGroupId acceptance by the Modern service and live linkage
semantics still require an authorized live lab test; catalog advertisement is not proof.

Exactly 8 existing Ubuntu files changed; 0 added/deleted; 52 unrelated files byte-identical.
Ubuntu 24.04/Tomcat 10.1/Java 17, SQL, four guests, ports/network, KVP/traffic, quotas and
appliance remain unchanged. The entire older Tomcat source/archive/tree is byte-identical.
Executed: 14 retained app + 16 integration checks (30), private lexical/source-contract
checks and deterministic 60-file ZIP/CRC/SHA256/readback. Native fixture groups: **130
DEFINED, NOT EXECUTED** (108 retained + 22 Modern). No PowerShell AST/native tests, live
Azure/Hyper-V, Java/SQL, package installation, OS upgrade, Git or Office guide edits.

### Earlier: provider metadata and parent API repair (2026-10-07)

The preceding revision wrongly required 2024-01-15 on the parent assessmentProjects
resource and treated every omitted nested provider row as unsupported. The actual
catalog supplied for this failure advertises parent 2023-03-15, not parent 2024-01-15.
Parent LIST/GET now use verified-advertised 2023-03-15; classic machine/group/assessment/
results operations retain documented 2024-01-15. Missing nested entries warn and permit
fixed read-only endpoint validation; explicit child-version omissions are not converted
to previews. Actual namespace/Registered state remains mandatory. Malformed/duplicate
metadata or unadvertised chosen parent versions stop before writes. Top-level
assessmentProjects/assessments is a different contract, never an alias for grouped
classic assessments. API rejection and parent/scope 404 stop without child writes or
blind retry. Pagination explicitly preserves its initial version.

Backend identity/Active/Succeeded, exact four-source-ID inventory mapping and resource
preflight reads still gate writes. All ownership/reuse/settings/completion/context and
immediate failure safeguards remain. No broad modern-API rewrite or VM/app changes.
Exactly 8 existing files changed per branch, 52 untouched byte-for-byte, 60 files each;
60 retained Python static/integration tests executed across both. Native groups defined
105 Tomcat / 108 Ubuntu (8 additional metadata groups each), **not executed**. No live
Azure read/write or successful assessment creation is claimed. ZIP/tree checksum readback
is verified; preserve the lab and rerun Step 2 using its real backend, not deployment.

### Earlier: actual assessment backend and stable machine/group APIs (2026-10-07)

The parent-version/nested-catalog support claims below are superseded by the current repair.

The focused correction supersedes the authentication-only patch: resolve and verify the
selected Migrate project's real classic assessment backend rather than guessing its name;
list actual candidates and require an explicit existing backend if association is missing.
Provider API support, exact four-machine source mapping, group create plus updateMachines
Add, normalized pricing wire enums and exact membership are now checked. Existing groups/
assessments are preserved/reused instead of overwritten; name options handle reviewed
conflicts. Stable 2024-01-15 classic MachineAssessment is not new logical-application preview
coverage, and published 2023-03-15 is not blamed for resource 404.

Step 6 reports operation failures immediately. Step 7 has no continuation pause and only
polls accepted/matching work. Completed status, succeeded provisioning, all pages/exactly
four verified source-matched results and final unchanged settings/membership gate replication
guidance; created/running/stale/partial states cannot claim ready. Earlier pinned-context,
SecureString-safe Az authentication and secret-safe/no-blind-write-retry behavior remain.

Exactly 8 existing files change; no new/deleted delivered files, still 60 per branch.
All unrelated bytes and distinct OS/Tomcat/Jakarta runtimes are preserved. 60 retained
app/integration tests execute across both branches. Native groups now define 97 Tomcat /
100 Ubuntu, **not executed here** (22 new backend groups each). No live Azure actions,
PowerShell/Java execution, installs, app rebuild, Git or Office guide edits. See the current
static report for evidence, remaining native/live acceptance and authoritative API references
in Module 1. Update the same full branch and rerun Step 2, not deployment/rebuild.

### Earlier: context-authenticated assessment requests and honest completion (2026-10-07)

Both maintained branches receive the same focused Step 2 fix. `Invoke-AzRestMethod` owns
ARM authentication/refresh via the pinned validated Az context and current-cloud endpoint;
all manual `Get-AzAccessToken`/Authorization code is removed. Az 14 / Az.Accounts 5's
SecureString token change explains a real compatibility defect in that old code, but the
reported user's installed version/root cause has not been established live.

Group failure/pending prevents assessment PUT; HTTP status/error JSON is checked even
without a thrown exception. Auth/RBAC/context/prerequisite/schema/project failures are
reported by stage with safe messages, without tokens/headers/raw exception dumps. Reads do
not hide authentication as computation; only accepted requests are polled, with at most one
transient/unverified GET retry and no blind PUT retry. Accepted/202 creation, confirmed
resource existence and pending/ready results are separate. Unverified/failed states cannot
print completion or direct replication. Four distinct workload IDs and existing HyperV
inventory selection are retained; API version, project-name and machines schema are not
silently remapped and still need live verification.

Existing running labs use the matching fixed checkout and rerun Step 2 only, after reviewing
any existing group/assessment. No deploy/rebuild/OS upgrade or guest modification is needed.
Only Step 2, the existing native checker, README/Module 1/this log/report, baseline manifest
and root checksums change: **8 files, no added/deleted deliverables, 60 total**. All host,
app/WAR/runtime, network/quota/KVP/appliance guards and other runtime scripts are byte-identical
to each branch's immediate preceding revision. Historical original archive digests are retained.

The checker adds **18 assessment groups** with strict local ARM/context mocks and source
contracts. Current totals: **75 Tomcat 9 / 78 Ubuntu 24.04**, defined **not executed** here.
The retained 30 tests per branch (14 app + 16 integration), private lexical/source inspection
and deterministic CRC/SHA archive/expanded-tree verification pass. No new learner Python
or shipped helper files. Native PowerShell 5.1/parser/groups/.NET packaging and live Azure
assessment creation remain unexecuted; authentication repair does not certify service success.

References: [Az 14 migration](https://learn.microsoft.com/en-us/powershell/azure/migrate-az-14.0.0),
[context-backed ARM requests](https://learn.microsoft.com/en-us/powershell/azure/manage-azure-resources-invoke-azrestmethod).

### Earlier: separate Ubuntu 24.04 / Tomcat 10.1 rebuild (2026-10-07)

Full separate 60-file checkout/ZIP, not an overlay. Both Linux guests use Noble's exact-name
SHA256-checked moving current QCOW2, distinct Ubuntu2404 cache names, the same fixed disks,
memory/CPU, guest names/IPs and nested topology. Fresh-host build-marker refusal prevents
adopting/rebuilding an old or unmarked lab; incomplete same-revision resumes remain possible.
The earlier deployed lab and all earlier packages are unchanged. No live OS upgrade occurs.

Linux-App uses current repository `tomcat10`/common/lib packages, checks 10.1.x and pins
OpenJDK 17 via JAVA_HOME. JSP Servlet signatures and the descriptor migrate to Jakarta
Servlet 6.0 / Pages 3.1; Java SE javax.sql/javax.naming remain unchanged. WAR/runtime and
all checksums are rebuilt. The custom controlled ROOT.war deployment, non-root service,
private 0640 JNDI, bounded JDBC pool/JVM, endpoints, original SQL schema/seeds/login and
Nginx proxy/optional traffic contracts are retained. Same-OS legacy app scripts now require
24.04; they do not upgrade or roll back Ubuntu/Tomcat cross-version environments.

Exact-kernel KVP install/binary/mask/stop-until-reboot safeguards, joint/final acceptance,
Step 2 selected-host strict read-only gate and explicit HyperV discovery are preserved.
Region/VNet/quota 6-vCPU baseline/12-overlap, project footer/traffic default No and appliance
exact-ZIP/copy-import/no-expansion safeguards remain. Step 6 is write-enabled, not read-only.
Associated Markdown guides are revised without editing the earlier Word guide. Module 3's
Mobility discussion is explicitly separate/optional; no invented Noble Mobility installer
or extra workshop appliance is prescribed. Current distro/kernel/package versions must be
verified at target; standard Main lifetime is not blanket Universe Tomcat coverage.

Three native Ubuntu/Jakarta/fresh-host contract groups extend the 57 retained groups to
60 **defined, not executed**. Retained Python/bash checks and archive/source provenance
are rerun; see the current static reports for measured results and unexecuted live gates.
Release requires Windows PowerShell 5.1/native groups and fresh Azure/Hyper-V/appliance
Ubuntu OS + Tomcat/Java software + visible Java web-asset acceptance. Local health checks
are not proof of discovery and the rebuild makes no claim to solve prior classifier issues.

### Earlier: require guest communication, not just health (2026-10-07)

Focused changes in existing `scripts/host/configure-host.ps1` and
`scripts/migrate-step2-discover-assess.ps1`: identical inline read-only KVP/CIM and safe XML
helpers now enforce enabled numeric normal communication plus recognizable OS name/version
for exactly four guests. Lost/no contact, degraded/incompatible protocol, unknown/missing
status, missing guests, read failures and malformed/duplicate OS metadata fail closed.
Inherited CommunicationStatus can be null/unimplemented; HealthState/Enabled alone cannot
pass. Only OSName/OSVersion are exported, not arbitrary KVP items or guest secrets.

Provisioning now installs/checks both exact-running-kernel tools packages, with no silent
virtual-flavour fallback. A critical failure logs an actionable marker and masks KVP; success
keeps the enabled daemon stopped until the existing scheduled reboot. Bounded joint
application/communication polling and a final fresh recheck prevent incomplete setup from
emitting LAB_WORKLOADS_READY/setup-complete. Existing host-preparation JSON records KVP rows.
Step 2 performs its separate read-only, strict four-row Run Command gate before prerequisite
success or appliance/project-key/discovery work, without guest credentials or automatic repair.
This does not guarantee appliance classifier/software/web discovery success.

The existing checker adds 14 offline communication groups (**57 defined**, not executed here).
README, Module 1, this log/report, baseline hashes and SHA256SUMS are updated. No new delivered
files (**60 total**); application/WAR/runtime, SQL seed, deployment, Step 1 and Steps 3–6 remain
byte-for-byte unchanged. The preceding explicit HyperV discovery fix is retained. No OS/kernel
upgrade, installs, Git operations or legacy-package changes were made. The final 30 retained
app/integration tests and scratch-only composition/lexical/archive checks pass; native
PowerShell 5.1 and live Azure/Hyper-V/appliance acceptance still need target validation.

Reference: [Msvm_KvpExchangeComponent status and guest intrinsic items](https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/msvm-kvpexchangecomponent).

### Earlier: merge the supplied Step 2 discovery fix (2026-10-06)

Merged the latest edited Step 2's explicit `-SourceMachineType 'HyperV'` into the current
branch, rather than replacing it with the older script/package. The discovery poll now
selects this Hyper-V lab's inventory explicitly; this is not a VMware platform conversion.
The current Linux-App summary already says Tomcat 9 and is retained. Target-region/VNet
checks, all-four-workload power gates, strict appliance ZIP/extraction hashes and exported
configuration copy-import without resizing remain intact. Other runtime scripts/assets are
unchanged.

The existing `scripts/check-lab-scripts.ps1` gains one AST/source-contract regression:
every actual discovered-server command must supply literal HyperV, and the final summary
must retain Tomcat 9. There are now **43 offline groups** (the original 42 plus discovery),
with no new shipped files. Changed files: Step 2, checker, README, CHANGES, static report,
`tests/baseline-manifest.json` and `SHA256SUMS`. The complete ZIP/expanded tree remains
**60 files**. Refresh the full package for matching checker/manifest/checksums; a standalone
Step 2 write-back is not a whole-folder upgrade. All 30 retained app/integration checks and
scratch-only lexical/source/archive checks passed; native PowerShell and live discovery
remain unexecuted here.

Reference: [Get-AzMigrateDiscoveredServer, Hyper-V example](https://learn.microsoft.com/en-us/powershell/module/az.migrate/get-azmigratediscoveredserver?view=azps-16.3.0).

### Earlier: consolidate recent maintenance tooling into PowerShell (2026-10-06)

The existing `scripts/check-lab-scripts.ps1` now owns the 12 regional, 5 project-guidance
and 25 workload-readiness/traffic check groups through `-RunRegressionChecks`, with no Pester
or Python dependency. Known helper definitions are extracted by AST into an isolated child
scope with synthetic inputs and local read mocks; no complete migration script is executed.
Ordering, traffic and credential protections remain explicitly labeled source contracts.
The checker now returns a nonzero status on failures. Default parsing remains read-only.

Optional `-PackagePath` runs validation first, verifies the checked-in runtime hash, creates
fresh full-checkout SHA256SUMS and a sorted/fixed-timestamp ZIP using built-in .NET, then
verifies CRC and SHA256 readback. An external destination is mandatory; replacement requires
`-OverwritePackage`. `-UpdateChecksums` refreshes only checksums after checks. App assets are
not rebuilt. Removed: root `build.py`, `tests/regional_quota_checks.py`,
`tests/step1_guidance_checks.py`, `tests/workload_readiness_checks.py`; no replacement files
are added. The full checkout drops from 64 to **60 files**.

Deployment, host configuration, traffic launcher and migration scripts are unchanged by
this cleanup. Learner Windows deployment/migration needs no local Python; earlier Linux
runtime helpers and optional older maintainer integration/app tests still use Python.
The original 72 static checks passed before consolidation; the retained 30 checks and
archive integrity checks passed afterward. Native PowerShell checks/packaging and live
Azure/Hyper-V execution remain untested here. The legacy workshop-update is untouched.

### Earlier: workload power gates and final traffic opt-in (2026-10-06)

Steps 1 and 2 now independently read the resolved Azure Hyper-V host's actual power code
and exactly four nested workload states through Azure Run Command. Small marked JSON/end
payloads require successful status records, no stderr, a complete unique payload and all four
expected rows. Missing, Off, Saved, Paused, unknown/unreadable and malformed outcomes stop
progress. Each state is reported with manual host-side Start-VM/Resume-VM repair guidance;
missing guests require deployment restoration. Neither the Azure host nor nested workloads
are automatically started by these gates. MigrateAppl is separate; Running is power state,
not an application-health assertion. Step 1 rechecks before final verified-project guidance;
Step 2 gates before module/appliance/download/registration/assessment work.

After WHAT TO DO NEXT, Step 1's final optional action warns about ongoing background sample
order creation and asks the requested immediate-continuation question with safe `[y/N]`.
No/Enter/unrecognized input changes no generators. No offer is shown for absent/unverified
projects or unready/unverifiable guests. `-LabTraffic Prompt|Start|Skip` is explicit; supplied
environment inputs default to no new prompt/start. `-LabTrafficPassword` optionally accepts
SecureString input; otherwise Yes/Start privately prompts for the deployment password.

An elevated local invocation must match Azure instance metadata to the selected VM ID/name,
RG and subscription. Workstation execution uses the reviewed protected managed Run Command
pattern with unique names and the host's actual location. No password is embedded in source
or ordinary parameters; transient plaintext/protected values are cleared. Capability/settings/
SSH checks happen first. The traffic script's small NonInteractive extension requires supplied
credentials/settings, installed OpenSSH 8.4+ and working noninteractive Linux password/sudo
access on both Linux guests before generator writes. Older/missing capabilities explicitly
fall back to the elevated host-interactive command, never a remote Read-Host/SSH hang or
Windows-only success. Existing hosts need the refreshed staged script; deployment code is
unchanged and already stages the checkout's script.

Full success requires Windows task Running, Linux generator/proxy markers, managed execution
Succeeded, exit 0 and the exact launcher success marker. Partial/failure and uncertain/timeouts
are reported without pretending generators were rolled back or never ran. Only terminal own
managed resources are removed. Generators persist across consoles/reboots: **lab/script
completion does not stop them**. Explicitly disable traffic or stop/remove VMs during teardown.
No timer/completion detector is added. Deployment, app code, stages 3–6 and the legacy package
are unchanged. Updated reusable notes and 25 new Python fixture/lexical checks complement the
retained project-guidance regressions; no PowerShell or Azure execution is claimed.

### Earlier: Step 1 project-dependent completion guidance (2026-10-06)

When the requested Azure Migrate project is absent, Step 1 finishes on the portal project
creation instructions, followed by a command to rerun Step 1 with the same resource groups,
project, host and target region. It does not display WHAT TO DO NEXT or direct the learner to
Step 2. The landing zone remains prepared, but the summary does not label Step 1 complete.
Only a successful project lookup enables the existing Step 2 guidance. Read failures are
reported as unverified, not as proof of absence, and instruct portal/access verification
before a retry rather than creating a duplicate. No deployment, quota or migration behavior
is changed. Five lexical regressions cover these output branches; no live lookup is claimed.

### Current: separate migration target region and quota heads-up (2026-10-06)

Step 1 no longer inherits the source resource-group region. The learner explicitly chooses a
subscription-listed target region different from the **actual source host VM** region, with
name/display-name normalization. Existing target VNet/NSG conflicts stop before provider
registration or resource writes; RG metadata alone is not a conflict. Project data geography
is independent: the old target-to-project-region map is removed, existing projects are unchanged,
and project creation stays in the portal. A prominent warning requires choosing the migration
target before portal Create resources / Finalize discovery locks it; lock detection is not claimed.

Read-only, timestamped quota reporting uses the same signed-in masked subscription, live
`Get-AzVMUsage` and SKU `vCPUs`/family metadata in source and target. Total Regional vCPU,
relevant family and VM-count limits are independent checks. All reported usage is retained,
including other resources/VM scale sets and allocated/deallocated VMs. Nested workloads and
appliance do not consume separate Azure VM quota; the source host is not added twice.
Planning defaults match step 3 (6 vCPUs/four new VMs); 12 vCPUs/eight new VMs is the optional
full-target-plus-full-test overlap, not an automatic requirement or reserved replication capacity.
Missing/denied/unregistered reads and incomplete SKU/family metadata are **Unknown**, not zero.
Interactive warnings offer reselect/network-only/cancel; supplied locations need explicit
`-AllowQuotaWarning` to proceed with networking despite warnings. No quota bypass is provided.
`-ForecastVmSizes` is an explicit planning list, not a change to migration sizing.

Step 2 assesses the selected target, optionally deriving it from the existing target VNet.
Steps 3–6 use actual target VNet location rather than RG metadata; test VNet reuse is checked.
Wrappers 3a/3b no longer prefill location from RG metadata, but otherwise retain their behavior.
Helpers remain self-contained; no common.ps1 dependency, app/JDBC change, or Pull 12 import.
Twelve new Python reference-fixture/lexical regression checks supplement all 30 prior checks;
they are not PowerShell AST execution, live quota evidence or Azure allocation tests.

### Current: Tomcat initial deployment (2026-10-05)

| Area | Implemented behavior |
|---|---|
| Linux-App | Original Contoso Order Desk WAR, Tomcat 9/OpenJDK 17, non-root contoso-orderdesk service, port 3000 |
| SQL | Same schema/seeds; initial mixed mode + labapp reader/writer login using protected deployment password |
| Linux-Web | Original Nginx port-80 site; required desk/API proxy on 8080 with port-bearing Host header |
| Payload | Checkout-local deterministic minimal runtime ZIP/WAR and SHA256 guards; no branch source download |
| JDBC | Pinned official 13.6.0.jre11 HTTPS retrieval with bounded retries/structural checks; explicit locally checksum-verified JAR option |
| Ordering | Early health has no SQL dependency; final host validation requires SQL/data/page/proxy before success |
| Credentials | Root-only initial seed; root:runtime 0640 JNDI descriptor; no secret in source/WAR/arguments/log messages |
| Traffic | Instructor opt-in HTTP-only Python via Nginx; real Java-owned bounded SQL pool; disable preserves prerequisites |
| Discovery | Actual appliance SSH mapping plus both Tomcat trees directory r+x and sudo ls/netstat; not appliance-tested |
| Validation | Reproducible packaging, helper tests, static deploy/host/cloud-init composition; target PS AST/JSP/SQL/discovery still required |
| Deliverables | Full published baseline plus complete apps/contoso-orderdesk and integration tests; untouched files preserved byte-for-byte |

Current module/runtime checks and instructor script labels are updated. AgentBased remains the
Module 3 workload grouping/agentless automation shortcut; migration architecture, VM names,
workload sizing/disks and schema/seeds are not changed. The appliance-flow correction below
supersedes the original appliance handling. Module 4 remains unchanged.
No material was imported from Pull 12 modules. Existing-lab staging/rollback is documented only
as a fallback. Personal account/session override notes and obsolete source-only pointers were
removed. The prior dated parser report is omitted because it is not evidence for this revision.

### Current: Appliance verification and installation correction (2026-10-05)

- Removed learner VHD/guest-partition expansion and Step 2's automatic VHD resize. The
  roughly 80 GB requirement remains: inspect capacity read-only; discrepancies require
  instructor review of the verified package, not a learner resizing workaround. Historical
  section 3c is superseded. Host deployment's automatic ApplianceStore partition remains.
- Module 1 selects one explicit ZIP path and stops on a current official Hyper-V ZIP hash
  mismatch before extraction. Rename/copy/extraction do not change source ZIP bytes;
  recompression/internal renames do, and VHD writes are not source ZIP changes. A mismatch's
  cause is unresolved without the exact artifact, source and actual/expected hashes.
- Deployment rehashes the actual ZIP at the end, reports full path/bytes and cached-record
  agreement separately, and compares any supplied expected hash before reporting MATCH.
  Staging no longer trusts a completion marker alone or overwrites an existing ZIP by default.
- Step 2 refuses ambiguous ZIP/disk/configuration selection and stale/unrecorded extracted
  content; it records and rechecks extraction file hashes independently of the ZIP hash.
  Copy-import preserves exported generation, places all destinations on the actual store,
  checks physical copy space/headroom, renames before boot and guards DHCP/MAC conflicts.
  Source ZIP and extraction folders are retained; no verification bypass is offered.
- Corrected host-store versus guest capacity, UTC accuracy versus display time zone,
  actual deployed host/Linux username, initial Tomcat labapp login versus SQL discovery
  permissions, guest OS verification and nested-switch/WinRM/installer/project boundaries.

Sources: [Microsoft appliance requirements and Verify security](https://learn.microsoft.com/en-us/azure/migrate/migrate-appliance?view=migrate),
[Hyper-V appliance import tutorial](https://learn.microsoft.com/en-us/azure/migrate/tutorial-discover-hyper-v?view=migrate),
and [Compare-VM compatibility/import parameters](https://learn.microsoft.com/en-us/powershell/module/hyper-v/compare-vm?view=windowsserver2025-ps).
Four regression checks cover the new flow, including a fictional ZIP rename/copy/extract
fixture; they do not validate a real Microsoft archive or execute Hyper-V/Azure/PowerShell.

## Troubleshooting & Open Items

### Which script completes which module step

The scripts and the modules are run separately, so this is the map between them. It also appears
in `README.md`, and each script carries its own copy in a `MODULE COVERAGE` block that
`Get-Help <script> -Full` will show.

| Script | Coverage and execution boundary |
|---|---|
| `deploy-lab.ps1` | Module 0 §4 in full; Module 1 §2 in full; Module 1 §3.3 download and extract, **only when you opt in** |
| `migrate-step1-setup-project.ps1` | **Optional.** Module 2 §4.1 (target landing zone) as an instructor shortcut. Module 1 §1 is **not** automated — it prints the portal steps |
| `migrate-step2-discover-assess.ps1` | Module 1 §3.2–3.5, §4 and §5. §3.1 (project key) stops for you |
| `migrate-step3-replicate.ps1` | **Prerequisite checks and partial portal guidance only, not module completion or automated replication/monitoring.** `Agentless`: Module 2 §5–§7 (Web/Linux-Web); `AgentBased`: Module 3 §8–§9 (SQL/Linux-App); `All`: both groups. Complete wizard actions and monitoring manually in the portal |
| `migrate-step4-test-migrate.ps1` | **Guarded prerequisite/group checks and manual portal guidance only.** Complete separate portal test migration/cleanup at Module 2 §8 / Module 3 §10; the unverified VMwareCbt test call cannot execute in this Hyper-V path. No automated completed-state claim |
| `migrate-step5-cutover.ps1` | **Guarded prerequisite/group checks and manual portal guidance only.** Complete separately authorized portal cutover, including source shutdown, at Module 2 §9 / Module 3 §11; the unverified VMwareCbt migration call cannot execute in this Hyper-V path. No automated completed-state claim |
| `migrate-step6-post-migration.ps1` | Module 5 §2–§5 |
| `enable-lab-traffic.ps1` | Module 0 §6; supplies what Module 1 §6 needs to show anything |
| `cleanup-lab.ps1` | Teardown. Leaves the Migrate project, key vault, recovery vault and Entra app |
| `check-lab-scripts.ps1` | Nothing — maintenance tool |

**The student runs `deploy-lab.ps1` and nothing else.** Everything after it is done in the Azure
portal and on the host, which is how a real discovery and migration is driven. The `migrate-step`
scripts exist so an instructor can move a lab to the state a given module expects — for
troubleshooting alongside a student, or to recover a session that ran out of time.

Nothing automates Module 4: it is analysis, with no lab state to reach.

The numbered records below are retained history, not current execution options. References
to retired wrapper entry points describe their former behavior; use the coverage map above.

---

### 1. The lab builds four workload VMs, not five

Pull 12 created a fifth nested VM, `MigrateAppl`, as a bare Windows Server guest that Module 1 then
installed the Azure Migrate appliance onto. That VM is no longer created.

The four workloads — `OnPrem-Web` (.10, IIS), `OnPrem-SQL` (.11, SQL Express), `OnPrem-Linux-Web`
(.12, Nginx) and `OnPrem-Linux-App` (.13, now Tomcat) — retain the published baseline topology using
the same creation methods that are known to work: managed Run Command with protected parameters, a
SAS-exported marketplace disk for the Windows base image, qemu-img conversion for the Ubuntu cloud
image, cloud-init for the Linux guests and `unattend.xml` injection for the Windows guests.

In `scripts/host/configure-host.ps1`:

- The `MigrateAppl` creation call is removed.
- `$allVMs` lists four VMs, so `setup-complete.json` records four.
- The post-boot partition-expansion loop and the unattend-cleanup loop cover `OnPrem-Web` and
  `OnPrem-SQL` only.
- The `192.168.0.20` address and the appliance's share of host memory are deliberately left free.

The appliance instead arrives as Microsoft's published VHD, downloaded and imported by the
instructor in Module 1.

### 2. Host size default is `Standard_E8s_v7`

`Standard_E8s_v5` was not available in the subscription this lab was built in. The default is now
`Standard_E8s_v7` — the same 8 vCPU / 64 GiB shape, Generation 2, Premium SSD, with nested
virtualization support.

`Get-LabHostSku` is unchanged and still validates whatever size is passed against the subscription's
regional SKU metadata and both the family and regional vCPU quotas. Only the default and the example
size names changed.

> Esv7 is a Generation 2 only series whose sizes require an OS image with NVMe support. The
> workshop's `2022-datacenter-g2` host image satisfies both. See *A note from the author* in the
> README.

### 3. Appliance staging uses the host OS disk, not a data disk

The 512 GB OS disk has ample spare capacity, so no additional managed data disk is attached. An
earlier revision of this work did attach a 128 GB `StandardSSD_LRS` data disk; it was removed
because a data disk bills continuously — including while the VM is deallocated — for space the lab
already owns. How that space is presented is described in 3b below.

### 3a. Guest disks and memory are statically allocated

The guest VHDs were dynamic, so 140 GB of declared capacity consumed far less at first and grew
unpredictably through the workshop. They are now **fixed**: `Convert-VHD -VHDType Fixed` in both the
Windows and Linux creation helpers, with a post-creation assertion that the resulting disk really is
`Fixed`. `Create-LinuxGuestVM` gains a `-DiskGB` parameter (default 30) so both helpers size their
disks the same way.

| Guest | Disk | Memory |
|---|---|---|
| `OnPrem-Web` | 40 GB fixed | 4 GB static |
| `OnPrem-SQL` | 40 GB fixed | 4 GB static |
| `OnPrem-Linux-Web` | 30 GB fixed | 2 GB static |
| `OnPrem-Linux-App` | 30 GB fixed | 2 GB static |
| **Total** | **140 GB** | **12 GB** |

Dynamic memory was already disabled on both guest types and is unchanged; the ADR now records it as
a deliberate decision rather than an implementation detail.

Two reasons, both about the assessment in Module 1. Host capacity is known from the start instead of
shifting as guests write, and a dynamic disk's expansion-on-write produces write amplification that
shows up as erratic disk I/O in performance-based sizing.

**The cost is deployment time.** Setup now writes all 140 GB during provisioning rather than
deferring it to first use, which adds roughly 20–40 minutes on a 512 GB Premium SSD. The estimate in
Module 0 moves from 30–60 minutes to **50–100 minutes**, and the conversion timeout rises from 1800
to 5400 seconds. A new troubleshooting entry records that slow guest disk creation is expected.

### 3b. The appliance gets its own partition

`-ApplianceStagingMinimumFreeGB` and the free-space check on `C:` are replaced by a dedicated
partition. A new step, **Create appliance store partition**, sizes `C:` and creates a 100 GB NTFS
volume labelled `ApplianceStore`, creates `E:\Appliance` and grants the lab administrator Modify on
it. New parameters `-ApplianceStoreSizeGB` (default 100) and `-ApplianceStoreDriveLetter` (unset by
default, meaning the first free letter). The marker becomes `APPLIANCE_STORE_READY`, still checked
by `Assert-LabRunResult`.

Because the guest disks are fixed, the two never compete: 140 GB is committed on `C:` and the
appliance has 100 GB that guest growth cannot reach.

> **Sizing works in both directions.** A first attempt assumed `C:` spanned the disk and had to be
> shrunk, and failed on a live run: Azure creates the OS disk at the requested 512 GB but leaves
> `C:` at the image's native size, with most of the disk unallocated. Subtracting the store from the
> *current* size of `C:` produced a target far below what Windows would allow. The step now targets
> `Get-PartitionSupportedSize -SizeMax` minus the store — `SizeMax` being the current size plus the
> adjacent free space — so a single `Resize-Partition` call extends `C:` into unallocated space or
> shrinks it, whichever the disk requires, and leaves exactly the store free. Both failure messages
> now report the current size of `C:`, the range it can occupy and the largest store that range
> permits.

> **Drive letter is chosen, not fixed.** A first attempt defaulted the partition to `D:` and failed
> on a live run: a host size with no local temporary disk leaves the letter after `C:` unused, so
> Windows assigns it to the **virtual DVD drive**. `D:` is occupied even though no disk is attached
> there. Rather than relocate the optical drive, the step now takes the **first unassigned letter**
> and reports it back to the client, which sets the appliance path from that value. On the default
> host size this is `E:`; a size with a temporary disk lands on `F:`. `-ApplianceStoreDriveLetter`
> remains as an explicit override and fails fast if the letter named is in use. Nothing existing is
> moved or reassigned, and the check runs before `C:` is resized, so a failure leaves the OS disk
> untouched.

Module 1 section 3 now downloads, extracts, imports and runs the appliance entirely on `E:`, and
adds an optional `Convert-VHD -VHDType Fixed` step for the appliance disk — guarded by a free-space
check, with a documented fallback if the expanded size does not fit.

### 3c. The appliance disk is grown to Microsoft's documented size

> **Historical — superseded by the current appliance-flow revision below.** The manual VHD
> and guest-partition expansion instructions described here are removed. Do not use the
> old 40 GB packaging assumption or this historical entry as current installation guidance.

Microsoft publishes the Hyper-V appliance VHD at around 40 GB, while the documented requirement for
that appliance is **16 GB memory, eight vCPUs and roughly 80 GB of disk**. Importing the VHD as-is
therefore produces an under-provisioned appliance — observed on a live lab.

Module 1 section 3.4 now runs `Resize-VHD -SizeBytes 80GB` before first boot, and section 3.5 extends
the partition inside the guest with `Resize-Partition` so Windows actually sees the space. Growing
the virtual disk before Windows has booted from it is markedly simpler than afterwards.

> **Two different numbers, easily conflated.** The 100 GB `E:` partition is **host-side storage** for
> the appliance — the download, the extracted VHD and the running VM. The 80 GB is the **appliance's
> own virtual disk**. An 80 GB dynamic disk consumes only what the appliance writes, so it fits
> inside the 100 GB partition alongside the archive. The disk is deliberately left **dynamic**: the
> appliance is lab infrastructure rather than an assessment subject, so its I/O profile does not
> affect sizing data, and a fixed 80 GB disk plus the 40 GB source during conversion would not fit.
> The earlier optional fixed-conversion step is removed for that reason.

Module 0 section 3.7 now lists the appliance's disk, memory and vCPU requirements separately from
the host partition that stores it.

### 4. Lab firewall posture is configured, not left to the instructor

Previously, making a guest answer a ping required enabling the **File and Printer Sharing** group by
hand — which works only because ICMPv4 echo happens to live in that group, and which also opens SMB
and NetBIOS. `scripts/host/configure-host.ps1` now configures the posture directly.

On the Windows guests, in the existing per-guest loop:

| Rule | Scope |
|---|---|
| `LabTrustedIcmp4` — inbound ICMPv4 echo | `192.168.0.0/24`, `10.0.0.0/16`, `10.1.0.0/16`, `10.2.0.0/16` |
| `LabTrustedInbound` — inbound any protocol | the same four ranges |
| Connection profile set to `Private` | a DHCP NIC is frequently classified `Public` |

On **HyperVHost**, scoped to `192.168.0.0/24` only: `LabHostIcmp4`, `LabHostWinRM` (5985/5986) and
`LabHostSmb` (445). WinRM is the path the Azure Migrate appliance uses to reach the host for
Hyper-V discovery, and it was previously left entirely to the manual host-preparation step.

On the Linux guests, `ufw --force disable || true` is added to the shared cloud-init `runcmd`. It
ships inactive on Ubuntu cloud images; the explicit disable makes the posture deliberate.

The ICMP rule is kept separate from the any-protocol rule so ping survives if the broad rule is
later narrowed. Both are removed and recreated if present, so re-running is safe.

**Not changed:** the Azure NSG. The host's public NIC still permits RDP from the single `/32`
supplied at deployment.

### 4a. Hyper-V guest daemons on the Linux guests

Ubuntu cloud images ship the Hyper-V kernel modules but not the userspace daemons. Without the
Data Exchange (KVP) daemon the host cannot report a guest's operating system or IP address, and
because Azure Migrate reads guest OS details **through the host**, the two Linux guests are
discovered but listed with blank OS information. This was observed in a live run.

Two separate pieces are required, and an Ubuntu cloud image as provisioned has neither. The
`hv_utils` **kernel module** publishes `/dev/vmbus/hv_kvp`, and the daemon's systemd unit `Requires`
that device — so enabling the service before the module is loaded fails with *"A dependency job for
hv-kvp-daemon.service failed"*, which reads like a daemon fault but is not one. The **userspace
daemons** then have to be installed on top. Both failures were observed in a live run.

`configure-host.ps1` now provisions both, in order:

- `modprobe hv_utils`, followed by `/etc/modules-load.d/hyperv.conf` so it survives a reboot.
- `linux-cloud-tools-common` in the shared cloud-init package list — it supplies the systemd units
  and helper scripts.
- A `runcmd` install of `linux-cloud-tools-$(uname -r)`, matching the running kernel so no reboot is
  needed, falling back to the `linux-cloud-tools-virtual` / `linux-tools-virtual` meta-packages when
  that exact version is not in the archive. That fallback pulls a different kernel and does require
  a reboot to take effect.
- `udevadm settle`, so the device node is present before the services are enabled.
- `hv-kvp-daemon.service` and `hv-vss-daemon.service` enabled and started.
- An evidence block that echoes `LAB_KVP_DAEMON_RUNNING`, or `LAB_KVP_DAEMON_MISSING` plus a
  `LAB_KVP_CAUSE` line distinguishing a missing module, a missing device node and a missing binary —
  enough to diagnose from the cloud-init log without a live session.

**A reboot is required, and is now scheduled.** Installing the tools package also installs the udev
rules that create `/dev/vmbus/hv_kvp`. The daemon's systemd unit `Requires` that device, so the
service cannot start in the same boot that installed the package — enabling it succeeds, starting it
does not. This was confirmed on a live lab: both guests started the daemon correctly after a manual
reboot. Cloud-init now reloads and triggers the udev rules, enables the services, and ends with a
`power_state: reboot` so they come up on the next boot. The evidence marker distinguishes
`LAB_KVP_DAEMON_RUNNING` from `LAB_KVP_DAEMON_PENDING_REBOOT` so the log shows which path was taken.
Workload validation already retries for 20 minutes, which absorbs the restart.

**Packages for the full command set.** Microsoft's support matrix lists the commands Azure Migrate
executes over SSH for software inventory and agentless dependency analysis. Ubuntu cloud images do
not reliably ship four of them, so `net-tools` (netstat), `iproute2` (ss), `libcap2-bin` (getcap) and
`plocate` (locate) are all installed. `getcap` is the easiest to miss — it is in Microsoft's list but
in few base images.

**The Linux guest password was never actually set.** The cloud-config used the top-level
`password:` key, which cloud-init applies to the distro's **default user**. This file replaces
`users:` without including `default`, so no default user exists and the password was applied to
nobody; the per-user `plain_text_passwd` it also carried is deprecated. The password is now set
through `chpasswd.users`, which names the account explicitly:

```yaml
chpasswd:
  expire: false
  users:
    - name: labadmin
      password: <lab password>
      type: text
```

`lock_passwd: false` is retained so the account is not locked, and a `LAB_GUEST_PASSWORD_SET` /
`_LOCKED` / `_MISSING` marker records the result of `passwd -S` in the setup log.

> Fixing this exposed a second defect in the same block. `Expand-LabTextTemplate` substitutes tokens
> in a single pass and deliberately never rescans inserted text, so that a password cannot be
> reinterpreted as another token. A `__USER__` token placed inside a `runcmd` fragment is inserted
> after that pass and would have survived into the guest literally. The fragment now resolves its
> own tokens before being joined into the document.

**Account naming is stated explicitly.** The guest credential guidance listed `Administrator` for
the Windows guests and `labadmin` for the Linux guests without explaining why they differ, which
read as though the lab creates a separate Linux-only account. It does not: `configure-host.ps1` sets
`$guestUser = $AdminUsername`, so the Linux guests and HyperVHost share one username, and only the
Windows guests differ because they reuse the built-in `Administrator` rather than creating a second
account. Module 0 and Module 1 now both carry a short table giving the account per machine and where
it comes from, and point at `lab-traffic.settings.json` for the name actually used when
`-AdminUsername` was not the documented default.

**Prerequisites are verified during provisioning.** A new cloud-init block records
`LAB_SUDO_NOPASSWD_OK`, `LAB_DEPENDENCY_COMMANDS_OK` (or the exact commands missing) and
`LAB_SSH_ACTIVE` in the setup log, so a gap is visible immediately rather than as an empty inventory
days later. Cloud-init already granted the lab user `ALL=(ALL) NOPASSWD:ALL`; that is now confirmed
rather than assumed.

Every step is `|| true`, so a package-source or kernel-flavour problem degrades guest OS reporting
rather than failing the whole deployment. The Windows guests need nothing equivalent: Data Exchange
and Heartbeat are enabled by default, and `configure-host.ps1` additionally enables Guest Service
Interface.

Module 1 section 4 gains the matching checks and full remediation for an existing lab — module
first, then packages installed **separately**, because combining an unavailable versioned package
with an available one makes apt abort the whole transaction and install neither. It also records
that these commands need `sudo`: Ubuntu cloud images leave root locked by design, and `systemctl`
without `sudo` falls through to a polkit prompt for a root password that does not exist. Module 0
section 3.6 lists the extra package source.

### 4b. Software inventory prerequisites

An assessment run against a live lab returned **no applications**, despite IIS, ASP.NET, SQL Server
Express, Nginx and Node.js all being installed. Software inventory is a separate mechanism from VM
discovery: VM inventory arrives through the Hyper-V host, while software inventory connects
**directly to each guest** over PowerShell remoting on Windows and SSH on Linux, using guest
credentials added in the appliance configuration manager. Missing any of those produces an empty
column and no error.

Three causes were addressed:

- **Guest credentials.** Module 1 step 5 previously read *"Add guest credentials only for the
  software inventory or dependency features you intend to demonstrate,"* which reads as optional. It
  now states plainly that these are required, names the accounts to use, and distinguishes them from
  the Hyper-V host credentials added earlier in the same panel.
- **`locate` on the Linux guests.** Microsoft's support matrix lists `locate` among the commands
  software inventory runs, and Ubuntu cloud images omit it. `plocate` is added to the cloud-init
  package list and `updatedb` runs once during provisioning so the first inventory pass has a
  database to read.
- **PowerShell remoting on the Windows guests.** Windows Server enables WinRM by default, but a DHCP
  guest can classify its network as Public and refuse the listener. `configure-host.ps1` now runs
  `Enable-PSRemoting -Force -SkipNetworkProfileCheck` inside the existing per-guest loop and, after
  the guests are configured, tests port 5985 from the host and logs a warning naming the affected
  guest if it is unreachable.

Module 1 section 4 gains an expected-inventory table, a warning that an empty column means missing
credentials rather than missing applications, and the connection checks to run if it stays empty. It
also records that software inventory and the Azure VM assessment are different views — applications
never appear in the assessment.

### 4c. Subscription ID and admin address are masked at entry

`deploy-lab.ps1` takes `-SubscriptionId` and `-AdminSourceCidr` as **SecureString**, so neither is
visible while being typed — relevant when a delivery is screen-shared or recorded. New helpers
`ConvertFrom-LabSecureString` and `Assert-LabSubscriptionId` in `common.ps1` convert once, trim
surrounding whitespace, reject an empty entry and check the subscription GUID format before Azure is
contacted. Both plain values are cleared in the `finally` block alongside the password, and the
deployment banner no longer echoes the subscription ID.

The `/32` suffix on `-AdminSourceCidr` is now **optional**. The lab only ever permits a single
address, so the prefix carried no information while being easy to omit — and now that the value is
masked at entry, a missing or mistyped suffix is invisible until validation rejects it. A new
`Resolve-LabAdminSource` accepts a bare address, trims surrounding whitespace and returns the
normalised `/32` form, which deployment then uses for the NSG rule.

An explicitly supplied prefix is still **checked rather than overridden**: `203.0.113.14/24` is
refused, not silently narrowed to a single address the caller did not choose. Every rejection the
original validation made is preserved — abbreviated, hexadecimal, integer and leading-zero
notations, IPv6, `0.0.0.0` and non-dotted-quad input all still fail, because those forms resolve to
a different address than they appear to and would open RDP to the wrong host.

> This is screen hygiene, not secret storage. Both values still reach Azure and remain visible
> afterwards — the subscription ID in `Get-AzContext` and every resource ID, the address in the
> host's NSG rule.

**No other script needed the same change.** `migrate-step1` through `step6` and `cleanup-lab.ps1`
take **no subscription parameter at all** — they act on whichever subscription is active in the
session, read from `Get-AzContext`. `deploy-lab.ps1` is the only script in the lab that accepts one,
so it is the only one converted.

That check exposed two invocation examples that were carried over from a different revision of the
repository and would fail on first run:

- Module 0 step 2 and the README passed `-SubscriptionId` to `migrate-step1-setup-project.ps1`,
  which has no such parameter. PowerShell rejects an unknown parameter outright.
- The README and Module 0's cost table passed `-SubscriptionId`, an array of two group names, and
  `-WhatIf` to `cleanup-lab.ps1`. That script takes a single `[string]$ResourceGroupName` and a
  `-Force` switch, and its `[CmdletBinding()]` does not declare `SupportsShouldProcess`, so `-WhatIf`
  is not available either.

Both are corrected, and both documents now state that the migrate and cleanup scripts depend on the
active context rather than an explicit subscription.

### 4d. A failed deployment resumes instead of requiring a rebuild

Pull 12 replaced the original lab's "create if absent" pattern with hard refusals — an existing
resource group, a `setup-complete.json` marker, or an existing guest VM each threw. The intent was
to stop a re-run resurrecting retired source VMs after cutover. The effect during build-out was that
any failure, however trivial, cost a full teardown and another full deployment.

The guards now distinguish **incomplete** from **complete**:

| Check | Before | Now |
|---|---|---|
| Existing resource group | Always refused | Allowed when tagged as this workshop **and** its `ConfigureWorkshop` has not succeeded; refused otherwise |
| `setup-complete.json` on the host | Refused | Unchanged — a completed host is still refused |
| Existing guest VM | Refused | Removed and rebuilt, with its VHD, cloud-init ISO and DHCP reservation |

On a resumed run `deploy-lab.ps1` reuses the virtual network, public IP, NSG, NIC, host VM and image
disk when they already exist, and clears any Run Command left by the previous attempt before
resubmitting. On the host, the virtual switch, NAT, DHCP scope and downloaded base images were
already `if exists → skip`, so they are kept; only partly built guests are discarded, because a
half-provisioned guest cannot be trusted. The host logs that it is resuming.

The post-cutover protection is preserved: once guest setup has succeeded, the group is refused with
a message saying why.

### 4e. Lost monitoring no longer reads as failure

A live run ended with *"Setup status has been unavailable for 300 seconds"* at 21:34 UTC. The host
finished successfully at 21:59 UTC — the client had stopped watching 26 minutes early because its
Azure token expired. Guest setup is submitted with `-AsyncExecution`, so the client only observes it;
losing the observer never stops the work.

Three faults, all in `Wait-LabManagedSetup`:

- **The reason was discarded.** `catch { $readFailed = $true }` threw away the exception, so an
  expired token, a throttle and a network fault produced identical output. The message now carries
  the underlying Azure error.
- **Sign-in failure was waited out.** A failed token refresh does not heal with time. Auth failures
  are now identified and reported immediately, rather than after the full window.
- **The message implied the deployment had failed.** It now states plainly that setup runs
  asynchronously on the host and is probably still running, gives the `Get-AzVMRunCommand` reattach
  command, points at `setup-log.txt`, and says not to redeploy before confirming a real failure.

`StatusFailureSeconds` also rises from 300 to 900, which is safe now that the genuinely fatal case
is identified rather than waited on.

Module 0 gains a matching troubleshooting entry, including the two cleanup steps the client would
have performed had it still been watching — revoking and removing `WinServerBase-temp`, and removing
the completed Run Command.

### 4f. Progress reporting follows the host through its phases

The deployment reported 13 steps, of which the last — *Guest setup* — covered the entire host
payload. That is 40 to 80 minutes of the run, so the counter sat on `Step 13/13` for the majority of
a deployment while the detail line changed underneath it. Observed on a live run.

The host payload already emitted `LAB_STAGE` markers for each phase, and `Wait-LabManagedSetup`
already parsed them — but it passed the constant string `Guest setup` to `Write-LabHealth`, and the
step number is derived from that stage name. The phase was shown as detail text only.

The phase is now reported **as the stage**, and the phase names are entries in the step list, so the
counter advances through the host's work:

| Steps | Where they run |
|---|---|
| 1–12 | The deployment client: resource group through `Submit guest setup` |
| 13–22 | The host: starting, networking, images, nested VMs, first boot, workloads, IIS, SQL, validation, traffic generator |
| 23 | `Guest setup complete` |

`PHASE 6` in `configure-host.ps1` emitted no marker at all — it was added after the mapping was
written — so it now reports `traffic`, and `Staging the traffic generator` is a phase name and step.

The failure and status-unavailable paths also report against the current phase rather than a
constant, so a stall or an error now names the phase it stopped in instead of saying `Guest setup`
regardless of how far the run got.

### 5. Optional traffic mesh

`scripts/enable-lab-traffic.ps1` is new. It wires the four independent samples into one
small-business order desk so Azure Migrate dependency analysis has real connections to observe:

| Edge | Protocol | Driver |
|---|---|---|
| `OnPrem-Web` → `OnPrem-SQL` | TDS 1433 | scheduled task `LabOrderDeskTraffic`, recent-orders report |
| `OnPrem-Web` → `OnPrem-Linux-App` | HTTP 3000 | same task, `/api/health` batch call |
| `OnPrem-Linux-App` → `OnPrem-SQL` | TDS 1433 | systemd unit `lab-traffic`, inserts an order per cycle |
| `OnPrem-Linux-App` → `OnPrem-Linux-Web` | HTTP 8080 | same unit, proxy call |
| `OnPrem-Linux-Web` → `OnPrem-Linux-App` | HTTP 3000 | Nginx `proxy_pass` on a new 8080 server block |

`OnPrem-SQL` becomes a shared dependency of both application tiers.

**Deployment validation is untouched.** The IIS site, the Nginx root site on port 80 and the Node
service on 3000 keep their original content, so `Assert-LabSourceWorkloads` still passes. The proxy
listens on 8080, the generators are separate units, and `server.js` is not edited.

**It is delivered to the host by deployment.** `Read-LabHostConfiguration` reads the script, parses
it for syntax errors, gzip+base64 encodes it via the new `Compress-LabScript`, and substitutes it
into the `__LAB_TRAFFIC_PAYLOAD__` placeholder in the host payload. A new PHASE 6 in
`configure-host.ps1` decodes it after workload validation and writes two files — the script itself at
`C:\AzMigrateLab\enable-lab-traffic.ps1`, and `lab-traffic.settings.json` holding the lab user name,
guest addresses, SQL login and interval that deployment actually used. Nothing is executed.
`setup-complete.json` gains a `TrafficScript` path.

Running it on the host therefore needs no arguments beyond the lab password, which it prompts for.
Explicit parameters override the settings file; `-SettingsPath` points at a different one. The
password is deliberately **not** persisted — setup already deletes unattended-install password
material after first boot.

**Names, not addresses.** Generators resolve `onprem-sql`, `onprem-app` and `onprem-nginx` through
hosts entries written to all four guests. The generators start at boot, so migrated VMs resume the
same traffic in Azure and fail until those entries are repointed — documented as a deliberate
Module 3 exercise rather than a defect.

**`-Disable`** stops and removes the generators, the proxy and the lab SQL login. Every step is
idempotent, so a part-way failure can simply be re-run.

Guest changes: SQL Express switched to mixed-mode authentication with one lab-only login (`labapp`,
`db_datareader` + `db_datawriter` on `ContosoApp` only, required because the Linux generator cannot
use Windows authentication); `C:\LabTraffic\` and a scheduled task on `OnPrem-Web`; the `mssql` npm
package, `lab-traffic.js`, the `lab-traffic` systemd unit and `/etc/lab-traffic.env` (mode 600) on
`OnPrem-Linux-App`; one Nginx conf file on `OnPrem-Linux-Web`.

#### Fix: ssh stderr aborted Linux configuration

`Invoke-LabLinuxPayload` sets `$ErrorActionPreference = 'Stop'`. Merging a native executable's
stderr with `2>&1` under `Stop` turns each stderr line into a terminating `NativeCommandError`, and
ssh writes its host-key notice to stderr on a *successful* connection — so a benign warning aborted
the run, every time, because `UserKnownHostsFile=NUL` means the key is never actually remembered.

The preference is now saved, set to `Continue` around the native call and restored in a `finally`
block; `$LASTEXITCODE` is captured immediately and used for the success test; `-o LogLevel=ERROR`
suppresses the notice; and output is flattened to a string before the marker match. The same
bracketing pattern already existed around the `oscdimg` call in `configure-host.ps1`.

### 6. Helper functions

- `Assert-LabResourceGroup` and `Assert-LabWorkloadNames` are removed from `common.ps1`. Their only
  callers were Pull 12's `cleanup-lab.ps1` and test scripts, neither of which is part of this lab.
- `Assert-LabManagedRunResult` moved from `common.ps1` to `health.ps1`, beside `Wait-LabManagedSetup`,
  its only caller. `health.ps1` is now self-contained, which removes an implicit dot-source ordering
  requirement in `deploy-lab.ps1` and — more importantly — fixes the embedded host payload, which
  receives `health.ps1` but never `common.ps1`.
- `Compress-LabScript` is added to `common.ps1` for the traffic-script payload.
- The `LAB_PROGRESS` marker machinery in `health.ps1` is retained: `Wait-LabManagedSetup` consumes it
  and `deploy-lab.ps1` calls that directly for live progress during guest setup.

### 7. Documentation

#### `docs/Module-0-Setup.md`

Rewritten from the instructor to the student, following the unmodified lab's conventions: numbered
sub-steps, `> **Note:** / **Tip:** / **Warning:**` callouts, **Expected result** labels and direct
address. Instructor-only material is retained in annotated `> **Instructor note.**` callouts.

Structure, with the unmodified lab's sections reinstated:

| § | Section |
|---|---|
| 1 | Module Overview |
| 2 | Architecture Decisions Record |
| 3 | Prerequisites (3.1 governance · 3.2 quota · 3.3 region · 3.4 tooling · 3.5 network · 3.6 downloads · 3.7 appliance requirements) |
| 4 | Deployment Steps |
| 5 | Verify inside HyperVHost |
| 6 | Start the sample business traffic |
| 7 | Troubleshooting |
| 8 | Security Baseline (8.1 NSG · 8.2 lab firewall posture · 8.3 remote access · 8.4 credentials · 8.5 least privilege) |
| 9 | Cost Analysis |

Specific points:

- The ADR is updated for the decisions actually made: `Standard_E8s_v7`, the 512 GB OS disk, staging
  on that disk rather than a data disk, appliance-by-VHD-import, the trusted-range firewall posture
  and managed Run Command.
- Prerequisites are refreshed for Esv7 and four guests. **3.7** is where the appliance appears in
  Module 0 — stated once, as reserved capacity and a proxy requirement, with no build steps.
- Troubleshooting returns to the `**Symptom:** / **Cause:** / **Resolution:**` format, updated for
  the current environment and extended with the genuinely new cases (insufficient free space, guest
  will not answer a ping, traffic script not staged).
- Security Baseline's NSG table is corrected: this lab's rule is a single `/32`, not the unmodified
  lab's `*`, so the warning changes meaning. The firewall posture lives here as 8.2.
- Cost Analysis reinstated. The verified figure is the `Standard_E8s_v7` **Linux** PAYG rate; the
  Windows rate, disk and IP lines are marked *verify* rather than guessed, with the pricing
  calculator linked. A note records the data disk that was removed and why.
- Section 5 checks carry an inline `# <item> on <computer> — expect <result>` comment above each
  command, with the summary table kept below.
- The SQL check is a single query returning both counts as columns of one row, because
  `Invoke-Sqlcmd` surfaces only the first result set — two separate `SELECT COUNT(*)` statements
  silently discarded the Orders count.
- Image-catalog and disk-security implementation detail is removed; it was troubleshooting residue,
  not lab narrative. The behaviour is unchanged in the scripts and explained in the README note.

#### `docs/Module-1-Discovery.md`

Rewritten to the same conventions. Section 3 is broken into 3.1–3.5 — generate the project key,
confirm staging space, download and verify the archive, import the VHD, complete first boot — and
creates `MigrateAppl` on `intSwitch` with 8 vCPU / 16 GB, a static `00-15-5D-00-00-14` MAC matching
the scheme deployment uses, and a DHCP reservation for `192.168.0.20`.

Section 4 is an ordered registration walkthrough with the HTTPS-port warning and the "check names,
not the count" point called out. Section 6, *Interpret the dependency view*, tells the student what
to expect both with and without the traffic mesh, rather than instructing the instructor what not to
ask.

> The appliance VHD Microsoft publishes for Hyper-V is Generation 1, so the import specifies
> `-Generation 1`. The document tells the reader to confirm this against the current article rather
> than assume it.

**Appliance clock checks.** Section 3.4 explicitly enables the Time Synchronization integration
service on the imported VM and verifies it, because an imported VM carries whatever its exported
configuration held rather than the Hyper-V default. Section 3.5 adds a UTC clock and time-zone check
at first boot, and section 4 adds an ordered "no servers appear at all" table.

> Hyper-V time synchronization aligns the guest's UTC clock with the host's; it does not set the
> guest's time zone, and it does not override a clock changed inside the guest after boot. An
> appliance with a skewed clock registers successfully and then discovers nothing, because Azure
> rejects the timestamps on its requests — an empty inventory with no obvious error. This was
> observed in a live run. The same table records that Integration Services governs whether a guest's
> **OS details** can be read, not whether the VM is discovered, so it is not the cause of an empty
> inventory.

#### `docs/Lab-Traffic.md`

New. What the mesh creates, how to run and verify it from the staged copy, the names-not-addresses
rationale, load guidance, and the exact per-guest changes.

#### `README.md`

Diagram, module table and script table updated. Adds **A note from the author**, recording the
compatibility findings met while building this lab — the v5 → v7 change, the Esv7 Gen2/NVMe
constraint, why the catalog API is pinned and Standard disk security forced, the Generation 1
appliance VHD, and the staging-disk removal — framed as observations from one subscription and one
region, closing with an invitation for feedback from anyone who meets a different problem.

---

### 8. Lab-wide consistency reconciliation

Modules 2-5 and `migrate-step1` through `migrate-step6` were still carrying values from
the lab they were forked from. They now agree with Modules 0 and 1.

**Resource groups.** Three naming schemes were in play: the step scripts defaulted to
`nazli-onprem`/`nazli-oncloud`, Modules 2-5 and `cleanup-lab.ps1` used
`rg-migrate-workshop`, and Modules 0-1 used `rg-ces-source-01`/`rg-ces-target-01`.
All of them now use the Module 0 pair.

**Project name.** `migrate-step1`, `step2` and `step3` defaulted to
`MigrateProject-Workshop` while `step4` and `step5` defaulted to `nazli-migrate-project` -
so step 4 looked for a project step 1 never created. All six now default to
`ces-migrate-01`, matching the example in Module 1.

**Appliance identity.** `migrate-step2` called the appliance `AzMigrateAppliance` and put
it in `C:\AzMigrateAppliance`; Module 1 imports `MigrateAppl` into `E:\Appliance`. The
script now uses the Module 1 name and path.

**Appliance identity, continued.** `migrate-step2` step 3 downloads the appliance VHD and
creates the Hyper-V VM - the same work Module 1 walks the instructor through by hand. This is
deliberate: the step scripts are an automation track that reaches the same state as the manual
modules, so the two routes must produce the *same* artifact. Renaming was the only change made;
the download-and-import logic is untouched and still runs by default.

**Smaller corrections.**

- `migrate-step5` printed `ssh azureuser@<Public-IP>`; the lab user is `labadmin`.
- Module 3's machine table listed OnPrem-SQL as SQL Server 2019 Express; the lab installs 2022.
- 31 `../images/*.png` references across Modules 2-5 pointed at an `images/` folder that
  does not exist in this repository, so every one rendered as a broken image. They have been
  removed, which also matches Modules 0 and 1, where verification is written as
  **Expected result** text rather than screenshots.
- `README.md` linked to `Module-2-HyperV-Migration.md` and `Module-3-Stateful-Migration.md`,
  and Module 1 linked to `Module-2-HyperV-Migration.md`. None of those files exist here. The
  links now point at `Module-2-Agentless-Migration.md` and `Module-3-Agent-Based-Migration.md`,
  and the README module table describes what those modules actually cover (Module 2 is
  agentless for the two web servers, Module 3 is agent-based for SQL and the Linux app server).

**Checked and already correct.** The four workload names (`OnPrem-Web`, `OnPrem-SQL`,
`OnPrem-Linux-Web`, `OnPrem-Linux-App`), the `192.168.0.0/24` guest addressing, and the
cross-links among Modules 2-5 were consistent throughout and were not touched.

### 9. State-bridging scripts for Modules 2 and 3

The step scripts are an automation track that reaches the same state as the manual
modules. They were decomposed by PHASE (step 3 replicated all four VMs, step 4 tested all
four, step 5 cut over all four), but the modules are organised by WORKLOAD: Module 2 takes
OnPrem-Web and OnPrem-Linux-Web all the way through cutover, and Module 3 does the same for
OnPrem-SQL and OnPrem-Linux-App. Module 3's prerequisites list Module 1, not Module 2, so
the two are parallel branches rather than a sequence.

That mismatch meant there was no way to advance the lab one module at a time.

**`-Workload` filter on steps 3, 4 and 5.** A new parameter accepting `All` (default),
`Agentless` (the Module 2 pair) or `AgentBased` (the Module 3 pair) narrows each script to
one branch. The groups are disjoint and together cover all four VMs. The default preserves
the original behaviour exactly.

**Two new wrappers.**

- `migrate-step3a-agentless.ps1` - reaches the end state of Module 2.
- `migrate-step3b-agent-based.ps1` - reaches the end state of Module 3.

Each runs `migrate-step3` then `migrate-step4` then `migrate-step5` with the matching
`-Workload` value, so there is one command per module. No migration logic is duplicated -
the wrappers only sequence the existing scripts. Both prompt for confirmation before
starting, because cutover shuts down the matching source VMs on the Hyper-V host. Both
accept `-SkipTestMigration` to omit the test-migration stage, which shortens the run and
avoids creating temporary test VMs on a restricted training subscription, at the cost of
the validation that would catch a bad replica before cutover.

Because Modules 2 and 3 are parallel branches, a student who completed Module 2 by hand
runs `step3b` only. Running both, in order, leaves all four VMs migrated and the lab ready
for Module 5.

**Known limitation, documented in the script header.** Module 3 teaches agent-based
migration - replication appliance plus Mobility Service in each guest. `step3b` reaches the
same end state using the agentless path, because that is what `migrate-step3` implements.
This is correct for bypassing Module 3 to reach Module 5, since Module 5 only requires the
four VMs running in Azure. It will **not** reproduce a Mobility Service or replication
appliance fault, so an instructor troubleshooting those must work against the student's own
environment following Module 3 sections 5-7.

**Already tolerant of partial state.** `migrate-step6-post-migration.ps1` builds its VM list
from what actually exists in the target resource group and only fails if it finds none, so
Module 5 automation works against a half-migrated estate without modification.

### 10. Prompts find the resources instead of asking you to recall them

The first pass at interactive entry removed hard-coded defaults but still asked for every name
as free text. That reproduced the problem it was meant to solve: the learner had to know the
exact spelling of a resource group, project or VM before the script would move, and a typo
failed late.

The scripts now ask Azure. When a value is not supplied on the command line, the script queries
the signed-in subscription and presents what it found as a numbered list:

- **Resource groups** - from `Get-AzResourceGroup`.
- **Azure Migrate project** - from the source resource group, covering both resource types the
  service uses (`migrateProjects` and `assessmentProjects`).
- **Hyper-V host VM** - from the VMs in the source resource group.
- **Appliance VM** - from the VMs on the Hyper-V host itself, with the four lab workloads
  filtered out.
- **Workload group** - All, Agentless or AgentBased.

**The region is no longer asked for at all.** A resource group already carries a location, so it
is read from the group that was just chosen and reported rather than prompted.

**One candidate means no question.** Where the subscription holds exactly one match, it is
selected and reported. A list appears only when there is a real choice to make.

**Resources this script creates are still named by you.** In `migrate-step1-setup-project.ps1`
the target resource group and the Azure Migrate project offer the existing ones plus a final
entry for typing a new name, so the same prompt covers reuse and creation. Values that are not
Azure resources - assessment currency, offer code, auto-shutdown time and time zone, backup
retention - remain typed, because nothing can look them up.

**Trailing parameters still work.** A value passed on the command line is used as before; it is
only checked against what the subscription actually contains, and a name that does not exist is
rejected with the list of names that do.

### 11. Appliance naming reverted to a single parameter

The previous round split the appliance name into `-ApplianceVMName` and `-ApplianceProjectName`.
That added a prompt without adding information, since the lab uses one name for both. It has
been reverted to a single `-ApplianceVMName`, now chosen from the VMs actually present on the
Hyper-V host.

The underlying constraint is still handled: Azure Migrate accepts only alphanumeric names of 14
characters or fewer under *Generate project key*, while Hyper-V allows longer names with
hyphens. The script checks the chosen name against that rule and asks for a separate
registration name **only when the check fails**. With `MigrateAppl` it never fires.

Because the appliance is chosen from the host's own inventory, an appliance imported through
Microsoft's documented route - Hyper-V Manager > *Import Virtual Machine*, which keeps the name
from Microsoft's exported configuration and offers no rename step - appears in the list under
whatever name it carries. If it is not there yet, the final list entry names it and the script
downloads and imports it as before.

### 12. Parameter entry across the migrate-step scripts

All eight scripts take no value silently, and prompts validate before accepting. Pressing Enter
does not accept the example shown in a prompt. Subscription and tenant IDs are masked wherever
these scripts write to the console.

Two consistency items were resolved:

- `migrate-step3a` and `migrate-step3b` did not set `Set-StrictMode -Version Latest`; the other
  six did. They now match.
- `migrate-common.ps1` is dot-sourced by nothing - every step script inlines its own copy of the
  helpers so it can run standalone - and its copy had drifted. It has been resynchronised and
  its header now states that nothing loads it at run time and that it is the copy to edit first.
  An unused file that looks authoritative is worse than no file at all.

### 13. Each migrate-step script now starts on its own

`migrate-step2-discover-assess.ps1` could not be run bare from the scripts folder. It failed
before showing a single prompt, and the reason was the startup sequence rather than the prompts:

```
trap { ... }
$context = Get-LabAzContext      <-- three hard stops live in here
... prompts ...
```

`Get-LabAzContext` refused the run outright in three cases: the Az modules were not loadable in
that session, the session was not signed in, or the session had no subscription selected. All
three threw with instructions to go and fix it by hand, so the script never reached the point
where it asks anything.

`deploy-lab.ps1` does not behave this way. It imports the modules it needs itself, and its
`[Parameter(Mandatory)]` declarations make PowerShell prompt before the body runs. That is why
it works from the folder and the migrate-step scripts did not.

The startup is now self-sufficient in all eight:

- **Modules are loaded, not merely checked.** Each script declares what it needs.
  `Az.Accounts` and `Az.Resources` are required everywhere, plus `Az.Compute` and `Az.Network`
  where they are used. `Az.Migrate` -- and `Az.Monitor`, `Az.OperationalInsights` and
  `Az.RecoveryServices` in step 6 -- are optional: a missing one produces a warning, not a
  refusal, because those steps already fall back to portal instructions.
- **Sign-in is offered, not demanded.** With no Azure sign-in in the session the script runs
  `Connect-AzAccount` instead of telling you to.
- **The subscription is chosen from the ones the account can see.** When the context has no
  subscription, the enabled ones are listed and selected with `Set-AzContext`. A single
  subscription is taken without asking. A subscription already chosen with `Set-AzContext` is
  used as it stands -- an existing session is never second-guessed.

`.\scripts\migrate-step2-discover-assess.ps1` with no arguments now signs in, selects a
subscription and asks its questions. The README Start-here block no longer sets the context by
hand before running them.

### 14. Failures are recorded to a file and the window stays open

A failure was unreadable when the script was launched by double-click or *Run with PowerShell*:
the trap ended with `exit 1`, the console closed on the spot, and the error went with it.

The trap now writes the whole failure to `migrate-step<N>-error-<timestamp>.log` beside the
script - falling back to the temp folder when that location is not writable - and then waits for
Enter before exiting. The report carries the message, exception type, category, the failing line
and its number, the script stack trace, and the loaded Az module versions. It passes through the
same masking as the screen output, so subscription and tenant IDs are truncated in the file too.
Set `LAB_NO_PAUSE=1` to skip the pause for an unattended run.

### 15. Module loading is best-effort again

Section 13 changed the module check from `Get-Command Get-AzContext` to
`Import-Module <module> -ErrorAction Stop` for a list of required modules. That was too strict:
any module that would not import - a partial Az installation, a version conflict, a module
present but not importable in that session - stopped the script at startup, before any prompt,
even though the cmdlets it needed were callable.

Modules are now imported best-effort. What is actually verified is that `Get-AzContext` and
`Get-AzResourceGroup` resolve, which is also how PowerShell auto-loads them on first use. A
module that fails to import produces a warning naming it, not a refusal. Only a genuinely
missing cmdlet stops the run.

### 16. The actual cause: a parse error in migrate-step2

`migrate-step2-discover-assess.ps1` could not run at all, with or without parameters. Its
section 4 instruction block contained:

```
"4. Check the clock inside $ApplianceVMName: [DateTime]::UtcNow and Get-TimeZone (expect UTC)."
```

Inside a double-quoted string PowerShell reads `$Name:` as a drive-qualified variable reference,
the same form as `$env:PATH`. With a space after the colon there is no drive name to find, so
the file fails to parse:

```
Variable reference is not valid. ':' was not followed by a valid variable name character.
```

A PowerShell script is parsed in full before its first line executes. So this stopped the script
before `Set-StrictMode`, before the sign-in, before the prompts, and before the error trap that
would have reported it. Launched with *Run with PowerShell* it looked like a window opening and
closing with nothing in it.

The fix is `${ApplianceVMName}:`, which delimits the name and ends the reference before the
colon. A scan of every lab script found this to be the only instance of the pattern.

This was the failure behind every "step 2 fails before prompting" report, including the ones
attributed earlier to the sign-in sequence and to module loading. Those two were real weaknesses
and the changes to them stand on their own, but neither was the cause here.

### 17. A parse check that runs nothing

`scripts/check-lab-scripts.ps1` runs the PowerShell parser over every `.ps1` beside it and
reports the file, line, column and message for anything that will not parse. It executes no
script, signs in to nothing and changes nothing.

A syntax error is invisible to every safeguard inside a script, because none of them have run
yet. This catches that class in a second, and it would have caught the fault above immediately.
Worth running after editing any lab script, and before a workshop.

### 18. Resource groups are typed, not listed

Listing every resource group in the subscription was the wrong shape for a training
subscription, which can hold a great many groups belonging to other people. The learner knows
which group is theirs.

Both resource-group prompts now take a typed name. The name is checked against Azure as soon as
it is entered and re-asked when it is not found, so a typo is caught at the prompt rather than
part way through the run. A name passed on the command line that does not exist fails
immediately with the same check.

In `migrate-step1-setup-project.ps1` the target group is the one the script creates, so that
prompt carries `-AllowNew`: a name that does not exist is offered for creation instead of
refused. Every other script needs the target group to exist already and says which script
creates it when it does not.

Narrow, script-generated lists are unchanged, because they are not subscription-wide and the
names are not ones a learner is expected to memorise: the Azure Migrate project in the chosen
source group, the VMs in that group, the appliance VM from the Hyper-V host's own inventory, the
workload group, and the subscription when none is current.

### 19. Step 2 no longer asks for a target resource group

Every use of `-TargetResourceGroup` in `migrate-step2-discover-assess.ps1` was traced: a
pre-flight existence check, and reading the group's region for `Resolve-LabLocation`. Nothing
else. Discovery and assessment never write to the landing zone.

The assessment body confirms it - the field Azure Migrate consumes is `azureLocation`, a region,
not a resource group:

```
sizingCriterion       = "AsOnPremises"
azureLocation         = $Location
currency              = $AssessmentCurrency
reservedInstance      = "None"
azureOfferCode        = $AzureOfferCode
azureHybridUseBenefit = $AzureHybridBenefit
```

So step 2 was asking for a resource group in order to learn a region. The parameter, the prompt,
the pre-flight check and the `Assert-LabResources` argument are all removed, and the region is
read from the source resource group instead. `migrate-step3` onwards still ask for the target
group, because those genuinely deploy into it.

### 20. A default that Enter accepts, for lab-wide settings only

`Read-LabParameter` gained `-Default`. A prompt carrying one shows it in square brackets and
Enter accepts it:

```
Assessment currency [USD]:
Azure offer (pricing agreement) for the assessment [MS-AZR-0003P]:
```

This applies to the two assessment pricing settings, which the unmodified lab hardcoded to the
same values. They are properties of the workshop rather than of anyone's subscription, so a
learner confirming them is not inheriting someone else's environment.

The distinction is deliberate and the prompt header now states it: a value in `[brackets]` is a
lab default that Enter accepts; an `(example: ...)` is a hint that must be typed. **No resource
name carries a default** - resource groups, projects, VM names and the appliance name must all
be entered or chosen, because those differ per learner and a silently inherited name is the
failure this was built to prevent.

Azure Hybrid Benefit deliberately keeps its Yes/No question with no default. It changes the cost
figures the assessment reports, and answering it is part of the exercise.

Three assessment values remain hardcoded, as they were in the unmodified lab: `sizingCriterion`
is `AsOnPremises`, because performance-based sizing needs days of utilisation data this lab does
not produce; `reservedInstance` is `None`; and the group and assessment are named
`AllServers-Group` and `Workshop-Assessment`.

### 21. Appliance selection moved after the pre-flight

Moving the appliance question earlier (section 11) put it above the line that defines
`Invoke-HostScript`, so the call failed at run time:

```
Invoke-HostScript : The term 'Invoke-HostScript' is not recognized as the name of a cmdlet...
```

A PowerShell script runs top to bottom, and a function exists only once execution passes its
definition. The parser accepts the call without complaint, so `check-lab-scripts.ps1` did not
catch it either.

The block now sits between step 1 and step 2, which is where it belonged on its own merits: the
helper functions are defined, the pre-flight has confirmed the Hyper-V host exists and is
running, and the appliance name is settled before the project key that needs it. The earlier
placement also queried the host before anything had verified the host was up.

### 22. check-lab-scripts.ps1 now catches calls made before their definition

The parse check could not see the fault above, because it is not a syntax error. The checker now
walks each script's syntax tree, records the line that defines each function, and reports any
call to one of those functions made at script level on an earlier line. Calls inside another
function body are ignored: those run later, by which time every definition in the file has been
processed.

Output names the call site and the definition:

```
FAIL  migrate-step2-discover-assess.ps1  (1 call(s) before definition)
      line 741: 'Invoke-HostScript' is called here but not defined until line 811
```

### 23. A valid resource group reported as not found

A resource group that plainly exists could be rejected at the prompt. The lookup was correct;
where it looked was not.

`Get-LabAzContext` only offered a subscription when the session had **none** selected. A session
already pointing at a subscription was used as it stood - deliberately, so an existing
`Set-AzContext` was never second-guessed. The flaw is that an account with several subscriptions
is easily pointed at the wrong one, and the Azure portal spans every subscription: a group that
is obviously there in the portal can be genuinely absent from the one the script is querying.
`Get-AzResourceGroup` then returns nothing, correctly, and the prompt says not found.

Three changes:

**The subscription is confirmed at startup.** When the account has more than one enabled
subscription, the current one is named and confirmed before any prompt. Answer No and the
others are listed. An account with a single subscription is not asked.

**A failed lookup says where it looked.** The message now names the subscription rather than
saying "this subscription", so a wrong context is visible rather than inferred.

**A failed lookup offers to find the group.** It can search the account's other enabled
subscriptions for that name and, when it finds one, offer to switch to it - then re-check the
same name without asking for it again. The original context is restored if the search is
declined or finds nothing.

It also lists resource groups in the current subscription whose names resemble what was typed,
capped at eight, which catches a plain typo without printing the whole subscription.

### 24. Two more checks in check-lab-scripts.ps1

Alongside parse errors and calls made before their definition, the checker's companion scan now
also looks for `*-Lab*` helper functions that are called somewhere in a file but never defined
in it. Every migrate-step script inlines its own helpers, so a helper that exists only in
`common.ps1` resolves during development and fails at run time for a learner. That class would
otherwise reach a live run.

### 25. common.ps1 and migrate-common.ps1 are gone

Two shared files have been removed. Delete both from your checkout.

**`migrate-common.ps1` was never loaded by anything.** Every migrate-step script already carries
its own copy of the helpers, so the file was a reference document that looked like a dependency.
Its copy had drifted from the live ones twice during this work, which is the failure mode of a
file nobody executes: it reads as authoritative and is not.

**`common.ps1` had exactly one consumer.** Only `deploy-lab.ps1` dot-sourced it; `health.ps1`,
`cleanup-lab.ps1` and the migrate-step scripts never did. All fifteen of its functions are now
defined inside `deploy-lab.ps1`, under a banner marking where they came from. All fifteen were
needed: five are called by `deploy-lab.ps1` directly, and the rest are called by those five
(`Compress-LabScript` by `Read-LabHostConfiguration`, `Invoke-LabImageCatalogGet` by
`Get-LabWindowsImages`, and so on).

`deploy-lab.ps1` is longer for it. That is the trade asked for: one file to open instead of two
to keep in step.

**Two files are still read from disk, and have to be.** `host/configure-host.ps1` is the payload
that runs on the Hyper-V host, and `health.ps1` is spliced into that payload by
`Read-LabHostConfiguration` before it is sent. Inlining either would mean holding its text
inside `deploy-lab.ps1` *and* keeping the live functions as well, so the same code would exist
twice in one file. That is worse than two files, so they stay as they are.

Verified after the move: no function in `deploy-lab.ps1` is called before the line that defines
it, and the five helpers it takes from `health.ps1` are all used after the line that
dot-sources it.

### 26. migrate-step1 no longer creates an unusable Azure Migrate project

Generating a project key failed in the browser with:

```
TypeError: Cannot read properties of undefined (reading 'properties')
migrateProjectId: ".../providers/Microsoft.Migrate/migrateprojects/<project>"
```

That is portal JavaScript, not an Azure error. Nothing was ever submitted to Azure, which is
why the activity log shows nothing and why no policy or permission check finds anything wrong.

**Cause.** `New-AzMigrateProject` creates a bare `Microsoft.Migrate/migrateProjects` resource
and nothing else - its own documented output confirms the type. Creating the project **in the
portal** also registers the tool solutions the project needs:
`Servers-Discovery-ServerDiscovery`, `Servers-Assessment-ServerAssessment` and
`Servers-Migration-ServerMigration`.

Without those, the project exists and looks correct in the resource group, but the Generate key
blade reads the discovery solution, gets `undefined`, and throws before it can submit anything.

**Second consequence, same cause.** `migrate-step2`'s assessment stage writes to
`Microsoft.Migrate/assessmentProjects/<name>` - a resource created as part of tool registration,
not by `New-AzMigrateProject`. A project created in PowerShell would have failed there too, after
the appliance work was already done.

**This was inherited, not introduced.** The unmodified lab's `migrate-step1` called
`New-AzMigrateProject` the same way.

**Change.** `migrate-step1` no longer creates the project. When the named project is absent it
prints the portal steps - resource group, project name and the matching geography already filled
in - and says why, which is what Module 1 section 1 instructs anyway. An existing project is
still detected and used. A project that looks right and cannot be used is worse than no project.

`Write-ManualAction` was only defined in `migrate-step2`; it has been added to `migrate-step1`
beside `Write-NextSteps`. The companion scan in `check-lab-scripts.ps1` catches exactly this.

**If you have a broken project,** it cannot be repaired from the portal UI - the blade that would
repair it is the one that fails. Delete it and create a replacement in the portal under the same
name, or use a new name.

### 27. Host preparation for discovery is automated (Module 1 section 2)

Deployment now applies Module 1 section 2 itself, as a new PHASE 7 in `configure-host.ps1`.
Microsoft's table of what its host-preparation script does maps to five items; four are applied,
one deliberately is not:

| Item | Applied | Why the appliance needs it |
|---|---|---|
| WinRM service, ports 5985/5986 | Yes | Carries the CIM session that collects guest metadata |
| PowerShell remoting | Yes | Lets the appliance run commands on the host, not merely connect |
| Discovery account | Yes | Host administrator, plus Remote Management Users, Hyper-V Administrators and Performance Monitor Users |
| Hyper-V Integration Services | Verified | Supplies each guest's OS detail and IP |
| CredSSP delegation | **No** | Only for guest disks on remote SMB shares. These are local, and CredSSP relays credentials to the host |

That confirms the reading that CredSSP is the only item that should be declined.

**Two deliberate differences from running the script by hand.** WinRM stays scoped to the nested
lab subnet - Microsoft's script opens 5985/5986 unscoped, and there is no reason to widen the
host. And the lab user is already a host administrator, which satisfies the account requirement
on its own; the three groups are added anyway so the least-privilege path can be demonstrated.

**Why the steps are applied directly rather than by driving the script.** The script is
interactive, and a Run Command session has no console. Answers cannot be piped to it either:
`Read-Host` reads the console, not the pipeline. So each item is applied directly and
idempotently, and Microsoft's script is then downloaded, **Authenticode-signature verified**
(more durable than a published hash, which changes each release) and run as a verifier inside a
job with a **300-second timeout**. Without that timeout an interactive prompt would hang the
whole deployment.

The script stopping at a prompt is expected and is logged as such, not as a failure. Its output
goes to `C:\AzMigrateLab\hyperv-prep-output.txt`; the state of every item goes to
`C:\AzMigrateLab\hyperv-prep.json`. Both are quoted in Module 1 section 2 as the first place to
look when the appliance cannot reach the host.

**Module 1 section 2 rewritten** with a per-option table: what each prompt does, and what breaks
if it is skipped. Sections 2.1 and 2.2 separate Microsoft's script from what deployment did
differently.

### 28. The appliance VHD downloads during deployment

The appliance VHD is published at a fixed link and does not depend on the project key - only
*registration* does. The ~11 GB download now starts as a background job at the beginning of
PHASE 2, so it runs alongside the OS image downloads instead of costing a separate wait in
Module 1, and is collected in PHASE 7.

The store partition already exists when `configure-host.ps1` starts - `deploy-lab.ps1` creates it
earlier in the run - so it is found by its `ApplianceStore` volume label rather than by assuming
a drive letter. The archive is downloaded, extracted, and its SHA256 recorded in
`E:\Appliance\download-complete.json`.

`curl.exe` is used rather than `Start-BitsTransfer`, because BITS fails in the non-interactive
SYSTEM context this script runs as. This matches what `migrate-step2` already does for the same
archive, including `--continue-at -` to resume a dropped transfer.

The whole thing is best-effort: nothing later depends on it, and Module 1 section 3.3 still works
unchanged if it did not run.

**One module change was unavoidable.** Section 3.3's `Expand-Archive` had no `-Force`, so it
would now fail on the pre-staged files. It has been added, along with a note that the archive is
usually already present and that the recorded SHA256 must still be compared against Microsoft's
published value - a hash is only worth something checked against the vendor's.

The import is **not** automated. Section 3.4 still builds the VM by hand, and `migrate-step2`
still imports it on the automated path.

### 29. Every script states which module steps it completes

The scripts and the modules are run separately, so a script that silently overlaps a module
step - or silently skips one - is a trap. Each script now carries a `MODULE COVERAGE` block in
its comment-based help, visible with `Get-Help <script> -Full`, and the README carries the same
mapping as a table.

Each block names the sections completed, and - more usefully - the ones NOT completed and why:

- `migrate-step1` does not create the project (section 26); it prints the portal steps.
- `migrate-step2` stops at Module 1 section 3.1: the project key is issued interactively.
  Registration in section 4 is a browser sign-in on the appliance and is printed, not driven.
- `migrate-step3b` reaches Module 3 sections 8 to 11 but does not perform sections 5 to 7 -
  the replication appliance and Mobility Service - because it gets there agentlessly.
- `migrate-step4` does not perform the in-guest validation those sections describe. It confirms
  the test VMs exist and are healthy; whether the application works is still yours to check.
- `migrate-step5` does not perform post-cutover validation, which is the point of the exercise.
- `migrate-step6` skips the discussion sections, and tolerates a partial estate.
- `cleanup-lab` leaves the Migrate project, key vault and recovery services vault behind. Those
  hold their names against a future lab, so they are worth removing by hand.
- Nothing automates Module 4: it is analysis, with no lab state to reach.

Every section number in these blocks was checked against the module files rather than written
from memory.

### 30. migrate-step2 checks host preparation as well as the appliance

**The appliance was already skipped.** `migrate-step2` lists the VMs on the Hyper-V host and
sets `$doImport` from whether the chosen name is among them. When `MigrateAppl` is already
there, the download, the SHA256 prompt, the extract and the import are all skipped, and the
script logs that it was not recreated. It then checks the existing VM against Module 1's
specification rather than trusting it: state, vCPUs, memory, dynamic memory off, disks on the
store drive, virtual disk size and virtual switch. A re-run against a prepared host is cheap.

**Host preparation was not checked at all.** That gap mattered more once deployment started
applying Module 1 section 2 itself, because the two tracks are run separately: a host built
another way, or one where PHASE 7 failed, would reach discovery and find nothing, with no
earlier signal.

`migrate-step2` now checks it, before the appliance download rather than after, so a problem
costs seconds instead of 11 GB:

- whether `hyperv-prep.json` exists, which tells you whether deployment applied section 2
- the Hyper-V role
- the WinRM service, status and start type
- PowerShell remoting, by looking for a WSMan listener
- Heartbeat and Key-Value Pair Exchange on each guest that is present

Everything found is logged. If WinRM or remoting is missing it offers to apply them; answering
No continues with a warning. A missing Hyper-V role is reported but not fixed - that needs a
restart, so it says so and tells you to rerun.

The guest group memberships are not re-checked here, because this script does not know which
account the lab was built with. `hyperv-prep.json` records it, which is why its presence is the
first line of the report.

### 31. Three faults found by the first real check-lab-scripts run

#### Encoding: four scripts could never parse in Windows PowerShell 5.1

`migrate-step3`, `step4`, `step5` and `step6` contain box-drawing characters, emoji and curly
quotes - 6, 785, 1509 and 1467 non-ASCII bytes - and had **no UTF-8 byte-order mark**. Windows
PowerShell 5.1 reads a BOM-less file using the ANSI code page, so those bytes arrive as
mojibake and break string terminators and brackets. The reported faults were things like
`Unexpected token '€" * 50)` on a line that reads `Write-Host ("─" * 50)`.

**This is pre-existing, not a regression.** The originals in adjustments2 have no BOM either, so
these four have never been runnable in Windows PowerShell. They would work in PowerShell 7,
which assumes UTF-8.

Fixed by rule, not case by case:

- **Directly-invoked scripts** keep their characters and gain a UTF-8 BOM. Nothing about their
  output changes.
- **Payload files** must stay pure ASCII. `host/configure-host.ps1` is spliced into a Run
  Command string and never runs from disk, so a BOM would land inside the payload. Its five
  em-dashes - all in comments - are now hyphens.

`check-lab-scripts.ps1` now applies the same rule, so this cannot ship again.

#### A leaked console proxy could kill an unrelated script

```
Write-Host : The variable '$script:LabMaskedValues' cannot be retrieved because it has not been set.
At ...\deploy-lab.ps1:286 char:9
```

`deploy-lab.ps1` does not define `Write-Host` and does not use `$script:LabMaskedValues`. The
`Write-Host` that ran was the masking proxy from a migrate-step script, still present in the
session. Its defining scope was gone, so `$script:` resolved to `deploy-lab.ps1`'s scope, where
the variable does not exist - and `deploy-lab.ps1` sets `Set-StrictMode`, which turns reading an
unset variable into a terminating error. A console-formatting helper killed a deployment.

`Protect-LabText` now resolves the list with
`Get-Variable -Name LabMaskedValues -Scope Script -ValueOnly -ErrorAction SilentlyContinue`
instead of reading it directly. Unset yields nothing rather than an error, so the worst case is
text that was never masked rather than a script that stops. Applied in all eight scripts that
carry the proxy.

**Immediate workaround if you hit it again:** open a fresh PowerShell window. The proxy only
exists in a session where a migrate-step script has already run.

#### The checker was crying wolf

It reported `Initialize-LabProgress`, `Write-LabHealth`, `Wait-LabJob`, `Wait-LabManagedSetup`
and `Complete-LabProgress` as undefined in `deploy-lab.ps1`, and four similar in
`configure-host.ps1`. All nine are false. `deploy-lab.ps1` dot-sources `health.ps1`;
`configure-host.ps1` has `health.ps1` spliced into it at the `# LAB_HEALTH_HELPERS` marker
before it is sent to the host.

The checker now follows both: it walks dot-source commands and resolves the target, and it
treats the splice marker as importing `health.ps1`. A checker that reports faults which are not
faults gets ignored, which is worse than no checker.

### 32. deploy-lab.ps1 launches the same way from a window or a right-click

**The two banner lines about the appliance store and the fixed guest disks are removed.** The
detail is in Module 0; it does not need restating every run.

**Launch resilience.** A right-click *Run with PowerShell* starts a fresh process whose window
closes the moment the script ends - taking the summary, or the error, with it. An open window
keeps its output but may be carrying state from an earlier script. Both are now handled:

- A `trap` writes the failure to `deploy-lab-error-<timestamp>.log` beside the script, with
  every GUID redacted, then holds the window open. The subscription ID is never written to disk.
- The window is held open on **success** too. The summary is the point of the run.
- `LAB_NO_PAUSE=1` skips the pause for an unattended run.

**The cause of the reported failure, fixed at the other end as well.** Running from an open
window was not itself the problem - the problem was what the window was carrying. A
`migrate-step` script defines `Write-Host` and `Write-Warning` as functions so it can mask
subscription IDs on a shared screen, and a function can outlive the script that defined it.
`deploy-lab.ps1` now removes any such override at startup, so an open window behaves exactly
like a fresh one. Section 31 fixed the same fault from the other side, by making the override
unable to throw; this stops it being present at all.

**Launch flexibility of the other scripts, assessed.**

| Script | Right-click | Notes |
|---|---|---|
| `deploy-lab.ps1` | Yes, fully | Prompts for everything, pauses on both paths, clears session overrides |
| `migrate-step1` to `step6`, `step3a`, `step3b` | Yes | Trap, error report and pause already present. Built for an open window - they are interactive throughout - but they do not lose their output on a right-click |
| `check-lab-scripts.ps1` | Yes | Already pauses before closing |
| `cleanup-lab.ps1` | Not recommended | No pause: a right-click window closes on what it deleted. Run it from a window |
| `enable-lab-traffic.ps1` | N/A | Runs on the Hyper-V host, from a session there |

The follow-up scripts were left as they are, per the priority given: deploy must be flexible,
the rest need not be.

### 33. cleanup-lab.ps1 reports what it deleted, and what it cannot

**Launch resilience, matching deploy-lab.** A `trap`, an error report beside the script with
GUIDs redacted, a pause on every exit path, and removal of any leftover console override from
an earlier `migrate-step` run. Losing the record of what a destructive script did is the one
outcome worth designing against, and a right-click window used to close on exactly that.

**It now shows its work.** Before deleting it reads the group and prints every resource,
grouped by type and named, so the confirmation is informed rather than blind. After deleting it
confirms the group is actually gone - the cmdlet returning is not the same as the group being
removed - and prints the summary of what went with it.

**Two failure modes are caught before the confirmation, not after.**

- A `CanNotDelete` lock makes `Remove-AzResourceGroup` fail partway. The script now names the
  locks and stops, rather than asking you to confirm a deletion that cannot succeed.
- A Recovery Services vault holding protected items refuses deletion and takes the whole group
  with it. Any vault in the group is named as a warning before you confirm.

**A closing list of what a resource group deletion does not reach.** Printed on every exit path,
including a cancelled run, because each item causes a confusing failure in a LATER lab:

1. The other lab resource group - there are two, and this script takes one at a time.
2. **Soft-deleted key vaults.** Generating the appliance project key creates one; deleting its
   resource group only soft-deletes it and the name stays reserved. A later lab reusing the
   project name then cannot generate a key, for no visible reason. The check and purge commands
   are printed.
3. **Recovery Services vaults still holding backup items.**
4. **The Microsoft Entra app registration** created during appliance registration. It is not an
   Azure resource; no resource group deletion touches it.
5. **The Azure Migrate project** if it sits outside the groups deleted - an orphaned project
   keeps its name and its appliance can still be registered and calling home.

**A README correction.** The script table claimed cleanup-lab did "preview/confirmed deletion of
explicitly named, tagged groups; refuses vaults and locks". It did none of that: no tag check,
no lock check, no vault check, no preview - just `Remove-AzResourceGroup -Force` after a
yes/no prompt. The entry now describes what the script does, and the lock check it claimed now
genuinely exists.

**A help-block fix.** The `MODULE COVERAGE` block had been inserted immediately after the last
`.EXAMPLE` with no directive between them, so `Get-Help` ran the example text into it. It now
sits under `.NOTES`.

### 34. The static appliance link served a stale image

A deployment log showed the pre-staged appliance extracting to:

```
E:\Appliance\Extracted\AzureMigrateAppliance_v3.20.09.25\Virtual Hard Disks\
  14393.0.amd64fre.rs1_release.160715-1616_server_serverdatacentereval_en-us.vhd
```

Two independent signals say that is not the current appliance:

- **The archive hash did not match.** The run computed
  `40AA037987771794428B1C6EBEE2614B092E6D69AC56D48A2BBC75EEEF86C99A`. Microsoft publishes
  `AD3C72FB21037B10969548228B4F651BF5A79CD0A34D608CD470B75329A24A24` for the current Hyper-V VHD
  zip. This alone is decisive.
- **The VHD is Windows Server 2016.** Build 14393, `rs1_release.160715`, evaluation edition. The
  appliance support matrix requires Windows Server 2022 or 2025 and states that Server 2016 or
  earlier is blocked. A 2016 evaluation image is also long past its 180-day licence.

`https://aka.ms/migrate/appliance/hyperv` is therefore not a safe substitute for the download
link the portal serves. That link came from the unmodified lab's `migrate-step2`; section 28
propagated it into the deployment pre-stage, which is what surfaced it.

#### Two holes this exposed

**migrate-step2 skipped verification for a pre-staged appliance.** The worker began:

```powershell
$vhd = Find-ApplianceVhd
if ($vhd) { Set-Status 'Ready' $vhd.FullName; exit 0 }
```

An already-extracted VHD was accepted and imported without ever reaching the SHA256 check
below it. Worse, the check could not have run anyway: `deploy-lab.ps1` stages the archive as
`MigrateAppl.zip` while the worker only looked for `AzureMigrateAppliance.zip`, so the staged
archive was invisible to it. The two faults together guaranteed an unverified import.

Both fixed. Any `.zip` in the appliance folder is now a verification candidate, and an extracted
VHD is verified against the published hash before it is accepted. A mismatch refuses the import
and leaves the files in place for inspection. Where no archive remains to check against, the
script says so and requires either a fresh download or an explicit `-ApplianceSha256 SKIP`.

**The pre-stage now checks what it downloaded.** The published VHD carries a Windows build in
its file name, so that is read back: below 20348 (Windows Server 2022) the phase logs a warning
naming the problem and telling the instructor not to import it. `download-complete.json` now
records `WindowsBuild`, `LooksCurrent` and `Verified: false`.

This is a heuristic on a file name, not proof. The published hash is what decides, and it is
still the instructor who compares it.

**Module 1 section 3.3 rewritten** to say plainly that the staged copy comes from the static
link, is unverified, has been seen to be stale, and must be checked against Microsoft's published
SHA256 before import - with the project's own download link as the correct source.

#### Not a fault: the host-preparation warning

The same log showed:

```
WARNING: Microsoft's host-preparation script did not run (The Wait-Job cmdlet cannot finish
working, because one or more jobs are blocked waiting for user interaction...)
```

That is the designed outcome. The script is interactive and the deployment session has no
console, so it blocks at its first prompt and the job is stopped. The five prerequisites were
applied directly beforehand, and the log confirms all five: Hyper-V role installed, remoting
enabled, WinRM scoped to 192.168.0.0/24, the discovery account in all three groups, integration
services on all four guests, CredSSP correctly left off. The script's own SHA256 also matched
Microsoft's published value, so the signature and hash checks both did their job.

### 35. The appliance VHD download is now opt-in, and Module 1 speaks to the learner

#### Staging the appliance is a choice, defaulting to No

`deploy-lab.ps1` gained `-IncludeApplianceVhd` (`Yes`/`No`). When it is not supplied the script
asks once and takes **No** on Enter. No is right for a learner: nothing in Module 0 needs the
appliance, it is an ~11 GB download, and Module 1 fetches it from the Azure Migrate project at
the point it is required - which is also the link that serves the current build. Yes is for an
instructor staging a host before a session.

`-ApplianceVhdSha256` accompanies it. When supplied, the staged archive is checked against that
value on the host and **deleted** on a mismatch, rather than left looking ready to import. When
omitted the archive is staged unverified and both the log and `download-complete.json` say so.
Section 34's build-number heuristic still runs either way.

`configure-host.ps1` takes both as parameters and skips the download entirely when the answer is
No, logging that Module 1 will fetch it.

#### Module 1 section 2 rewritten for the learner

The section described what this lab's deployment had done. It now describes what the **learner's
own organisation** will face, because that is the transferable part:

- The direct `aka.ms` script link is gone; the Hyper-V discovery tutorial is still cited, with
  the instruction to verify the script's signature before running it anywhere.
- The per-prompt table keeps the explanation of each item and what fails without it, and drops
  the Yes/No answer column - the answers belong to a run of the script, not to understanding it.
- CredSSP is described as what it is and when an estate needs it, rather than carrying a warning
  not to enable it here. The warning made sense when the table told you how to answer.
- Added: the observation that on a real estate this is usually where a migration stalls, because
  the host belongs to someone else and the discovery account needs an owner.

Section 2.2 is now "In this environment" and opens with the point rather than the mechanism:
our lab environment anticipates the needs the Hyper-V script would account for. The two details
that genuinely differ - WinRM scoped to the nested subnet, and the lab user's group memberships -
are kept, with the scoping framed as a habit worth carrying into an engagement. The explanation
of why the script is not driven directly is gone; it is implementation, and it is in section 27.

#### Section 3.3 trimmed

The staged-appliance warning is now a short note: the archive may already be there, it is a
convenience rather than a verification, check it against Microsoft's published value, and where
to go if it does not match. The observed stale-build detail moved here, to section 34, with a
pointer for instructors. A learner needs the hash-check habit, not the incident history.

#### Module 0 aligned with the same principle

The student now runs **one** script. The `migrate-step1-setup-project.ps1` call was removed from
the Step 4 block and became an instructor note: the target landing zone is still needed before
Module 2's target settings, and can be built in the portal with the students or staged
beforehand. Step 4 also tells the learner to answer **No** to the appliance staging question.

Two "deployment did X" phrasings in Module 1 became "our lab environment", one of them gaining
the more useful instruction to confirm those packages exist in their own estate before relying
on dependency analysis.

### 36. Module 0 claimed NAT gateways that no script creates

Two statements in Module 0 described infrastructure that does not exist:

- *"The target and test NAT gateways created by `migrate-step1-setup-project.ps1` provide
  explicit outbound access without public IPs on the workload VMs."*
- A cost-table row reading *"Two NAT gateways and their public IPs"*.

`NatGateway` and `New-AzPublicIpAddress` appear **nowhere** in `migrate-step1-setup-project.ps1`,
`migrate-step4-test-migrate.ps1` or `deploy-lab.ps1`. No NAT gateway is created by anything in
this lab.

This mattered twice. It overstated the cost estimate, and - worse - it asserted that the thing
the paragraph's own linked article warns about had been handled. Migrated VMs in the target
subnet reach the internet only through Azure's **default outbound access**, which Microsoft is
retiring. A reader who trusted that paragraph would carry the assumption into a design.

Both corrected. The paragraph now states plainly that the lab's landing zone has no NAT gateway
and no firewall, and that a real one needs explicit egress. The cost row reads "None - one host
public IP only".

**The landing zone is also now enumerated** in the Module 0 instructor note, because it is easy
to assume that creating the Azure Migrate project creates it. It does not, and the two are
different planes:

- The **project** - with the key vault, storage account and recovery services vault that
  generating the appliance key creates - is the *management* plane, and lives in the source
  resource group.
- The **landing zone** is the *destination network*: a target resource group, a VNet
  (`10.1.0.0/16`), a subnet (`default`, `10.1.0.0/24`) and an NSG with inbound RDP, SSH, HTTP,
  HTTPS and Node.js rules. Plus registration of `Microsoft.OffAzure`, `Microsoft.Migrate` and
  `Microsoft.KeyVault`.

The note also records which parts Module 2's replication wizard can create inline - the resource
group and the storage account - and which it cannot: the **VNet and subnet are selected from a
dropdown and must already exist**. That is the constraint that decides whether the landing zone
has to be staged in advance.

### 37. Module 2 builds the landing zone; step1 becomes optional

Module 2 assumed a target resource group and VNet already existed, and nothing student-facing
created them. Section 36 established why that gap was easy to miss - the Azure Migrate project
creates resources, so it feels like the destination was set up too, when the project is the
management side and the landing zone is the destination network.

**New Module 2 section 4.1, "Build the target landing zone."** Portal steps for the resource
group, the VNet (`10.1.0.0/16` with a `default` subnet on `10.1.0.0/24`), and the NSG with its
five inbound rules, associated to the subnet. The existing 4.1 to 4.3 shifted to 4.2 to 4.4;
nothing cross-referenced them.

It teaches three things the scripted version cannot:

- **Why the address space differs.** Source is `10.0.0.0/16` and the test network in section 8 is
  `10.2.0.0/16`. Overlapping ranges are a common reason a real cutover cannot complete - the VM
  migrates, then cannot reach anything on-premises.
- **That the NSG rules are deliberately open.** Source `Any` on RDP and SSH is a lab decision,
  stated as one, with the note that Module 5 section 4 has them tighten exactly these rules.
- **That there is no egress.** No NAT gateway, no firewall, and default outbound access is being
  retired.

It also states plainly why the wizard cannot cover it: section 5.3 creates a resource group and
storage account inline, but the VNet and subnet are dropdown selections.

**`migrate-step1-setup-project.ps1` is unchanged functionally** and is now described as optional
- the instructor's shortcut to the same landing zone, identical names, ranges and rules. Its
`MODULE COVERAGE` block, the README row and the Module 0 instructor note all now say so, and
point at Module 2 section 4.1 as the place the decisions are actually taught.

**The script-to-module map moved to the top of this file**, above the numbered sections, since it
is reference rather than change history. It remains in `README.md` and in each script's own
`MODULE COVERAGE` block.

### 38. The lab password is entered once for the traffic mesh

`enable-lab-traffic.ps1` asked for the lab password, and then ssh asked again for each Linux
guest, so the same password was typed three or four times in one run.

The script's own prompt is worth keeping - the alternative is deployment writing the lab password
to disk on the host, which is a poor trade for saving one entry. What has changed is that the
password entered there is now handed to ssh instead of being asked for again.

Windows has no `sshpass`. OpenSSH's own mechanism is `SSH_ASKPASS`: ssh runs a named program and
reads the password from its output. `SSH_ASKPASS_REQUIRE=force`, which makes ssh use it even when
a console is attached, arrived in **OpenSSH 8.4** - so `ssh -V` is parsed and the interactive
prompt is kept, with a line saying why, on anything older. Windows Server 2022 shipped 8.1
originally, so that fallback is a real path, not a formality.

**The helper holds no secret.** It is a two-line `.cmd` that echoes an environment variable. The
variable is set immediately before the ssh call and removed in the `finally` immediately after,
so the password stays in process memory - where `$passwordText` already held it - and is never
written to disk. The helper file itself is deleted when the script ends.

`sudo` does not add a prompt: the guests are provisioned with `sudo: ALL=(ALL) NOPASSWD:ALL`,
which was verified rather than assumed.

### 39. Portal navigation in Modules 2 and 3 did not match the current experience

Module 2 section 4.2 read:

```
1. Open the Azure Portal.
2. Search for Azure Migrate and select it.
3. Click "Servers, databases and web apps" in the left menu.
```

Two problems. It omitted the step that actually matters - **Azure Migrate is project-scoped**.
Searching for the service lands on a hub page, and no migration tool appears until a specific
project is open. And "Servers, databases and web apps" is the **classic** heading; Azure Migrate
is rolling out an **Explore / Decide / Execute** experience that reaches tenants at different
times, so that label is not what many people now see.

Module 1 already carried the portal-variance caveat. Modules 2 and 3 did not, and both also
skipped the project selection.

**Module 2 section 4.2** is now "Open your Azure Migrate project": search, **All projects**,
choose the Module 1 project, and confirm the subscription - because an account that can see
several subscriptions will often open on the wrong one and show an empty project list. It states
the expected result (the discovered servers from Module 1) and where to go if the count is zero.

**Section 4.3** describes the tool by what it does rather than by its name, and adds the warning
that earns its place here: **Discovery and assessment** and **Migration and modernization** are
adjacent tiles, and selecting the assessment tile at this point is the most common wrong turn in
the module.

**Module 3 section 5.1** got the same treatment, shorter.

The underlying principle, now applied consistently: describe the operation, not the label. Labels
in this service are being actively changed.

### 40. Appliance hash verification moved to the end of the run, and terminology corrected

#### The hash was being asked for before anything could be verified

`deploy-lab.ps1` prompted for the published SHA256 immediately after the opt-in question - before
the download had started, let alone finished. There was nothing to compare against yet, so the
question arrived long before it could do any work.

The host already computes the archive's SHA256 while staging it and records it in
`download-complete.json`. That value is now read back at the **end** of the run and this script
performs the comparison:

```
Azure Migrate appliance staged on the host.
  Location : E:\Appliance
  SHA256   : 40AA0379...
  Compare that against the value Microsoft publishes for the Hyper-V VHD zip under
  "Verify security": https://learn.microsoft.com/azure/migrate/migrate-appliance

  Paste the published SHA256 to verify now, or press Enter to verify later:
```

A match is reported plainly; a mismatch names the file, says not to import it, and points at the
project's own download link. **No RDP to the host is needed** - the value is already on the host
and the script fetches it.

`-ApplianceVhdSha256` still exists for unattended runs. Supplied that way, the host checks during
staging and deletes the archive on a mismatch, which is the right behaviour when no one is
watching.

#### Two different downloads were being described with one name

The prompt said "the Hyper-V appliance archive", which conflates two unrelated downloads:

| Thing | What it is |
|---|---|
| **Hyper-V host-preparation script** | `MicrosoftAzureMigrate-Hyper-V.ps1`, from `aka.ms/migrate/script/hyperv`. A PowerShell script that configures WinRM, remoting and the discovery account on the **host**. Published SHA256 `0AD60E72...` - which the deployment log shows **matched**. |
| **Azure Migrate appliance VHD** | An ~11 GB zip containing the appliance **virtual machine**. Published SHA256 `AD3C72FB...`. This is the one that staged as a stale Windows Server 2016 image with hash `40AA0379...`. |

There is no such thing as a "Hyper-V appliance". The prompts and parameter help now say
**Azure Migrate appliance VHD** and note explicitly that it is not the host-preparation script.
Section 34 named the correct link throughout, but the prompt wording did not, which is how the
two came to look like one thing.

### 41. Appliance download source, and where its hash comes from

#### Source of truth

The Azure Migrate appliance VHD download link and the SHA256 it should have are published
**together, in the same table row**, under "Verify security":

**https://learn.microsoft.com/azure/migrate/migrate-appliance#verify-security**

| Item | Value |
|---|---|
| Download | `https://go.microsoft.com/fwlink/?linkid=2191848` (the "Latest version" link, Hyper-V VHD zip, ~11.4 GB) |
| SHA256 | `AD3C72FB21037B10969548228B4F651BF5A79CD0A34D608CD470B75329A24A24` |
| Recorded | 2026-09-27 |

**That is the page to check first if the hash ever fails.** Both values move when Microsoft
republishes the appliance, and they move together.

#### The download source changed

`aka.ms/migrate/appliance/hyperv` was inherited from the lab this was forked from. It appears in
no Microsoft documentation, and it was observed serving a Windows Server 2016 build with hash
`40AA0379...` - years out of date and outside the appliance support matrix (section 34).

The download now uses the fwlink above. The argument for it is not just that it is newer: it is
published in the same row as the hash it will be checked against, so the link and its expected
value are maintained as one thing. An undocumented redirect has no such guarantee.

Changed in `host/configure-host.ps1` (the staging download) and in the example shown by
`migrate-step2-discover-assess.ps1`.

**One caveat, stated plainly.** The fwlink target could not be confirmed independently from here -
it is a redirect that resolves in a browser, and it does not appear in search results. It was read
off the live article. If a future run downloads something unexpected, that page is the first place
to look.

#### Where the hash comes from, and why it is advisory

There was no published hash anywhere in the scripts before this. The host computed the SHA256 of
whatever it downloaded; the published value only ever arrived by someone pasting it.

The reference value above is now recorded in `deploy-lab.ps1` and compared automatically at the
end of a staging run. It is deliberately **advisory, not authoritative**:

- **Match** - reported as matching the appliance published as of the recorded date.
- **Mismatch** - reported as *ambiguous*, because there are two causes and they need opposite
  responses: Microsoft has republished the appliance (normal - confirm and continue), or the
  download is wrong (do not import). The script says both and points at the article.

Hardcoding it as a pass/fail test would have been worse than useless. Microsoft republishes the
appliance periodically; the first time they did, every run would report a failure for a download
that was correct, and the check would be learned as noise and ignored.

An explicitly supplied `-ApplianceVhdSha256` is still treated as authoritative - the host deletes
the archive on mismatch - because in that case someone has asserted what the value should be.

When a verified hash differs from the reference, the script says so and suggests updating the
constant in `deploy-lab.ps1`.

### Not changed

`cleanup-lab.ps1` and `migrate-step1` through `migrate-step6` are the supplied versions. Modules 2
through 5 are unchanged. No rehearsal launcher is present in this lab; if one is wanted later it can
be modelled on Pull 12's `Start-LabRehearsal.ps1`, and all references to it have been removed from
the documentation rather than left pointing at absent files.

### Known open items

- **README links to `docs/Module-2-HyperV-Migration.md` and `docs/Module-3-Stateful-Migration.md`.**
  Those are Pull 12's filenames; this lab carries the supplied `Module-2-Agentless-Migration.md` and
  `Module-3-Agent-Based-Migration.md`. Deferred deliberately, to be handled with the Module 2/3 work.

### Verification status

Documentation links and heading anchors were checked programmatically, code fences balanced, and the
gzip+base64 traffic payload round-tripped byte-for-byte through the placeholder substitution that
`Read-LabHostConfiguration` performs. PowerShell brace balance, here-string pairing and
cross-file helper resolution were checked statically.

**The scripts have not been executed.** No live Azure or Hyper-V run has been performed against this
revision. The staging preflight, PHASE 6 payload decode, settings-file load and the Node, Nginx and
SQL portions of the traffic mesh in particular should be exercised in a training subscription before
partner delivery.
