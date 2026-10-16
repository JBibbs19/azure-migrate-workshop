# Module 5: Post-Migration — Operational Excellence & Governance

> **Estimated Time:** ~60 minutes, excluding optional backup/restore jobs and later data reviews
>
> **CSA Competency:** CAF Manage Phase · Azure Well-Architected Framework · Day 2 Operations Design
>
> **WAF Pillars Covered:** Operational Excellence · Reliability · Security · Cost Optimization
>
> **Objectives:** Review application health, configure and verify guest monitoring, assess data protection, harden role-specific network access, review costs, assess updates, and complete an operations runbook.
>
> **Lab Scope:** Four migrated Azure IaaS VMs; both Linux guests remain Ubuntu 24.04. Required student work is manual and portal-first. Resource creation and configuration changes require the appropriate permissions and approved lab scope/budget. Backup/restore, ASR, flow logging, Bastion, paid Defender plans, commitments, and scheduled patch installation are optional, not assumed to exist.

## 1. Overview — Day 2 Operations: Where Migrations Succeed or Fail

**Concept:**

The migration is not done at cutover. It is done when operations are **stable, secure, observable, and cost-optimized** in their new cloud environment.

This module maps directly to the **Manage phase** of the Cloud Adoption Framework (CAF) and operationalizes the **Azure Well-Architected Framework (WAF)** across five pillars:

| Pillar | Operational Focus |
|---|---|
| **Operational Excellence** | Observability, alerting strategy, operational runbooks |
| **Reliability** | Data protection, recovery planning, patch management |
| **Security** | Network segmentation, least-privilege access, threat-protection review |
| **Cost Optimization** | Right-sizing, commitment review, governance controls |
| **Performance Efficiency** | Baseline metrics collection, capacity-planning foundation |

### The Five Pillars of This Module

1. **Observability** — You cannot manage what you cannot measure
2. **Protection** — Backup and DR address different recovery needs
3. **Security** — Migrated workloads need role-appropriate access controls
4. **Optimization** — Cloud cost is variable and needs governance
5. **Governance** — Policies, tags, budgets, and accountability prevent drift

### Well-Architected Framework Alignment

| Section | WAF Pillar | Student Activity |
|---|---|---|
| Azure Monitor | Operational Excellence | Configure collection and verify actual telemetry |
| Azure Backup | Reliability | Record recovery needs; optionally configure and verify a backup |
| NSG Hardening | Security | Review effective policy and preserve required application paths |
| Right-Sizing | Cost Optimization | Review actual sizes, utilization, and prices |
| Update Management | Reliability + Security | Assess current patch status without installing updates |
| Cost Management | Cost Optimization | Review tags, costs, and an approved budget scope |

### Migrated Application — Required Health Baseline

The target VM names and roles are:

| Azure VM | Operating System / Workload | Local Service and Port |
|---|---|---|
| `OnPrem-Web` | Windows Server 2022, IIS static site | `W3SVC`, HTTP 80 |
| `OnPrem-SQL` | Windows Server 2022, SQL Express 2022, `ContosoApp` | `MSSQL$SQLEXPRESS`, TCP 1433 |
| `OnPrem-Linux-Web` | Ubuntu 24.04, Nginx static site and reverse proxy | `nginx`, HTTP 80 and proxy 8080 |
| `OnPrem-Linux-App` | Ubuntu 24.04, Tomcat 10.1 / Java 17, Contoso Order Desk JSP | `contoso-orderdesk`, HTTP 3000 |

The static sites are not proof of database connectivity. `/api/health` checks application liveness; `/api/ready` and GET `/api/orders` exercise the application's SQL access. The Order Desk page reads orders; submitting its form writes an order.

**Why It Matters:** A known-good application baseline is needed before monitoring changes or network hardening. Module 3 contains the full migration validation and alias-repointing procedure; this module repeats only the operational checks needed before and after changes.

**Student Actions:**

1. Open **Azure portal** → **Virtual machines**. Select the actual target subscription/resource group and the four migrated VMs above, not any `-test` copies. Record each VM's power state, target region, and size.
2. For each VM, open **Networking / Network settings** → the attached NIC → **IP configurations**. Record the actual primary private IP, subnet, NIC NSG, and subnet NSG. Use these actual target addresses throughout this module, not source-lab addresses or sample IPs.
3. Choose an approved guest-access method: **VM → Run command → RunPowerShellScript/RunShellScript** when the Azure VM agent is ready, or approved RDP/SSH guest access. Check agent status in the VM's properties before relying on Run command. A workstation without a route to the private network cannot directly reach these addresses; lack of a public IP/FQDN is not a health failure.
4. Confirm the local services and HTTP paths using the short checks below. Run each block **inside the named guest**, replacing placeholders before execution.

   **OnPrem-Web — Windows PowerShell:**

   ```powershell
   Get-Service -Name W3SVC
   (Invoke-WebRequest 'http://localhost/' -UseBasicParsing -TimeoutSec 10).StatusCode
   ```

   **OnPrem-SQL — Windows PowerShell:**

   ```powershell
   Get-Service -Name 'MSSQL$SQLEXPRESS'
   Get-NetTCPConnection -State Listen -LocalPort 1433 |
     Select-Object LocalAddress, LocalPort, State
   ```

   **OnPrem-Linux-Web — shell:**

   ```bash
   systemctl is-active nginx
   curl --fail --show-error --max-time 10 http://127.0.0.1/
   curl --fail --show-error --max-time 20 http://127.0.0.1:8080/api/ready
   ```

   **OnPrem-Linux-App — shell:**

   ```bash
   systemctl is-active contoso-orderdesk
   curl --fail --show-error --max-time 10 http://127.0.0.1:3000/api/health
   curl --fail --show-error --max-time 20 http://127.0.0.1:3000/api/ready
   curl --fail --show-error --max-time 20 http://127.0.0.1:3000/api/orders
   ```

5. Check the five directed application paths from their actual source guests. These are targeted connection/HTTP checks, not scans. Replace the placeholders with the private IPs collected in Step 2.

   | Run From | Destination | Required TCP Port | Purpose |
   |---|---|---|---|
   | `OnPrem-Web` | `OnPrem-SQL` | 1433 | Windows web-to-database path |
   | `OnPrem-Web` | `OnPrem-Linux-App` | 3000 | Windows web-to-application path |
   | `OnPrem-Linux-App` | `OnPrem-SQL` | 1433 | Tomcat JDBC database access |
   | `OnPrem-Linux-App` | `OnPrem-Linux-Web` | 8080 | Application-to-Nginx proxy path |
   | `OnPrem-Linux-Web` | `OnPrem-Linux-App` | 3000 | Nginx upstream application path |

   **OnPrem-Web — Windows PowerShell:**

   ```powershell
   $SqlIp = '<actual-SQL-private-IP>'
   $AppIp = '<actual-Linux-App-private-IP>'
   Test-NetConnection -ComputerName $SqlIp -Port 1433 -InformationLevel Detailed
   Test-NetConnection -ComputerName $AppIp -Port 3000 -InformationLevel Detailed
   Invoke-RestMethod -Uri "http://${AppIp}:3000/api/ready" -TimeoutSec 20
   ```

   **OnPrem-Linux-App — shell:**

   ```bash
   SQL_IP='<actual-SQL-private-IP>'
   NGINX_IP='<actual-Linux-Web-private-IP>'
   timeout 5 bash -c 'exec 3<>/dev/tcp/"$1"/1433' _ "$SQL_IP"
   printf 'SQL TCP check exit code: %s\n' "$?"
   curl --fail --show-error --max-time 20 "http://${NGINX_IP}:8080/api/ready"
   ```

   **OnPrem-Linux-Web — shell:**

   ```bash
   APP_IP='<actual-Linux-App-private-IP>'
   curl --fail --show-error --max-time 20 "http://${APP_IP}:3000/api/ready"
   ```

