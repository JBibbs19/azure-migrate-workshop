# Documentation release validation — 2026-10-14

## Current: student introduction and root Version Notes integration

**Scope:** 62 files; one root `CHANGES.md` → `VersionNotes.md` rename with edited
content and 10 same-path edits, **0 genuinely added / 0 genuinely deleted**.
The other **51 files are byte-identical** to the private 62-file prechange archive.
Same-path edits are README, four script comment/help references (deploy, Step 1,
Step 3 and host), the existing checker's moved-document source contract, the existing
Python manifest test, this report, baseline manifest and root SHA256SUMS.
Exact inverse replacement restores all four scripts and the checker to their original
bytes. No deployment/migration assessment behavior, SQL, application, WAR/runtime,
workload configuration or traffic-controller behavior changes. The nested application
`CHANGES.md` retains its original filename and bytes. No organizational cleanup.

**Documentation preservation:** the reviewed README is byte-frozen, with its exact
student title/subtitle. Only the new 2026-10-13 documentation log entry is amended for
integration accuracy. All 72 historical sections and 18 dated entries retain
their bodies/dates, with heading depth adjusted as reviewed; all 50 numbered sections
(1–41 plus 3a–3c and 4a–4f) remain in order. All 8 transferred README sections
retain their bodies. Exact three top-level Version Notes headings, the bold red
non-distribution warning, local targets/anchors and balanced fences are verified.

**Actually executed:** normal retained Python suites, bytecode disabled, with ordinary
fixture writes and subprocess stdin pipes: **14 application + 16 integration = 30 passed**
on this branch; **60 distinct retained tests across both branches**, zero skips,
errors or failures. No readonly monkeypatch, test disabling or dependency installation.
Additional private source/document checks: **262 on this branch**. Those are literal,
byte-preservation and source-contract checks, not native/runtime fixture execution.
The initial normal Ubuntu integration run exposed its historical ledger's literal
old-name path/inventory check. Only that same manifest test was made rename-aware;
all prior hashes and test registrations were retained. The final complete normal
suite results above supersede that initial single failure.

**Native limits:** **169 PowerShell groups DEFINED, SOURCE-INSPECTED, NOT EXECUTED**;
no group was added or removed. Only the existing regional documentation contract now
reads VersionNotes instead of the moved README section. PowerShell is unavailable;
no native parser, AST fixture, native helper/mock or checker execution is claimed.
No Java/JSP compilation, guest/Tomcat/SQL/systemd, Azure/Az, Hyper-V/appliance or live
migration validation was performed. Native and authorized end-to-end lab acceptance
remain required before partner delivery.

**Integrity/provenance:** all 24 original baseline entries and hashes, SQL-seed hash,
original added inventory of 39 and historical previous/archive hashes are preserved.
Root CHANGES is explicitly `status: renamed`, `current_path: VersionNotes.md` with
the actual current hash, never a deletion or a fresh baseline. Historical file maps
retain original path keys with the same explicit current-path mapping. Other baseline
statuses remain unchanged; non-self-referential current hashes are refreshed.
Root checksums cover all 61 other files; unchanged app checksums cover 32 files.
Two independently built sorted fixed-1980 ZIPs match byte-for-byte; CRC, every entry
SHA256/source parity, exact 62-file inventory, checksum coverage and final readback pass.
No fixture/cache/private helper is packaged. Final archive digests are stored outside
this report to avoid self-reference. Staged working ZIPs only; no output write,
publication, upload, send, Git operation or cloud action.

Earlier report text below is preserved verbatim as historical evidence; its release
counts, filenames and reviewed hashes describe those earlier releases.

---

# Branch-ready static validation — 2026-10-13

## Current: Classic Completed assessment optional provisioning metadata (2026-10-13)

**Scope:** exactly **8 existing changed / 0 added / 0 deleted / 62 files**. Changes are
Step 2, the existing checker, README, Module 1, CHANGES, this report, baseline manifest
and root SHA256SUMS. All **54 files outside that scope are byte-identical** to the latest
post-traffic release, including Steps 1 and 3-6, every Step 3 route, deployment, application,
WAR/runtime and traffic/controller guide. Standalone controller, guide, Step 6 and assessment
API originals and the existing output archives/expanded trees remain unchanged. This is a
staged offline release, **not publication**; delivery belongs to a separate owner.

**Reviewed code remains frozen:** Step 2 SHA256
`76b3fd0eeb1cc865cd9dfb34b2a2219b0895becf0822ec18567ce6196e6be6b8`;
checker SHA256 `795be3010e21b179a7b6f89888671216f09cd3a6de69abd6e73aa82e12da2c50`.
Exact source comparison confines runtime edits to new `Get-LabClassicAssessmentState` and
`Get-LabAssessmentCompletion`; all other functions and surrounding runtime source match,
including Modern and the shared response adapter. Initial and final Classic GETs use the
same helper. Nonpending Completed permits absent/null/blank optional provisioning;
Succeeded is the positive populated value. Provisioning/Updating/Accepted remain pending;
other explicit or nonstring values fail closed. Creation PUT success alone is never ready.
All four unique source-linked results, identity/settings, group idle state, exact membership,
mapping stability and final update timestamp checks remain required. Existing matching
assessment names/settings are reused without overwrite; no redeployment/new assessment is
needed for this correction. Earlier mandatory-Succeeded assessment claims are superseded.

**Actually executed:** full normal unmodified retained suites, bytecode disabled:
**14 application + 16 integration = 30 passed on this branch; 60 distinct tests across both
branches**, zero skips/errors/failures. Ordinary private fixtures and subprocess stdin pipes
were allowed and cleaned. The previously repeated two targeted tests per branch are a subset
of these suites, not additional distinct tests. Python/stdlib mocks in retained suites are
not native PowerShell helper or workflow execution.

