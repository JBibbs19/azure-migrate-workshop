# Module 1 · Discovery and assessment

**TD SYNNEX | Cloud Enablement Services**

Discover the four workload VMs and build an Azure VM assessment. Keep the discovery appliance separate from the host replication provider introduced in Module 2.

## 1. Create the project

From the Azure portal, search for **Azure Migrate** and create a project in the **source resource group**, for example `ces-migrate-01`. Select the intended subscription and permitted project geography. Project metadata location and migration target region are separate settings; do not use a hard-coded geography mapping. Record the actual resource names the service creates.

Portal labels vary as Azure Migrate rolls out its newer **Explore / Decide / Execute** experience. Follow the operation described here if the portal places it under a different heading. The classic equivalent is **Servers, databases and web apps**. [Create and manage projects](https://learn.microsoft.com/azure/migrate/create-manage-projects)

## 2. Prepare the Hyper-V host

Inside HyperVHost, use the host-preparation script linked from Microsoft's [Hyper-V discovery tutorial](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v). Verify the current published hash/signature before running it in elevated Windows PowerShell. Follow its prompts to configure the discovery account, PowerShell remoting and required permissions. Restrict access to the internal lab network; do not expose WinRM publicly.

For this single-host lab, use `HyperVHost\labadmin` (or your chosen host user) when adding host credentials. Guest Windows credentials are different: `Administrator`, with the lab password. Do not enable CredSSP solely because it appears in a cluster example: this lab stores guest disks locally, not on remote SMB shares.

## 3. Download, extract and import the appliance VHD

Deployment creates the four workloads only; it does not build an appliance VM. It does attach and format the host's staging volume, so the appliance VHD has capacity of its own. Work inside HyperVHost in an elevated Windows PowerShell session.

1. In the project, open discovery, select **Hyper-V** as the source, and choose the **VHD** download option rather than the installer script. Generate a project key for `MigrateAppl`. Keep the key out of Git and screenshots.
2. Confirm the staging volume before downloading anything:

```powershell
Get-Volume -DriveLetter L | Select-Object DriveLetter,FileSystemLabel,SizeRemaining
```

   Continue only when `L:` is present, labelled `ApplianceStaging`, and reports at least 30 GB free. The compressed download and the extracted VHD must both fit; do not stage either one on `C:`, where the guest VHDs live.
3. Download the current appliance archive from the project's download link into `L:\Appliance`, then verify it against the hash Microsoft publishes for that exact file before extracting:

```powershell
$archive = Get-ChildItem 'L:\Appliance' -Filter *.zip | Select-Object -First 1
Get-FileHash -Path $archive.FullName -Algorithm SHA256 | Format-List
Expand-Archive -Path $archive.FullName -DestinationPath 'L:\Appliance\Extracted'
```

   Stop if the hash does not match the published value. Delete the archive only after the import succeeds, and only if you need the space back.
4. Import the extracted VHD as a Hyper-V VM on the internal lab switch, then reserve its address:

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

   `-Generation 1` matches Microsoft's currently published `.vhd`. Confirm the generation and disk format in the current article instead of assuming; a Generation 2 VM will not boot a Generation 1 VHD. The static MAC and reservation follow the same `00-15-5D-00-00-xx` scheme the deployment uses for the workloads, so the appliance receives `192.168.0.20` from the host's DHCP scope.
5. Open the VM console, accept the appliance's first-boot prompts and set its administrator password when prompted. Verify eight processors, 16 GB RAM, address `192.168.0.20`, gateway `192.168.0.1`, working DNS, internet access and correct time before continuing.

The appliance software is already present in Microsoft's VHD; do not run `AzureMigrateInstaller.ps1` inside it, and never run it on HyperVHost itself. If your instructor deliberately chooses the script-based installation route on a Windows VM they build separately, prepare the Gateway payload first with [Expand-LabApplianceGateway.ps1](../scripts/Expand-LabApplianceGateway.ps1) and follow [Gateway extraction troubleshooting](Troubleshooting.md#appliance-installer-cannot-find-the-gateway-setup-program) if it fails.

Production prerequisites document an external switch. This nested lab uses one NIC with NAT/DHCP for both host reachability and egress; its end-to-end operation must be proven in the instructor rehearsal. [Set up an appliance for Hyper-V](https://learn.microsoft.com/azure/migrate/tutorial-discover-hyper-v)

## 4. Register and discover

After the imported appliance finishes its first boot, use the appliance configuration manager shortcut inside `MigrateAppl`, or its documented HTTPS endpoint from the host browser: `https://192.168.0.20:44368`. Confirm the page opens before beginning registration. Verify you are connecting to your own appliance before accepting its initial certificate prompt.

1. Finish connectivity, time and update checks.
2. Paste the project key and sign in to the correct Azure tenant/subscription.
3. Add the Hyper-V host credentials and host address `192.168.0.1`.
4. Validate the source, resolve every failed prerequisite, then start discovery.
5. Add guest credentials only for the software inventory/dependency features being demonstrated. Confirm their guest-side prerequisites in the support matrix.
6. Return to the project and verify the four **workload names**, OS details, CPU and memory. Do not accept a raw count of four machines as proof: the appliance itself can appear in inventory.

| Workload | Expected source OS | Expected address |
|---|---|---|
| OnPrem-Web | Windows Server 2022 | 192.168.0.10 |
| OnPrem-SQL | Windows Server 2022 | 192.168.0.11 |
| OnPrem-Linux-Web | Ubuntu 22.04 | 192.168.0.12 |
| OnPrem-Linux-App | Ubuntu 22.04 | 192.168.0.13 |

Exclude `MigrateAppl` from workload migration. Discovery takes time and runs continuously; diagnose appliance/host validation failures before simply waiting longer. [Hyper-V assessment support matrix](https://learn.microsoft.com/azure/migrate/migrate-support-matrix-hyper-v)

## 5. Create the assessment

Create an **Azure VM** assessment for a group containing exactly the four workload VMs. Use the target region chosen in Module 0, the relevant currency/pricing agreement, no commitment discounts for this short lab, and no Azure Hybrid Benefit unless the instructor has confirmed entitlement.

For a just-created lab, first use **as-on-premises** sizing. Then compare a performance-based assessment after data has accumulated. Record the collection period, confidence rating and idle nature of the samples. A few minutes of idle telemetry cannot justify a production right-sizing recommendation. [Assess Hyper-V servers](https://learn.microsoft.com/azure/migrate/tutorial-assess-hyper-v)

Record for each machine: readiness, any unsupported configuration, selected Azure size, OS disk, target network, and estimated compute/storage cost. Resolve readiness warnings against the migration support matrix before replication.

## 6. Discuss dependencies honestly

In a lab deployed without the optional traffic mesh, the sample IIS site, Nginx site and Node API do **not** call SQL or each other. An empty application dependency view is then correct. Do not ask learners to locate a connection string or a `/api/products` endpoint that does not exist. Agentless dependency discovery also requires supported guest credentials and time to collect observations. Do not install the retired Microsoft Monitoring Agent to make a diagram appear.

To demonstrate a populated map instead, enable the [lab traffic mesh](Lab-Traffic.md) on HyperVHost after deployment. It wires the four workloads into one order desk — Nginx proxies to the Node API, the Node API reads and writes `ContosoApp` over TCP 1433, and the IIS guest runs an internal order report against the same database — so `OnPrem-SQL` appears as a shared dependency of both application tiers. Enable it early: dependency analysis samples active connections on a polling interval, so traffic started minutes before you open the map may not appear in it. Keep the generated load light, for the same reason the sizing guidance below warns about idle telemetry.

**Pass gate:** the appliance is registered, host validation succeeds, the four named workloads are visible, and the assessment exists with reviewed readiness. Continue to [Module 2](Module-2-HyperV-Migration.md).
