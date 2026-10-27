<#
.SYNOPSIS
Deploy the TD SYNNEX Cloud Enablement Services Hyper-V workshop.
.DESCRIPTION
Creates one Standard-security Windows host and provisions four nested workload VMs
(two Windows, two Linux) that behave as one small-business environment. All four use the
existing Hyper-V host provider for migration. Optional discovery archive staging starts alongside OS image preparation
on the host's own disk; Module 1 imports it manually. This script creates billable Azure resources.
Use a new dedicated resource group. Existing groups are refused intentionally.
Process timing starts after parameter binding and includes preflight and user prompts.
It includes required network startup/verification and cleanup, before optional CPU startup and the final exit pause.
.PARAMETER AdminPasswordConfirmation
Enter the administrator password a second time as a SecureString. It must match exactly,
including case and spaces. When omitted, an interactive run prompts with masked input;
unattended runs must supply this parameter. LAB_NO_PAUSE does not waive confirmation.
.PARAMETER SubscriptionId
The workshop subscription GUID, supplied as a SecureString so it is masked at the prompt
rather than displayed on a shared screen. It is not treated as a stored secret.
.PARAMETER AdminSourceCidr
Your public IPv4 address, supplied as a SecureString for the same reason. The /32 suffix
is optional and is added when absent; the lab only ever permits a single address.
Required for the host RDP rule.
.PARAMETER AzureOperationTimeoutMinutes
Maximum monitored wait for each Azure host, network or disk creation operation.
.PARAMETER GuestSetupTimeoutMinutes
Azure's execution limit for ConfigureWorkshop; individual installer limits also apply.
.PARAMETER ApplianceStoreSizeGB
Size of the dedicated partition carved out of the host OS disk for the Azure Migrate
appliance files. This is host-side storage, not the appliance guest's disk/partition capacity.
.PARAMETER ApplianceStoreDriveLetter
Drive letter for that partition inside HyperVHost. Leave it unset and deployment uses the
first unassigned letter, which is E: on the default host size: C: is the OS disk and D: is
the virtual DVD drive. Supply a letter only to override that choice.
.PARAMETER IncludeApplianceVhd
Whether to download the AZURE MIGRATE APPLIANCE VHD onto the host during deployment. This is
Microsoft's appliance virtual machine - not the Hyper-V host-preparation script, which is a
separate download and easily confused with it. Default No,
which is the right answer for a learner: it is an ~11 GB download that is not needed to finish
Module 0, and Module 1 fetches the appliance from the Azure Migrate project when it is actually
required - which is also the link that serves the current build. Yes is for an instructor
preparing a host before a session. Yes starts background download/extraction in the OS image
phase, overlapping ADK/QEMU and workload setup. It is collected before final host readiness;
any optional staging failure is reported separately. No host sign-in is needed during setup.
When not supplied, the script asks once and defaults to No.
.PARAMETER ApplianceVhdSha256
The SHA256 Microsoft publishes for the AZURE MIGRATE APPLIANCE VHD archive - the Hyper-V zip
listed under 'Verify security' in the appliance article. Used only with -IncludeApplianceVhd
Yes, and intended for unattended runs: when supplied, the host checks the archive against it
during staging and retains a mismatching ZIP for inspection without extracting it. When omitted,
the archive is staged as unverified. SHA256 is still computed on the host; there is no end-of-run
checksum prompt or extra rehash call. Module 1 section 2.1 retains an optional recommended manual
comparison against Microsoft's current Hyper-V ZIP hash after deployment and before import.
.PARAMETER TomcatJdbcJar
Optional local official mssql-jdbc-13.6.0.jre11.jar when the guest cannot use Maven HTTPS.
Supply -TomcatJdbcSha256 with a separately reviewed expected checksum. No new password prompt.
.PARAMETER TomcatJdbcSha256
Expected SHA256 for the explicit local JDBC JAR. Required together with -TomcatJdbcJar.
.PARAMETER CpuSimulation
Independent OPTIONAL Prompt (default, No), Start or Skip for bounded source CPU activity after
deployment timing. Noninteractive/unattended Prompt skips CPU; LAB_NO_PAUSE=1 suppresses its
default question. Explicit CpuSimulation Prompt overrides that only interactively. No automatic renewal.
.PARAMETER CpuDurationHours
CPU lifetime in hours, default 24, range 1-168. Does not limit persistent network traffic.
.PARAMETER HealthPath
Local JSON status summary, without credentials or raw Run Command output.
.EXAMPLE
$secureSubscriptionId = Read-Host 'Workshop subscription ID' -AsSecureString
$secureAdminCidr = Read-Host 'Your public IPv4 address' -AsSecureString
$password = Read-Host 'Lab password' -AsSecureString
$passwordConfirmation = Read-Host 'Confirm lab password' -AsSecureString
.\scripts\deploy-lab.ps1 -SubscriptionId $secureSubscriptionId -ResourceGroupName 'rg-ces-source-01' -AdminUsername 'labadmin' -AdminPassword $password -AdminPasswordConfirmation $passwordConfirmation -AdminSourceCidr $secureAdminCidr
MODULE COVERAGE
    The scripts and the modules are run separately. This script completes:

      Module 0, section 4   Deployment Steps - the whole of it.
      Module 1, section 2.2 Prepare the Hyper-V host - applied in full (PHASE 7 of the
                             host payload); the module retains manual confirmation steps.
      Module 1, section 2.1 Download the archive - optional staging begins in the image phase
                             and is collected before final readiness. Hash comparison is enforced
                             if supplied; otherwise the staged archive is explicitly unverified.
                             The recommended manual publisher comparison remains optional.

    Required source network traffic is installed, started and verified after application readiness.
    Independent optional CPU startup is offered only after preparation/cleanup and deployment timing.
    Left for you: Module 0 section 5 (verify inside HyperVHost), section 6 (observe required traffic),
    and all of Module 1 from section 1 onward.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][SecureString]$SubscriptionId,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]{1,60}$')][string]$ResourceGroupName,
    [string]$Location = 'eastus',
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]{2,18}$')][string]$AdminUsername,
    [Parameter(Mandatory)][SecureString]$AdminPassword,
    [Parameter(Mandatory)][SecureString]$AdminSourceCidr,
    [string]$VMSize = 'Standard_E8s_v7',
    [ValidateRange(15,120)][int]$AzureOperationTimeoutMinutes = 60,
    [ValidateRange(30,240)][int]$GuestSetupTimeoutMinutes = 240,
    [ValidateRange(60,400)][int]$ApplianceStoreSizeGB = 100,
    [ValidatePattern('^([D-Zd-z])?$')][string]$ApplianceStoreDriveLetter = '',
    [ValidateSet('Yes','No')][string]$IncludeApplianceVhd,
    [ValidatePattern('^([0-9A-Fa-f]{64})?$')][string]$ApplianceVhdSha256 = '',
    [string]$TomcatJdbcJar = '',
    [ValidatePattern('^([0-9A-Fa-f]{64})?$')][string]$TomcatJdbcSha256 = '',
    [ValidateSet('Prompt','Start','Skip')][string]$CpuSimulation = 'Prompt',
    [ValidateRange(1,168)][int]$CpuDurationHours = 24,
    [string]$HealthPath,
    [SecureString]$AdminPasswordConfirmation
)
$script:ProcessStartedAt = [DateTimeOffset]::Now
$script:ProcessClock = [Diagnostics.Stopwatch]::StartNew()
$script:ProcessTimingReported = $false
Microsoft.PowerShell.Utility\Write-Host "Deployment process started: $($script:ProcessStartedAt.ToString('o'))"
Microsoft.PowerShell.Utility\Write-Host 'Timing includes preflight, prompts, required network startup/verification and cleanup; excludes optional CPU startup and the final exit pause.'
$ErrorActionPreference = 'Stop'
$script:CpuPromptExplicit = $PSBoundParameters.ContainsKey('CpuSimulation') -and $CpuSimulation -eq 'Prompt'

# ================================================================
# Launch resilience
# ================================================================
# This script must run the same way whether it is started from an open PowerShell window or
# by right-clicking it and choosing "Run with PowerShell". The two differ in ways that matter:
#
#   Right-click  - a brand new process, and the WINDOW CLOSES the moment the script ends,
#                  taking any error with it.
#   Open window  - the window survives, but the session may already be carrying state from a
#                  script run earlier in it.
#
# Both are handled here.

# A migrate-step script defines its own Write-Host and Write-Warning so it can mask
# subscription IDs on a shared screen. Those are functions, and a function can outlive the
# script that defined it. When one does, it shadows the real cmdlet for everything that runs
# afterwards in that window - including this script, which then fails on a Write-Host line
# with "$script:LabMaskedValues cannot be retrieved". Any such shadow is removed here, so an
# open window behaves exactly like a fresh one.
foreach ($shadowed in @('Write-Host', 'Write-Warning', 'Write-Error')) {
    try {
        if (Test-Path "Function:\$shadowed") {
            Remove-Item "Function:\$shadowed" -Force -ErrorAction SilentlyContinue
            Microsoft.PowerShell.Utility\Write-Host "Removed a leftover $shadowed override from this session." -ForegroundColor DarkGray
        }
    } catch { }
}

$script:LabScriptPath = $PSCommandPath

function Save-LabDeploymentError {
    # Writes the failure to a file so it survives a window that closes on exit. Any GUID is
    # redacted: the subscription ID is deliberately never written to disk by this script.
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    try {
        $name = if ($script:LabScriptPath) { [IO.Path]::GetFileNameWithoutExtension($script:LabScriptPath) } else { 'deploy-lab' }
        $folder = if ($script:LabScriptPath) { Split-Path -Parent $script:LabScriptPath } else { [IO.Path]::GetTempPath() }
        $path = Join-Path $folder ("{0}-error-{1}.log" -f $name, (Get-Date -Format 'yyyyMMdd-HHmmss'))
        try { Set-Content -Path (Join-Path $folder '.lab-write-test') -Value 'x' -ErrorAction Stop
              Remove-Item (Join-Path $folder '.lab-write-test') -Force -ErrorAction SilentlyContinue }
        catch { $path = Join-Path ([IO.Path]::GetTempPath()) (Split-Path -Leaf $path) }

        $invocation = $ErrorRecord.InvocationInfo
        $report = @(
            "Time       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
            "Script     : $script:LabScriptPath"
            "PowerShell : $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
            "OS         : $([Environment]::OSVersion.VersionString)"
            ''
            "Message    : $([string]$ErrorRecord.Exception.Message)"
            "Type       : $($ErrorRecord.Exception.GetType().FullName)"
            "ErrorId    : $($ErrorRecord.FullyQualifiedErrorId)"
            ''
            "Failed at  : line $($invocation.ScriptLineNumber), column $($invocation.OffsetInLine)"
            "Statement  : $(([string]$invocation.Line).Trim())"
            ''
            'Stack trace:'
            ([string]$ErrorRecord.ScriptStackTrace)
            ''
            'Loaded Az modules:'
        ) + @(Get-Module -Name 'Az.*' | ForEach-Object { "  $($_.Name) $($_.Version)" })

        $redacted = $report | ForEach-Object {
            [regex]::Replace([string]$_, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid-redacted>')
        }
        Set-Content -Path $path -Value $redacted -Encoding UTF8 -ErrorAction Stop
        Write-Host ''
        Write-Host 'A full error report was saved to:' -ForegroundColor Yellow
        Write-Host "  $path" -ForegroundColor Yellow
    } catch {
        Write-Host ''
        Write-Host "  (the error report could not be saved: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

function Complete-LabProcessTiming {
    if ($script:ProcessTimingReported) { return }
    $script:ProcessClock.Stop()
    $endedAt = [DateTimeOffset]::Now
    $script:ProcessTimingReported = $true
    Microsoft.PowerShell.Utility\Write-Host "Deployment process ended: $($endedAt.ToString('o'))"
    Microsoft.PowerShell.Utility\Write-Host "Deployment process elapsed (including preflight, prompts and cleanup): $($script:ProcessClock.Elapsed.ToString('c'))"
}

function Wait-LabBeforeExit {
    # Holds a right-click window open. Set LAB_NO_PAUSE=1 for an unattended run.
    if ($env:LAB_NO_PAUSE -eq '1') { return }
    try {
        if (-not [Environment]::UserInteractive) { return }
        Write-Host ''
        $null = Read-Host 'Press Enter to close this window'
    } catch { }
}

trap {
    Write-Host ''
    Write-Host ($_ | Out-String) -ForegroundColor Red
    Save-LabDeploymentError -ErrorRecord $_
    Complete-LabProcessTiming
    Wait-LabBeforeExit
    exit 1
}
# ================================================================
# Shared helpers, formerly scripts/common.ps1
# ================================================================
# These were a separate file that deploy-lab.ps1 dot-sourced. They are inlined here so the
# deployment is one file plus the two payload files it reads from disk (host/configure-host.ps1
# and health.ps1). Nothing else consumes them: the migrate-step scripts each carry their own
# copies of the helpers they need, for the same reason.

# Shared checks. Dot-source this file; it never connects to Azure or changes resources.
Set-StrictMode -Version Latest

function ConvertFrom-LabSecureString {
    param([Parameter(Mandatory)][SecureString]$Secure, [Parameter(Mandatory)][string]$Name)
    # Masked at the prompt so the value is not readable over a shared screen. It is not a
    # stored secret: the value still reaches Azure and appears in resource identifiers.
    $plain = [pscredential]::new('lab', $Secure).GetNetworkCredential().Password
    if ($null -ne $plain) { $plain = $plain.Trim() }
    if ([string]::IsNullOrWhiteSpace($plain)) { throw "$Name was entered empty. Rerun and supply it when prompted." }
    return $plain
}

function Assert-LabSubscriptionId {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    if ($SubscriptionId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        throw 'SubscriptionId must be one subscription GUID. Check for a stray character or a pasted resource ID.'
    }
}

function Assert-LabContext {
    param([Parameter(Mandatory)][string]$SubscriptionId)
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context -or -not $context.Subscription -or $context.Subscription.Id -ne $SubscriptionId) {
        throw "Select the intended subscription first: Set-AzContext -SubscriptionId '$SubscriptionId'"
    }
    return $context
}

function Assert-LabResourceGroupName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[\p{L}\p{M}\p{N}_.()-]{1,90}$' -or $Name.EndsWith('.')) {
        throw 'Supply one exact resource group name, without wildcards, whitespace or a resource ID.'
    }
}