6. From an approved browser session in the Windows Web guest, where desktop access is available, open `http://<actual-Linux-App-private-IP>:3000/`. Confirm that the Order Desk shows customers and recent orders. This uses the Web → App path; do not open port 3000 to all clients merely to obtain a screenshot. If this browser path is unavailable, record that limitation and retain the guest HTTP results rather than claiming browser verification.
7. **Optional write check:** Only with approved disposable lab data, submit **one** clearly labelled sample order through the Order Desk form and confirm that it appears on a subsequent read. Record its order ID, not credentials. Do not enable persistent traffic jobs or repeatedly submit the form.
8. Record pass/fail/pending for the local services, private-IP paths, readiness, and order read. If aliases or endpoints still reference source/test VMs, return to Module 3's manual repointing steps before hardening. Repeat this baseline after Section 4 and after any later resize or patch/reboot.

**Expected Outcome:** You have an actual target-IP inventory and a recorded application baseline. All five required paths are checked from the correct guests; no monitoring, public endpoint, or background traffic is assumed to exist.

---

## 2. Observability Strategy

> **WAF Pillar: Operational Excellence**

**Concept:**

Monitoring is not "install an agent and set some alerts." An observability strategy defines *what* you measure, *why* you measure it, *who* responds, and *how fast*.

### 2.1 Azure Monitor Architecture — The Modern Approach

**Concept:**

The modern guest-log collection architecture uses **Data Collection Rules (DCRs)** and the **Azure Monitor Agent (AMA)**. A DCR defines sources and destinations; a **DCR association connects a VM to that rule**. A rule without the VM association does not collect that VM's guest data.

```text
Azure VM platform metrics ---------------------> Azure Monitor Metrics
  CPU, disk, network platform signals              (no AMA required)

Guest sources -> AMA on VM -> Associated DCR ----> Log Analytics workspace
  Windows events / Linux syslog / performance       Logs and KQL
                                                        |
                                              Alerts / workbooks
                                                        |
                                                  Action group
```

**Log Analytics Workspace Design Guidance:**

| Pattern | When to Use | Trade-off |
|---|---|---|
| **Single workspace per environment** | A small lab or a single operations team | Simpler collection and access review |
| **Per-environment** | Data separation requirements | More workspaces and access controls to manage |
| **Per-application** | Application-specific ownership/chargeback | More granular, with greater management overhead |

Platform metrics are available independently of AMA. Guest memory counters and guest logs require a suitable collection configuration. Existing Windows application files and Linux journals are not automatically merged into a central application log by this exercise.

**Why It Matters:** Installing AMA or creating an empty DCR alone is not evidence that the expected data is arriving.

**Student Actions:**

1. Open one migrated VM → **Monitoring** → **Metrics**. Select **Percentage CPU**, a recent time range, and an appropriate aggregation. Review the chart and repeat for the other three VMs.
2. Record the observed metric/time range. A new VM may have only a short history; do not invent a multi-week baseline.
3. Confirm the lab's approved monitoring resource group, region, permissions, retention, and ingestion budget before creating the workspace and rules below. If these are unavailable, record the collection exercise as not completed rather than claiming it was configured.

**Expected Outcome:** Platform-metric review is recorded, and guest collection is identified as a separate student configuration activity.

### 2.2 Create a Log Analytics Workspace

**Concept:**

A Log Analytics workspace is the destination for the guest logs and performance data selected in the DCRs. Ingestion and retention settings affect cost.

**Student Actions:**

1. Search **Log Analytics workspaces** in the portal → **+ Create**.
2. Configure the approved values:

   | Setting | Value |
   |---|---|
   | Subscription | Approved lab subscription |
   | Resource group | Actual target lab resource group |
   | Name | Unique lab name, such as `law-migrate-workshop` |
   | Region | Reviewed region for this lab's monitoring data |
   | Tags | Existing lab ownership/environment conventions |

3. Select **Review + create** → **Create**. Open the workspace after deployment completes.
4. Review **Usage and estimated costs** and the available retention settings. Keep the agreed settings; do not expand collection or retention without an approved budget.
5. Record the workspace name and resource ID for the next step. If an approved workspace already exists, verify its scope and use it rather than creating a duplicate.

**Expected Outcome:** An approved workspace is available and identified; no guest collection is claimed yet.

### 2.3 Configure Data Collection Rules and Associate the VMs

**Concept:**

DCRs define what telemetry to collect and where to deliver it. Separate Windows and Linux rules keep this exercise's sources and VM associations clear. The portal's DCR resource workflow can deploy AMA to the selected Azure VMs.

| Lab Rule | Associated VMs | Data Sources | Destination |
|---|---|---|---|
| `dcr-migrate-windows` | `OnPrem-Web`, `OnPrem-SQL` | Basic supported performance counters; Application/System event logs at Warning, Error, Critical | Approved Log Analytics workspace |
| `dcr-migrate-linux` | `OnPrem-Linux-Web`, `OnPrem-Linux-App` | Basic supported Linux performance counters; Syslog facilities such as `syslog` and `daemon`, Warning and more severe | Same workspace |

These are bounded baseline sources, not complete application instrumentation. IIS/Nginx text logs, SQL-specific counters, and Tomcat/JVM application telemetry require additional source-specific collection if later approved. Linux Syslog collection does not automatically collect every systemd journal entry.

**Student Actions:**

1. For the selected VMs, review **Identity** and the managed-identity requirement shown by the collection workflow. With the required permission, enable the approved system-assigned identity if needed; otherwise use the lab's approved identity configuration. Do not change unrelated identities or subscription-wide permissions.
2. Search **Monitor** → **Data Collection Rules** → **+ Create**. Enter `dcr-migrate-windows` (or a unique equivalent), the approved subscription/resource group/region, and **Windows** as the platform type.
3. On **Resources**, select **Add resources** and select **only** `OnPrem-Web` and `OnPrem-SQL`. Review the AMA installation/identity choice presented by the wizard. Adding these resources establishes the required VM-to-DCR associations when the rule is saved.
4. On **Collect and deliver**, add **Performance Counters** using the supported basic preset/counters shown for Windows, including CPU and available memory where offered. Set the destination to **Azure Monitor Logs** and select the workspace from Section 2.2.
5. Add **Windows Event Logs** for **Application** and **System**, selecting Warning, Error, and Critical levels. Select the same workspace as destination. Do not select every channel or verbose level by default.
6. Select **Review + create** → **Create**. Open the saved rule → **Resources** and confirm that both Windows VM resource IDs are listed.
7. Repeat **Create** for `dcr-migrate-linux`, platform **Linux**, and associate **only** `OnPrem-Linux-Web` and `OnPrem-Linux-App` under **Resources**.
8. Add supported basic Linux **Performance Counters**, then **Linux Syslog** for the selected facilities at Warning and more severe levels. Select the same workspace as the destination for both sources, then **Review + create** → **Create**.
9. Open the saved Linux rule → **Resources** and confirm both Ubuntu VM resource IDs. Review **Data sources** and destinations on both saved rules. If a source was not offered or not selected, record it as absent rather than claiming it is collected.

