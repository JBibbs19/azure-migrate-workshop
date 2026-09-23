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