function Get-LabResourceGroup {
    param([Parameter(Mandatory)][string]$Name, [switch]$AllowMissing)
    Assert-LabResourceGroupName $Name
    $context = Get-AzContext -ErrorAction Stop
    if (-not $context -or -not $context.Subscription -or [string]::IsNullOrWhiteSpace($context.Subscription.Id)) {
        throw 'Select the intended Azure subscription before inspecting resource groups.'
    }
    $subscription = [uri]::EscapeDataString($context.Subscription.Id)
    $group = [uri]::EscapeDataString($Name)
    # Get-AzResourceGroup can replace CloudException with a generic missing-group
    # message. Use the documented exact ARM GET to preserve its status and code.
    $response = Invoke-AzRestMethod -Path "/subscriptions/$subscription/resourcegroups/$group`?api-version=2021-04-01" -Method GET -ErrorAction Stop
    if ($null -eq $response -or $null -eq $response.StatusCode -or [string]::IsNullOrWhiteSpace($response.Content)) {
        throw "No verifiable Azure response for group '$Name'. No absence or deletion is assumed."
    }
    $body = ConvertFrom-Json -InputObject $response.Content -ErrorAction Stop
    if ($response.StatusCode -ne 200) {
        $code = ''
        if ($null -ne $body -and $body.PSObject.Properties['error'] -and $null -ne $body.error -and $body.error.PSObject.Properties['code']) {
            $code = [string]$body.error.code
        }
        if ($AllowMissing -and $response.StatusCode -eq 404 -and $code -eq 'ResourceGroupNotFound') { return $null }
        throw "Could not verify group '$Name': HTTP $($response.StatusCode), code '$code'. No absence or deletion is assumed."
    }
    $expectedId = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$Name"
    if ($null -eq $body -or $body.name -ne $Name -or
        [uri]::UnescapeDataString($body.id) -ne $expectedId) {
        throw "Azure returned an unexpected resource identity for '$Name'."
    }
    $tags = @{}
    if ($body.PSObject.Properties['tags'] -and $null -ne $body.tags) {
        foreach ($tag in $body.tags.PSObject.Properties) { $tags[$tag.Name] = $tag.Value }
    }
    return [pscustomobject]@{ ResourceGroupName=$body.name; ResourceId=$body.id; Tags=$tags }
}

function Resolve-LabAdminSource {
    param([Parameter(Mandatory)][string]$Cidr)
    # The lab only ever permits a single host, so /32 carries no information and is optional:
    # a bare address is accepted and normalised. An explicitly supplied prefix is still
    # checked rather than overridden, so a range is refused instead of being silently
    # narrowed to one address the caller did not choose.
    $value = $Cidr.Trim()
    $parts = $value.Split('/')
    if ($parts.Count -eq 1) {
        $address = $parts[0]
    } elseif ($parts.Count -eq 2) {
        $address = $parts[0]
        if ($parts[1] -ne '32') {
            throw "AdminSourceCidr must identify a single address. '$value' has a /$($parts[1]) prefix; supply one public IPv4 address, optionally followed by /32."
        }
    } else {
        throw 'AdminSourceCidr must be one public IPv4 address, optionally followed by /32.'
    }
    # Dotted-quad only, no leading zeros. Abbreviated, hexadecimal and integer forms parse to
    # a different address than they appear to, so they are refused rather than interpreted.
    $ip = $null
    if ($address -notmatch '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' -or
        -not [System.Net.IPAddress]::TryParse($address, [ref]$ip) -or
        $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $address -eq '0.0.0.0') {
        throw 'AdminSourceCidr must be your current public IPv4 address, written as four decimal octets without leading zeros. The /32 suffix is optional.'
    }
    return "$address/32"
}

function Assert-LabAdminSource {
    param([Parameter(Mandatory)][string]$Cidr)
    $null = Resolve-LabAdminSource $Cidr
}

function Assert-LabHostSizeName {
    param([Parameter(Mandatory)][string]$VMSize)
    if ($VMSize -notmatch '^Standard_[a-zA-Z0-9][a-zA-Z0-9_-]{1,80}$') {
        throw 'VMSize must be one exact Azure size name, such as Standard_E8s_v7, without wildcards or whitespace.'
    }
}

function Get-LabHostSku {
    param([Parameter(Mandatory)][string]$VMSize, [Parameter(Mandatory)][string]$Location)
    Assert-LabHostSizeName $VMSize
    $matches = @(Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
        Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VMSize })
    if ($matches.Count -ne 1 -or $Location -notin $matches[0].Locations -or
        @($matches[0].Restrictions | Where-Object Type -EQ 'Location').Count) {
        throw "VM size '$VMSize' is not available to this subscription in '$Location'. Choose a size offered in that region or resolve the subscription restriction."
    }
    $sku = $matches[0]
    $capabilities = @{}
    foreach ($capability in $sku.Capabilities) { $capabilities[$capability.Name] = [string]$capability.Value }
    $cores = 0; $availableCores = 0; $memory = [decimal]0
    if (-not [int]::TryParse($capabilities['vCPUs'], [ref]$cores) -or $cores -le 0 -or
        -not [decimal]::TryParse($capabilities['MemoryGB'], [Globalization.NumberStyles]::Number,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$memory)) {
        throw "Cannot verify CPU/RAM metadata for '$VMSize' in '$Location'."
    }
    $availableCores = $cores
    if ($capabilities.ContainsKey('vCPUsAvailable') -and
        -not [int]::TryParse($capabilities['vCPUsAvailable'], [ref]$availableCores)) {
        throw "Cannot verify enabled vCPUs for '$VMSize'."
    }
    if ($availableCores -lt 8 -or $availableCores -gt $cores -or $memory -lt 64) {
        throw "Host size '$VMSize' has $availableCores enabled vCPUs and $memory GiB RAM. This workshop's four workloads plus the imported Azure Migrate appliance require at least 8 enabled vCPUs and 64 GiB RAM."
    }
    if ($capabilities['CpuArchitectureType'] -ne 'x64' -or
        'V2' -notin @($capabilities['HyperVGenerations'] -split ',' | ForEach-Object { $_.Trim() }) -or
        $capabilities['PremiumIO'] -ne 'True') {
        throw "Host size '$VMSize' must report x64, Generation 2 and Premium SSD support for this workshop's Windows image and OS disk."
    }
    if ([string]::IsNullOrWhiteSpace($sku.Family)) { throw "Cannot identify the quota family for '$VMSize'." }
    $usage = @(Get-AzVMUsage -Location $Location -ErrorAction Stop)
    foreach ($name in @($sku.Family, 'cores')) {
        $quota = @($usage | Where-Object { $_.Name.Value -eq $name })
        $limit = [long]0; $used = [long]0
        if ($quota.Count -ne 1 -or
            -not [long]::TryParse([string]$quota[0].Limit, [ref]$limit) -or
            -not [long]::TryParse([string]$quota[0].CurrentValue, [ref]$used) -or $limit -lt 0 -or $used -lt 0) {
            throw "Cannot verify quota '$name' for '$VMSize' in '$Location'."
        }
        if ($limit - $used -lt $cores) {
            throw "Insufficient '$name' quota in '$Location' for '$VMSize': need $cores free vCPUs; $($limit - $used) available. Reserve target/test quota separately."
        }
    }
    # SKU metadata is not a nested-virtualization certification. The instructor
    # verifies the selected series' Microsoft documentation before provisioning.
    return [pscustomobject]@{ Name=$sku.Name; Family=$sku.Family; Cores=$availableCores; MemoryGB=$memory;
        AcceleratedNetworking=($capabilities['AcceleratedNetworkingEnabled'] -eq 'True') }
}

function Invoke-LabImageCatalogGet {
    param([Parameter(Mandatory)][string]$Path)
    # Keep image catalog requests on an explicitly supported API instead of
    # inheriting the installed Az.Compute SDK's default version.
    $response=Invoke-AzRestMethod -Path "$Path`?api-version=2025-04-01" -Method GET -ErrorAction Stop
    if ($null -eq $response -or [string]::IsNullOrWhiteSpace($response.Content)) { throw "No verifiable Windows image catalog response for '$Path'." }
    $body=ConvertFrom-Json -InputObject $response.Content -ErrorAction Stop
    if ($response.StatusCode -ne 200) {
        $code='Unknown'
        if ($null -ne $body -and $body.PSObject.Properties['error'] -and $null -ne $body.error -and $body.error.PSObject.Properties['code']) { $code=[string]$body.error.code }
        throw "Windows image catalog lookup failed: HTTP $($response.StatusCode), code '$code', API 2025-04-01, path '$Path'. Resolve image catalog access before deploying."
    }
    return $body
}