**Source-only checks:** **75 literal contracts per branch** passed, with UTF-8 BOM/lexical
inspection and exact function/source diff checks. All retained checker registrations remain;
11 `classic-completion/` groups were added, and one retained missing-provisioning expectation
was corrected. Positive optional-field/padded-Succeeded cases, status/pending/failure/malformed
negatives, both final/initial gates, four-result identity failures, settings/group/membership/
mapping/timestamp failures and no-PUT reuse fixtures were inspected in source, not executed.
**169 native groups DEFINED, SOURCE-INSPECTED, NOT EXECUTED** on this branch (158 retained + 11).
No native parser, AST fixture, PowerShell mock/helper, regression checker or native packager
was run; PowerShell is unavailable and no runtime was installed.

**Integrity/provenance and staged archive:** all original 24 baseline names/hashes, SQL-seed
hash and historical previous/archive hashes are preserved. Every non-self-referential current
hash/status is refreshed and verified; the unchanged original added inventory remains 39.
Root SHA256SUMS verifies all 61 other files; application SHA256SUMS verifies its unchanged
32 files. Two independent sorted, fixed-1980-timestamp builds match byte-for-byte. The staged
62-entry archive passes all CRCs, every entry SHA256/source parity, exact inventory, checksum
coverage and final readback. No cache, fixture, private verifier or new helper is shipped.
Final archive digests are recorded separately to avoid self-referential metadata.

**Evidence and limits:** supplied observations show Completed Classic computation, a blank
displayed provisioning field and four Ready exported servers. They do not establish whether
raw API JSON omitted the field or returned null, and do not prove this merged script's
end-to-end execution. No official-document update-date claim is introduced. No Java/JSP,
SQL/Tomcat/systemd, Azure API/Az module, Hyper-V/appliance, guest or replication execution was
performed. Step 3 is unchanged; assessment readiness does not prove replication compatibility.
Run the native checker and an authorized full lab validation before partner delivery.

Earlier report sections describe their own historical releases and limits; their counts and
mandatory Classic provisioning assumptions do not govern this completion-field correction.

---

## Earlier: reviewed post-migration traffic and exact NSG application edges (2026-10-13)

**Scope:** exactly **2 added / 8 existing changed / 0 deleted / 62 files** per package.
Added: `scripts/post-migration-labtraffic.ps1` and `docs/post-migration-labtraffic.md`.
Existing edits: Step 6, the existing native checker, README, Module 5 Section 4, CHANGES,
this report, baseline manifest and root SHA256SUMS. No deployment/app/runtime/Step 1-5
or standalone diagnostic code changes. The release owner changes only these four release
metadata files; reviewed controller/guide and other source bytes remain frozen.

Reviewed controller SHA256: `dad264dccd09e8f109239c8e992b419f36e664ed4ab595bb9bdd3f7efbb88fa4`.
Reviewed guide SHA256: `3c7b93a1f06c2513c10fe6dfc707c058144e15a53dbf82207a1bb28df02c3a86`.

**Executed in this release:** normal, unmodified retained suites with bytecode disabled:
**14 app + 16 integration = 30 passed; zero skips/errors/failures** on this branch
(**60 retained tests across both branches**). The two embedded Linux Python bodies were
compiled and their complete mocked `self_test()` bodies executed: **25 + 3 = 28 fixtures
passed per branch**. The generated Linux wrapper passed `bash -n`;
**25 lexical/source guards and 4 additional mocked read-only/stale-alias cases passed** per branch.
These mocks and lexical checks are not live systemd or native PowerShell execution.

**Integrity/provenance:** the original 24-file baseline names/hashes and historical
previous hashes are preserved. All non-self-referential `current_sha256` records and
statuses are refreshed; the original-baseline added inventory is 39, reflecting exactly
two new files since the 60-file prechange release. Root SHA256SUMS verifies 61 files;
unchanged application SHA256SUMS verifies 32 files. **88 immutable-scope checks passed**:
43 application/runtime/deployment/traffic/Step 1-5 files per branch plus both standalone
assessment-diagnostic copies. All 52 files outside the eight allowed existing edits
remain byte-identical per branch. Tests use normal fixture writes and subprocess stdin
pipes; only private `.static-work` scratch is cleaned, and no cache/helper is packaged.

**Archive verification:** two independent deterministic, sorted, fixed-1980-timestamp
builds matched byte-for-byte. Both resulting 62-entry ZIPs passed CRC, every entry's
SHA256/source parity, root/application checksum coverage and complete inventory checks.
Final metadata is rechecked before the final builds. Publication is a separate owner action;
this offline release operation performs no publisher call.

**Native groups: 158 DEFINED, NOT EXECUTED** (seven new Step 6/controller cases).
PowerShell 5.1/7 is unavailable on PATH: neither the native checker, AST fixtures nor
controller `-SelfTest` was run. No Java/JSP compilation, Az module/cmdlet execution,
VM-agent/Run Command, live Azure/Hyper-V, Windows guest, SQL, Tomcat or systemd runtime
validation was performed. Offline success does not establish live migration, network
reachability or guaranteed Stop/expiry when guest agents are unavailable.

The prior guarded preflight's partial/skipped/error results were environmental guard
limits, not project failures, and are superseded by the complete normal-suite results above.
The first normal release attempt passed Tomcat 30/30 and Ubuntu app 14/14 but found one
Ubuntu integration metadata failure: its historical comparison ledger lacked the two
new-file entries. Metadata only was corrected using null previous hashes for additions,
preserving all 60 original entries/hashes; both full normal suites were then rerun.
Earlier report sections retain evidence/counts for their own historical revisions.

---

# Branch-ready static validation — 2026-10-08

## Current: Step 3 Hyper-V inventory selection (2026-10-08)