**Expected Outcome:** Each of the four VMs is explicitly associated with an OS-appropriate DCR that has configured sources and the intended workspace destination.

### 2.4 Install/Verify Azure Monitor Agent and Check Data Arrival

**Concept:**

AMA runs on each selected guest and uses its associated rule. Successful extension deployment is a prerequisite, not a guarantee that telemetry has already arrived.

**Student Actions:**

1. Open each VM → **Extensions + applications**. Confirm `AzureMonitorWindowsAgent` on the two Windows VMs and `AzureMonitorLinuxAgent` on the two Ubuntu VMs, with successful provisioning. If missing after DCR creation, return to the rule's **Resources** workflow and complete its AMA deployment option for that VM. Do not install a different legacy monitoring agent.
2. Recheck that the VM resource IDs appear under the correct DCR's **Resources**, and that the rule routes to the correct workspace. Record any missing identity, extension, association, or destination as incomplete.
3. Allow for collection and ingestion delay. Open the workspace → **Logs**, set a time range that includes the collection start, and run:

   ```kusto
   Heartbeat
   | where TimeGenerated > ago(1h)
   | summarize LastSeen = max(TimeGenerated) by Computer, _ResourceId
   | order by Computer asc
   ```

4. Compare the returned resource IDs with your four-VM inventory, rather than relying only on computer names. Record the latest observed timestamp for each VM. If the lab has been collecting longer, adjust the query/time range deliberately.
5. For the configured performance source, run:

   ```kusto
   Perf
   | where TimeGenerated > ago(1h)
   | summarize Samples = count(), LastSeen = max(TimeGenerated)
       by Computer, ObjectName, CounterName
   | order by Computer asc, CounterName asc
   ```

6. If guest events have arrived, open the **Event** table for Windows and **Syslog** for Linux in the workspace and review a small recent sample. Warning-level events may not occur during a short lab. Do not generate failures just to populate a table or claim that a missing table contains data.
7. If data is not yet present, record **pending — no arrival verified**, recheck the four configuration points above, and revisit after ingestion has had time to occur. Keep the platform-metric result separate from guest-log verification; an empty result is not a successful collection check.

**Why It Matters:** Actual timestamps and resource IDs prove collection more reliably than a saved rule or an extension success message.

**Expected Outcome:** You have either verified actual Heartbeat/performance/log arrivals for the selected sources or recorded the specific pending/incomplete status. Central collection of existing application files/journals is not implied.

### 2.5 Alert Strategy — Avoiding Alert Fatigue

**Concept:**

If every alert fires, no alert matters. Useful alerts drive **action**, not noise.

**Alert Severity Framework — Example Response Targets:**

| Severity | Meaning | Example |
|---|---|---|
| **Sev 0 — Critical** | Service down or imminent data loss | Confirmed critical service outage |
| **Sev 1 — Error** | Customer-impacting degradation | Confirmed disk exhaustion or repeated application failures |
| **Sev 2 — Warning** | Action needed soon | Sustained high CPU |
| **Sev 3 — Informational** | Noteworthy, not urgent | Capacity trend requiring review |
| **Sev 4 — Verbose** | Diagnostic information | Nonurgent diagnostic signal |

CPU platform metrics are suitable for the basic alert exercise. Guest-disk, HTTP error-rate, and backup alerts need their relevant telemetry or protection configuration first. An action-group notification test validates delivery, not application outage detection.

**Student Actions:**

1. With approved alerting scope/cost, open **Monitor** → **Alerts** → **+ Create** → **Alert rule**.
2. Set **Scope** to one migrated VM. Choose the platform signal **Percentage CPU**, condition **Greater than 90%**, aggregation **Average**, over a five-minute window (or the equivalent options shown). Use these as lab example thresholds, not a production response guarantee.
3. Under **Actions**, create/select an approved action group such as `ag-migrate-warning`. Add an email notification to a lab-approved recipient. Do not add billable SMS or external webhooks without approval.
4. Set a clear rule name, severity **2 — Warning**, the approved resource group, and a description naming the response action. Review the estimated charges and select **Create** only within the approved scope.
5. Open the action group → **Test**, select the email notification type, send a test, and confirm receipt. Record the result separately from whether the CPU rule has fired.
6. Repeat for the other migrated VMs if approved. Do not force CPU load or stop services to trigger a notification.
7. Record any additional desired alerts and their prerequisites, for example backup failure only after backup is configured, or HTTP errors only after the application log source is configured.

**Expected Outcome:** Your alert record identifies actual rule scope, threshold, severity, recipient, and notification-test status. Uncreated rules or unavailable signals are marked deferred rather than assumed active.

---

## 3. Data Protection Strategy

> **WAF Pillar: Reliability**

**Concept:**

Backup is the minimum viable data protection. A complete strategy includes policies aligned to RPO, tested restore procedures, and DR planning. Backup retention and backup frequency are different settings.

### 3.1 Backup Policy Design — RPO-Based Thinking

**Concept:**

The business question is: **How much data can you afford to lose?** A daily backup does not satisfy a one-hour RPO just because its retention is 30 days.

| Workload | Example Requirement | Lab Protection Discussion |
|---|---|---|
| `OnPrem-SQL` — SQL Express / `ContosoApp` | Business-defined transaction-loss tolerance | Daily VM backup alone cannot establish an hourly database RPO |
| `OnPrem-Web` — IIS static site | Example: up to 24 hours of changes | Daily VM backup, subject to successful recent recovery points |
| `OnPrem-Linux-Web` — Nginx | Example: up to 24 hours of changes | Daily VM backup including configuration |
| `OnPrem-Linux-App` — Tomcat | Example: up to 24 hours of VM/configuration changes | Daily VM backup; database protection remains a separate consideration |

Thirty-day daily retention is a lab example, not a universal compliance requirement. Actual recovery-point age and a successful restore determine what can be recovered.

**Student Actions:**

1. Record required RPO and RTO for the sample application using your Module 4 decision record.
2. Record which parts are VM/configuration recovery and which depend on the `ContosoApp` database.
3. Choose whether to perform the optional backup exercise below. Confirm permissions, eligible VM configuration, region, storage/retention charges, and approved budget **before** creating or enabling protection. Otherwise mark backup implementation **deferred** and retain the policy design.

**Expected Outcome:** Your protection record states requirements, a policy proposal, and whether backup configuration is approved; it does not claim an unsupported hourly RPO.

