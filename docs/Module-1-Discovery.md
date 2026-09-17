# Module 1 · Discovery and assessment

**TD SYNNEX | Cloud Enablement Services**

In this module you discover the four workload VMs you built in Module 0 and produce an Azure VM assessment from them. Two different components are involved, and keeping them straight now will save confusion later: the **discovery appliance** you build here performs assessment, while the **host replication provider** introduced in Module 2 is what actually moves VM data.

## 1. Create the project

From the Azure portal, search for **Azure Migrate** and create a project in your **source resource group** — for example `ces-migrate-01`. Select the intended subscription and a permitted project geography, then record the resource names the service creates.

> **Note:** The project metadata location and the migration target region are separate settings. Do not assume one determines the other, and do not rely on a hard-coded geography mapping.

Portal labels vary as Azure Migrate rolls out its newer **Explore / Decide / Execute** experience. Follow the operation described here if the portal places it under a different heading. The classic equivalent is **Servers, databases and web apps**. [Create and manage projects](https://learn.microsoft.com/azure/migrate/create-manage-projects)

## 2. Prepare the Hyper-V host

Inside HyperVHost, run the host-preparation script linked from Microsoft's [Hyper-V discovery tutorial](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v) in an elevated Windows PowerShell session. Verify its currently published hash or signature before running it. Follow its prompts to configure the discovery account, PowerShell remoting and the required permissions.

Deployment has already opened WinRM to the nested subnet only, which is the path the appliance uses. Keep it that way — there is no reason to expose WinRM beyond the internal lab network.

When you add host credentials later, use `HyperVHost\labadmin` (or whichever host user you chose). The guest Windows credentials are different: `Administrator`, with the lab password.

> **Warning:** Do not enable CredSSP just because you see it in a cluster example. This lab stores guest disks locally, not on remote SMB shares, so it is not needed.

## 3. Download, extract and import the appliance VHD

The Azure Migrate appliance is a lightweight Windows Server VM that performs agentless discovery of your Hyper-V environment. Deployment did not create it — it created the four workloads and a staging volume sized for the appliance download. You build the appliance here, from Microsoft's published VHD.

Work inside HyperVHost in an elevated Windows PowerShell session.

### 3.1 — Generate the project key

1. In your Azure Migrate project, open discovery and select **Hyper-V** as the source.
2. Choose the **VHD** download option rather than the installer script.
3. Enter the appliance name `MigrateAppl` and generate the project key.
4. **Copy the key and keep it somewhere safe** — you need it during registration, and it must stay out of Git, screenshots and chat.

### 3.2 — Confirm the staging volume

Before downloading anything, check that the volume deployment prepared for you is present and has room:

```powershell
Get-Volume -DriveLetter L | Select-Object DriveLetter,FileSystemLabel,SizeRemaining
```

**Expected result:** `L:` exists, is labelled `ApplianceStaging`, and reports at least 30 GB free.

> **Note:** Both the compressed download and the extracted VHD have to fit here. Do not stage either one on `C:` — that is where the four guest VHDs live, and filling it will disrupt the running workloads.

### 3.3 — Download and verify the archive

Download the appliance archive from the project's download link into `L:\Appliance`. Then verify it against the hash Microsoft publishes for that exact file before you extract it:

```powershell
$archive = Get-ChildItem 'L:\Appliance' -Filter *.zip | Select-Object -First 1
Get-FileHash -Path $archive.FullName -Algorithm SHA256 | Format-List
Expand-Archive -Path $archive.FullName -DestinationPath 'L:\Appliance\Extracted'
```

Stop if the hash does not match. Keep the archive until the import succeeds; delete it afterwards only if you need the space back.

> **Tip:** Download directly onto the host with the Edge browser inside HyperVHost, rather than downloading to your workstation and copying a 10 GB file across an RDP session.

### 3.4 — Import the VHD as a VM

Create the appliance VM on the internal lab switch and reserve its address:

```powershell
$vhd = (Get-ChildItem 'L:\Appliance\Extracted' -Recurse -Include *.vhd,*.vhdx | Select-Object -First 1).FullName
New-VM -Name MigrateAppl -MemoryStartupBytes 16GB -VHDPath $vhd -SwitchName intSwitch -Path 'L:\Appliance\VMs' -Generation 1
Set-VMProcessor -VMName MigrateAppl -Count 8
Set-VMMemory -VMName MigrateAppl -DynamicMemoryEnabled $false
Set-VM -Name MigrateAppl -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing
Set-VMNetworkAdapter -VMName MigrateAppl -StaticMacAddress '00155D000014'
Add-DhcpServerv4Reservation -ScopeId 192.168.0.0 -IPAddress 192.168.0.20 `
    -ClientId '00-15-5D-00-00-14' -Name MigrateAppl
Start-VM -Name MigrateAppl
```

The static MAC follows the same `00-15-5D-00-00-xx` scheme deployment used for the workloads, so the appliance picks up `192.168.0.20` from the host's DHCP scope automatically.

> **Warning:** `-Generation 1` matches the `.vhd` Microsoft currently publishes. Confirm the generation and disk format in the current article rather than assuming — a Generation 2 VM will not boot a Generation 1 VHD, and the failure looks like a broken download.

### 3.5 — Complete first boot

Open the VM console in Hyper-V Manager, accept the appliance's first-boot prompts, and set its administrator password when asked. Then confirm the appliance has:

- Eight processors and 16 GB RAM
- Address `192.168.0.20`, gateway `192.168.0.1`
- Working DNS and internet access
- Correct system time

**Expected outcome:** `MigrateAppl` is running in Hyper-V Manager alongside the four workload VMs.

> **Note:** The appliance software is already in Microsoft's VHD. Do not run `AzureMigrateInstaller.ps1` inside it, and never run it on HyperVHost itself.

> **Instructor note.** If you deliberately choose the script-based installation route on a Windows VM you build separately, prepare the Gateway payload first with [Expand-LabApplianceGateway.ps1](../scripts/Expand-LabApplianceGateway.ps1), and follow [Gateway extraction troubleshooting](Troubleshooting.md#appliance-installer-cannot-find-the-gateway-setup-program) if it fails. Note also that Microsoft's production prerequisites document an external switch; this nested lab uses one NIC with NAT and DHCP for both host reachability and egress, so prove that path end to end in rehearsal before teaching it. [Set up an appliance for Hyper-V](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v)

## 4. Register and discover

Once the appliance has finished its first boot, open the appliance configuration manager — the shortcut inside `MigrateAppl`, or `https://192.168.0.20:44368` from a browser on the host.

> **Warning:** Use HTTPS on port 44368. The configuration manager does not respond on HTTP. You will see a certificate prompt on first connection; confirm you are connecting to your own appliance before accepting it.

Work through the configuration manager in order:

1. Complete the connectivity, time and update checks.
2. Paste the project key and sign in to the correct Azure tenant and subscription.
3. Add the Hyper-V host credentials and the host address `192.168.0.1`. Use `HyperVHost\labadmin` — the guest Windows credentials are different.
4. Validate the source, resolve every failed prerequisite, then start discovery.
5. Add guest credentials only for the software inventory or dependency features you intend to demonstrate. Check their guest-side prerequisites in the support matrix first.
6. Return to the project and confirm the four workloads appear:

| Workload | Expected source OS | Expected address |
|---|---|---|
| OnPrem-Web | Windows Server 2022 | 192.168.0.10 |
| OnPrem-SQL | Windows Server 2022 | 192.168.0.11 |
| OnPrem-Linux-Web | Ubuntu 22.04 | 192.168.0.12 |
| OnPrem-Linux-App | Ubuntu 22.04 | 192.168.0.13 |

Check the **names**, OS details, CPU and memory — not just the count. A raw total of four machines is not proof, because the appliance itself can appear in inventory.

> **Tip:** Discovery runs continuously and takes time, so a short wait and a refresh are normal. But if host validation is failing, waiting longer will not fix it — diagnose the validation error first. [Hyper-V assessment support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v)

When you plan migration waves later, exclude `MigrateAppl` from the workloads you move. The appliance is lab infrastructure, not a workload.

## 5. Create the assessment

Create an **Azure VM** assessment for a group containing exactly the four workload VMs. Use the target region you chose in Module 0, the currency and pricing agreement that apply to you, no commitment discounts for a lab this short, and no Azure Hybrid Benefit unless entitlement has been confirmed.

On a freshly built lab, start with **as-on-premises** sizing. Then create a second, performance-based assessment once data has accumulated and compare the two.

Record for each machine: readiness, any unsupported configuration, the selected Azure size, OS disk, target network, and the estimated compute and storage cost. Resolve readiness warnings against the migration support matrix before you replicate anything in Module 2.

> **Warning:** Write down the collection period, the confidence rating, and the fact that these samples come from an idle lab. A few minutes of idle telemetry cannot justify a production right-sizing recommendation, and presenting it as though it can is the single most common way a good assessment loses a customer's trust. [Assess Hyper-V servers](https://learn.microsoft.com/azure/migrate/tutorial-assess-hyper-v)

## 6. Interpret the dependency view

What you see here depends on whether the sample business traffic from [Module 0, section 6](Module-0-Setup.md#6-start-the-sample-business-traffic) is running.

**Without it,** the IIS site, the Nginx site and the Node API are independent samples — none of them calls SQL or each other. An empty application dependency view is the correct result, and saying so is a more useful lesson than manufacturing a diagram. Do not go looking for a connection string or a `/api/products` endpoint; they do not exist in the base lab.

**With it,** the four workloads behave as one order desk: Nginx proxies to the Node API, the Node API reads and writes `ContosoApp` over TCP 1433, and the IIS server runs an internal order report against that same database. `OnPrem-SQL` therefore appears as a shared dependency of both application tiers — the finding that tells a customer the database cannot be moved on its own.

Either way, agentless dependency discovery needs supported guest credentials and time to collect observations.

> **Note:** Do not install the retired Microsoft Monitoring Agent to make a diagram appear.

> **Instructor note.** Start the traffic mesh before appliance registration if you want a populated map. Dependency analysis samples active connections on a polling interval rather than recording continuously, so traffic that begins a few minutes before you open the map may not be represented in it. Keep the generated load light — the same idle-telemetry caveat in section 5 cuts both ways, and a heavy generator produces sizing recommendations that are just as fictional as an idle lab's.

**Pass gate:** the appliance is registered, host validation succeeds, the four named workloads are visible, and the assessment exists with reviewed readiness. Continue to [Module 2](Module-2-HyperV-Migration.md).