**Scope:** exactly 6 existing files changed: Step 3, the existing native checker, CHANGES,
this report, baseline manifest and root SHA256SUMS. **0 added/deleted; 60 files per package;
54 unrelated files byte-identical** against captured pre-edit hashes. The only Step 3
code change is literal `-SourceMachineType 'HyperV'` on its existing discovered-server
query, plus one explanatory comment. Step 2 remains Classic by default with explicit
Modern opt-in. All replication/disk/network commands, VM sizes/configurations, workload
filters/3a/3b wrappers, region guards and Ubuntu 24.04/Tomcat 10.1/Java 17 runtime are unchanged.

**Executed:** retained 14 app + 16 integration tests on each branch, **60 passed total**;
private lexical/source checks verifying literal HyperV on every discovered-server query,
positive call count, exact inverse byte diff and matched branch edit. Native regression
case definitions/counts and UTF-8 BOM were inspected, not executed. Deterministic sorted
1980-timestamp ZIPs, CRC, 60 source/archive file hashes, 59 root SHA256 entries and clean
expanded-tree/readback matching were verified. All other output and the standalone
diagnostic remain byte-identical. No extra file, cache or private helper is packaged.

**Native groups: 151 DEFINED, NOT EXECUTED** (150 retained + 1 Step 3 AST/contract case).
The case checks every Step 3 discovered-server call for exactly one SourceMachineType
parameter with literal HyperV, requires at least one call, and checks both unchanged
wrapper routes/workload filters. Step 2's prior AST/summary check is unchanged.

**Limits:** inventory selection is corrected; later replication cmdlet/module compatibility
and full replication success are **not verified**. No PowerShell 5.1 parser/mocks/packager,
Java/Tomcat/SQL, Azure API/sign-in, Hyper-V or live VM actions were run. No deployment,
Git/remote source writeback, legacy-output or Word-document changes. The user can replace
the matching branch's Step 3 script without redeploying; any subsequent replication error
requires its own command/error diagnosis, not an assumption that this query fixes it.

Earlier sections retain historical evidence and counts for their own revisions.

## Earlier: Classic default restored with live-observed group safeguards (2026-10-08)

**Scope:** exactly 8 existing files changed per branch: Step 2, the existing native checker,
README, Module 1, CHANGES, this report, baseline manifest and root SHA256SUMS. **0 added or
deleted; 60 files per package; 52 unrelated files byte-identical** to captured pre-edit
SHA256 inventories. Distinct Ubuntu 22.04/Tomcat 9/Java 17 and Ubuntu 24.04/Tomcat 10.1/
Jakarta/Java 17 runtimes, apps/WAR/SQL, KVP/network/power/traffic, quotas/appliance and all
other steps remain unchanged. The standalone Test-MigrateAssessmentApi.ps1 remains
byte-identical in working and output; no experimental diagnostic revision is included.

**Restored core:** default Classic grouped Azure VM MachineAssessment 2024-01-15, no
PaaS/application retooling or silent mode fallback. Preserve normalized relevant catalog,
parent 2023-03-15 and child endpoint plan, pinned context, pagination and exact source-ID
mapping. New group PUT is only properties.groupType=Default. Empty Unknown capability is
not rejected before Add. Shared readiness accepts absent/null group provisioning only with
Completed, never overriding explicit failure/malformed/unknown values. Owned-group Add uses
four real assessment IDs; bounded membership confirmation requires exact four/count/idle
and post-membership capabilities. Existing empty/conflicting groups remain preserved;
explicit unused names or verified matching resources are required. Resource-specific 404
absence codes are scoped to their corresponding GET, never parent/list/write or other HTTP
failures. Classic assessment's own Succeeded/Completed/four-result contract is unchanged.

**Supplied live evidence, not a merged-script execution:**
`ApiTest-Classic-20261008-173456-106b8072.xlsx`, AssessmentSummaryAzureVMAssessment, reports
**4 assessed / 4 Ready**, all four workloads, AsOnPremises, USD, West US 2, no reserved
commitment/Windows or Linux benefit/security uplift, and Standard_D2als_v6 recommendations.
The isolated group observations show minimal Default PUT acceptance, a fresh Completed
zero-machine group with Unknown capabilities and absent provisioning, an initial Updated
zero-count response after Add, then Completed/count four/MachineAssessment/exact membership.
The isolated Modern PUT was HTTP 400 MalformedRequestBody; no assessment was created by
that request. These facts justify the focused repair but do not prove full-script handoff,
PowerShell execution, runtime discovery or assessment creation after this merge.

**Executed here:** 14 retained app + 16 integration tests per branch = **60 tests total**.
Private source/encoding/delimiter/contract checks are static inspection, not a PowerShell
AST parser or execution of extracted mocks. Sorted fixed-timestamp ZIPs are built twice,
verified deterministically, CRC checked, all 60 entries compared to source SHA256 and all
59 root integrity entries verified. Clean staged expanded trees and published ZIP/tree
readback match the source. No newly shipped helper/test files or dependency installs.

**Native groups: 150 DEFINED, NOT EXECUTED** on this branch, including all prior
138 groups and 12 Classic-restoration groups. Existing 22 Modern groups remain
explicit-mode tests. Added coverage includes default parameter AST, minimal PUT/live empty
Unknown then exact four, absent/null provisioning versus pending/returned failure/malformed
states, transient Updated zero count, post-member capability bounds, conservative existing
empty-group preservation, PS5.1 empty/singleton/multiple/scalar array shapes, resource/method/
HTTP-specific 404 classification, shared completion group checks without weakening Classic
assessment fields, and no Classic-to-Modern fallback. Exact mapping, appliance exclusion,
context, GET-only retry and all-page results checks remain in the existing checker.

**Not executed here:** native PowerShell 5.1 AST/mocks/packager, Java/Tomcat/SQL, Azure API
reads/writes/sign-in, Hyper-V/appliance/deployment/migration or any live VM changes. No Git,
Code Assessment or instructor Word guide edits. The live proof belongs to the supplied
standalone test; **the merged full script still needs an authorized end-to-end lab run**.
For an already-running lab, update its same full branch and rerun Step 2, not provisioning.
Modern/full-application/PaaS API and advanced architecture work remain deferred.