### 3.2 Create a Recovery Services Vault and Backup Policy — Optional

**Concept:**

Azure VM backup uses a supported Recovery Services vault and policy. This exercise uses a **new dedicated backup vault**, not the Azure Migrate-created migration vault and not the optional ASR comparison vault. No source Hyper-V registration is required for backing up the migrated Azure VMs.

**Student Actions — Optional, Approved Scope Only:**

1. Search **Recovery Services vaults** → **+ Create**. Select the approved subscription, dedicated lab resource group, and a unique backup name such as `MigrateWorkshop-Backup-Vault`.
2. Select the same region as the Azure VMs to be backed up. Apply the lab ownership/environment tags. Review the vault's redundancy, security, and retention implications before proceeding; do not rely on immediate deletion of protected data to end all charges.
3. Select **Review + create** → **Create**, then open the new vault.
4. Open **Backup policies** → **+ Add**, select **Azure Virtual Machine**, and choose a policy type offered for the selected VMs.
5. Set a lab policy such as the following, using the supported options shown:

   | Setting | Example Lab Value |
   |---|---|
   | Policy name | `DailyBackup-30DayRetention` |
   | Schedule | Daily, at an approved off-peak time; record the time zone |
   | Daily recovery-point retention | 30 days, only if approved |
   | Instant-restore retention | Supported default or approved value shown |
   | Weekly/monthly/yearly retention | No additional long-term retention unless approved |

6. Review the policy and select **Create**. Record the actual vault name, policy, schedule/time zone, retention, and approved VM scope.

**Expected Outcome:** A separate approved Azure VM backup vault/policy exists, or this optional activity is explicitly deferred. Migration and DR resources remain unchanged.

### 3.3 Enable Backup for the Approved VMs — Optional

**Concept:**

Enabling a policy schedules protection; it does not mean an initial recovery point already exists.

**Student Actions — Optional:**

1. In the new backup vault, select **Backup** → workload location **Azure** → **Virtual machine**.
2. Select the policy from Section 3.2 → **Add**. Review the eligible migrated VM list and select only the approved scope. If the budget covers all four, select `OnPrem-Web`, `OnPrem-SQL`, `OnPrem-Linux-Web`, and `OnPrem-Linux-App`; otherwise record the chosen subset.
3. Check the listed VM names/resource IDs against the target inventory, not the `-test` VMs. Review any eligibility message before continuing.
4. Select **Enable backup**. Open **Backup items** → **Azure Virtual Machine** and inspect each selected item's status.
5. Record enabled/pending/failed separately for each VM. Do not record a successful recovery point until Section 3.4 verifies one.

**Expected Outcome:** Backup configuration status is recorded for the approved VMs without confusing policy enablement with completed backup protection.

### 3.4 Trigger and Verify a Backup — Optional

**Concept:**

A completed backup and an isolated restore test provide different evidence. An in-progress job is not a verified recovery point.

**Student Actions — Optional:**

1. In the backup vault → **Backup items** → **Azure Virtual Machine**, select an approved protected VM, such as `OnPrem-Web`.
2. Select **Backup now**, choose an approved retain-until date within the lab policy, and confirm.
3. Open **Backup jobs**, select the new job, and review its detailed status. Initial snapshot and transfer can take time; record **in progress** if it has not completed by the end of the session.
4. After completion, return to the backup item → **Recovery points**. Record the actual recovery-point timestamp and consistency type reported. Do not assume application consistency for every VM or SQL installation.
5. **Optional isolated restore test:** With separately approved compute/storage/network cost, select **Restore VM** from a verified recovery point. Choose **Create new** or **Restore disks** as appropriate, a distinct restore name, and an approved isolated recovery VNet/subnet. Do not replace the current VM, overwrite source data, or connect a duplicate application to the live/source database.
6. If a restore is performed, validate only within the isolated recovery environment and record the result. Record the approved retention/cleanup decision for the restore resources; do not delete existing source or migration resources as part of this exercise.

**Why It Matters:** The evidence is a completed job plus an actual recovery point; a restore test is additional evidence, not something inferred from a green configuration screen.

**Expected Outcome:** Your record contains the actual job and recovery-point status, or a clear pending/deferred result. A restore is claimed only if the optional isolated test was completed.

### 3.5 SQL Server Backup Considerations

**Concept:**

`OnPrem-SQL` runs **SQL Server Express 2022**. SQL Express has no SQL Server Agent for scheduled SQL Agent jobs. VM backup consistency depends on the actual guest/application backup outcome; it is not a blanket SQL workload-backup or application-consistency guarantee.

| Approach | Consideration for This Lab |
|---|---|
| **Azure VM backup** | Basic optional exercise; inspect the reported recovery-point consistency |
| **Native SQL full backup** | Separately approved manual database task, with protected backup storage and a restore test |
| **SQL workload backup services** | Separate support/edition/configuration review; not assumed enabled or supported by this exercise |

**Student Actions:**

1. Record SQL Express as the database edition and distinguish VM recovery from database-level recovery.
2. If native SQL backup is separately approved, use an approved guest session on `OnPrem-SQL`: **SQL Server Management Studio** → **Databases** → **ContosoApp** → **Tasks** → **Back Up**. Select **Full**, select an approved disk path writable by the SQL service, and review the destination before selecting **OK**.
3. If performed, verify the backup task's result and record how the backup will be held in approved private storage. Do not publish the backup, embed credentials, or create a SQL Agent job.
4. Record database restore testing as a separate isolated activity if not performed. Do not infer a database RPO from the presence of a `.bak` file alone.

**Expected Outcome:** Your notes accurately describe SQL Express protection and any actual manual backup result, without claiming a SQL workload-backup service or SQL Agent schedule.

### 3.6 Disaster Recovery — Tie Back to Module 4

**Concept:**

Azure-to-Azure ASR can be evaluated for cross-region DR after migration. It requires a separate design for region, network, support, capacity, costs, replication, and recovery plans. The stabilization timing in Module 4 is an example; business recovery requirements determine protection timing.

**Student Actions:**

1. Bring forward your Module 4 DR purpose, RPO/RTO, prerequisites, and recovery-plan outline.
2. Record DR implementation as **not performed** in this module, unless separately approved and evidenced outside the required exercise. Do not select **Configure disaster recovery** on the current VMs for this comparison.

**Expected Outcome:** Backup activity and future DR planning are distinct, with no assumption that migration replication continues as DR.

---

## 4. Security Hardening — Zero Trust Approach

> **WAF Pillar: Security**

**Concept:**

Migrated workloads carry their on-premises security posture into the cloud. Hardening applies Zero Trust principles: verify explicitly, use least-privilege access, and assume breach. The immediate lab objective is role-specific access without breaking the existing application.

### Security Hardening Flow

```text
Record current health and effective policy
                  |
Stage specific application and management allows
                  |
Verify access -> tighten reviewed broad rules -> add role-specific deny
                  |
Repeat application/management checks
                  |
Review optional flow logging, Bastion/JIT, and Defender scope
```

**Why It Matters:** The sample is not a simple linear web → app → database chain. All five directed dependencies in Section 1 must survive hardening. Management ports are not application dependencies.