function Get-LabWindowsImages {
    param([Parameter(Mandatory)][string]$Location)
    $context=Get-AzContext -ErrorAction Stop
    if (-not $context -or -not $context.Subscription -or [string]::IsNullOrWhiteSpace($context.Subscription.Id)) { throw 'Select the intended Azure subscription before resolving Windows images.' }
    $subscription=[uri]::EscapeDataString($context.Subscription.Id)
    $region=[uri]::EscapeDataString($Location)
    $images = @{}
    foreach ($role in @('Host','Guest')) {
        $sku = if ($role -eq 'Host') { '2022-datacenter-g2' } else { '2022-datacenter-smalldisk-g2' }
        $offer = 'windowsserver2022'
        $catalog="/subscriptions/$subscription/providers/Microsoft.Compute/locations/$region/publishers/MicrosoftWindowsServer/artifacttypes/vmimage/offers/$offer/skus/$sku/versions"
        $versions = @(Invoke-LabImageCatalogGet $catalog)
        if (-not $versions.Count) { throw "No Windows image versions found: MicrosoftWindowsServer:${offer}:${sku} in '$Location'. Verify region, offer and image access before deploying." }
        foreach ($entry in $versions) {
            $parsed=$null
            if (-not $entry.PSObject.Properties['name'] -or $entry.name -notmatch '^\d+\.\d+\.\d+$' -or
                -not [version]::TryParse($entry.name,[ref]$parsed)) { throw "Invalid Windows image version metadata for ${offer}:${sku} in '$Location'." }
        }
        $version=($versions | Sort-Object { [version]$_.name } -Descending | Select-Object -First 1).name
        $imageId="$catalog/$version"
        $details = @(Invoke-LabImageCatalogGet $imageId)
        if ($details.Count -ne 1 -or -not $details[0].PSObject.Properties['id'] -or
            [uri]::UnescapeDataString($details[0].id) -ne [uri]::UnescapeDataString($imageId) -or
            -not $details[0].PSObject.Properties['properties'] -or $null -eq $details[0].properties) {
            throw "Cannot verify the Windows image identity for ${offer}:${sku}:${version} in '$Location'."
        }
        $properties=$details[0].properties
        if (-not $properties.PSObject.Properties['hyperVGeneration'] -or $properties.hyperVGeneration -ne 'V2' -or
            -not $properties.PSObject.Properties['architecture'] -or $properties.architecture -ne 'x64' -or
            -not $properties.PSObject.Properties['osDiskImage'] -or $null -eq $properties.osDiskImage -or
            -not $properties.osDiskImage.PSObject.Properties['operatingSystem'] -or $properties.osDiskImage.operatingSystem -ne 'Windows') {
            throw "Cannot verify a Windows x64 Gen2 image for ${offer}:${sku}:${version} in '$Location'."
        }
        $images[$role] = [pscustomobject]@{ Publisher='MicrosoftWindowsServer'; Offer=$offer; Sku=$sku; Version=$version; Id=$imageId }
        Write-Host "Resolved $role image: MicrosoftWindowsServer:${offer}:${sku}:${version} (catalog API 2025-04-01)"
    }
    return [pscustomobject]$images
}

function New-LabWindowsGuestDiskConfig {
    param([Parameter(Mandatory)][string]$Location, [Parameter(Mandatory)][string]$ImageId)
    $disk=New-AzDiskConfig -Location $Location -CreateOption FromImage -HyperVGeneration V2 -OsType Windows -ImageReference @{Id=$ImageId} -ErrorAction Stop
    # Standard prevents New-AzDisk's implicit Trusted Launch image lookup and
    # prepares an ordinary OS disk for export to the nested Hyper-V guests.
    $disk=Set-AzDiskSecurityProfile -Disk $disk -SecurityType Standard -ErrorAction Stop
    if ($null -eq $disk -or $null -eq $disk.SecurityProfile -or $disk.SecurityProfile.SecurityType -ne 'Standard') {
        throw 'Az.Compute did not retain Standard security on the temporary guest disk configuration. Update the module before deployment.'
    }
    return $disk
}

function Compress-LabScript {
    param([Parameter(Mandatory)][string]$Text)
    # Gzip keeps the embedded copy small so the managed Run Command payload stays close to
    # its original size. The host decompresses it with the matching framework classes.
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $buffer = [IO.MemoryStream]::new()
    $compressor = [IO.Compression.GzipStream]::new($buffer, [IO.Compression.CompressionMode]::Compress)
    try { $compressor.Write($bytes, 0, $bytes.Length) } finally { $compressor.Dispose() }
    return [Convert]::ToBase64String($buffer.ToArray())
}