All earlier entries below are historical. Their Modern-default wording, group capability/
provisioning assumptions and previous native counts are superseded by this revision.

## Earlier: relevant provider-catalog normalization on both branches

**Scope:** only Step 2 catalog helpers/profile consumption, existing native checker fixtures,
README, Module 1, CHANGES, this report, baseline manifest and root integrity list.
Exactly **8 existing files modified, 0 added/deleted, 60 files per branch**, with **52
unrelated files byte-identical** to full captured pre-edit SHA256 inventories. Ubuntu 24.04 / Tomcat 10.1 / OpenJDK 17 / Jakarta Servlet 6.0
remains unchanged. No runtime/host/guest/app/WAR/source/SQL/appliance/region/KVP/traffic or
other-step changes, new shipped files or learner Windows Python requirement were introduced.
Both full ZIPs and matching clean expanded folders are refreshed; legacy output is untouched.

**Catalog contract:** validate namespace/Registered and actual resourceTypes array, then
normalize only the exact routes used by the selected mode. Trim canonical names/tokens,
deduplicate versions and merge valid repeated relevant rows case-insensitively. Irrelevant
malformed/legacy/business-case rows do not invalidate the implemented assessment contracts.
One normalized catalog is used for validation and Modern profile selection; no raw-row
Count==1 gate remains. API tokens need not match a date-only format to be metadata, but
only exact implemented versions can establish selected capability. Parent 2023-03-15 and
Modern 2024-03-03-preview advertisement remain mandatory; 2025/opaque APIs are not selected.
Required malformed arrays/entries fail with canonical resource type, field and index, not
raw values. Optional malformed rows warn/are ignored; fixed read-only endpoint validation
remains mandatory. No registration, guessed API, payload conversion, fallback or write retry.

**Executed:** 14 retained app + 16 integration tests on each branch = **60 tests total**.
Private lexical delimiter/encoding/helper/source-contract checks are source inspection,
**not a PowerShell AST parser or mocked-helper execution**. Sorted fixed-timestamp ZIPs were
built twice deterministically, CRC checked, all 60 entries compared to source SHA256, all
59 root integrity entries verified, and published ZIP/tree readback matched the builds.
No dependencies installed, PowerShell/Java run, Azure reads/writes/sign-in, guest changes,
Git or Code Assessment/Word edits occurred.

**Native groups: 138 DEFINED, NOT EXECUTED** in this branch: 8 added to the prior
130; the old all-catalog duplicate-rejection fixture was corrected. The 16 metadata
fixture groups now include realistic unused rows/opaque APIs/bad shapes/tag maps, duplicate
versions and cased rows, split-row Modern profile proof, required field/row/index diagnostics,
optional malformed metadata plus read-error/no-write gates, dictionary singleton/empty array
preservation, inconsistent required repeated rows, unknown-version/no-downgrade and safe
value redaction. Existing context/path/mapping/membership/payload/completion tests remain.
The existing checker still only extracts whitelisted definitions and uses offline mocks.

**Evidence limitation:** the older generic 'malformed or duplicate API versions' stop did
not identify an offending row/token; no exact live trigger can be inferred. A catalog-only
stop is before submission, not pending computation. This fix removes known structural
false negatives and improves diagnostics, but does not prove service availability/write
acceptance. Modern ServerGroupId interoperability, actual result linkages and IaaS
ManualReview remain unchanged and live-unverified. Run the existing Windows PowerShell 5.1
checker, then an authorized lab validation. Applying this fix needs no guest redeployment.

Earlier sections below are historical; blanket catalog/duplicate rejection assumptions and
native counts there are superseded. Their executions/preservation statements are retained
as evidence for their own revisions, not claims for this release.

## Earlier: Ubuntu 24.04-only Modern MachineAssessmentV2 preview modernization

**Selected implementation:** `-AssessmentMode Modern|Classic`, default Modern only on this
Ubuntu branch. The reviewed inline catalog currently implements **2024-03-03-preview** for
top-level assessmentProjects/assessments GET/PUT and its assessedMachines GET. Actual runtime
provider advertisement is required; unimplemented 2025-09-09-preview is logged/skipped, not
chosen by date or sent another version's payload. Missing availability/metadata failure stops
before group writes; no silent Classic fallback or preview feature registration.

Parent backend LIST/GET remains 2023-03-15, solution GET 2018-09-01-preview, provider GET
2021-04-01; shared machines/group preparation remains the hardened 2024-01-15 exact-four
contract. The latter is factored once for both modes. Modern PUT is top-level (no groups
segment), nested scope/settings with ServerGroupId and nested savingsSettings, integer
scaling/discount and AsOnPremises pricing assumptions. No ARG scope, readonly compute
fields, flat classic offer/reservedInstance or undocumented billing/security writes.

Modern completion reads properties.details.status. The public GET example establishes
that field but not a mandatory provisioningState, so absent provisioning does not falsely
fail or imply success; a returned properties.provisioningState is checked conservatively.
Accepted/Running is not Completed. Terminal/stale/unknown shapes preserve resources and
stop. Four unique top-level results must link via linkages.armId to exactly one known
source/assessment machine per VM, across every pinned page. Completed/unmatched linkages
are SourceUnverified, not failed creation, with safe field/linkage-kind labels only.
Nested returned targets/strategies/readiness/SKUs/cost details are shown as returned;
omissions NoData, no alternative sum or invented units/monthly cost. Source-verified Modern
completion is ManualReview: no verified Azure VM target/strategy selector is implemented,
so no automatic Step 3 handoff. Classic retains its original completion contract explicitly.