### 4.1 Network Security — NSG Design Principles

**Concept:**

The foundational rule is default-deny inbound with explicit allows per workload role. Both NIC and subnet NSGs apply, and an allow in one does not override a deny in the other. Outbound policy, routes, and guest firewalls also affect connectivity.

**Student Actions:**

1. Confirm that Section 1's baseline and actual target private-IP inventory are current.
2. Open each VM → **Networking / Network settings** and its NIC. Review the **Effective security rules** view and the associated NSG's **Inbound security rules** and **Outbound security rules**.
3. Open the VNet → **Subnets** → the VM's subnet and review any subnet NSG. Record existing allow/deny priorities, rules relevant to the five application paths, and the approved management path.
4. Identify whether a NIC NSG is dedicated to one VM or shared. Do not change unrelated/shared NSGs or delete all custom rules. If a shared policy needs a change beyond your approved scope, record the blocker rather than editing it.
5. Keep portal **Run command** available where the agent is ready while changing guest management access. It is a control-plane guest-command path, not an inbound RDP/SSH rule; it does not remove the need to verify network access.

**Expected Outcome:** You have a before-change record of NIC/subnet policy, relevant priorities, and a usable management method.

### 4.2 Remove Overly Permissive Rules — Stage Before Restricting

**Concept:**

Removing broad access before staging specific allows can lock out management or stop the application. Existing unrelated rules and shared policies are outside this lab change.

**Student Actions:**

1. Identify only the lab-specific broad rules that need narrowing, recording their original values for rollback. Do not remove them yet.
2. If the NIC has no dedicated NSG, use **Network security groups** → **+ Create** to create an approved role-specific NIC NSG in the target region. Associate it through **Network interfaces** → select only the intended VM NIC. If replacing a shared NIC association, first review the required existing rules and obtain approval for that NIC-only change; do not modify the shared NSG itself.
3. Record the approved HTTP client network and management source. For direct public RDP/SSH, use the actual **My public IP /32** only when that path is approved and routable. For an existing approved Bastion path, use the actual Bastion subnet and its required policy. An unknown client IP is a reason to stop that rule change, not to allow `*`.
4. Add and review the specific application/management allows in Section 4.3 **before** removing or narrowing any broad rule or adding the final deny.

**Expected Outcome:** Changes are limited to reviewed lab NIC policy, with specific allows planned before restrictions.

### 4.3 Apply Role-Based NSG Rules — Microsegmentation

**Concept:**

The following table preserves the actual five application dependencies. Each `<role-IP>` means the **actual target NIC private IPv4 address** recorded in Section 1, with `/32` added for the rule. These are not source-lab addresses or a set of sample target addresses.

| Destination NIC / Role | Example Available Priority | Allow Source | Destination | TCP Port |
|---|---|---|---|---|
| `OnPrem-Web` — IIS | 100 | Approved HTTP client CIDR | `<Web-IP>/32` | 80 |
| `OnPrem-SQL` — SQL Express | 100 | `<Web-IP>/32` | `<SQL-IP>/32` | 1433 |
| `OnPrem-SQL` — SQL Express | 110 | `<App-IP>/32` | `<SQL-IP>/32` | 1433 |
| `OnPrem-Linux-Web` — Nginx static site | 100 | Approved HTTP client CIDR | `<Nginx-IP>/32` | 80 |
| `OnPrem-Linux-Web` — Nginx proxy | 120 | `<App-IP>/32` | `<Nginx-IP>/32` | 8080 |
| `OnPrem-Linux-App` — Tomcat | 100 | `<Nginx-IP>/32` | `<App-IP>/32` | 3000 |
| `OnPrem-Linux-App` — Tomcat | 110 | `<Web-IP>/32` | `<App-IP>/32` | 3000 |
| Each Windows VM — management only | 200 | Approved management source | That VM's private IP `/32` | 3389 |
| Each Ubuntu VM — management only | 200 | Approved management source | That VM's private IP `/32` | 22 |

Port 3000 is allowed only from Web and Nginx; SQL 1433 only from Web and App; Nginx 8080 only from App. HTTP 80 is limited to the appropriate client network. HTTPS 443 is not a required health path because TLS is not configured in this lab. No NAT gateway or public endpoint is assumed to have been created.

**Student Actions:**

1. Open a dedicated NIC NSG → **Inbound security rules** → **+ Add**. For each application row targeting that NIC, set:

   | Rule Field | Student Value |
   |---|---|
   | Source | **IP Addresses**, using the actual peer `/32` or approved HTTP client CIDR |
   | Source port ranges | `*` — client ephemeral ports, not unrestricted source addresses |
   | Destination | **IP Addresses**, using the destination NIC private IP `/32` |
   | Service | **Custom** |
   | Destination port ranges | The single TCP port in the table |
   | Protocol / Action | **TCP / Allow** |
   | Priority | An unused value lower than `4000`; the table values are examples |
   | Name | Clear peer-and-port name, such as `Allow-SQL-From-Web` |

2. Add the appropriate management allow only for your chosen verified management path. Do not create RDP/SSH rules with an unrestricted source. A private-only VM does not become reachable from your workstation just because an NSG rule is added.
3. Repeat for the other dedicated NIC NSGs. Review the saved rules and **effective** NIC/subnet rules for each dependency, including outbound restrictions at the source. If a shared subnet policy denies an application path, record it for the authorized scope owner rather than weakening unrelated controls.
4. Verify the approved management session and repeat the five source-to-destination checks in Section 1. Confirm that the planned specific rules have the correct addresses/ports/priorities; broad existing allows must not be mistaken for proof that the final restricted policy is correct.
5. Narrow/remove only the broad lab rules identified in Section 4.2, after the specific allows and management path are verified. Preserve unrelated custom rules. Do not retain a higher-precedence broad allow that bypasses the intended restriction.
6. On each dedicated NIC NSG, add or maintain a reviewed **DenyAll** inbound rule at priority **4000**, protocol **Any**, source **Any**, destination that VM's private IP `/32`, destination ports `*`. All required allows must have lower priority numbers. If priority 4000 is occupied, review that rule rather than overwriting it blindly.
7. Immediately repeat Section 1's local service, five-edge, readiness, and order-read checks, plus management access. Record before/after results. If a change blocks a required path, use the saved rule record and portal access to correct/revert **that change**, not to open all ports or erase the NSG.

**Expected Outcome:** Reviewed NIC rules enforce role-specific access while all five application paths and the chosen management path still work. Shared/subnet blockers and uncompleted changes are recorded explicitly.

### 4.4 VNet Flow Logs + Traffic Analytics — Optional

**Concept:**

Flow logging provides network-traffic visibility. The optional current portal workflow is **virtual network flow logging**, not creation of new legacy NSG flow logs. Storage and Traffic Analytics can add charges; they are not required to complete the application checks.

**Student Actions — Optional:**