function Read-LabHostConfiguration {
    param([Parameter(Mandatory)][string]$Path)
    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($content)) { throw 'The host configuration script is empty. Obtain the complete workshop checkout.' }
    $scriptsRoot = Split-Path (Split-Path $Path -Parent) -Parent
    $healthPath = Join-Path $scriptsRoot 'health.ps1'
    $health = Get-Content -LiteralPath $healthPath -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($health) -or ([regex]::Matches($content, '(?m)^# LAB_HEALTH_HELPERS\r?$')).Count -ne 1) {
        throw 'Host health helpers are missing or incompatible. Obtain the complete workshop checkout.'
    }
    $content = $content.Replace('# LAB_HEALTH_HELPERS', $health)
    # Always deliver the controller. After host readiness, deployment runs the protected
    # required network stage; CPU remains a separate optional action.
    $trafficPath = Join-Path $scriptsRoot 'enable-lab-traffic.ps1'
    $traffic = Get-Content -LiteralPath $trafficPath -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($traffic) -or ([regex]::Matches($content, '__LAB_TRAFFIC_PAYLOAD__')).Count -ne 1) {
        throw 'The lab traffic script is missing or its host placeholder is incompatible. Obtain the complete workshop checkout.'
    }
    $trafficTokens = $null; $trafficErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($traffic, [ref]$trafficTokens, [ref]$trafficErrors)
    if ($trafficErrors.Count) { throw 'The lab traffic script has syntax errors. Obtain the reviewed workshop revision.' }
    $content = $content.Replace('__LAB_TRAFFIC_PAYLOAD__', (Compress-LabScript $traffic))
    if (([regex]::Matches($content, '__LAB_CPU_ASSETS_PAYLOAD__')).Count -ne 1) { throw 'CPU host payload marker incompatible.' }
    $cpuAssets = [ordered]@{}
    $cpuAssetUtf8 = [Text.UTF8Encoding]::new($false, $true)
    foreach ($name in @('control.ps1','windows-cpu.ps1','linux-cpu.py')) {
        $assetPath = Join-Path $scriptsRoot ('cpu-simulation/' + $name)
        $assetBytes = [IO.File]::ReadAllBytes($assetPath)
        # Bare .NET text avoids Get-Content ETS metadata in Windows PowerShell 5.1 JSON.
        # Decoding the bytes directly also preserves a UTF-8 BOM and every newline byte.
        $asset = $cpuAssetUtf8.GetString($assetBytes)
        if ([string]::IsNullOrWhiteSpace($asset)) { throw 'CPU asset missing or empty. Obtain the complete workshop checkout.' }
        if ($name.EndsWith('.ps1')) {
            $assetTokens = $null; $assetErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($assetPath, [ref]$assetTokens, [ref]$assetErrors)
            if ($assetErrors.Count) { throw 'CPU asset syntax errors. Obtain the reviewed workshop revision.' }
        }
        $assetSha = [Security.Cryptography.SHA256]::Create()
        try { $assetHash = ([BitConverter]::ToString($assetSha.ComputeHash($assetBytes))).Replace('-', '').ToLowerInvariant() }
        finally { $assetSha.Dispose() }
        $cpuAssets[$name] = [ordered]@{ Text = $asset; Sha256 = $assetHash }
    }
    $content = $content.Replace('__LAB_CPU_ASSETS_PAYLOAD__', (Compress-LabScript ($cpuAssets | ConvertTo-Json -Depth 4 -Compress)))
    foreach ($entry in @(
        @{ Name='employee-orders.py'; Token='WORKER' },
        @{ Name='control.sh'; Token='CONTROL' },
        @{ Name='contoso-employee-orders.service'; Token='UNIT' }
    )) {
        $assetBytes = [IO.File]::ReadAllBytes((Join-Path $scriptsRoot ('employee-orders/' + $entry.Name)))
        if ($assetBytes.Length -eq 0) { throw 'Employee-order asset is empty.' }
        $assetSha = [Security.Cryptography.SHA256]::Create()
        try { $assetHash = ([BitConverter]::ToString($assetSha.ComputeHash($assetBytes))).Replace('-', '').ToLowerInvariant() }
        finally { $assetSha.Dispose() }
        $payloadMarker = '__EMPLOYEE_' + $entry.Token + '_B64__'
        $hashMarker = '__EMPLOYEE_' + $entry.Token + '_SHA256__'
        foreach ($marker in @($payloadMarker,$hashMarker)) {
            if (([regex]::Matches($content, [regex]::Escape($marker))).Count -ne 1) { throw 'Employee-order host marker incompatible.' }
        }
        $content = $content.Replace($payloadMarker, [Convert]::ToBase64String($assetBytes)).Replace($hashMarker, $assetHash)
    }
    $appRoot = Join-Path (Split-Path $scriptsRoot -Parent) 'apps/contoso-orderdesk'
    $runtimePath = Join-Path $appRoot 'dist/runtime.zip'
    $runtimeHashPath = Join-Path $appRoot 'dist/runtime.sha256'
    foreach ($marker in @('__TOMCAT_RUNTIME_PAYLOAD__','__TOMCAT_RUNTIME_SHA256__')) {
        if (([regex]::Matches($content, [regex]::Escape($marker))).Count -ne 1) { throw 'Tomcat host runtime markers incompatible.' }
    }
    $expected = (Get-Content -LiteralPath $runtimeHashPath -Raw -ErrorAction Stop).Trim()
    if ($expected -notmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash -ine $expected) {
        throw 'Tomcat runtime ZIP missing or checksum mismatch. Rebuild the complete reviewed checkout before deployment.'
    }
    $runtimeBytes = [IO.File]::ReadAllBytes($runtimePath)
    if ([bool]$TomcatJdbcJar -ne [bool]$TomcatJdbcSha256) { throw 'Supply both -TomcatJdbcJar and -TomcatJdbcSha256, or neither.' }
    if ($TomcatJdbcJar) {
        if ([IO.Path]::GetFileName($TomcatJdbcJar) -cne 'mssql-jdbc-13.6.0.jre11.jar') { throw 'Local driver must be the pinned official mssql-jdbc-13.6.0.jre11.jar.' }
        if ((Get-FileHash -LiteralPath $TomcatJdbcJar -Algorithm SHA256).Hash -ine $TomcatJdbcSha256) { throw 'Local JDBC prerequisite checksum mismatch.' }
        Add-Type -AssemblyName System.IO.Compression
        $memory = [IO.MemoryStream]::new()
        $memory.Write($runtimeBytes, 0, $runtimeBytes.Length)
        $memory.Position = 0
        $archive = [IO.Compression.ZipArchive]::new($memory, [IO.Compression.ZipArchiveMode]::Update, $true)
        try {
            foreach ($pair in @(
                @{ Name='jdbc/mssql-jdbc-13.6.0.jre11.jar'; Bytes=[IO.File]::ReadAllBytes($TomcatJdbcJar) },
                @{ Name='jdbc/SHA256SUMS'; Bytes=[Text.Encoding]::UTF8.GetBytes($TomcatJdbcSha256.ToLowerInvariant() + '  mssql-jdbc-13.6.0.jre11.jar' + "`n") }
            )) {
                $entry = $archive.CreateEntry($pair.Name)
                $stream = $entry.Open()
                try { $stream.Write($pair.Bytes, 0, $pair.Bytes.Length) } finally { $stream.Dispose() }
            }
        } finally { $archive.Dispose() }
        $runtimeBytes = $memory.ToArray()
        $memory.Dispose()
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actualHash = ([BitConverter]::ToString($sha.ComputeHash($runtimeBytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    $content = $content.Replace('__TOMCAT_RUNTIME_PAYLOAD__', [Convert]::ToBase64String($runtimeBytes))
    $content = $content.Replace('__TOMCAT_RUNTIME_SHA256__', $actualHash)
    if ($content -match '__(LAB_[A-Z_]+|EMPLOYEE_(WORKER|CONTROL|UNIT)_(B64|SHA256)|TOMCAT_RUNTIME_(PAYLOAD|SHA256))__|(?m)^# LAB_HEALTH_HELPERS\r?$') {
        throw 'Unresolved host transport placeholder; obtain the complete compatible workshop checkout.'
    }
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'The host configuration script has syntax errors. Obtain the reviewed workshop revision.' }
    return $content
}

function Assert-LabRunResult {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Marker)
    $stdout = @($Result.Value | Where-Object Code -Match 'StdOut' | ForEach-Object Message) -join "`n"
    $stderr = @($Result.Value | Where-Object Code -Match 'StdErr' | ForEach-Object Message) -join "`n"
    $failedStatuses = @($Result.Value | Where-Object { $_.Code -match '/(failed|error)(/|$)' })
    $markerLine = '(?m)^' + [regex]::Escape($Marker) + '\r?$'
    if ($failedStatuses.Count -gt 0 -or $stdout -cnotmatch $markerLine -or -not [string]::IsNullOrWhiteSpace($stderr)) {
        throw "Remote validation did not pass. Review the VM Run Command output. $stderr"
    }
    return $stdout
}

# Fresh-source activity never repairs, boots or migrates VMs. Only CPU is optional.
function Test-LabCpuPromptSession {
    param([bool]$ExplicitPrompt)
    if (-not [Environment]::UserInteractive -or ([Environment]::GetCommandLineArgs() -imatch '^-noni')) { return $false }
    if ($Host.Name -eq 'ConsoleHost') {
        try { if ([Console]::IsInputRedirected) { return $false } } catch { return $false }
    }
    return ($ExplicitPrompt -or $env:LAB_NO_PAUSE -ne '1')
}

function New-LabFreshTrafficGuard {
    param([Parameter(Mandatory)][guid]$HostId)
    $guard = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$metadata = Invoke-RestMethod -Uri 'http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01' -Headers @{Metadata='true'} -TimeoutSec 5
if ([string]$metadata.vmId -ine '__HOST_ID__' -or [string]$metadata.name -cne 'HyperVHost' -or
    [string]$metadata.resourceGroupName -ine '__SOURCE_GROUP__') { throw 'Source identity mismatch.' }
$required = @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App')
$complete = Get-Content 'C:\AzMigrateLab\setup-complete.json' -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$completedAt = [DateTimeOffset]::Parse([string]$complete.CompletedUtc)
if ($completedAt -lt [DateTimeOffset]::Parse('__STARTED_AT__') -or $completedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or
    @($complete.VMs).Count -ne 4 -or (Compare-Object $required @($complete.VMs)) -or
    [string]$complete.TrafficScript -cne 'C:\AzMigrateLab\enable-lab-traffic.ps1') { throw 'Not this fresh completed deployment.' }
foreach ($name in $required) {
    $vm = @(Get-VM -Name $name -ErrorAction Stop)
    if ($vm.Count -ne 1 -or [string]$vm[0].Name -cne $name -or [string]$vm[0].State -cne 'Running' -or
        [string]$vm[0].AutomaticStartAction -cne 'Start') { throw 'Source is not running or is retired/disarmed.' }
}
$path = 'C:\AzMigrateLab\enable-lab-traffic.ps1'
$command = Get-Command $path -ErrorAction Stop
foreach ($parameter in @('NonInteractive','Mode','Component','CpuSimulation','CpuDurationHours')) {
    if (-not $command.Parameters.ContainsKey($parameter)) { throw 'Staged controller capability missing.' }
}
foreach ($asset in @('control.ps1','windows-cpu.ps1','linux-cpu.py')) {
    if (-not (Test-Path -LiteralPath (Join-Path 'C:\AzMigrateLab\cpu-simulation' $asset))) { throw 'Staged CPU asset missing.' }
}
$settings = Get-Content 'C:\AzMigrateLab\lab-traffic.settings.json' -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
if ([string]$settings.LinuxUsername -cne '__ADMIN_USER__' -or [string]$settings.SchemaVersion -cne '1' -or
    [string]$settings.SqlLogin -cne 'labapp') { throw 'Deployment settings mismatch.' }
$expected = [ordered]@{'onprem-web'='192.168.0.10';'onprem-sql'='192.168.0.11';'onprem-nginx'='192.168.0.12';'onprem-app'='192.168.0.13'}
if (@($settings.WorkloadAddresses.PSObject.Properties).Count -ne 4) { throw 'Unexpected source aliases.' }
foreach ($alias in $expected.Keys) {
    if ([string]$settings.WorkloadAddresses.$alias -cne $expected[$alias]) { throw 'Source alias mismatch.' }
}
$null = Get-Command ssh.exe -ErrorAction Stop
$oldPreference = $ErrorActionPreference
try { $ErrorActionPreference = 'Continue'; $version = (& ssh.exe -V 2>&1 | Out-String); $sshExit = $LASTEXITCODE }
finally { $ErrorActionPreference = $oldPreference }
if ($sshExit -ne 0 -or $version -notmatch 'OpenSSH[_a-zA-Z]*(\d+)\.(\d+)' -or [int]$Matches[1] -lt 8 -or
    ([int]$Matches[1] -eq 8 -and [int]$Matches[2] -lt 4)) { throw 'Installed OpenSSH 8.4+ is required.' }
function Assert-LabSourceWorkloads {
    foreach ($address in @('http://192.168.0.10','http://192.168.0.12')) {
        $page = Invoke-WebRequest $address -UseBasicParsing -TimeoutSec 10
        if ($page.StatusCode -ne 200 -or $page.Content -notmatch 'TD SYNNEX') {
            throw "Workshop sample site missing at $address."
        }
    }
    $api = Invoke-RestMethod 'http://192.168.0.13:3000/api/health' -TimeoutSec 10
    if ($api.status -ne 'healthy' -or $api.server -ne 'OnPrem-Linux-App' -or $api.app -ne 'Contoso Order Desk' -or -not $api.timestamp) {
        throw 'Tomcat health contract failed or wrong application.'
    }
    $info = Invoke-RestMethod 'http://192.168.0.13:3000/api/info' -TimeoutSec 10
    if ($info.app -ne 'Contoso Order Desk' -or $info.javaVersion -notmatch '^17(?:\.|$)') { throw 'Tomcat Java runtime contract failed.' }
    $ready = Invoke-RestMethod 'http://192.168.0.13:3000/api/ready' -TimeoutSec 20
    if ($ready.status -ne 'ready') { throw 'Tomcat SQL readiness failed.' }
    $orders = Invoke-RestMethod 'http://192.168.0.13:3000/api/orders' -TimeoutSec 20
    if ($orders.customerCount -lt 1 -or $orders.count -lt 1 -or @($orders.customers).Count -lt 1 -or @($orders.orders).Count -lt 1) {
        throw 'Tomcat cannot read the existing ContosoApp seed data.'
    }
    $desk = Invoke-WebRequest 'http://192.168.0.13:3000/' -UseBasicParsing -TimeoutSec 20
    if ($desk.StatusCode -ne 200 -or $desk.Content -notmatch 'Contoso Order Desk') { throw 'Named Tomcat order desk page missing.' }
    $proxy = Invoke-RestMethod 'http://192.168.0.12:8080/api/ready' -TimeoutSec 20
    if ($proxy.status -ne 'ready' -or $proxy.app -ne 'Contoso Order Desk') { throw 'Nginx-to-Tomcat SQL readiness failed.' }
    if (-not (Test-NetConnection 192.168.0.11 -Port 1433 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
        throw 'SQL TCP listener unavailable.'
    }
}
Assert-LabSourceWorkloads
'@
    return $guard.Replace('__HOST_ID__', $HostId.ToString()).Replace('__SOURCE_GROUP__', $ResourceGroupName).Replace(
        '__STARTED_AT__', $script:ProcessStartedAt.ToUniversalTime().ToString('o')).Replace('__ADMIN_USER__', $AdminUsername)
}

function Get-LabTrafficProbeText {
    param([Parameter(Mandatory)]$Result)
    if (@($Result).Count -ne 1 -or $null -eq $Result -or $null -eq $Result.PSObject.Properties['Value']) { throw 'Invalid probe result.' }
    $stdout = @()
    foreach ($entry in @($Result.Value)) {
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['Code'] -or
            $null -eq $entry.PSObject.Properties['Message']) { throw 'Invalid probe status.' }
        $code = [string]$entry.Code
        if ($code -match '(?i)(failed|error)' -or ($entry.PSObject.Properties['Level'] -and [string]$entry.Level -eq 'Error')) { throw 'Probe failed.' }
        if ($code -match '(?i)StdErr' -and -not [string]::IsNullOrWhiteSpace([string]$entry.Message)) { throw 'Probe stderr.' }
        if ($code -match '(?i)StdOut') {
            if ($code -notmatch '(?i)/succeeded$') { throw 'Probe stdout failed.' }
            $stdout += [string]$entry.Message
        }
    }
    $text = $stdout -join "`n"
    if (([regex]::Matches($text, '(?m)^LAB_DEPLOY_TRAFFIC_READY\r?$')).Count -ne 1 -or
        $text -match 'LAB_DEPLOY_PREFLIGHT_FAILED') { throw 'Fresh source readiness not confirmed.' }
    return $text
}

function Write-LabTrafficOutcome {
    param([Parameter(Mandatory)]$View, [bool]$StartNetwork, [bool]$StartCpu)
    $valid = $null -ne $View -and $null -ne $View.PSObject.Properties['ExecutionState'] -and
        [string]$View.ExecutionState -ceq 'Succeeded' -and $null -ne $View.PSObject.Properties['ExitCode'] -and
        $null -ne $View.ExitCode -and [string]$View.ExitCode -ceq '0' -and
        $null -ne $View.PSObject.Properties['Error'] -and [string]::IsNullOrWhiteSpace([string]$View.Error) -and
        $null -ne $View.PSObject.Properties['Output']
    $text = if ($valid) { [string]$View.Output } else { '' }
    $confirmed = $false
    if ($StartNetwork) {
        $growth = [regex]::Matches($text, '(?m)^LAB_DEPLOY_NETWORK_VERIFIED\|([0-9]+)\|([0-9]+)\r?$')
        $first = [long]0; $second = [long]0
        $confirmed = $valid -and ([regex]::Matches($text, '(?m)^LAB_TRAFFIC_FULLY_STARTED\r?$')).Count -eq 1 -and
            $growth.Count -eq 1 -and [long]::TryParse($growth[0].Groups[1].Value, [ref]$first) -and
            [long]::TryParse($growth[0].Groups[2].Value, [ref]$second) -and $first -ge 1 -and $second -gt $first -and
            $text -notmatch 'LAB_DEPLOY_NETWORK_UNVERIFIED|LAB_DEPLOY_PREFLIGHT_FAILED'
        if ($confirmed) {
            Write-Host "Required network stage confirmed: Windows task Running; both Linux order units healthy/enabled (employee night-sleep is healthy); direct/proxy ready; API total orders $first -> $second (at least 90 seconds apart)." -ForegroundColor Green
            Write-Host 'Network traffic persists until explicitly stopped, including across reboot.'
        } else { Write-Warning 'Required network stage UNKNOWN/partial; generators may be running. Inspect source Status/Stop before any retry. Deployment is not complete.' }
    }
    if ($StartCpu) {
        $confirmed = $valid -and ([regex]::Matches($text, '(?m)^LAB_CPU_FULLY_STARTED\r?$')).Count -eq 1 -and
            $text -notmatch 'LAB_DEPLOY_CPU_UNVERIFIED|LAB_DEPLOY_PREFLIGHT_FAILED'
        if ($confirmed) {
            Write-Host 'CPU Simulation fully started on all four source guests; its bounded guest-local expiry is independent of network traffic.' -ForegroundColor Green
        } else { Write-Warning 'CPU Simulation outcome UNKNOWN/partial; inspect CPU Status/Stop before any retry. This does not change the network outcome.' }
    }
    return $confirmed
}

function Assert-LabFreshTrafficHostIdentity {
    param($Model, $Status, [Parameter(Mandatory)][string]$SourceResourceGroup,
        [Parameter(Mandatory)][string]$ExpectedName, [Parameter(Mandatory)][string]$ExpectedSubscriptionId)
    $models = @($Model); $views = @($Status)
    if ($models.Count -ne 1 -or $views.Count -ne 1 -or $null -eq $models[0] -or $null -eq $views[0]) {
        throw 'Source host model/status unavailable.'
    }
    $hostModel = $models[0]; $hostStatus = $views[0]
    foreach ($item in @($hostModel,$hostStatus)) {
        if ($null -eq $item.PSObject.Properties['Name'] -or $null -eq $item.PSObject.Properties['ResourceGroupName'] -or
            [string]$item.Name -ine $ExpectedName -or [string]$item.ResourceGroupName -ine $SourceResourceGroup) {
            throw 'Source host name/group mismatch.'
        }
    }
    $expectedId = "/subscriptions/$ExpectedSubscriptionId/resourceGroups/$SourceResourceGroup/providers/Microsoft.Compute/virtualMachines/$ExpectedName"
    $hostId = [guid]::Empty
    if ($null -eq $hostModel.PSObject.Properties['Id'] -or [string]$hostModel.Id -ine $expectedId -or
        $null -eq $hostModel.PSObject.Properties['VmId'] -or
        -not [guid]::TryParse([string]$hostModel.VmId, [ref]$hostId) -or $hostId -eq [guid]::Empty) {
        throw 'Source host resource identity unavailable or mismatched.'
    }
    if ($null -eq $hostStatus.PSObject.Properties['Statuses']) { throw 'Source host power unavailable.' }
    $power = @($hostStatus.Statuses | Where-Object {
        $null -ne $_ -and $null -ne $_.PSObject.Properties['Code'] -and [string]$_.Code -like 'PowerState/*'
    })
    if ($power.Count -ne 1 -or [string]$power[0].Code -cne 'PowerState/running') { throw 'Source host is not confirmed running.' }
    return $hostId
}

function Start-LabFreshSourceTraffic {
    param([bool]$StartNetwork, [bool]$StartCpu)
    $job = $null; $probeJob = $null; $protectedTraffic = $null; $trafficPassword = $null
    $attempted = $false; $startupConfirmed = $false
    $phase = 'command-prerequisites'
    $runName = 'fresh-source-traffic-' + [guid]::NewGuid().ToString('N')
    try {
        foreach ($name in @('Set-AzVMRunCommand','Get-AzVMRunCommand','Remove-AzVMRunCommand','Invoke-AzVMRunCommand')) {
            $null = Get-Command $name -ErrorAction Stop
        }
        if (-not (Get-Command Set-AzVMRunCommand).Parameters.ContainsKey('ProtectedParameter')) { throw 'Protected parameters unavailable.' }
        $trafficSubscriptionId = ConvertFrom-LabSecureString -Secure $SubscriptionId -Name 'SubscriptionId'
        $trafficContext = Assert-LabContext $trafficSubscriptionId
        $phase = 'host-model'
        $hostModel = Get-AzVM -ResourceGroupName $ResourceGroupName -Name 'HyperVHost' -DefaultProfile $trafficContext -ErrorAction Stop
        $phase = 'host-status'
        $hostStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name 'HyperVHost' -Status -DefaultProfile $trafficContext -ErrorAction Stop
        $phase = 'host-identity'
        $hostId = Assert-LabFreshTrafficHostIdentity -Model $hostModel -Status $hostStatus -SourceResourceGroup $ResourceGroupName -ExpectedName 'HyperVHost' -ExpectedSubscriptionId $trafficSubscriptionId
        $guard = New-LabFreshTrafficGuard -HostId $hostId
        $probe = "try {`n$guard`nWrite-Output 'LAB_DEPLOY_TRAFFIC_READY'`n} catch { Write-Output 'LAB_DEPLOY_PREFLIGHT_FAILED'; exit 1 }"
        $phase = 'readiness-probe-submit'
        $probeJob = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName 'HyperVHost' -CommandId RunPowerShellScript -ScriptString $probe -AsJob -ErrorAction Stop
        $phase = 'readiness-probe-wait'
        $waited = Wait-Job -Job $probeJob -Timeout 300
        if (-not $waited -or $probeJob.State -ne 'Completed') { throw 'Readiness probe not confirmed.' }
        $phase = 'readiness-probe-result'
        $probeResult = Receive-Job -Job $probeJob -ErrorAction Stop
        $null = Get-LabTrafficProbeText -Result $probeResult
        $payload = @'
param([Parameter(Mandatory)][string]$AdminPassword)
$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$secure = $null
try {
    __FRESH_GUARD__
    $secure = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
    if (__START_NETWORK__) {
        try {
            $result = @(& 'C:\AzMigrateLab\enable-lab-traffic.ps1' -AdminPassword $secure -NonInteractive -Mode Start -Component Network -CpuSimulation Skip -CpuDurationHours __CPU_HOURS__ -ErrorAction Stop 2>$null 6>$null)
            if (@($result | Where-Object { [string]$_ -ceq 'LAB_TRAFFIC_FULLY_STARTED' }).Count -ne 1) { throw 'Unverified.' }
            function Get-LabSourceOrderCount {
                $orders = Invoke-RestMethod 'http://192.168.0.13:3000/api/orders' -TimeoutSec 20
                $count = [long]0
                if ($null -eq $orders -or $null -eq $orders.PSObject.Properties['count'] -or
                    -not [long]::TryParse([string]$orders.count, [ref]$count) -or $count -lt 1) { throw 'Invalid total order count.' }
                return $count
            }
            $interval = [int]$settings.IntervalSeconds
            if ($interval -lt 20 -or $interval -gt 600) { throw 'Invalid source traffic interval.' }
            $first = Get-LabSourceOrderCount
            $growthDeadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(90, $interval + 120))
            Start-Sleep -Seconds 90
            $second = Get-LabSourceOrderCount
            while ($second -le $first -and [DateTime]::UtcNow -lt $growthDeadline) {
                Start-Sleep -Seconds 15
                $second = Get-LabSourceOrderCount
            }
            __FRESH_GUARD__
            $status = @(& 'C:\AzMigrateLab\enable-lab-traffic.ps1' -AdminPassword $secure -NonInteractive -Mode Status -Component Network -ErrorAction Stop 2>$null 6>$null)
            if (@($status | Where-Object { [string]$_ -ceq 'LAB_NETWORK_RUNNING_CONFIRMED' }).Count -ne 1) { throw 'Generators not confirmed running.' }
            $second = Get-LabSourceOrderCount
            if ($second -le $first) { throw 'No observed order growth.' }
            Write-Output 'LAB_TRAFFIC_FULLY_STARTED'
            Write-Output "LAB_DEPLOY_NETWORK_VERIFIED|$first|$second"
        } catch { Write-Output 'LAB_DEPLOY_NETWORK_UNVERIFIED'; exit 1 }
    }
    if (__START_CPU__) {
        try {
            __FRESH_GUARD__
            $result = @(& 'C:\AzMigrateLab\enable-lab-traffic.ps1' -AdminPassword $secure -NonInteractive -Mode Start -Component Cpu -CpuSimulation Start -CpuDurationHours __CPU_HOURS__ -ErrorAction Stop 2>$null 6>$null)
            if (@($result | Where-Object { [string]$_ -ceq 'LAB_CPU_FULLY_STARTED' }).Count -ne 1) { throw 'Unverified.' }
            Write-Output 'LAB_CPU_FULLY_STARTED'
        } catch { Write-Output 'LAB_DEPLOY_CPU_UNVERIFIED' }
    }
} catch { Write-Output 'LAB_DEPLOY_PREFLIGHT_FAILED'; exit 1 }
finally { $AdminPassword = $null; $secure = $null; $result = $null }
'@
        $networkLiteral = if ($StartNetwork) { '$true' } else { '$false' }
        $cpuLiteral = if ($StartCpu) { '$true' } else { '$false' }
        $payload = $payload.Replace('__FRESH_GUARD__', $guard).Replace('__START_NETWORK__', $networkLiteral).Replace('__START_CPU__', $cpuLiteral).Replace('__CPU_HOURS__', [string]$CpuDurationHours)
        $phase = 'protected-start-submit'
        $trafficPassword = ([pscredential]::new($AdminUsername, $AdminPassword)).GetNetworkCredential().Password
        $protectedTraffic = @(@{Name='AdminPassword';Value=$trafficPassword})
        $attempted = $true
        $job = Set-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName 'HyperVHost' -Location $Location -RunCommandName $runName -SourceScript $payload -ProtectedParameter $protectedTraffic -TimeoutInSecond 1800 -AsyncExecution -AsJob -ErrorAction Stop
        $waited = Wait-Job -Job $job -Timeout 300
        if (-not $waited -or $job.State -ne 'Completed') { throw 'Submission not confirmed.' }
        $null = Receive-Job -Job $job -ErrorAction Stop
        $phase = 'managed-observation'
        $deadline = [DateTime]::UtcNow.AddSeconds(1860)
        while ([DateTime]::UtcNow -lt $deadline) {
            $run = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName 'HyperVHost' -RunCommandName $runName -Expand InstanceView -ErrorAction Stop
            if ($null -ne $run -and $run.PSObject.Properties['InstanceView'] -and $null -ne $run.InstanceView -and
                $run.InstanceView.PSObject.Properties['ExecutionState'] -and
                [string]$run.InstanceView.ExecutionState -in @('Succeeded','Failed','TimedOut','Canceled','Cancelled')) {
                $phase = 'result-validation'
                $startupConfirmed = Write-LabTrafficOutcome -View $run.InstanceView -StartNetwork $StartNetwork -StartCpu $StartCpu
                return $startupConfirmed
            }
            Start-Sleep -Seconds 10
        }
        throw 'Observation timed out.'
    } catch {
        # Protected Run Command exceptions/output can contain credentials: report only fixed text.
        if ($attempted) { Write-Warning "Source startup outcome UNKNOWN (phase: $phase); generators or remote execution may still be running. Inspect managed Run Command '$runName' and source Status/Stop before retrying. No automatic retry or rollback occurred." }
        else { Write-Warning "Source startup NOT initiated by this invocation (phase: $phase): fresh-source readiness/protected remote prerequisites were not verified. Inspect the source before using the host-interactive fallback." }
        return $false
    } finally {
        if ($startupConfirmed) {
            try { Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName 'HyperVHost' -RunCommandName $runName -ErrorAction Stop | Out-Null }
            catch { Write-Warning 'Confirmed source-startup Run Command needs manual cleanup; removing it does not stop generators.' }
        } elseif ($attempted) {
            Write-Warning 'Unconfirmed source-startup Run Command is retained for review. Inspect it before any manual cleanup; removing it does not stop generators.'
        }
        foreach ($finishedJob in @($job,$probeJob)) {
            if ($null -ne $finishedJob -and $finishedJob.State -in @('Completed','Failed','Stopped')) {
                Remove-Job -Job $finishedJob -ErrorAction SilentlyContinue
            }
        }
        if ($null -ne $protectedTraffic) { foreach ($parameter in $protectedTraffic) { $parameter.Value = $null } }
        $trafficPassword = $null; $protectedTraffic = $null; $probeResult = $null; $run = $null
    }
}