**Changed:** 8 existing files: Step 2, native checker, README, Module 1, CHANGES, this report,
baseline manifest and root SHA256SUMS. **0 added/deleted; exact 60-file checkout/package;
52 unrelated files unchanged** from the captured immediate pre-edit inventory. All older
Tomcat source, ZIP and expanded output hashes remain identical. Historical comparison
baseline/archive hashes are retained; new modernization lineage is recorded separately.
Runtime/app/WAR/SQL/four VMs/ports/network/KVP/traffic/quotas/appliance and other steps unchanged.

**Executed:** 14 retained app + 16 integration checks = **30 tests on Ubuntu only**; private
lexical delimiter/encoding/helper/source-contract inspection (not PowerShell AST/compilation
or mocked helper execution); deterministic sorted fixed-timestamp ZIP, CRC/all-entry SHA256,
59 root integrity entries and final published ZIP/tree readback. No dependency installation,
new shipped Python runtime/test file, Git, Office guide or Code Assessment writeback.

**Native groups: 130 DEFINED, NOT EXECUTED** (all 108 retained plus 22 Modern). New fixtures
cover default/explicit mode, metadata/availability/2025 skip, top-level-only assessment PUT,
correct nested payload/enums/integer assumptions, GET/PUT method/API boundaries, same-cloud/
scope/version pagination, exact read-only reuse/conflicts, scope rejection/no fallback,
Accepted/Running bounds, terminal/stale/unknown status, absent/optional provisioning,
source/assessment linkages versus missing/ambiguous/duplicate/foreign IDs, all-page Completed
ManualReview, SourceUnverified distinct from creation failure, nested display/NoData without
fake flat fields/cost sums/units, final membership drift and auth errors. Existing offline
Start-Sleep/Get-AzContext/Invoke-AzRestMethod mocks cannot call Azure.

**Live unknowns:** Modern service acceptance of this classic ServerGroupId; actual result
linkage semantics; deployment/runtime/discovery/RBAC; PowerShell 5.1 AST and native mocks.
No assessment was created here. Run the existing checker on Windows, then validate an
authorized disposable Ubuntu 24.04 lab before release. Do not rebuild/upgrade the running
22.04 lab. Modern server assessment is not full mixed application assessment: the optional
portal exercise is separate, and unverified full application/2025 request APIs, heterogeneous
bundles, automatic waves/PaaS/SQL/web creation remain deferred.

## Earlier: reconcile sparse provider metadata with endpoint-specific APIs

This focused repair supersedes the previous revision's **incorrect uniform parent API
and exhaustive nested-catalog gate**, not its mapping/group/completion safeguards.
The supplied catalog advertises parent `assessmentProjects` **2023-03-15**, but not
2024-01-15. Parent LIST/GET now use only 2023-03-15, checked against actual provider
metadata; machine inventory, classic group GET/PUT/updateMachines POST, grouped
assessment GET/PUT and assessed results retain the documented **2024-01-15** contract.
Solution GET stays 2018-09-01-preview; provider GET stays 2021-04-01. There is no global
version, newest-preview selection, top-level assessment alias or payload/path rewrite.

Actual registered namespace is still required from the runtime provider GET; a pasted
resource-type table without namespace/registrationState does not establish registration.
Missing nested catalog rows warn **not advertised**, not unsupported. A present child
row excluding the fixed version warns support is unverified; the documented read is
still used, not an invented preview fallback. Malformed/duplicate catalog rows and
unadvertised selected parent versions fail closed. The newer top-level
`assessmentProjects/assessments` entry is not evidence for
`assessmentProjects/groups/assessments`; its MachineAssessmentV2 schema is different.

Resolved parent identity/type/Active/Succeeded and all pages of exactly four unique
source-ID machine mappings must succeed before group writes. Group and assessment
preflight GETs remain required. A 404 for an unused group after valid backend/inventory
reads is consistent with new-group creation, not proof of unsupported API. Explicit
InvalidApiVersionParameter/NoRegisteredProviderFound/InvalidResourceType/UnsupportedApiVersion
errors stop without version fallback/retry; parent/scope-not-found codes never become
new-child writes. Read success does not promise write/RBAC acceptance. Group ownership,
exact membership, existing-assessment preservation, Completed/four paginated results,
context safety, immediate Step 6 failure and no replication on failure are retained.
Pagination also explicitly pins each continuation to its original API version.

**Verified scope:** 8 existing files modified, 0 added/deleted, **60 files per branch**;
**52 unrelated files byte-identical** to the immediate pre-repair inventories. Host/KVP,
guest/app/runtime/WAR, baseline SQL and all other steps retain their bytes; Ubuntu
22.04/Tomcat 9 and Ubuntu 24.04/Tomcat 10.1/Jakarta remain distinct. Baseline/previous
archive hashes stay historical. Root integrity lists have 59 entries each.

**Executed:** 14 retained app + 16 integration checks per branch = **60 tests total**;
private lexical/source-contract and fixed-request-plan checks (not PowerShell execution),
sorted/fixed-timestamp ZIP CRC/all-entry SHA256 checks and final published ZIP/tree readback.
No install, runtime/WAR rebuild, new shipped Python file, Git or Office edit occurred.
**Native groups DEFINED, NOT EXECUTED: 105 Tomcat / 108 Ubuntu**, including 8 new
provider-metadata fixtures each; prior 97/100 groups remain with the invalid provider
assumption corrected. New fixtures cover the supplied sparse metadata shape, explicit
child-version omissions, no top-level aliasing, malformed/duplicate rows, registration,
endpoint versions/methods, parent paging, read-only gates and authoritative API/scope errors.

**Not verified live:** PowerShell AST/native helper tests, Azure reads/writes, group or
assessment creation, portal visibility and Java/SQL runtime. Template/catalog evidence
supports the selected parent contract; it is not a claim that a live 2023-03-15 GET was
executed here. Keep the running lab, update its same full branch and rerun Step 2 with
its actual existing backend name when required; never infer assessment target region
from project/resource geography. Run native checks and review completed results before
replication. See Module 1 for endpoint-specific Microsoft references.

