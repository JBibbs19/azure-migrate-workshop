<#
.SYNOPSIS
Deploy the TD SYNNEX Cloud Enablement Services Hyper-V workshop.
.DESCRIPTION
Creates one Standard-security Windows host and provisions four nested workload VMs
(two Windows, two Linux) that behave as one small-business environment. No appliance
OS VM is created: Module 1 downloads the Azure Migrate appliance VHD onto the host's
own OS disk and imports it. This script creates billable Azure resources.
Use a new dedicated resource group. Existing groups are refused intentionally.
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
appliance. The guest VHDs never touch it, so the appliance has capacity of its own.
.PARAMETER ApplianceStoreDriveLetter
Drive letter for that partition inside HyperVHost. Leave it unset and deployment uses the
first unassigned letter, which is E: on the default host size: C: is the OS disk and D: is
the virtual DVD drive. Supply a letter only to override that choice.
.PARAMETER HealthPath
Local JSON status summary, without credentials or raw Run Command output.
.EXAMPLE
$secureSubscriptionId = Read-Host 'Workshop subscription ID' -AsSecureString
$secureAdminCidr = Read-Host 'Your public IPv4 address' -AsSecureString
$password = Read-Host 'Lab password' -AsSecureString
.\scripts\deploy-lab.ps1 -SubscriptionId $secureSubscriptionId -ResourceGroupName 'rg-ces-source-01' -AdminUsername 'labadmin' -AdminPassword $password -AdminSourceCidr $secureAdminCidr
MODULE COVERAGE
    The scripts and the modules are run separately. This script completes:

      Module 0, section 4   Deployment Steps - the whole of it.
      Module 1, section 2   Prepare the Hyper-V host - applied in full (PHASE 7 of the
                            host payload). Nothing is left to do there on a script-deployed lab.
      Module 1, section 3.3 Download and verify the archive - the download and extract are
                            started during deployment. You still compare the recorded SHA256
                            against Microsoft's published value.

    Left for you: Module 0 section 5 (verify inside HyperVHost), section 6 (start the sample
    traffic, optional), and all of Module 1 from section 1 onward.
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
    [string]$HealthPath
)
$ErrorActionPreference = 'Stop'

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
    # The optional traffic generator is delivered to the host during setup so the instructor
    # never has to copy a file onto HyperVHost by hand. The host payload writes it to disk;
    # it is never executed by deployment.
    $trafficPath = Join-Path $scriptsRoot 'enable-lab-traffic.ps1'
    $traffic = Get-Content -LiteralPath $trafficPath -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($traffic) -or ([regex]::Matches($content, '__LAB_TRAFFIC_PAYLOAD__')).Count -ne 1) {
        throw 'The lab traffic script is missing or its host placeholder is incompatible. Obtain the complete workshop checkout.'
    }
    $trafficTokens = $null; $trafficErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($traffic, [ref]$trafficTokens, [ref]$trafficErrors)
    if ($trafficErrors.Count) { throw 'The lab traffic script has syntax errors. Obtain the reviewed workshop revision.' }
    $content = $content.Replace('__LAB_TRAFFIC_PAYLOAD__', (Compress-LabScript $traffic))
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
    'Staging the traffic generator', 'Preparing the host for discovery', 'Guest setup complete'
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
    $existingHost = Get-AzVM -ResourceGroupName $ResourceGroupName -Name 'HyperVHost' -ErrorAction SilentlyContinue
    if (-not $existingHost) {
        throw "Resource group '$ResourceGroupName' exists but has no HyperVHost. Inspect and remove it, then deploy into a clean group."
    }
    $completed = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName 'HyperVHost' -RunCommandName $runNameProbe -Expand InstanceView -ErrorAction SilentlyContinue
    if ($completed -and [string]$completed.InstanceView.ExecutionState -eq 'Succeeded') {
        throw "Guest setup already succeeded in '$ResourceGroupName'. Deployment is not a post-migration repair command; use a new group for a fresh lab."
    }
    $resumeDeployment = $true
    Write-Host "Resuming the incomplete deployment in '$ResourceGroupName'. Existing resources are reused; unfinished guests are rebuilt."
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
$tags = @{ Workshop = 'TD-SYNNEX-CES-HyperV'; Team = 'Cloud Enablement Services'; Purpose = 'Training' }
$vmName = 'HyperVHost'
$diskName = 'WinServerBase-temp'
# Resolved by the host during the store step, since only the host knows which letters are free.
$storeDrive = $null
$appliancePath = $null
$runName = 'ConfigureWorkshop'
$diskCreated = $false
$runCreated = $false
$setupPassed = $false
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
    # C: must still hold Windows, the base images and the 140 GB of fixed guest disks.
    $needed = $guestReserveBytes + 60GB
    $toGB = { param($b) [math]::Round($b / 1GB, 1) }
    if ($targetSize -lt $supported.SizeMin) {
        $maxStore = & $toGB ($supported.SizeMax - $supported.SizeMin)
        throw ("Cannot reserve __STOREGB__ GB for the appliance store. C: is $(& $toGB $system.Size) GB and can range from $(& $toGB $supported.SizeMin) GB to $(& $toGB $supported.SizeMax) GB on this disk, so at most $maxStore GB can be set aside. Deploy with a larger OS disk, or pass -ApplianceStoreSizeGB with a value at or below $maxStore.")
    }
    if (($targetSize - $usedBytes) -lt $needed) {
        throw ("Reserving __STOREGB__ GB would leave C: with $(& $toGB ($targetSize - $usedBytes)) GB free, below the $(& $toGB $needed) GB the 140 GB of fixed guest disks and their base images require. Deploy with a larger OS disk or a smaller -ApplianceStoreSizeGB.")
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
    $access = Grant-AzDiskAccess -ResourceGroupName $ResourceGroupName -DiskName $diskName -Access Read -DurationInSecond 18000
    $parameters = @(@{ Name = 'AdminUsername'; Value = $AdminUsername })
    $protected = @(@{ Name = 'AdminPassword'; Value = $passwordPlain }, @{ Name = 'WindowsVhdSasUrl'; Value = $access.AccessSAS })
    # A Run Command left by an interrupted attempt would block the new submission.
    $staleRun = Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -ErrorAction SilentlyContinue
    if ($staleRun) {
        Write-Host 'Removing the Run Command left by the previous attempt before resubmitting.'
        Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -ErrorAction Stop | Out-Null
    }
    $runCreated = $true
    $job = Set-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -Location $Location -RunCommandName $runName `
        -SourceScript $hostScript -Parameter $parameters -ProtectedParameter $protected -TimeoutInSecond ($GuestSetupTimeoutMinutes * 60) -AsyncExecution -AsJob
    $null = Wait-LabJob $job 'Submit guest setup' -TimeoutSeconds 900 -HealthPath $HealthPath
    $null = Wait-LabManagedSetup -ReadStatus {
        Get-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName -Expand InstanceView -ErrorAction Stop
    } -Observation $setupObservation -TimeoutSeconds (($GuestSetupTimeoutMinutes * 60) + 600) -HealthPath $HealthPath
    $setupPassed = $true
    Write-Host "Workload setup verified. Host public IP: $($pip.IpAddress). Host login: $AdminUsername."
    Write-Host 'Windows guests: Administrator and the supplied lab password. Linux guests: the supplied username/password.'
    Write-Host 'Four workload VMs are running: OnPrem-Web (.10), OnPrem-SQL (.11), OnPrem-Linux-Web (.12) and OnPrem-Linux-App (.13).'
    if ($stagingSummary) { Write-Host $stagingSummary }
    Write-Host 'Guest disks are fixed: OnPrem-Web 40 GB, OnPrem-SQL 40 GB, OnPrem-Linux-Web 30 GB, OnPrem-Linux-App 30 GB.'
    Write-Host 'Optional traffic generator staged on the host at C:\AzMigrateLab\enable-lab-traffic.ps1 with its settings file. It is not running; start it from HyperVHost if you want a populated dependency map.'
    Write-Host "Download and extract the Azure Migrate appliance VHD into $appliancePath on HyperVHost, then import and register it as described in docs/Module-1-Discovery.md."
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
    if ($runCreated -and $setupPassed) {
        try { Remove-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -RunCommandName $runName | Out-Null }
        catch { Write-Warning 'Managed Run Command removal failed. Inspect and remove ConfigureWorkshop from the host when it has stopped.' }
    } elseif ($runCreated) {
        Write-Warning 'ConfigureWorkshop is retained for failure diagnostics. Inspect its instance view and remove it after it has stopped.'
    }
}

# A right-click window closes on success just as fast as on failure. The summary above is the
# point of the run, so hold it until it has been read.
Wait-LabBeforeExit