1. Open **Network Watcher** → **Flow logs** → **+ Create** and review the available **Virtual network** target workflow for the approved target region.
2. Select only the approved target VNet, subscription, and region. Review an approved storage destination, retention, and any Traffic Analytics workspace/processing options.
3. Create the flow log only if this VNet scope, storage, retention, and processing budget are approved. Otherwise cancel and record **reviewed — not enabled**. If the workflow is unavailable for the chosen scope, record that result rather than switching to legacy NSG flow-log creation.
4. If enabled, inspect the flow-log resource status and later data/analytics availability. Do not claim instant traffic visibility or centrally collected application logs.

**Expected Outcome:** The current VNet flow-logging option is reviewed, and any actual enablement/status is recorded without adding mandatory logging costs.

### 4.5 Azure Bastion — Eliminate Open Management Ports

**Concept:**

Azure Bastion can provide portal-based RDP/SSH to private VMs. It requires suitable network configuration, access permissions, and an approved deployment/SKU budget. It is not automatically present in this lab.

**Student Actions:**

1. Open a VM → **Connect** → **Bastion** and review whether an approved deployment already exists for the target network.
2. If one exists, connect using an authorized guest account and confirm the session works before changing direct RDP/SSH rules. Preserve the actual required Bastion-subnet policy.
3. If none exists, review the **Bastions** creation settings only if a separate deployment is approved. Review VNet, supported subnet/SKU requirements, region, public/private connectivity options, and charges before creating anything. Otherwise record **not deployed** and retain the restricted management method chosen in Section 4.2.
4. Remove/narrow a direct public management rule only after the replacement path is tested. Do not delete the management path you are currently relying on.

**Expected Outcome:** Your runbook states the management path actually available; Bastion is not reported as deployed merely because its creation page was reviewed.

### 4.6 JIT VM Access via Microsoft Defender for Cloud

**Concept:**

Just-In-Time (JIT) access can time-limit approved management access for eligible configurations. Licensing, permissions, and existing network rules affect availability. JIT is not a reason to enable paid plans across an unrelated subscription.

**Student Actions:**

1. Open **Microsoft Defender for Cloud** → **Workload protections** → **Just-in-time VM access**, where available.
2. Review eligibility and existing configuration for the lab VMs. Record whether the current plan and approved scope support JIT.
3. If separately approved and eligible, review the chosen VM's management port, approved source IP, and maximum request duration before configuring/requesting access. Test the selected path and record its expiry. Otherwise leave configuration unchanged and record **reviewed — not enabled**.

**Expected Outcome:** JIT availability and any approved change are recorded without assuming licensing or altering company-wide protection settings.

### 4.7 Identity, Access & Threat Protection

**Concept:**

Identity, resource access, and threat protection complement network controls. Least privilege means granting only the operations needed at the appropriate scope; VM Contributor is not automatically the right role for every task or guest login.

| Control | Review Focus |
|---|---|
| **Microsoft Entra ID / guest access** | Approved sign-in method and guest-login permissions; no new login extension required by this exercise |
| **Managed identities** | Identity used by approved Azure services, including AMA collection |
| **RBAC least privilege** | Resource scope, inherited role assignments, and necessary operations |
| **Defender for Servers / SQL** | Current plans, eligible resources, recommendations, and approved licensing/billing scope |

**Student Actions:**

1. Open each lab VM/resource group → **Access control (IAM)** → **View my access** and **Role assignments**. Review inherited versus direct roles. Record excessive access for authorized review; do not grant yourself Owner or remove another user's access.
2. Review the VM **Identity** configuration used for monitoring. Do not display private application configuration or SQL credentials in notes/screenshots.
3. Open **Microsoft Defender for Cloud** → **Recommendations** or inventory, filter to the lab resource scope, and record relevant findings for the Windows/Ubuntu VMs and SQL VM.
4. Review **Environment settings** and currently enabled plans only within your permitted scope. Do not enable a subscription-wide paid plan to complete a lab checklist. Any plan change needs explicit approval of licensing, billing, affected resources, and scope; reviewing recommendations without enablement is a valid exercise result.
5. Record which controls are active, which were merely reviewed, and which need approval.

**Expected Outcome:** The application remains healthy after NSG changes, and identity/threat-protection records describe actual scope and status rather than a blanket claim that Zero Trust or paid protection has been achieved.

---

## 5. Cost Optimization — Strategic, Not Tactical

> **WAF Pillar: Cost Optimization**

**Concept:**

Cost optimization is not "resize VMs." It is a **continuous discipline** spanning right-sizing, commitment review, and governance controls, not a one-time exercise.

### Cost Optimization Decision Flow

```text
Review actual size and representative utilization
                       |
Review workload peaks, memory, disks, and availability needs
                       |
Record a sizing recommendation and maintenance impact
                       |
Review current portal prices and eligible licensing
                       |
Apply only approved changes; review again later
```

### 5.1 Right-Sizing Process

**Concept:**

A representative post-migration baseline is needed before right-sizing. The original 2–4 week review window is a planning example; a short lab session is not enough to establish production sizing.

The lab plan selects eligible B2 or D2 targets in ascending current regional, OS-specific pay-as-you-go compute cost order, with 2 vCPUs each and minimum RAM of 4 GiB for Web, 8 GiB for SQL, and 2 GiB for each Linux VM. An assessment recommendation is not proof that a size was selected for the migrated VM.

**Student Actions:**

1. Open **Azure Advisor** → **Cost**, filter to the lab scope, and review any right-size/shutdown recommendations. A newly migrated VM may not yet have a recommendation.
2. Open each VM → **Size** and record the **actual** size. Do not substitute the planned or assessed size for the deployed result.
3. Open **Monitoring** → **Metrics**. Review CPU, disk, and network over the available history. For guest memory, use the configured guest collection and its actual data; do not assume memory is a platform metric just because CPU is available.
4. Compare sustained demand with peaks and workload role. For B-series, review CPU-credit behavior where available; low average CPU alone does not establish that a smaller burstable VM is suitable.
5. Record a recommendation, evidence period, missing data, and expected maintenance impact. Leave size unchanged if the lab has no representative baseline.
6. **Optional approved resize:** During an approved application maintenance window, open **Size**, review available sizes and current displayed prices in the actual region, and select **Resize** only after confirming quota/capacity and downtime implications. Do not stop all four VMs during live writes. Recheck Section 1's application baseline afterward.

**Expected Outcome:** Actual sizes and a justified sizing recommendation are recorded. Any approved resize is distinguished from a proposal and followed by application validation.

### 5.2 Commitment Discounts

**Concept:**

Commitments make sense only after workload and ownership are stable. Current prices and terms depend on region, size, currency, offer, and entitlement; no fixed savings percentage or monthly D2 cost is assumed here.

| Option | Commitment / Entitlement | Appropriate Review |
|---|---|---|
| **Pay-as-you-go** | No long-term compute commitment | Short-lived or uncertain lab usage |
| **Reservation** | Applicable term, scope, and eligible compute usage | Stable, approved long-term demand |
| **Savings plan** | Applicable hourly spend commitment and term | Approved predictable eligible compute spend |
| **Azure Hybrid Benefit** | Qualifying Windows/SQL licensing entitlement | Explicit licensing review; not assumed from a migrated VM or SQL Express installation |

**Student Actions:**