## Earlier: correct classic assessment backend and machine/group/completion contracts

The parent-version and exhaustive catalog gate in this earlier revision were incorrect;
the current repair above supersedes those support claims. Historical counts remain below.

This supersedes the earlier authentication-only fix. Both branches now resolve the actual
assessment backend through the selected Migrate project's assessment solution reference;
there is no migrate-name/assessment-name assumption or same-name 404 fallback. A missing
or malformed association lists all existing same-scope backends and stops for explicit
`-AssessmentProjectName`, never silently picking even one. Active/Succeeded identity/type
and registered provider API support are verified before writes. Endpoint versions are tied
to the documented contract: solutions 2018-09-01-preview, provider metadata 2021-04-01,
classic assessment project/inventory/group/assessment/results 2024-01-15. The published
2023-03-15 version is not labeled obsolete or blamed for a missing resource. This remains
classic Azure VM MachineAssessment, not modern logical-application/PaaS/wave previews.

All inventory/result pages are read with pinned same-cloud/scope/collection/API validation,
duplicate-link/query rejection and safe bounds. Four distinct OffAzure Hyper-V source IDs
must map uniquely via discoveryMachineArmId to real assessment inventory IDs. Group create
contains only Default/supported MachineAssessment; POST updateMachines Add uses those full
assessment IDs only after new-group provisioning and ownership/membership checks. Existing
exact groups/settings are reused read-only; existing empty/extra/different memberships,
invalid/stale/conflicting settings and busy unrelated assessments are preserved. Optional
explicit unused group/assessment names avoid conflicts. No project creation, provider
registration, membership removal/DELETE, wildcard eTag or atomic-concurrency claim occurs.

Step 6 logs each resolver/mapping/provisioning/membership phase and reports failure immediately.
The Step 7 continuation pause is gone. Accepted requests or matching assessments enter
bounded polling automatically; failure/pending group work skips Step 7. Resource creation
is not computation completion: status=Completed (not stage), succeeded provisioning,
exactly four complete unique source-matched result rows and final unchanged resource/settings/
source mapping/membership are required for ResultsReady and Step 3 guidance. Pinned context,
no manual token handling, safe service messages, bounded Retry-After and one transient GET
retry remain; writes are never blindly retried and operation URLs are not followed.

**Scope:** exactly 8 existing files change per branch: Step 2, native checker, README,
Module 1, CHANGES, this report, baseline manifest and root SHA256SUMS. **0 new/deleted files;
60 per checkout.** Immediate pre-edit SHA inventories verify every unrelated source byte,
including distinct Ubuntu 22.04/Tomcat 9 and Ubuntu 24.04/Tomcat 10.1/Jakarta assets,
guest/app/KVP/host/deployment/quota/region/appliance/filter and Steps 1/3–6. Historical
baseline and archive reference hashes remain historical, not regenerated.

**Executed:** 14 retained app + 16 integration tests per branch = **60 tests across both**.
Private lexical/source inspection is not PowerShell parsing or helper execution. Deterministic
private stdlib packaging verifies sorted fixed timestamps, CRC, exact 60 files and all 59
root checksum entries; ZIP and clean expanded published copies match the verified source.
No package installation, runtime/WAR rebuild, Git operation, Office guide writeback or new
published Python file occurred. Native package generation was not used.

**Native groups DEFINED, NOT EXECUTED:** 97 Tomcat / 100 Ubuntu (75/78 retained,
22 new backend-contract groups). Existing auth/context/secret/error fixtures remain; old
workflow contracts are updated, not disabled. Added mocked fixtures exercise generated
linked backend names, true 404/no fallback, missing association with zero/one/multiple
candidates, explicit/conflicting/malformed links, provider/API gating, case-insensitive
exact mapping and duplicate/foreign/missing IDs, correct create/POST/wire pricing contracts,
exact reuse versus conflict preservation, busy/stale/invalid settings, bounded 202 waits,
write failures/no retry, Completed versus review stage, complete pagination versus partial/
duplicate/foreign results, unsafe nextLinks/query/path/method denial, Retry-After/secret
headers, read failures/final membership drift, and immediate Stage 6 reporting/no pause.
Offline Start-Sleep/Get-AzContext/Invoke-AzRestMethod mocks cannot contact Azure.

**Not executed:** Windows PowerShell 5.1 AST parser/native helper groups/.NET packager,
Java/JSP/SQL runtime, live Azure/Hyper-V/appliance assessment or migration. Before live use,
run the documented native parser/regressions and test in an authorized lab: solution linking,
actual provider metadata/inventory synchronization, group provisioning/membership, assessment
status/settings and fully paginated four-machine results; RBAC/auth/context errors and shared
resource conflicts must fail closed. No live creation success or portal full-new-experience
coverage is claimed. Preserve the existing lab and rerun Step 2, not deployment.

## Earlier: assessment authentication/completion fix — both maintained branches

Focused Step 2 group PUT, assessment PUT and resource/results GET now use
`Invoke-AzRestMethod -DefaultProfile` with a pinned original account/tenant/subscription/cloud.
There is no token unwrapping/manual bearer header. Az 14 / Az.Accounts 5 documents the
SecureString change behind the old code's compatibility defect; **the user's installed
version and live failure cause were not inspected**. No tenant credentials or live VM/Azure
operations are used. HTTP/error-JSON/response shape/provisioning failures are checked;
authentication is never hidden as computation, writes are not blindly retried, and a group
failure/pending response gates assessment PUT. Only submitted assessments are polled,
with a single transient/unverified GET retry. Accepted/202, confirmed creation and pending
results have distinct states; failed/unverified output cannot claim completion or hand off
to replication. The portal manual route and same-settings Step 2 recovery retain the lab.