function Invoke-LabFreshCpuOffer {
    Write-Host ''
    Write-Host 'Required network stage and deployment cleanup are complete. Optional CPU startup below is NOT included in deployment timing.' -ForegroundColor Cyan
    Write-Host "CPU Simulation is independent: approximately 15% day / 2% night total guest CPU (UTC 06:00-22:00 / 22:00-06:00), no peaks. Duration $CpuDurationHours hours (default 24, range 1-168); no reboot auto-resume or automatic renewal." -ForegroundColor Yellow
    Write-Host 'For the full day/night profile, collect 24 hours during performance capture. No recommendation change is guaranteed; normal VM uptime charges continue.'
    $cpuStart = ($CpuSimulation -eq 'Start')
    if ($CpuSimulation -eq 'Prompt' -and (Test-LabCpuPromptSession -ExplicitPrompt $script:CpuPromptExplicit)) {
        $cpuStart = ((Read-Host 'Start optional CPU Simulation? [y/N]') -match '^(?i:y|yes)$')
    }
    if (-not $cpuStart) {
        Write-Host 'CPU not selected. Existing CPU workers are unchanged; confirmed network traffic continues.'
        return
    }
    $null = Start-LabFreshSourceTraffic -StartNetwork $false -StartCpu $true
    Write-Host 'Verify ON HyperVHost: C:\AzMigrateLab\enable-lab-traffic.ps1 -Mode Status -Component Cpu'
    Write-Host 'Do not repeat Start or renew CPU after an unknown result. Inspect CPU Status/Stop first; the required network result is unchanged.'
}