1. Review the actual VM price/offer in the portal and the applicable reservation/savings-plan options without purchasing a commitment.
2. If Azure Hybrid Benefit is being considered, record entitlement as **verified** or **not verified** using the approved licensing process. Do not enable it merely to reduce a displayed estimate.
3. Record whether a short-lived lab justifies any commitment. Leave purchases and licensing changes out of this exercise unless separately approved.

**Expected Outcome:** Your cost recommendation uses current portal values and explicit eligibility rather than canned savings or assumed licenses.

### 5.3 Cost Governance

**Concept:**

Tags support accountability and cost review. Budgets provide notifications; they do not automatically stop the application or cap subscription spending. Policy assignments can affect resources beyond the lab.

| Tag | Purpose | Example |
|---|---|---|
| `CostCenter` | Showback/chargeback | Approved lab cost center |
| `Environment` | Environment classification | `Lab` |
| `Owner` | Accountable team/person | Approved lab owner |
| `Application` | Workload grouping | `MigrationWorkshop` |
| `ManagedBy` | Operational responsibility | Approved operations team |

**Student Actions:**

1. Open each approved lab resource → **Tags**. Review existing values, add/update only the agreed lab tags, and **Save**. Preserve unrelated tags. Do not put credentials or secrets in tags.
2. Open **Cost Management** → select the actual approved **scope** → **Cost analysis**. Filter/group by resource group/resource and review compute, disks, monitoring, networking, and any optional backup/protection resources.
3. Record the displayed cost period, currency, actual VM SKUs, and data availability. Include all four VMs at their actual selected B2 or D2 sizes; do not apply a fixed-series estimate or a canned monthly total.
4. If budget creation is approved and your role permits it, open **Budgets** → **+ Add** at the smallest supported approved scope. Confirm the resource-group/subscription scope before creating anything.
5. Enter a name such as `migrate-workshop-budget`, a monthly reset period, approved amount/currency, and dates. Configure approved recipients with example thresholds of actual cost 50% and 80%, and forecast cost 100%; adjust to the approved budget.
6. Review and select **Create** only for that approved scope. If you lack budget rights, record the reviewed amount/scope and **creation deferred** rather than changing subscription access.
7. Review existing cost-related **Azure Policy** assignments if permitted; do not assign new allowed-size, allowed-region, deny, or modify policies at a shared/company scope for this lab.

**Expected Outcome:** Tags and actual cost scope are reviewed; any budget created is explicitly scoped and evidenced. No subscription-wide policy or spending-stop guarantee is implied.

### 5.4 Identify and Eliminate Waste

**Concept:**

Unattached disks and unused public IPs can still have a purpose, including rollback or recovery. Non-production shutdown schedules can save compute, but they interrupt this multi-VM application and do not eliminate all storage charges.

**Student Actions:**

1. Open the target resource group → filter for **Disks** and **Public IP addresses**. Inspect attachment/association status and ownership tags.
2. Record possible unused resources and their migration/test/backup/rollback purpose. Do not delete a disk, public IP, vault, or source VM based only on its apparent inactivity.
3. Open each VM → **Operations** → **Auto-shutdown** and review current configuration. Enable or change it only if separately approved for this lab, with a coordinated stop/start plan, time zone, and notification. Do not interrupt live order writes.
4. Record which resources need an authorized cleanup decision and which optional resources continue to incur charges. Keep rollback/recovery retention decisions separate from cost recommendations.

**Expected Outcome:** Potential waste and approved scheduling decisions are recorded without deleting needed recovery resources or stopping the application unexpectedly.

---

## 6. Operational Maturity — Update Management

> **WAF Pillar: Reliability + Security**

**Concept:**

Patch visibility and controlled installation are separate activities. **Azure Update Manager** provides current assessment; this required exercise does not install patches or reboot the four application VMs.

### 6.1 Configure Azure Update Manager — Assess Current Status

**Concept:**

An assessment checks the Windows/Ubuntu guest update state. It is not a patch deployment, and its result is specific to the actual assessment timestamp.

**Student Actions:**

1. Open **Azure Update Manager** → **Machines**, filter to the actual target subscription/resource group, and select the four migrated VMs, not test copies.
2. Check that each VM is running and its Azure VM agent is ready before relying on assessment. Record a not-ready/unsupported/permission result rather than treating it as success.
3. Select **Check for updates** (assessment), not **Install updates** or a one-time deployment. Review the selected VM scope before confirming.
4. Open each machine's assessment result after it completes. Record the last assessment time, available security/other update counts, reboot-pending indication, and any failed/pending status shown.
5. Keep the existing application running. Do not automatically reboot all VMs or install an update during live writes to make the status green.

**Expected Outcome:** A current Windows and Ubuntu patch-assessment record exists, including actual completion/pending status; no patch installation is claimed.

### 6.2 Schedule Maintenance Windows — Optional

**Concept:**

A maintenance schedule must account for SQL, Tomcat, Nginx, and IIS dependencies. A schedule that reboots all four simultaneously can interrupt transactions. The original weekly-window pattern is a design example, not a mandatory enabled schedule.

**Student Actions:**

1. Record a proposed maintenance window, time zone, update scope, reboot policy, application stop/start sequence, and post-change validation using Section 1.
2. If schedule creation is separately approved, open **Azure Update Manager** → **Maintenance configurations** → **+ Create** and select **Guest (Azure VM)** maintenance scope.
3. Review the approved name, region/resource group, schedule, supported duration, reboot setting, and machine patch-orchestration prerequisites shown. Select only the approved machine subset; do not automatically attach all four to the same reboot window.
4. Under **Updates**, review the classifications actually available for each OS, such as Windows Critical/Security and supported Linux Security/other classifications. Do not assume both operating systems expose identical options.
5. Create the configuration only when the schedule, machine assignments, prerequisites, and billing effects are approved. Otherwise cancel and record **planned — not enabled**.

**Expected Outcome:** A maintenance proposal is recorded, and an active schedule is claimed only if explicitly approved and created. No automatic installation/reboot is introduced by the required assessment exercise.

### 6.3 Enable Periodic Assessment — Optional

**Concept:**

Periodic assessment can maintain update visibility without itself being the scheduled installation policy. Permissions, supported guest configuration, and applicable costs still need review.

**Student Actions:**

1. In Update Manager, open **Update settings** for the approved VMs and review **Periodic assessment** separately from patch orchestration/installation settings.
2. If approved, enable periodic assessment for the selected scope and save. Otherwise leave it unchanged and record the current setting.
3. Record the actual setting and next review date. Do not change reboot/install orchestration while enabling assessment. After any later approved installation/reboot, repeat Section 1's application checks.

**Expected Outcome:** Periodic-assessment status is recorded accurately; assessment is not confused with automatic patching.

---

## 7. Day 2 Operations Runbook

**Concept:**

This is the checklist used for operational handoff after migration cutover. It records what was actually completed and what remains planned; a lab exercise is not proof of a production-ready environment.

### Day 2 Operations Workflow

```text
Application baseline -> Monitoring/data arrival -> Alert delivery
         -> Protection record -> NSG hardening and application recheck
         -> Cost review -> Update assessment -> Assigned follow-up review
```