Exact current changed files: `scripts/migrate-step2-discover-assess.ps1`,
`scripts/check-lab-scripts.ps1`, `README.md`, `docs/Module-1-Discovery.md`, `CHANGES.md`,
this report, `tests/baseline-manifest.json`, `SHA256SUMS`. **8 changed, 0 added/deleted,
60 files per branch.** Comparison with captured immediate pre-fix SHA256 inventory proves
all unrelated bytes unchanged, including each branch's distinct OS/Tomcat/Jakarta/app assets,
host/deployment/KVP/network/quota/appliance and Steps 1/3–6. Historical manifest baseline
and original archive digest remain intact.

**Executed: 30 retained tests per branch / 60 across both** (each 14 app + 16 integration),
including existing `bash -n`, source/encoding/SQL-seed/runtime/integrity checks. Private
Python lexical delimiter/quote and direct source-contract inspection are **not PowerShell
parsing or helper execution**. Deterministic stdlib packaging verifies sorted fixed-timestamp
entries, ZIP CRC, exact 60-file inventory and all 59 root SHA256SUMS entries; the clean
expanded tree and actually published ZIP/folder match source bytes. No runtime/WAR rebuild,
install, Git operation, existing-document writeback or extra shipped file occurred.

**Native groups defined, not run:** 75 Tomcat 9 (57 retained + 18 assessment), 78 Ubuntu
24.04 (60 retained + the same 18). New fixtures cover 200/201, 202/provisioning pending,
null/malformed/status/JSON shapes, nonthrowing and thrown auth failures, RBAC/schema/404/
409/transient distinctions, every identity/cloud drift field, missing cmdlet/context, external
path denial, secret-safe errors, actual mocked group-to-assessment gating, no write retry,
GET Content.value parsing and failed provisioning. Poll/final completion are labeled source
contracts plus isolated success-condition fixtures, not complete Step 2 execution.

**Not executed:** Windows PowerShell 5.1 AST parser, native helper/mock groups or .NET
packager, Java/JSP/SQL runtime, live Azure/Hyper-V/appliance discovery/assessment/migration.
Before live use run the documented native parser/regressions, then in an authorized
training lab test expired/rejected sign-in, context drift, group/assessment RBAC/schema
failure, 202/404 pending, 409 conflict, results-read auth failure and created-but-computing
results. Confirm actual ARM assessment-project name, machine IDs/group schema/API version,
resource creation and reviewed results. These retained service assumptions are not proven
by this authentication fix. Use the same branch and rerun Step 2, not deployment/rebuild.

## Earlier branch validation (history; counts below belong to earlier revisions)

## Deliverable and scope

**azure-migrate-workshop-ubuntu2404.zip** is a complete separate **60-file** source tree,
not a patch overlay or app-only package. Both nested Linux guests use Noble/Ubuntu 24.04;
Linux-App uses Ubuntu Tomcat **10.1.x**, explicit **OpenJDK 17** and Jakarta Servlet
**6.0** / Pages **3.1**. Java SE `javax.sql`/`javax.naming` remain unchanged.
At the preceding Ubuntu rebuild, the original Tomcat package and older deliverables were unchanged; SHA256
inventory comparison is performed independently of the new revision's manifests.
No live lab, Word guide, repository remote or assessment document is modified.

The new revision preserves all four guest names/IPs, fixed disk sizes, CPU/RAM, Windows
2022 host/IIS/SQL, NAT/reservations, separately imported appliance/store, SQL schema/seeds,
restricted shared login, protected credential flow, 3000 app/8080 proxy and API contracts.
Exact-kernel KVP install/binary/mask/stop-until-reboot, joint three-observation acceptance,
final recheck and Step 2 independent strict all-four read-only host gate are retained.
Explicit HyperV inventory, actual VM/VNet region checks, 6-vCPU planning baseline/12-overlap,
verified project guidance, traffic default No, exact appliance ZIP/hash/copy-import/no-expansion
and Step 6's write-enabled operation are preserved. Step 3's only code change is its runtime
label. Step 1, traffic, Steps 3a/3b/4/5/6, cleanup, health and Module 4 are byte-identical to
the preceding 60-file Tomcat revision. No new delivered helper/runtime/test files are added.

Fresh separate host only: old/unmarked lab state is refused before any nested VM removal.
Same-revision incomplete builds may resume. Cached QCOW2 must pass the publisher's exact
Noble filename/digest check before conversion; Ubuntu2404 filenames prevent old-base reuse.
`current` is moving, not a pinned digest; a publication race requires a matching retry.
Both installers enforce Ubuntu 24.04 and Tomcat 10.1.x, verify packaged paths and the JDBC
pool factory, and use the architecture-specific Java 17 executable. Same-OS legacy staging
remains optional on an already-24.04 guest only; it is not an OS/cross-Tomcat upgrade/rollback.

## Executed static/fixture checks

- **30 retained unittest tests passed: 14 app + 16 integration.** Existing SQL/privilege,
  parser-intent, resource bounds, routes, archive and appliance guard coverage is retained;
  the suites additionally check Noble/fresh-host/10.1/Java17/Jakarta/Javase contracts.
- `bash -n` checks every target shell script and generated cloud-init/traffic block. Python
  AST checks and fictional password/JNDI/hosts/service/driver fixtures execute with stdlib.
- JSP lexical/source checks and Servlet 6.0 descriptor parsing verify routes and Java SE JNDI;
  rebuilt WAR entries match source. **This is not Java/JSP compilation.**
- Seven private local KVP shell-mock scenarios pass: exact-package install failure, missing
  binary, unmask failure, enable failure, stop failure, successful generic-kernel stop-until-
  reboot and successful virtual-kernel exact-flavour resolution. apt/uname/test/systemctl are
  shadowed; no package install, system service operation or guest write executes.
- Private PS lexical delimiter/quote checks cover scripts and composed host; KVP helper
  source is identical in host/Step 2. All **57 prior native group names** are retained and
  **3 Ubuntu/Jakarta groups** added: **60 defined, NOT executed**. Their new contracts cover
  exact Noble image/cache/fresh-host, installed runtime/Java17 and Servlet XML/source/WAR.