function Test-LabAdminPasswordMatch {
    param([Parameter(Mandatory)][SecureString]$Password, [Parameter(Mandatory)][SecureString]$Confirmation)
    if ($Password.Length -ne $Confirmation.Length) { return $false }
    $passwordBuffer = [IntPtr]::Zero
    $confirmationBuffer = [IntPtr]::Zero
    try {
        $passwordBuffer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $confirmationBuffer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Confirmation)
        # Compare UTF-16 code units exactly, without managed plaintext strings or normalization.
        for ($i = 0; $i -lt $Password.Length; $i++) {
            if ([Runtime.InteropServices.Marshal]::ReadInt16($passwordBuffer, $i * 2) -ne
                [Runtime.InteropServices.Marshal]::ReadInt16($confirmationBuffer, $i * 2)) { return $false }
        }
        return $true
    } finally {
        if ($passwordBuffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBuffer) }
        if ($confirmationBuffer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($confirmationBuffer) }
    }
}

# Confirm before loading modules, checking Azure context, or writing any resources.
if (-not $PSBoundParameters.ContainsKey('AdminPasswordConfirmation')) {
    $confirmationInputRedirected = $false
    if ($Host.Name -eq 'ConsoleHost') {
        try { $confirmationInputRedirected = [Console]::IsInputRedirected } catch { }
    }
    if (-not [Environment]::UserInteractive -or $confirmationInputRedirected -or
        ([Environment]::GetCommandLineArgs() -imatch '^-noni')) {
        throw 'Unattended deployment requires -AdminPasswordConfirmation as a second SecureString entry matching -AdminPassword.'
    }
    try { $AdminPasswordConfirmation = Read-Host 'Confirm administrator password' -AsSecureString }
    catch { throw 'Could not read password confirmation. Rerun with -AdminPasswordConfirmation as a second SecureString entry.' }
}
if ($null -eq $AdminPasswordConfirmation -or -not (Test-LabAdminPasswordMatch -Password $AdminPassword -Confirmation $AdminPasswordConfirmation)) {
    throw 'Administrator passwords do not match. Rerun and enter the same password twice; case and spaces must match exactly. No resources were changed.'
}

# Both values arrive masked. Convert once, validate, then use the plain form internally.
$subscriptionIdPlain = ConvertFrom-LabSecureString -Secure $SubscriptionId -Name 'SubscriptionId'
Assert-LabSubscriptionId $subscriptionIdPlain
$adminSourceCidrPlain = ConvertFrom-LabSecureString -Secure $AdminSourceCidr -Name 'AdminSourceCidr'
$hostScript = Read-LabHostConfiguration "$PSScriptRoot/host/configure-host.ps1"
. "$PSScriptRoot/health.ps1"
# The steps after 'Submit guest setup' run on the host, not here. Their names match the phase
# markers the host payload emits, so the counter keeps advancing through the longest part of
# the deployment instead of resting on a single step for 40-80 minutes.
Initialize-LabProgress -Activity 'TD SYNNEX | Hyper-V deployment' -Steps @(
    'Source deployment', 'Create source network', 'Create host public IP', 'Create host firewall rules',
    'Create host network interface', 'Create Azure host', 'Install Hyper-V and DHCP', 'Restart Azure host',
    'Check Hyper-V readiness', 'Create appliance store partition', 'Create guest image disk',
    'Submit guest setup', 'Guest setup starting',
    'Host networking', 'Downloading and converting images', 'Creating nested VMs', 'Guest first boot',
    'Installing workloads', 'Installing IIS', 'Installing SQL', 'Validating sample applications',
    'Staging the traffic generator', 'Preparing the host for discovery', 'Guest setup complete',
    'Required network traffic'
)
if (-not $HealthPath) { $HealthPath = Join-Path $PSScriptRoot "../.artifacts/deployment-health-$ResourceGroupName.json" }
$adminSourceCidrPlain = Resolve-LabAdminSource $adminSourceCidrPlain
Assert-LabHostSizeName $VMSize
foreach ($module in @('Az.Accounts','Az.Resources','Az.Network','Az.Compute')) {
    Import-Module $module -ErrorAction Stop
}
$null = Assert-LabContext $subscriptionIdPlain
foreach ($command in @('Set-AzVMRunCommand','Get-AzVMRunCommand')) { $null = Get-Command $command -ErrorAction Stop }
if (-not (Get-Command Set-AzVMRunCommand).Parameters.ContainsKey('ProtectedParameter')) { throw 'Update Az.Compute; managed Run Command protected parameters are required.' }
if ($AdminUsername -in @('admin','administrator','root','guest','user','test')) { throw 'Choose a non-reserved administrator username, such as labadmin.' }
$credential = [pscredential]::new($AdminUsername,$AdminPassword)
$passwordPlain = $credential.GetNetworkCredential().Password
if ($passwordPlain.Length -lt 12 -or $passwordPlain.Length -gt 72 -or $passwordPlain -match '[\r\n\x00-\x1f]') { throw 'Use a 12-72 character lab password without control characters.' }
$classes = @('[a-z]','[A-Z]','[0-9]','[^a-zA-Z0-9]') | Where-Object { $passwordPlain -cmatch $_ }
if (@($classes).Count -lt 3) { throw 'The password must include at least three character categories: lower, upper, number, symbol.' }
$runNameProbe = 'ConfigureWorkshop'
# An existing group is allowed only when it is this workshop's own and its host never
# finished provisioning, so an interrupted run resumes instead of costing a full rebuild.
# A group that is not tagged as this workshop, or whose host completed setup, is refused:
# replaying provisioning after migration has begun could restart retired source VMs.
$existingGroup = Get-LabResourceGroup -Name $ResourceGroupName -AllowMissing
$resumeDeployment = $false
if ($existingGroup) {
    if (-not $existingGroup.Tags -or $existingGroup.Tags['Workshop'] -ne 'TD-SYNNEX-CES-HyperV') {
        throw "Resource group '$ResourceGroupName' exists and is not tagged as this workshop. Use a new, dedicated source resource group."
    }
    if ($existingGroup.Tags['Revision'] -ne 'HyperVStudent-512GiB-v1') {
        throw 'This revision needs a fresh, separate 512-GiB source deployment; an older lab is never resized or retrofitted.'
    }
    $existingHost = Get-AzVM -ResourceGroupName $ResourceGroupName -Name 'HyperVHost' -ErrorAction SilentlyContinue
    if (-not $existingHost) {
        throw "Resource group '$ResourceGroupName' exists but has no HyperVHost. Inspect and remove it, then deploy into a clean group."
    }
    $completed = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName 'HyperVHost' -RunCommandName $runNameProbe -Expand InstanceView -ErrorAction SilentlyContinue
    if ([int]$existingHost.StorageProfile.OsDisk.DiskSizeGB -ne 512 -or
        [string]$existingHost.StorageProfile.OsDisk.ManagedDisk.StorageAccountType -ne 'Premium_LRS' -or
        @($existingHost.StorageProfile.DataDisks).Count -ne 0) {
        throw 'Existing host OS storage differs from this 512-GiB Premium SSD revision; no in-place resize or storage change is allowed.'
    }
    if ($completed -and [string]$completed.InstanceView.ExecutionState -notin @('Succeeded','Failed','TimedOut','Canceled','Cancelled')) {
        throw 'Previous host setup is running or its termination is unknown. Preserve ConfigureWorkshop and resources; inspect it before any resume.'
    }
    if ($completed -and [string]$completed.InstanceView.ExecutionState -eq 'Succeeded') {
        throw "Guest setup already succeeded in '$ResourceGroupName'. Deployment is not a post-migration repair command; use a new group for a fresh lab."
    }
    # A successful run normally removes ConfigureWorkshop. Its absence therefore does
    # not prove incompleteness: check the host marker before rebooting or starting guests.
    $resumeProbe = @'
$ErrorActionPreference = 'Stop'
if (Test-Path 'C:\AzMigrateLab\setup-complete.json') { throw 'Completed host: deployment replay is forbidden.' }
$log = 'C:\AzMigrateLab\setup-log.txt'
if ((Test-Path $log) -and -not @(Get-Content -LiteralPath $log | Where-Object { $_ -ceq 'LAB_BUILD|ubuntu2404-hyperv-student-v1' }).Count) {
    throw 'Different or unknown host build: no retrofit or adoption.'
}
Write-Output 'LAB_RESUME_ALLOWED'
'@
    $probeJob = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName 'HyperVHost' -CommandId RunPowerShellScript -ScriptString $resumeProbe -AsJob -ErrorAction Stop
    $probeResult = Wait-LabJob $probeJob 'Check incomplete host identity' -TimeoutSeconds 300 -HealthPath $HealthPath
    $null = Assert-LabRunResult $probeResult 'LAB_RESUME_ALLOWED'
    $resumeDeployment = $true
    Write-Host "Resuming the recognized incomplete deployment in '$ResourceGroupName'. Existing resources are reused; only unfinished source workloads may be rebuilt. No completed lab is resized or retrofitted."
}
# The appliance VHD is an ~11 GB download and nothing in Module 0 needs it. A learner should
# skip it: Module 1 downloads the appliance from the Azure Migrate project when it is required,
# and the project's own link is the one that serves the current build. An instructor staging a
# host before a session usually does want it. Asked once, defaulting to No.
if (-not $PSBoundParameters.ContainsKey('IncludeApplianceVhd')) {
    $IncludeApplianceVhd = 'No'
    if ([Environment]::UserInteractive -and $env:LAB_NO_PAUSE -ne '1') {
        Write-Host ''
        Write-Host 'Stage the Azure Migrate appliance VHD on the host during deployment?' -ForegroundColor Cyan
        Write-Host '  No   Recommended. Module 1 downloads it from your project when it is needed.' -ForegroundColor Gray
        Write-Host '  Yes  For an instructor preparing a host ahead of a session. Adds an ~11 GB download.' -ForegroundColor Gray
        if ((Read-Host 'Yes or No [No]') -match '^(?i)y') { $IncludeApplianceVhd = 'Yes' }
    }
}
if ($IncludeApplianceVhd -eq 'Yes') {
    Write-Host ''
    Write-Host 'Optional appliance staging starts alongside OS image preparation and overlaps tool/workload setup.' -ForegroundColor Cyan
    Write-Host 'The host computes SHA256 and enforces any supplied expected hash; otherwise staging is unverified.' -ForegroundColor Gray
    Write-Host 'No checksum prompt or host sign-in is needed. Wait for deployment to finish before accessing HyperVHost.' -ForegroundColor Gray
}