### Post-Migration Operations Checklist

Statuses are **verified**, **pending**, **failed**, **deferred**, or **not approved**. Optional services are not required to be enabled to complete the record.

| # | Student Task / Evidence to Record | Scope |
|---|---|---|
| 1 | Record actual private IPs, local service checks, readiness, and order read | Required, all four target VMs |
| 2 | Record workspace, AMA status, DCR sources/destinations, and each VM association | Required monitoring activity, approved scope |
| 3 | Record actual telemetry timestamps/resource IDs or pending collection | Required; not inferred from extension status |
| 4 | Record alert rule scope and action-group email test result | Approved alerting scope; identify deferrals |
| 5 | Record RPO/RTO and backup policy design | Required decision record |
| 6 | Record backup job and actual recovery point | Optional approved backup activity |
| 7 | Record isolated restore result, if performed | Optional; no source/live overwrite |
| 8 | Record NIC/subnet effective-policy review and changed rule values | Required network review/hardening activity |
| 9 | Recheck all five application paths and management access after hardening | Required before/after evidence |
| 10 | Record actual Bastion/JIT availability and management method | Review required; deployments optional |
| 11 | Record VNet flow-logging status and approved costs, if enabled | Optional |
| 12 | Record Defender recommendations, existing plans, and any approved change | Review required; paid enablement optional |
| 13 | Record actual VM sizes, utilization history, and sizing recommendation | Required; resize optional |
| 14 | Record cost scope, currency/period, tags, and budget status | Required review; budget creation subject to rights/approval |
| 15 | Record Windows/Ubuntu update-assessment timestamps and results | Required; installation/reboot not required |
| 16 | Record periodic-assessment setting and proposed maintenance window | Review required; scheduling optional |
| 17 | Record IAM findings and DR purpose/prerequisites/recovery-plan outline | Required review; no new DR deployment |
| 18 | Record follow-up owners/dates and source-decommission/cleanup decisions | Planning only; no source deletion |

**Why It Matters:** Operational evidence needs clear ownership and due dates, including work that could not be completed or that needs a separate approval.

**Student Actions:**

1. Complete the checklist in your existing lab notes. For each item, add the actual status, resource scope, evidence timestamp/screenshot reference where useful, owner, and next review date. Do not include passwords, tokens, SQL connection secrets, or protected configuration contents.
2. For a failed health check, record the affected service/path and compare with the last known-good rule/configuration. For a monitoring gap, record the missing extension/association/source/destination/data result. Keep these focused observations, not a claim that all application logs were centrally collected.
3. Record the chosen management method, backup/restore status, patch-assessment result, and any maintenance/rollback decision needed for future changes.
4. Bring forward the Module 4 ADR, clearly separating migration completion, backup evidence, and future DR planning.
5. Review optional resources and ongoing charges against their approved lab lifecycle. Record follow-up decisions rather than deleting source VMs, migration vaults, or recovery data as part of this module.

**Expected Outcome:** Your Day 2 record is an actionable handoff with verified facts, explicit deferrals, and assigned follow-up — not a prefilled claim that every optional service is deployed.

---

## 8. Workshop Summary & Next Steps

**Concept:**

### Module Recap — Mapped to Cloud Adoption Framework

| Module | CAF Phase | Activity to Summarize From Your Actual Results |
|---|---|---|
| **Module 0: Environment Setup** | Ready | Nested Hyper-V lab with Windows Server 2022 and Ubuntu 24.04 workloads |
| **Module 1: Discovery & Assessment** | Plan | Discovery, assessment, sizing, and migration planning for the four servers |
| **Module 2: Migration Preparation** | Migrate | Supported Hyper-V replication preparation and target/test planning |
| **Module 3: Migration Validation & Cutover** | Migrate | All four VMs use the same host-provider path; manual tests, cutover, alias repointing, and application validation |
| **Module 4: ASR vs Azure Migrate** | Migrate — Tool Selection | Tool comparison, ADR, recovery requirements, and optional review-only ASR walkthrough |
| **Module 5: Post-Migration Operations** | Manage + Govern | Actual monitoring/network/cost/update results and optional protection activities |

All four targets remain **Azure IaaS VMs**. SQL Managed Instance, App Service, and containers are separate future modernization discussions, not services implemented by this migration lab.

### What You Delivered

The completed record distinguishes:

- Migration/application validation evidence from conceptual discussion
- A documented Azure Migrate versus ASR recommendation
- Monitoring configuration from actual received telemetry
- Backup policy design from completed backup/restore evidence
- Network hardening from optional Bastion/JIT/Defender deployment
- Cost and update assessments from optional resizing, commitments, or patch installation
- An operations handoff with remaining approvals and follow-up dates

### What Comes Next in a Real Migration

A workshop demonstrates mechanics; a real migration also needs organization-specific review.

| Next Step | Existing Planning Topic |
|---|---|
| **Landing zone** | Networking, identity, subscriptions, and resource governance |
| **Migration waves** | Repeatable assessment, testing, cutover, and acceptance |
| **Cloud governance** | Approved policy, tagging, budgets, and accountability |
| **Workload modernization** | Separately evaluated platform alternatives; not part of this IaaS rehost |
| **Well-Architected review** | Review actual operational evidence and remaining risks |

### Additional Resources

The following documentation links are retained as optional reading, not additional required exercises:

- [Azure Migrate Documentation](https://learn.microsoft.com/en-us/azure/migrate/)
- [Azure Site Recovery Documentation](https://learn.microsoft.com/en-us/azure/site-recovery/)
- [Azure Monitor Documentation](https://learn.microsoft.com/en-us/azure/azure-monitor/)
- [Azure Backup Documentation](https://learn.microsoft.com/en-us/azure/backup/)
- [Azure Update Manager Documentation](https://learn.microsoft.com/en-us/azure/update-manager/)
- [Azure Cost Management Documentation](https://learn.microsoft.com/en-us/azure/cost-management-billing/)
- [Azure Well-Architected Framework](https://learn.microsoft.com/en-us/azure/well-architected/)
- [Cloud Adoption Framework — Migrate](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/migrate/)

**Why It Matters:** Workshop completion means you can explain your decisions and actual results. It does not imply untested protection, production availability, or deployment of optional paid services.

**Student Actions:**

1. Review the recap against your own Modules 0–5 results. Correct any unchecked, pending, or deferred activity rather than marking it complete automatically.
2. Confirm the final post-hardening application checks and the operations checklist are recorded.
3. Record outstanding approvals, continuing resource charges, and the next review date. Keep future modernization and DR deployment outside this completed IaaS migration exercise.

**Expected Outcome:** You have a consistent student record of the four-VM Ubuntu 24.04 migration lab and its actual Day 2 operations results.

---

> **Congratulations on completing the Azure Migrate Workshop!**
>
> The operational foundation is as important as the migration mechanics. Keep the decision record, observed results, and follow-up ownership together.

---

> **Workshop Navigation:**
> [← Module 4: ASR vs Azure Migrate — Strategic Tool Selection](Module-4-ASR-Comparison.md) | **Workshop Complete!**