- Deterministic rebuilds use fixed 1980 timestamps/sorted entries. WAR/runtime/full ZIP CRC,
  runtime provenance and SHA256SUMS are verified. Root manifest has **59** entries for the
  other 59 files. Clean expanded tree and full archive contain the same 60 paths/bytes;
  no .git, __pycache__, .pyc, .static-work or private build harness is delivered.

No packages were installed in the build environment. No PowerShell, Java/JSP, SQL, Azure,
Hyper-V or appliance execution, live OS upgrade, Git push/commit or existing-file writeback
was performed. Static fixture success is not live discovery/migration certification.

## Measurements — default route, no embedded local JDBC JAR

| Item | Bytes |
|---|---:|
| Current raw host source | 86,885 |
| Composed host source (stdlib gzip/Base64 model) | 153,546 |
| Minimal runtime ZIP | 21,873 |
| Runtime Base64 insertion | 29,164 |
| JSP WAR | 7,346 |

WAR SHA256: `e92a3f1036e16641abf5bf726e865a4e54f1afdbda65ae7eecef8aa9e6caa554`

Runtime ZIP SHA256: `c57322a70906260a1adf392d4f92f5ca8c678cb415748cc6cc9d6361b0fc5a92`

The .NET gzip representation can differ slightly from this composition model; no
undocumented payload limit is assumed. Optional reviewed local JDBC embedding adds bytes.
The runtime contains only target scripts/WAR and its manifest, not docs/tests or secrets.
`tests/baseline-manifest.json` retains original 24-file history and the exact preceding
60-file revision comparison, including its archive digest. Self-referential metadata hashes
are intentionally omitted there; root SHA256SUMS verifies the lineage manifest.

## Required Windows and live release acceptance — not executed here

Run in **Windows PowerShell 5.1** before deploying. No Python is required on the learner's
Windows machine. The native parser/78 current groups/.NET packager have not run in this build:

```powershell
.\scripts\check-lab-scripts.ps1
.\scripts\check-lab-scripts.ps1 -RunRegressionChecks
# Optional native repackage to an existing external folder:
.\scripts\check-lab-scripts.ps1 -PackagePath '..\azure-migrate-workshop-ubuntu2404.zip'
```

Repackage replacement requires explicit `-OverwritePackage`. Packaging does not rebuild
app assets. Optional maintainer rebuilds/tests remain in the app README:

```bash
python3 -B apps/contoso-orderdesk/build.py war
python3 -B apps/contoso-orderdesk/build.py runtime
python3 -B apps/contoso-orderdesk/build.py checksums
python3 -B apps/contoso-orderdesk/tests/static_checks.py
python3 -B tests/integration_checks.py
```

Use a fresh disposable separate Azure/Hyper-V lab. Verify both `/etc/os-release` values
are 24.04, actual Noble package versions, Universe repository availability, Tomcat 10.1.x,
Java 17 and JDBC versions/hashes, exact running-kernel tools and KVP after reboot. Exercise
critical install failure/missing binary/pre-reboot stop/post-reboot failure, missing/bad OS
metadata, one failed guest, denied CIM/Run Command and malformed/truncated/duplicate payload;
none may mark setup complete or enter Step 2 discovery. Then verify normal all-four KVP/apps.
After any later reviewed kernel update, require tools for the **new running kernel/flavour**;
no virtual fallback, arbitrary kernel replacement or OS upgrade is a waiver.

Validate early SQL-independent health, delayed SQL recovery, health/info/ready/orders/named
page/proxy, explicit insert/read-back and invalid-order refusal, actual non-root Java-owned
SQL sockets, private root:runtime 0640 JNDI, directory read/execute and sudo ls/netstat under
the real discovery credential. Check reboot persistence, traffic on/off and local-driver
route when needed. After isolated test migration/cutover, repoint aliases to the matching
SQL/app/Nginx private addresses, restart/reload and repeat these checks.

**Mandatory appliance acceptance:** fresh visible Ubuntu OS metadata for both Linux guests,
Tomcat 10.1/Java 17 software inventory **and a visible Contoso Order Desk Java web asset**,
with successful appliance SSH/credential mapping and sufficient collection time. Local HTTP
or host KVP checks cannot substitute. Retained compressed ROOT.war/custom CATALINA_BASE
is not proven to fix a classifier/web-discovery issue; do not claim otherwise. Hyper-V VM
migration and a separate optional physical/Mobility support matrix are distinct. No invented
Ubuntu 24.04 Mobility binary or extra workshop appliance is prescribed.

## Primary compatibility references

- [Canonical Noble cloud image and exact-name checksum list](https://cloud-images.ubuntu.com/noble/current/)
- [Noble cloud image package manifest](https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.manifest)
- [Ubuntu Noble tomcat10 package](https://packages.ubuntu.com/noble/tomcat10)
- [Tomcat common package paths](https://packages.ubuntu.com/noble/all/tomcat10-common/filelist)
- [Ubuntu linux-cloud-tools-common](https://packages.ubuntu.com/noble/linux-cloud-tools-common)
- [Tomcat 10.1 migration: Servlet 6 / Pages 3.1 / supported Java](https://tomcat.apache.org/migration-10.1.html)
- [Ubuntu release lifecycle](https://ubuntu.com/about/release-cycle)
- [Hyper-V KVP numeric component contract](https://learn.microsoft.com/en-us/windows/win32/hyperv_v2/msvm-kvpexchangecomponent)

Standard Main maintenance through May 2029 is not blanket Universe Tomcat security coverage;
review Ubuntu Pro/ESM where applicable and actual approved repository patches. Source image
and repository patch contents may change; target availability/installation is not claimed.
Earlier chronology is retained in CHANGES.md and the exact lineage manifest, not relabeled
as validation of this Ubuntu 24.04 runtime.