$hostSku = Get-LabHostSku -VMSize $VMSize -Location $Location
$windowsImages = Get-LabWindowsImages -Location $Location
$guestDiskConfig = New-LabWindowsGuestDiskConfig -Location $Location -ImageId $windowsImages.Guest.Id
Write-Host "Selected host: $($hostSku.Name), $($hostSku.Cores) enabled vCPUs, $($hostSku.MemoryGB) GiB RAM. Confirm this series supports nested virtualization with Standard security before running deployment."
foreach ($provider in @('Microsoft.Compute','Microsoft.Network','Microsoft.Storage','Microsoft.Migrate','Microsoft.OffAzure','Microsoft.RecoveryServices','Microsoft.KeyVault')) {
    $state = @(Get-AzResourceProvider -ProviderNamespace $provider)[0].RegistrationState
    if ($state -ne 'Registered') { throw "Register $provider first with Register-AzResourceProvider and wait until Registered." }
}
Write-Host "Creating source lab in the selected subscription, region $Location."
Write-LabHealth 'Source deployment' Preparing 0 'Preflight passed. Starting dedicated workshop resource creation.' $HealthPath
$tags = @{ Workshop = 'TD-SYNNEX-CES-HyperV'; Team = 'Cloud Enablement Services'; Purpose = 'Training'; Revision = 'HyperVStudent-512GiB-v1' }
$vmName = 'HyperVHost'
$diskName = 'WinServerBase-temp'
# Resolved by the host during the store step, since only the host knows which letters are free.
$storeDrive = $null
$appliancePath = $null
$runName = 'ConfigureWorkshop'
$diskCreated = $false
$runCreated = $false
$setupPassed = $false
$networkConfirmed = $false
$setupObservation = @{ Terminal = $false }
$deploymentClock = [Diagnostics.Stopwatch]::StartNew()
try {
    if (-not $resumeDeployment) { New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $tags | Out-Null }
    # Every resource below is created only when absent, so a resumed run continues from the
    # point the previous attempt stopped instead of rebuilding what already exists.
    $vnet = Get-AzVirtualNetwork -Name "$ResourceGroupName-vnet" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($vnet) { Write-Host 'Reusing the existing source network.' } else {
        $subnet = New-AzVirtualNetworkSubnetConfig -Name default -AddressPrefix '10.0.0.0/24' -DefaultOutboundAccess $false
        $job = New-AzVirtualNetwork -Name "$ResourceGroupName-vnet" -ResourceGroupName $ResourceGroupName -Location $Location -AddressPrefix '10.0.0.0/16' -Subnet $subnet -AsJob
        $vnet = Wait-LabJob $job 'Create source network' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    # The host's attached Standard public IP provides explicit outbound connectivity.
    $pip = Get-AzPublicIpAddress -Name "$vmName-pip" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($pip) { Write-Host 'Reusing the existing host public IP.' } else {
        $job = New-AzPublicIpAddress -Name "$vmName-pip" -ResourceGroupName $ResourceGroupName -Location $Location -AllocationMethod Static -Sku Standard -AsJob
        $pip = Wait-LabJob $job 'Create host public IP' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    $nsg = Get-AzNetworkSecurityGroup -Name "$vmName-nsg" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($nsg) { Write-Host 'Reusing the existing host firewall rules.' } else {
        $rdp = New-AzNetworkSecurityRuleConfig -Name Allow-RDP -Access Allow -Protocol Tcp -Direction Inbound -Priority 100 -SourceAddressPrefix $adminSourceCidrPlain -SourcePortRange '*' -DestinationAddressPrefix '*' -DestinationPortRange 3389
        $job = New-AzNetworkSecurityGroup -Name "$vmName-nsg" -ResourceGroupName $ResourceGroupName -Location $Location -SecurityRules $rdp -AsJob
        $nsg = Wait-LabJob $job 'Create host firewall rules' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    $nic = Get-AzNetworkInterface -Name "$vmName-nic" -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue
    if ($nic) { Write-Host 'Reusing the existing host network interface.' } else {
        $job = New-AzNetworkInterface -Name "$vmName-nic" -ResourceGroupName $ResourceGroupName -Location $Location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id -EnableAcceleratedNetworking:$hostSku.AcceleratedNetworking -AsJob
        $nic = Wait-LabJob $job 'Create host network interface' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    $existingHostVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction SilentlyContinue
    if ($existingHostVm) { Write-Host 'Reusing the existing Azure host; Hyper-V setup is re-verified below.' }
    else {
    $vm = New-AzVMConfig -VMName $vmName -VMSize $VMSize -SecurityType Standard
    $vm = Set-AzVMOperatingSystem -VM $vm -Windows -ComputerName $vmName -Credential $credential -ProvisionVMAgent -EnableAutoUpdate
    $vm = Set-AzVMSourceImage -VM $vm -PublisherName $windowsImages.Host.Publisher -Offer $windowsImages.Host.Offer -Skus $windowsImages.Host.Sku -Version $windowsImages.Host.Version
    $vm = Set-AzVMOSDisk -VM $vm -Name "$vmName-osdisk" -CreateOption FromImage -StorageAccountType Premium_LRS -DiskSizeInGB 512
    $vm = Add-AzVMNetworkInterface -VM $vm -Id $nic.Id
    $vm = Set-AzVMBootDiagnostic -VM $vm -Enable
    $job = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vm -Tag $tags -AsJob
    $null = Wait-LabJob $job 'Create Azure host' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    # Idempotent on the host: Install-WindowsFeature is a no-op when the role is present.
    $install = @'
$ErrorActionPreference = 'Stop'
$result = Install-WindowsFeature Hyper-V,DHCP -IncludeManagementTools
if (-not $result.Success) { throw 'Hyper-V installation failed.' }
Write-Output 'HYPERV_INSTALLED'
'@
    $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId RunPowerShellScript -ScriptString $install -AsJob
    $result = Wait-LabJob $job 'Install Hyper-V and DHCP' -TimeoutSeconds 1800 -HealthPath $HealthPath
    $null = Assert-LabRunResult $result 'HYPERV_INSTALLED'
    $job = Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -AsJob
    $null = Wait-LabJob $job 'Restart Azure host' -TimeoutSeconds 900 -HealthPath $HealthPath
    $ready = $false
    $readinessClock = [Diagnostics.Stopwatch]::StartNew()
    $deadline = (Get-Date).AddMinutes(15)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        try {
            $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId RunPowerShellScript -ScriptString "if ((Get-Service vmms).Status -ne 'Running') { throw 'Hyper-V not ready' }; Write-Output 'HYPERV_READY'" -AsJob
            $probe = Wait-LabJob $job 'Check Hyper-V readiness' -TimeoutSeconds 120 -HealthPath $HealthPath
            $null = Assert-LabRunResult $probe 'HYPERV_READY'
            $ready = $true; break
        } catch {
            Write-LabHealth 'Check Hyper-V readiness' Warning $readinessClock.Elapsed.TotalSeconds 'VM agent and Hyper-V service are not ready; retrying within the readiness limit.' $HealthPath -TimeoutSeconds 900
        }
    }
    if (-not $ready) { throw 'Hyper-V host did not become ready.' }
    # The guest VHDs are fixed and consume 140 GB of the OS disk in full. Carve a dedicated
    # partition for the appliance out of the remainder so the two never compete, and do it
    # before any guest disk work so a capacity problem surfaces in minutes, not an hour.
    $storeTemplate = @'
$ErrorActionPreference = 'Stop'
$requested = '__DRIVE__'
$storeBytes = __STOREGB__GB
$label = 'ApplianceStore'
$guestReserveBytes = 140GB
$bootPartition = Get-Partition -DriveLetter C -ErrorAction Stop
$bootDisk = Get-Disk -Number $bootPartition.DiskNumber -ErrorAction Stop
if (-not $bootDisk.IsBoot -or [string]$bootDisk.PartitionStyle -ne 'GPT' -or [math]::Abs([double]$bootDisk.Size - 512GB) -gt 1MB) {
    throw 'This fresh revision requires the single 512-GiB GPT host OS disk; no additional data disk or in-place retrofit is provisioned.'
}
$existing = Get-Volume -FileSystemLabel $label -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
    $letter = $existing.DriveLetter
} else {
    # Only the host knows which letters are free. C: is the OS disk, and on a size with no
    # local temporary disk Windows gives the next letter to the virtual DVD drive, so the
    # first unassigned letter is normally E:. Nothing is moved or reassigned.
    $taken = @()
    $taken += @(Get-CimInstance -ClassName Win32_Volume -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter } | ForEach-Object { $_.DriveLetter.TrimEnd(':').ToUpperInvariant() })
    $taken += @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.Length -eq 1 } | ForEach-Object { $_.Name.ToUpperInvariant() })
    if ($requested) {
        $letter = $requested.ToUpperInvariant()
        if ($letter -in $taken) {
            $occupant = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = '${letter}:'" -ErrorAction SilentlyContinue
            $detail = if ($occupant) { "type $($occupant.DriveType), label '$($occupant.Label)'" } else { 'an existing drive' }
            throw "Drive ${letter}: is already in use on this host ($detail). Omit -ApplianceStoreDriveLetter to take the first free letter, or choose another."
        }
    } else {
        $letter = @(68..90 | ForEach-Object { [char]$_ }) | Where-Object { $_ -notin $taken } | Select-Object -First 1
        if (-not $letter) { throw 'No unassigned drive letter is available for the appliance store.' }
    }
    $system = Get-Partition -DriveLetter C -ErrorAction Stop
    $supported = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    # Azure creates the OS disk at the requested size but leaves C: at the image's native
    # size, so most of the disk is normally unallocated. SizeMax is what C: could occupy --
    # its current size plus the adjacent free space -- so sizing C: to SizeMax minus the
    # store leaves exactly the store free, whether that means growing C: or shrinking it.
    $targetSize = $supported.SizeMax - $storeBytes
    $usedBytes = $system.Size - (Get-Volume -DriveLetter C -ErrorAction Stop).SizeRemaining
    # Retain the original budget: measured host usage, four fixed workload disks and
    # 60 GiB for base images/tools. Host setup checks actual image-conversion overlap too.
    $needed = $guestReserveBytes + 60GB
    $toGB = { param($b) [math]::Round($b / 1GB, 1) }
    if ($targetSize -lt $supported.SizeMin) {
        $maxStore = & $toGB ($supported.SizeMax - $supported.SizeMin)
        throw ("Cannot reserve __STOREGB__ GB for the appliance store. C: is $(& $toGB $system.Size) GB and can range from $(& $toGB $supported.SizeMin) GB to $(& $toGB $supported.SizeMax) GB on this disk, so at most $maxStore GB can be set aside. Deploy with a larger OS disk, or pass -ApplianceStoreSizeGB with a value at or below $maxStore.")
    }
    if (($targetSize - $usedBytes) -lt $needed) {
        throw ("Reserving __STOREGB__ GB would leave C: with $(& $toGB ($targetSize - $usedBytes)) GB free, below the $(& $toGB $needed) GB the 140-GiB fixed workloads and 60-GiB base/tool headroom require. Reduce -ApplianceStoreSizeGB within the documented discovery requirements, or stop and review this fresh deployment; storage is not expanded automatically.")
    }
    if ($targetSize -ne $system.Size) {
        $action = if ($targetSize -gt $system.Size) { 'Extending' } else { 'Shrinking' }
        Write-Output ("{0} C: from {1} GB to {2} GB to free space for the appliance store." -f $action, (& $toGB $system.Size), (& $toGB $targetSize))
        Resize-Partition -DriveLetter C -Size $targetSize -ErrorAction Stop
    }
    $partition = New-Partition -DiskNumber $system.DiskNumber -UseMaximumSize -DriveLetter $letter -ErrorAction Stop
    $null = Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel $label -Confirm:$false -Force -ErrorAction Stop
}
$store = Get-Volume -DriveLetter $letter -ErrorAction Stop
if ($store.FileSystemLabel -ne $label) { throw "Drive ${letter}: is not the appliance store." }
New-Item -ItemType Directory -Path "${letter}:\Appliance" -Force | Out-Null
# Grant the lab administrator explicit rights so a non-elevated browser download can write here.
& icacls.exe "${letter}:\Appliance" /grant:r '__ADMINUSER__:(OI)(CI)M' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not grant the lab administrator access to the appliance store.' }
$system = Get-Volume -DriveLetter C -ErrorAction Stop
# On incomplete resumes existing files already consume space. Require every remaining
# reserved byte without counting allocated fixed workload files twice.
$reservedPaths = @(
    @{ Path='C:\AzMigrateLab\VHDs\OnPrem-Web.vhdx'; Bytes=40GB },
    @{ Path='C:\AzMigrateLab\VHDs\OnPrem-SQL.vhdx'; Bytes=40GB },
    @{ Path='C:\AzMigrateLab\VHDs\OnPrem-Linux-Web.vhdx'; Bytes=30GB },
    @{ Path='C:\AzMigrateLab\VHDs\OnPrem-Linux-App.vhdx'; Bytes=30GB }
)
$remainingReserve = 60GB
foreach ($entry in $reservedPaths) {
    $allocated = 0L
    if (Test-Path -LiteralPath $entry.Path) { $allocated = [long](Get-Item -LiteralPath $entry.Path -ErrorAction Stop).Length }
    $remainingReserve += [math]::Max(0L, ([long]$entry.Bytes - $allocated))
}
if ([long]$system.SizeRemaining -lt $remainingReserve) { throw 'Insufficient C: free backing for remaining guest capacity and 60-GiB base/tool headroom; no thin oversubscription.' }
Write-Output ("APPLIANCE_STORE_DRIVE|{0}" -f $letter)
Write-Output ("Appliance store {0}: {1} GB free; system C: {2} GB free before guest disks." -f $letter,
    [math]::Round($store.SizeRemaining/1GB,1), [math]::Round($system.SizeRemaining/1GB,1))
Write-Output 'APPLIANCE_STORE_READY'
'@
    $storeScript = $storeTemplate.Replace('__DRIVE__', $ApplianceStoreDriveLetter.ToUpperInvariant()).Replace('__STOREGB__', [string]$ApplianceStoreSizeGB).Replace('__ADMINUSER__', $AdminUsername)
    $job = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId RunPowerShellScript -ScriptString $storeScript -AsJob
    $storeResult = Wait-LabJob $job 'Create appliance store partition' -TimeoutSeconds 1800 -HealthPath $HealthPath
    $storeOutput = Assert-LabRunResult $storeResult 'APPLIANCE_STORE_READY'
    $driveMatch = [regex]::Match($storeOutput, '(?m)^APPLIANCE_STORE_DRIVE\|([A-Z])\r?$')
    if (-not $driveMatch.Success) { throw 'The appliance store step did not report which drive letter it used.' }
    $storeDrive = $driveMatch.Groups[1].Value
    $appliancePath = "${storeDrive}:\Appliance"
    Write-Host "Appliance store created as ${storeDrive}: ($ApplianceStoreSizeGB GB)."
    $stagingSummary = @($storeOutput -split "`n" | Where-Object { $_ -match 'GB free' } | ForEach-Object { $_.Trim() })[0]
    if (Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -ErrorAction SilentlyContinue) {
        Write-Host 'Reusing the existing guest image disk.'
    } else {
        $job = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Disk $guestDiskConfig -AsJob
        $null = Wait-LabJob $job 'Create guest image disk' -TimeoutSeconds ($AzureOperationTimeoutMinutes * 60) -HealthPath $HealthPath
    }
    $diskCreated = $true
    $imageDisk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -ErrorAction Stop
    if ([int]$imageDisk.DiskSizeGB -lt 1 -or [int]$imageDisk.DiskSizeGB -gt 40) {
        throw 'The actual temporary Windows source image must fit each 40-GiB workload disk. No image size or extra storage is guessed.'
    }
    $access = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName -Access Read -DurationInSecond 18000
    $parameters = @(
        @{ Name = 'AdminUsername';       Value = $AdminUsername }
        @{ Name = 'WindowsImageSizeGB';  Value = [string]$imageDisk.DiskSizeGB }
        @{ Name = 'IncludeApplianceVhd'; Value = $IncludeApplianceVhd }
        @{ Name = 'ApplianceVhdSha256';  Value = $ApplianceVhdSha256 }
    )
    $protected = @(@{ Name = 'AdminPassword'; Value = $passwordPlain }, @{ Name = 'WindowsVhdSasUrl'; Value = $access.AccessSAS })
    # A Run Command left by an interrupted attempt would block the new submission.
    $staleRun = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -ErrorAction SilentlyContinue
    if ($staleRun) {
        $staleView = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -Expand InstanceView -ErrorAction Stop
        if ([string]$staleView.InstanceView.ExecutionState -notin @('Failed','TimedOut','Canceled','Cancelled')) {
            throw 'Previous setup termination is not a confirmed failure; retain its command and resources for review, never replay unknown/completed work.'
        }
        Write-Host 'Removing the terminal failed Run Command before a guarded incomplete resume.'
        Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -ErrorAction Stop | Out-Null
    }
    $runCreated = $true
    $job = Set-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -Location $Location -RunCommandName $runName `
        -SourceScript $hostScript -Parameter $parameters -ProtectedParameter $protected -TimeoutInSecond ($GuestSetupTimeoutMinutes * 60) -AsyncExecution -AsJob
    $null = Wait-LabJob $job 'Submit guest setup' -TimeoutSeconds 900 -HealthPath $HealthPath
    $setupResult = Wait-LabManagedSetup -ReadStatus {
        Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -Expand InstanceView -ErrorAction Stop
    } -Observation $setupObservation -TimeoutSeconds (($GuestSetupTimeoutMinutes * 60) + 600) -HealthPath $HealthPath
    if ([string]$setupResult.Output -cnotmatch '(?m)^LAB_HOST_STORAGE_READY\r?$') { throw 'Final measured host storage headroom was not confirmed; deployment is incomplete.' }
    $setupPassed = $true
    Write-Host 'Host preparation complete. Wait for the deployment process end/timing message before connecting to HyperVHost.'
    Write-Host "Workload setup verified. Host public IP: $($pip.IpAddress). Host login: $AdminUsername."
    Write-Host 'Windows guests: Administrator and the supplied lab password. Linux guests: the supplied username/password.'
    Write-Host 'Contoso Order Desk runs on Tomcat 10.1 / OpenJDK 17 at .13:3000; initial SQL and Nginx proxy readiness passed.'
    Write-Host 'Four workload VMs are running: OnPrem-Web (.10), OnPrem-SQL (.11), OnPrem-Linux-Web (.12) and OnPrem-Linux-App (.13).'
    Write-Host 'All four workloads use the existing Hyper-V host provider. Module 1 imports the discovery appliance manually; no additional replication VM or guest Mobility Service is provisioned.'
    if ($stagingSummary) { Write-Host $stagingSummary }
    Write-Host 'Guest disks are fixed: OnPrem-Web 40 GB, OnPrem-SQL 40 GB, OnPrem-Linux-Web 30 GB, OnPrem-Linux-App 30 GB.'
    Write-Host 'Traffic controller/settings and CPU assets are staged at C:\AzMigrateLab. Required network installation/start/verification follows automatically, before cleanup and the deployment timing message. CPU remains optional afterward.'
    if ($IncludeApplianceVhd -eq 'Yes') {
        # Read only fixed status tokens from the already-completed managed setup result.
        # Do not print raw Run Command output or start a duplicate archive rehash command.
        $stageStatus = 'Incomplete'
        $hashCheck = 'NotChecked'
        $archiveSha256 = ''
        $stageMatch = [regex]::Match([string]$setupResult.Output,
            '(?m)^LAB_APPLIANCE_STAGE\|(Staged|ArchiveRehashed)\|(Unverified|SuppliedHashMatched)\|([0-9A-Fa-f]{64})\r?$')
        if ($stageMatch.Success) {
            $stageStatus = $stageMatch.Groups[1].Value
            $hashCheck = $stageMatch.Groups[2].Value
            $archiveSha256 = $stageMatch.Groups[3].Value
        }
        if ($stageStatus -eq 'Staged') {
            Write-Host "Optional appliance download/extraction and completion record finished in $appliancePath. Import and registration remain manual." -ForegroundColor Cyan
        } elseif ($stageStatus -eq 'ArchiveRehashed') {
            Write-Warning 'Existing appliance ZIP rehashed only; the existing extracted files still require separate verification. No fresh staging is claimed.'
        } else {
            Write-Warning 'Optional appliance staging is NOT COMPLETE or its result could not be confirmed. Workload setup passed separately; use Module 1 section 2.1 after deployment.'
        }
        if ($archiveSha256) {
            Write-Host "  Archive SHA256 computed during host staging: $archiveSha256"
            if ($hashCheck -eq 'SuppliedHashMatched') {
                Write-Host '  Archive matched the expected hash supplied at deployment; this is not a fresh publisher lookup.'
            } else {
                Write-Warning 'Staged archive is UNVERIFIED against the publisher. A computed hash alone is not publisher verification.'
            }
        }
        Write-Host 'Optional recommended manual SHA256 comparison after deployment and before import: docs/Module-1-Discovery.md section 2.1.'
    } else {
        Write-Host "Appliance staging was not selected. After deployment, use $appliancePath on HyperVHost for the manual Module 1 section 2.1 workflow."
    }
    Write-Host 'Required lab network traffic starts automatically after application readiness; startup and verification are included in deployment timing.' -ForegroundColor Cyan
    Write-LabHealth 'Required network traffic' Preparing $deploymentClock.Elapsed.TotalSeconds 'Installing/starting required source generators and checking task, unit, readiness and two increasing API totals. No network question or automatic write retry.' $HealthPath
    $networkConfirmed = Start-LabFreshSourceTraffic -StartNetwork $true -StartCpu $false
    if (-not $networkConfirmed) {
        throw 'Required network stage is incomplete or unknown. Deployment is NOT complete. Preserve Run Command diagnostics; inspect source Network Status/Stop before an approved manual retry. Do not replay deployment.'
    }
    Write-LabHealth 'Required network traffic' Completed $deploymentClock.Elapsed.TotalSeconds 'Required source network task/unit, application readiness and increasing API totals confirmed.' $HealthPath
} catch {
    try {
        $lastHealth = Get-Content -LiteralPath $HealthPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($lastHealth.State -ne 'NeedsReview') {
            Write-LabHealth 'Source deployment' NeedsReview $deploymentClock.Elapsed.TotalSeconds "Deployment stopped after $($lastHealth.Stage). Inspect the terminal and Azure/host diagnostics before retrying." $HealthPath
        }
    } catch { Write-Warning 'Could not update the local health summary. Preserve the terminal error and inspect Azure directly.' }
    throw
} finally {
    Complete-LabProgress
    $passwordPlain = $null
    $subscriptionIdPlain = $null
    $adminSourceCidrPlain = $null
    $protected = $null
    if ($diskCreated -and (-not $runCreated -or $setupObservation.Terminal)) {
        try {
            Revoke-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName | Out-Null
            Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -Force | Out-Null
        } catch { Write-Warning 'Temporary disk cleanup failed. Revoke its export access and remove WinServerBase-temp in the source resource group.' }
    } elseif ($diskCreated) {
        Write-Warning 'Setup termination is unconfirmed. WinServerBase-temp is retained so a running download is not interrupted. Its export access expires after five hours; revoke access and remove the disk after confirming ConfigureWorkshop has stopped.'
    }
    if ($runCreated -and $setupPassed -and $networkConfirmed) {
        try { Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName | Out-Null }
        catch { Write-Warning 'Managed Run Command removal failed. Inspect and remove ConfigureWorkshop from the host when it has stopped.' }
    } elseif ($runCreated) {
        Write-Warning 'ConfigureWorkshop is retained for failure diagnostics and replay protection. Inspect its instance view; do not rerun deployment to repair incomplete/unknown network traffic.'
    }
    Complete-LabProcessTiming
}

if ($setupPassed -and $networkConfirmed) {
    Write-LabHealth 'Source deployment' Completed $deploymentClock.Elapsed.TotalSeconds 'Infrastructure/application preparation and required source network stage confirmed; cleanup finished or was reported separately. Optional CPU is independent.' $HealthPath
    try { Invoke-LabFreshCpuOffer }
    catch { Write-Warning 'Optional CPU startup outcome UNKNOWN; inspect CPU Status/Stop before retrying. Required network startup remains confirmed; no automatic rollback or retry was attempted.' }
}

# A right-click window closes on success just as fast as on failure. The summary above is the
# point of the run, so hold it until it has been read.
Wait-LabBeforeExit
