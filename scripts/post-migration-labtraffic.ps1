#requires -Version 5.1
<#
.SYNOPSIS
Checks and controls bounded traffic on the four explicitly selected migrated lab VMs.
.DESCRIPTION
Native Windows PowerShell 5.1+ / Az.Compute managed Run Command controller. Check is
read-only in the guests unless VerifySampleOrder is explicitly requested; Azure Run
Command resources still require write/execution permission. No network/agent repair.
Prepare and Start explicitly authorize stopping/disabling inherited generators,
repointing only lab aliases, restarting Tomcat and reloading Nginx. Start also writes
sample orders through the installed Linux HTTP generator. Never run on source VMs.
See ../docs/post-migration-labtraffic.md for isolation, credentials and recovery.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check','Prepare','Start','Status','Stop')][string]$Mode = 'Check',
    [string]$TargetResourceGroup,
    [string]$SubscriptionId,
    [switch]$TestMigration,
    [ValidateRange(30,600)][int]$IntervalSeconds = 30,
    [ValidateRange(1,120)][int]$DurationMinutes = 60,
    [switch]$VerifySampleOrder,
    [Security.SecureString]$SqlPassword,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$WindowsWorkerBody = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Write-BoundedLog {
    param([string]$Name,[string]$Message)
    $path = Join-Path 'C:\LabTraffic' $Name
    if ((Test-Path $path) -and (Get-Item $path).Length -ge 1MB) {
        if (Test-Path "$path.2") { Remove-Item "$path.2" -Force }
        if (Test-Path "$path.1") { Move-Item "$path.1" "$path.2" -Force }
        Move-Item $path "$path.1" -Force
    }
    Add-Content -LiteralPath $path -Encoding UTF8 -Value ("{0:o} {1}" -f [DateTime]::UtcNow,$Message)
}
function Set-WorkerState {
    param([string]$Phase)
    $state.phase = $Phase
    $state.heartbeatUtc = [DateTime]::UtcNow.ToString('o')
    $state | ConvertTo-Json -Compress | Set-Content 'C:\LabTraffic\post-migration-state.json' -Encoding UTF8
}
function Test-WorkerAliases {
    foreach ($property in $config.aliases.PSObject.Properties) {
        $ips = @([Net.Dns]::GetHostAddresses($property.Name) | ForEach-Object { $_.IPAddressToString } | Sort-Object -Unique)
        if ($ips.Count -ne 1 -or $ips[0] -ne $property.Value) { return $false }
    }
    return $true
}
function Get-WorkerHealth {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Deadline reached' }
    $request = [Net.HttpWebRequest]::Create('http://onprem-app:3000/api/health')
    $request.Proxy = $null; $request.AllowAutoRedirect = $false
    $request.Timeout = 10000; $request.ReadWriteTimeout = 10000
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 200) { throw 'HTTP status' }
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try {
            $buffer=New-Object char[] 262145
            $length=$reader.ReadBlock($buffer,0,$buffer.Length)
            if ($length -gt 262144) { throw 'HTTP result too large' }
            $data=[string]::new($buffer,0,$length) | ConvertFrom-Json
        } finally { $reader.Dispose() }
        if ($data.app -cne 'Contoso Order Desk' -or $data.status -cne 'healthy') { throw 'HTTP identity' }
    } finally { $response.Dispose() }
}
$connection = $null
try {
    Add-Type -AssemblyName System.Security
    $config = Get-Content 'C:\LabTraffic\post-migration-config.json' -Raw | ConvertFrom-Json
    $state = Get-Content 'C:\LabTraffic\post-migration-state.json' -Raw | ConvertFrom-Json
    $deadline = [DateTime]::Parse($config.deadlineUtc).ToUniversalTime()
    if ($state.runId -ne $config.runId -or [DateTime]::UtcNow -ge $deadline) { throw 'Expired or different run' }
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes('C:\LabTraffic\post-migration-credential.bin'),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    $password = [Text.Encoding]::UTF8.GetString($bytes)
    [Array]::Clear($bytes,0,$bytes.Length)
    Set-WorkerState 'running'
    Write-BoundedLog 'native-traffic.log' 'Windows SQL-report/HTTP generator started; no inserts from Windows.'
    Write-EventLog -LogName Application -Source LabPostMigrationTraffic -EventId 110 -EntryType Information -Message 'Bounded Windows traffic started.'
    while ([DateTime]::UtcNow -lt $deadline) {
        $cycleStart = [DateTime]::UtcNow
        if (-not (Test-WorkerAliases)) { throw 'Target aliases changed' }
        try {
            $builder = New-Object Data.SqlClient.SqlConnectionStringBuilder
            $builder.DataSource = 'onprem-sql,1433'; $builder.InitialCatalog = 'ContosoApp'
            $builder.UserID = 'labapp'; $builder.Password = $password
            $builder.TrustServerCertificate = $true; $builder.ConnectTimeout = 10
            if ([DateTime]::UtcNow -ge $deadline) { break }
            $connection = New-Object Data.SqlClient.SqlConnection
            $connection.ConnectionString=$builder.ConnectionString
            $connection.Open()
            $command = $connection.CreateCommand(); $command.CommandTimeout = 10
            $command.CommandText = 'SELECT COUNT_BIG(*) FROM dbo.Orders'
            $count = [long]$command.ExecuteScalar()
            $command.CommandText = 'SELECT TOP 5 OrderID FROM dbo.Orders ORDER BY OrderID DESC'
            $reader = $command.ExecuteReader(); $rows = 0
            try { while ($reader.Read()) { $rows++ } } finally { $reader.Dispose() }
            Write-BoundedLog 'native-traffic.log' ("SQL snapshot orders={0}; reportRows={1}" -f $count,$rows)
            Write-EventLog -LogName Application -Source LabPostMigrationTraffic -EventId 111 -EntryType Information -Message ("Windows traffic cycle; SQL order count {0}." -f $count)
        } catch { Write-BoundedLog 'native-traffic.log' 'SQL report unavailable; inspect connectivity/readiness locally. No raw error recorded.' }
        finally { if ($connection) { $connection.Dispose(); $connection = $null } }
        try {
            Get-WorkerHealth
            Write-BoundedLog 'native-traffic.log' 'Expected Tomcat health returned.'
        } catch { Write-BoundedLog 'native-traffic.log' 'HTTP health unavailable; inspect connectivity/readiness locally. No raw error recorded.' }
        Set-WorkerState 'running'
        $next = $cycleStart.AddSeconds([int]$config.intervalSeconds)
        while ([DateTime]::UtcNow -lt $next -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 1 }
    }
    Set-WorkerState 'expired'
    Write-BoundedLog 'native-traffic.log' 'Guest-local deadline reached.'
} catch {
    if ($null -ne (Get-Variable state -ErrorAction SilentlyContinue)) { Set-WorkerState 'failed' }
    Write-BoundedLog 'native-traffic.log' 'Worker stopped fail-closed; inspect guest state. No raw error recorded.'
    exit 1
} finally { $password = $null; if ($connection) { $connection.Dispose() } }
'@

$WindowsGuestBody = @'
param([string]$SqlPassword)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONFIG_B64__')) | ConvertFrom-Json
$root = 'C:\LabTraffic'
function Update-LabHostsText {
    param([string]$Text,[hashtable]$Aliases)
    $lines = New-Object 'Collections.Generic.List[string]'
    foreach ($line in ($Text -split '\r?\n')) {
        $parts = $line -split '#',2
        $tokens = @($parts[0].Trim() -split '\s+' | Where-Object { $_ })
        if ($tokens.Count -lt 2) { $lines.Add($line); continue }
        $names = @($tokens | Select-Object -Skip 1 | Where-Object { -not $Aliases.ContainsKey($_.ToLowerInvariant()) })
        if ($names.Count -eq $tokens.Count - 1) { $lines.Add($line); continue }
        $comment = if ($parts.Count -eq 2) { '#' + $parts[1] } else { '' }
        if ($names.Count) { $lines.Add(($tokens[0] + "`t" + ($names -join ' ') + ' ' + $comment).TrimEnd()) }
        elseif ($comment) { $lines.Add($comment) }
    }
    foreach ($name in ($Aliases.Keys | Sort-Object)) { $lines.Add(($Aliases[$name] + "`t" + $name)) }
    return ($lines -join "`r`n").TrimEnd() + "`r`n"
}
function Get-LiteralPassword {
    param([string]$Text)
    $pattern = '(?m)^\$sqlPassword = \[Text\.Encoding\]::UTF8\.GetString\(\[Convert\]::FromBase64String\(''([A-Za-z0-9+/]+={0,2})''\)\)\r?$'
    $found = [regex]::Matches($Text,$pattern)
    if ($found.Count -ne 1 -or [regex]::Matches($Text,'(?m)^\s*\$sqlPassword\s*=').Count -ne 1) { throw 'Credential literal unavailable' }
    $encoding = New-Object Text.UTF8Encoding($false,$true)
    return $encoding.GetString([Convert]::FromBase64String($found[0].Groups[1].Value))
}
function Get-LabPassword {
    if ($SqlPassword) { return $SqlPassword }
    $old = Join-Path $root 'order-desk.ps1'
    if (Test-Path -LiteralPath $old) { return Get-LiteralPassword ([IO.File]::ReadAllText($old)) }
    $stored = Join-Path $root 'post-migration-credential.bin'
    if (Test-Path $stored) {
        Add-Type -AssemblyName System.Security
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($stored),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        try { return [Text.Encoding]::UTF8.GetString($bytes) } finally { [Array]::Clear($bytes,0,$bytes.Length) }
    }
    throw 'Credential unavailable; provide protected SqlPassword'
}
function Write-BoundedLog {
    param([string]$Message)
    $path = Join-Path $root 'summary.log'
    if ((Test-Path $path) -and (Get-Item $path).Length -ge 1MB) {
        if (Test-Path "$path.2") { Remove-Item "$path.2" -Force }
        if (Test-Path "$path.1") { Move-Item "$path.1" "$path.2" -Force }
        Move-Item $path "$path.1" -Force
    }
    Add-Content -LiteralPath $path -Encoding UTF8 -Value ("{0:o} {1}" -f [DateTime]::UtcNow,$Message)
}
function Protect-Root {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $directoryAcl = New-Object Security.AccessControl.DirectorySecurity
    $directoryAcl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $directoryAcl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $root -AclObject $directoryAcl
    # Remove explicit broad grants on secret-bearing and controller-owned files.
    foreach ($path in @(Get-ChildItem $root -File | Where-Object { $_.Name -like 'post-migration-*' -or $_.Name -like 'summary.log*' -or $_.Name -like 'native-traffic.log*' -or $_.Name -eq 'order-desk.ps1' })) {
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true,$false)
        foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
            $identity = New-Object Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $path.FullName -AclObject $acl
    }
}
function Get-TaskObservation {
    param([string]$Name)
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $Name })
    if ($tasks.Count -gt 1) { throw 'Ambiguous generator task' }
    if (-not $tasks.Count) { return @{ exists=$false; state='absent'; enabled=$false; startup=$false } }
    $task = $tasks[0]
    if ([string]$task.State -notin @('Ready','Running','Disabled','Queued')) { throw 'Generator task state unknown' }
    return @{ exists=$true; state=[string]$task.State; enabled=[bool]$task.Settings.Enabled; startup=(@($task.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' }).Count -gt 0) }
}
function Get-InheritedCpuObservation {
    $task=Get-TaskObservation 'LabCpuSimulation'
    $state=$null; $stale=$true; $healthy=$false; $actualPid=$null
    try {
        $path='C:\LabCpuSimulation\state.json'
        if ((Get-Item -LiteralPath $path).Length -gt 16384) { throw 'CPU state too large' }
        $stored=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $state=@{}
        foreach ($name in @('runId','pid','status','phase','heartbeatUtc','expiresUtc','targetTotalCpuPercent','targetWorkerCpuPercent','measuredTotalCpuPercent','measuredWorkerCpuPercent','baselineCpuPercent','baselineAboveGoal','guard','cooldownRemainingSeconds','reason')) { $state[$name]=$stored.$name }
        $age=([DateTime]::UtcNow-[DateTime]::Parse($stored.heartbeatUtc).ToUniversalTime()).TotalSeconds
        $stale=($age -lt 0 -or $age -gt 10)
        $process=Get-Process -Id ([int]$stored.pid) -ErrorAction Stop
        $identity=Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$stored.pid) -ErrorAction Stop
        if ($process.ProcessName -eq 'powershell' -and $identity.CommandLine -match '(?i)C:\\LabCpuSimulation\\windows-cpu\.ps1.*-Mode Worker' -and $process.StartTime.ToUniversalTime().ToString('o') -eq $stored.processStartUtc) { $actualPid=[int]$stored.pid }
        $cpuConfig=Get-Content 'C:\LabCpuSimulation\config.json' -Raw | ConvertFrom-Json
        $healthy=($task.state -eq 'Running' -and $null -ne $actualPid -and -not $stale -and $stored.status -eq 'running' -and $stored.runId -eq $cpuConfig.runId -and [DateTime]::UtcNow -lt [DateTime]::Parse($cpuConfig.expiresUtc).ToUniversalTime())
    } catch { $healthy=$false }
    return @{task=$task;pid=$actualPid;healthy=$healthy;stale=$stale;state=$state}
}
function Stop-InheritedCpu {
    $before=Get-InheritedCpuObservation
    $tasks=@(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq 'LabCpuSimulation' })
    if ($tasks.Count -gt 1) { throw 'Ambiguous CPU task' }
    if ($tasks.Count) {
        if ([string]$tasks[0].State -in @('Running','Queued')) { $tasks[0] | Stop-ScheduledTask -ErrorAction Stop }
        $tasks[0] | Disable-ScheduledTask -ErrorAction Stop | Out-Null
        $tasks[0] | Unregister-ScheduledTask -Confirm:$false -ErrorAction Stop
    }
    if ($null -ne $before.pid) {
        $wait=[Diagnostics.Stopwatch]::StartNew()
        do {
            $remaining=Get-InheritedCpuObservation
            if ($null -eq $remaining.pid) { break }
            Start-Sleep -Milliseconds 200
        } while ($wait.Elapsed.TotalSeconds -lt 15)
        if ($null -ne $remaining.pid) { throw 'CPU process stop unverified' }
    }
    $cpuProcesses=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object {
        $_.CommandLine -match '(?i)C:\\LabCpuSimulation\\windows-cpu\.ps1.*-Mode Worker'
    })
    if ((Get-TaskObservation 'LabCpuSimulation').exists -or $cpuProcesses.Count -gt 0) { throw 'CPU task/process disarm unverified' }
    $path='C:\LabCpuSimulation\state.json'
    if (Test-Path -LiteralPath $path) { @{status='stopped';targetWorkerCpuPercent=0;heartbeatUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress | Set-Content -LiteralPath $path -Encoding UTF8 }
}
function Stop-LabGenerators {
    Stop-InheritedCpu
    foreach ($name in @('LabOrderDeskTraffic','LabPostMigrationExpiry')) {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $name })
        if ($tasks.Count -gt 1) { throw 'Ambiguous generator task' }
        if ($tasks.Count) {
            if ([string]$tasks[0].State -in @('Running','Queued')) { $tasks[0] | Stop-ScheduledTask -ErrorAction Stop }
            $tasks[0] | Disable-ScheduledTask -ErrorAction Stop | Out-Null
            $until = [DateTime]::UtcNow.AddSeconds(20)
            do {
                $observation = Get-TaskObservation $name
                if ($observation.state -notin @('Running','Queued') -and -not $observation.enabled) { break }
                Start-Sleep -Seconds 1
            } while ([DateTime]::UtcNow -lt $until)
            if ($observation.state -in @('Running','Queued') -or $observation.enabled) { throw 'Generator stop unverified' }
        }
    }
    $statePath = Join-Path $root 'post-migration-state.json'
    if (Test-Path $statePath) {
        # Stop must recover a corrupt state too; only generator state is replaced.
        $stored=$null; $runId='unknown'; $deadlineValue=$null
        try {
            $stored = Get-Content $statePath -Raw | ConvertFrom-Json
            if ($stored.runId -match '^[a-f0-9]{32}$') { $runId=[string]$stored.runId }
            if ($stored.deadlineUtc) { $deadlineValue=[DateTime]::Parse($stored.deadlineUtc).ToUniversalTime().ToString('o') }
        } catch { $deadlineValue=$null }
        @{runId=$runId;deadlineUtc=$deadlineValue;phase='stopped';heartbeatUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress | Set-Content $statePath -Encoding UTF8
    }
}
function Get-AliasObservation {
    $observed = @{}; $matched = $true
    foreach ($property in $config.aliases.PSObject.Properties) {
        try { $ips = @([Net.Dns]::GetHostAddresses($property.Name) | ForEach-Object { $_.IPAddressToString } | Sort-Object -Unique) }
        catch { $ips = @('unavailable') }
        $observed[$property.Name] = ($ips -join ',')
        if ($ips.Count -ne 1 -or $ips[0] -ne $property.Value) { $matched = $false }
    }
    return @{ matched=$matched; observed=$observed }
}
function Test-Tcp {
    param([string]$IP,[int]$Port)
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($IP,$Port,$null,$null)
        if (-not $async.AsyncWaitHandle.WaitOne(3000)) { return $false }
        $client.EndConnect($async); return $client.Connected
    } catch { return $false } finally { $client.Dispose() }
}
function Get-SafeHttp {
    param([string]$Url)
    $request = [Net.HttpWebRequest]::Create($Url); $request.Proxy = $null
    $request.AllowAutoRedirect = $false; $request.Timeout = 10000; $request.ReadWriteTimeout = 10000
    $response = $request.GetResponse()
    try {
        if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt 262144) { throw 'HTTP response failed' }
        $reader = New-Object IO.StreamReader($response.GetResponseStream())
        try {
            $buffer=New-Object char[] 262145
            $length=$reader.ReadBlock($buffer,0,$buffer.Length)
            if ($length -gt 262144) { throw 'HTTP result too large' }
            return [string]::new($buffer,0,$length)
        } finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}
function Get-SqlSnapshot {
    $password = Get-LabPassword
    if ([string]::IsNullOrEmpty($password)) { throw 'Empty credential' }
    $builder = New-Object Data.SqlClient.SqlConnectionStringBuilder
    $builder.DataSource = 'onprem-sql,1433'; $builder.InitialCatalog = 'ContosoApp'; $builder.UserID = 'labapp'
    $builder.Password = $password; $builder.TrustServerCertificate = $true; $builder.ConnectTimeout = 10
    $connection = New-Object Data.SqlClient.SqlConnection
    $connection.ConnectionString=$builder.ConnectionString
    try {
        $connection.Open(); $command = $connection.CreateCommand(); $command.CommandTimeout = 10
        $command.CommandText = 'SELECT COUNT_BIG(*) FROM dbo.Orders'
        $count = [long]$command.ExecuteScalar()
        $command.CommandText = 'SELECT TOP 5 OrderID FROM dbo.Orders ORDER BY OrderID DESC'
        $reader = $command.ExecuteReader(); $rows = 0
        try { while ($reader.Read()) { $rows++ } } finally { $reader.Dispose() }
        return @{ count=$count; readRows=$rows }
    } finally { $connection.Dispose(); $password=$null; $builder.Password='' }
}
function Get-GuestObservation {
    $task = Get-TaskObservation 'LabOrderDeskTraffic'
    $expiry = Get-TaskObservation 'LabPostMigrationExpiry'
    $state = $null
    if (Test-Path (Join-Path $root 'post-migration-state.json')) {
        try {
            $stored = Get-Content (Join-Path $root 'post-migration-state.json') -Raw | ConvertFrom-Json
            if ($stored.phase -notin @('armed','running','expired','stopped','failed') -or $stored.runId -notmatch '^(unknown|[a-f0-9]{32})$') { throw 'Unknown state' }
            $state = @{ phase=[string]$stored.phase; runId=[string]$stored.runId; deadlineUtc=[string]$stored.deadlineUtc; heartbeatUtc=[string]$stored.heartbeatUtc; expired=$false }
            if ($stored.deadlineUtc) { $state.expired = ([DateTime]::UtcNow -ge [DateTime]::Parse($stored.deadlineUtc).ToUniversalTime()) }
        } catch { $state = @{phase='unknown'} }
    }
    $aliases = Get-AliasObservation
    $hostname = [string]$env:COMPUTERNAME
    $fqdn = 'unavailable'
    $properties = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
    if ($properties.DomainName) {
        $candidate = $properties.HostName + '.' + $properties.DomainName
        try {
            $dns = @(Resolve-DnsName -Name $candidate -Type A -DnsOnly -NoHostsFile -ErrorAction Stop | Where-Object { $_.IPAddress -eq $config.ownIP })
            if ($dns.Count) { $fqdn = $candidate }
        } catch { }
    }
    $ownIPMatched = (@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.IPAddress -eq $config.ownIP }).Count -eq 1)
    $serviceName = if ($config.role -eq 'Web') { 'W3SVC' } else { 'MSSQL$SQLEXPRESS' }
    $services = @(Get-Service -ErrorAction Stop | Where-Object { $_.Name -eq $serviceName })
    $serviceStatus = if ($services.Count -eq 1) { [string]$services[0].Status } else { 'unavailable' }
    $port = if ($config.role -eq 'Web') { 80 } else { 1433 }
    return @{ hostname=$hostname; fqdn=$fqdn; ownIPMatched=$ownIPMatched; aliases=$aliases; service=$serviceStatus; listeners=@{$port=(Test-Tcp '127.0.0.1' $port)}; generator=$task; expiry=$expiry; durableState=$state; cpu=(Get-InheritedCpuObservation) }
}
try {
    if ($config.action -eq 'Pause' -or $config.action -eq 'Stop') { Stop-LabGenerators }
    if ($config.action -eq 'Prepare') {
        $path = "$env:SystemRoot\System32\drivers\etc\hosts"
        $aliases = @{}; foreach ($property in $config.aliases.PSObject.Properties) { $aliases[$property.Name]=$property.Value }
        # Decode strictly: an unsupported hosts encoding must fail, not lose comments/names.
        $before = [IO.File]::ReadAllText($path,(New-Object Text.UTF8Encoding($false,$true)))
        $after = Update-LabHostsText $before $aliases
        if ($before -ne $after) {
            Copy-Item -LiteralPath $path -Destination ($path + '.labtraffic.' + $config.nonce + '.bak') -ErrorAction Stop
            [IO.File]::WriteAllText($path,$after,(New-Object Text.UTF8Encoding($false)))
            Clear-DnsClientCache -ErrorAction Stop
        }
        if ($config.role -eq 'Web') {
            Protect-Root
            if (-not [Diagnostics.EventLog]::SourceExists('LabPostMigrationTraffic')) { New-EventLog -LogName Application -Source LabPostMigrationTraffic }
        }
    }
    if ($config.action -eq 'Arm') {
        if ($config.role -ne 'Web' -or -not (Get-AliasObservation).matched) { throw 'Not safe to arm' }
        $observation = Get-TaskObservation 'LabOrderDeskTraffic'
        if ($observation.state -in @('Running','Queued') -or $observation.enabled) { throw 'Generator not paused' }
        Protect-Root; Add-Type -AssemblyName System.Security
        $password = Get-LabPassword
        $bytes = [Text.Encoding]::UTF8.GetBytes($password)
        try { [IO.File]::WriteAllBytes((Join-Path $root 'post-migration-credential.bin'),[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)) }
        finally { [Array]::Clear($bytes,0,$bytes.Length); $password=$null }
        $worker = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($config.workerBase64))
        Set-Content (Join-Path $root 'post-migration-worker.ps1') -Value $worker -Encoding UTF8
        $config | Select-Object runId,deadlineUtc,intervalSeconds,aliases | ConvertTo-Json -Depth 6 -Compress | Set-Content (Join-Path $root 'post-migration-config.json') -Encoding UTF8
        @{runId=$config.runId;deadlineUtc=$config.deadlineUtc;phase='armed';heartbeatUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress | Set-Content (Join-Path $root 'post-migration-state.json') -Encoding UTF8
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\LabTraffic\post-migration-worker.ps1'
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $config.durationSeconds) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName LabOrderDeskTraffic -Action $action -Settings $settings -User SYSTEM -RunLevel Highest -Force | Out-Null
        # No startup trigger or restart policy. A separate once-only task enforces expiry.
        $expiryText = @("Stop-ScheduledTask -TaskName LabOrderDeskTraffic -ErrorAction Stop", "Disable-ScheduledTask -TaskName LabOrderDeskTraffic | Out-Null", '$s = Get-Content C:\LabTraffic\post-migration-state.json -Raw | ConvertFrom-Json', '$s.phase = ''expired''', '$s | ConvertTo-Json -Compress | Set-Content C:\LabTraffic\post-migration-state.json -Encoding UTF8') -join "`r`n"
        Set-Content (Join-Path $root 'post-migration-expiry.ps1') -Value $expiryText -Encoding UTF8
        $expiryAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\LabTraffic\post-migration-expiry.ps1'
        $trigger = New-ScheduledTaskTrigger -Once -At ([DateTime]::Parse($config.deadlineUtc).ToLocalTime())
        Register-ScheduledTask -TaskName LabPostMigrationExpiry -Action $expiryAction -Trigger $trigger -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)) -User SYSTEM -RunLevel Highest -Force | Out-Null
        Protect-Root
    }
    if ($config.action -eq 'Launch') {
        $state = Get-Content (Join-Path $root 'post-migration-state.json') -Raw | ConvertFrom-Json
        if ($state.phase -ne 'armed' -or $state.runId -ne $config.runId -or [DateTime]::UtcNow -ge [DateTime]::Parse($state.deadlineUtc).ToUniversalTime()) { throw 'Not armed for this run' }
        Start-ScheduledTask -TaskName LabOrderDeskTraffic -ErrorAction Stop
        Start-Sleep -Seconds 2
        if ((Get-TaskObservation 'LabOrderDeskTraffic').state -ne 'Running') { throw 'Launch unverified' }
    }
    if ($config.action -eq 'Summary' -and $config.role -eq 'Web') {
        Protect-Root
        Write-BoundedLog $config.summary
        if ([Diagnostics.EventLog]::SourceExists('LabPostMigrationTraffic')) {
            Write-EventLog -LogName Application -Source LabPostMigrationTraffic -EventId 100 -EntryType Information -Message $config.summary
        }
    }
    $observation = Get-GuestObservation
    $checks = @{}; $snapshot = $null
    if ($config.action -eq 'Check') {
        $checks.localService = ($observation.service -eq 'Running')
        $checks.localListener = (@($observation.listeners.Values | Where-Object { -not $_ }).Count -eq 0)
        if ($config.role -eq 'Web') {
            $checks.webToSql1433 = Test-Tcp $config.aliases.'onprem-sql' 1433
            $checks.webToApp3000 = Test-Tcp $config.aliases.'onprem-app' 3000
            try { $checks.iisPage = ((Get-SafeHttp 'http://127.0.0.1/') -match '<title>TD SYNNEX - Cloud Enablement Services</title>') } catch { $checks.iisPage=$false }
            $checks.sqlRead=$false; $checks.appHealth=$false; $checks.appReady=$false; $checks.ordersRead=$false
            if ($config.allowApp -and $observation.aliases.matched -and $observation.ownIPMatched) {
                try { $snapshot=Get-SqlSnapshot; $checks.sqlRead=$true } catch { }
                try {
                    $health = Get-SafeHttp 'http://onprem-app:3000/api/health' | ConvertFrom-Json
                    $checks.appHealth = ($health.status -ceq 'healthy' -and $health.app -ceq 'Contoso Order Desk')
                    $ready = Get-SafeHttp 'http://onprem-app:3000/api/ready' | ConvertFrom-Json
                    $checks.appReady = ($ready.status -ceq 'ready' -and $ready.database -ceq 'reachable' -and $ready.app -ceq 'Contoso Order Desk')
                    $orders = Get-SafeHttp 'http://onprem-app:3000/api/orders' | ConvertFrom-Json
                    $checks.ordersRead = ($null -ne $orders.count -and $orders.customerCount -gt 0 -and @($orders.customers).Count -gt 0 -and $null -ne $orders.orders)
                } catch { }
            }
        }
    }
    $ready = ($observation.ownIPMatched -and $observation.aliases.matched -and @($checks.Values | Where-Object { -not $_ }).Count -eq 0)
    $result = @{ok=$true;nonce=$config.nonce;role=$config.role;action=$config.action;observation=$observation;checks=$checks;ready=$ready;sqlSnapshot=$snapshot}
    $json = $result | ConvertTo-Json -Depth 9 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 3500) { throw 'Result too large' }
    Write-Output ('LAB_POSTMIGRATION ' + $json)
} catch {
    Write-Output ('LAB_POSTMIGRATION ' + (@{ok=$false;nonce=$config.nonce;role=$config.role;action=$config.action;code='guest_failed_unknown_or_partial'} | ConvertTo-Json -Compress))
    exit 1
} finally { $SqlPassword=$null }
'@

$LinuxPythonBody = @'
import base64
import ctypes
import ipaddress
import json
import os
import pathlib
import re
import shutil
import socket
import struct
import subprocess
import sys
import time
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True
ROOT = pathlib.Path('/var/lib/contoso-orderdesk/labtraffic')
UNITS = ('contoso-orderdesk-traffic.service', 'lab-traffic.service')
DEADLINE_TIMER = 'lab-postmigration-deadline.timer'
DEADLINE_SERVICE = 'lab-postmigration-deadline.service'
ALIASES = ('onprem-web', 'onprem-sql', 'onprem-nginx', 'onprem-app')


def command(*args, required=True):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, timeout=30, check=False)
    if required and result.returncode:
        raise ValueError('local_command_failed')
    return result.stdout.strip()


def unit_observation(name):
    text = command('systemctl', 'show', name, '--property=LoadState,ActiveState,SubState,UnitFileState', required=False)
    values = dict(line.split('=', 1) for line in text.splitlines() if '=' in line)
    if not values.get('LoadState') or not values.get('ActiveState'):
        raise ValueError('unit_observation_unknown')
    exists = values['LoadState'] != 'not-found'
    return dict(exists=exists, active=values['ActiveState'], substate=values.get('SubState', ''),
                enabled=values.get('UnitFileState', 'unknown'))


def aliases_observation(config):
    observed = {}
    for name, expected in config['aliases'].items():
        try:
            observed[name] = ','.join(sorted({row[4][0] for row in socket.getaddrinfo(name, None)}))
        except OSError:
            observed[name] = 'unavailable'
    return dict(matched=all(observed[name] == ip for name, ip in config['aliases'].items()), observed=observed)


def update_hosts_text(text, aliases):
    lines = []
    for line in text.splitlines():
        content, marker, comment = line.partition('#')
        tokens = content.split()
        if len(tokens) < 2:
            lines.append(line)
            continue
        names = [name for name in tokens[1:] if name.lower() not in aliases]
        if len(names) == len(tokens) - 1:
            lines.append(line)
        elif names:
            lines.append((tokens[0] + '\t' + ' '.join(names) + (' #' + comment if marker else '')).rstrip())
        elif marker:
            lines.append('#' + comment)
    lines.extend(aliases[name] + '\t' + name for name in sorted(aliases))
    return '\n'.join(lines).rstrip() + '\n'


def tcp(ip, port):
    try:
        with socket.create_connection((ip, port), timeout=3):
            return True
    except OSError:
        return False


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('redirect_not_allowed')


def http(base, path, data=None, expected=200):
    if base not in ('http://127.0.0.1:80', 'http://127.0.0.1:8080', 'http://127.0.0.1:3000',
                    'http://onprem-nginx:8080', 'http://onprem-app:3000'):
        raise ValueError('non_lab_url')
    if path not in ('/', '/api/health', '/api/ready', '/api/orders'):
        raise ValueError('non_lab_path')
    body = None if data is None else urllib.parse.urlencode(data).encode('ascii')
    request = urllib.request.Request(base + path, data=body,
                                   headers={'Content-Type': 'application/x-www-form-urlencoded'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(request, timeout=10) as response:
        if response.status != expected:
            raise ValueError('unexpected_http_status')
        content = response.read(262145)
        if len(content) > 262144:
            raise ValueError('http_result_too_large')
        return content.decode('utf-8')


def app_checks(base):
    health = json.loads(http(base, '/api/health'))
    ready = json.loads(http(base, '/api/ready'))
    orders = json.loads(http(base, '/api/orders'))
    return dict(health=health.get('app') == 'Contoso Order Desk' and health.get('status') == 'healthy',
                ready=ready.get('app') == 'Contoso Order Desk' and ready.get('status') == 'ready' and ready.get('database') == 'reachable',
                orders=isinstance(orders.get('orders'), list) and isinstance(orders.get('count'), int)
                and orders.get('customerCount', 0) > 0 and bool(orders.get('customers')),
                page='Contoso Order Desk' in http(base, '/'))


def actual_dns_fqdn(own_ip):
    # hostname -f alone can be a hosts-file result, so separately ask DNS via libresolv.
    candidate = command('hostname', '-f', required=False)
    if '.' not in candidate or len(candidate) > 253 or not re.fullmatch(r'[A-Za-z0-9.-]+', candidate):
        return 'unavailable'
    try:
        library = ctypes.CDLL('libresolv.so.2')
        query = library.res_query
        query.argtypes = (ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_int)
        query.restype = ctypes.c_int
        packet = ctypes.create_string_buffer(4096)
        length = query(candidate.encode('ascii'), 1, 1, packet, len(packet))
        if length < 12 or length > len(packet):
            return 'unavailable'
        data = packet.raw[:length]
        qd, an = struct.unpack('!HH', data[4:8])
        def skip_name(pos):
            while True:
                size = data[pos]
                if size & 0xc0 == 0xc0:
                    return pos + 2
                pos += 1
                if size == 0:
                    return pos
                pos += size
        pos = 12
        for _ in range(qd):
            pos = skip_name(pos) + 4
        for _ in range(an):
            pos = skip_name(pos)
            kind, family, _, size = struct.unpack('!HHIH', data[pos:pos + 10])
            pos += 10
            if kind == 1 and family == 1 and size == 4 and socket.inet_ntoa(data[pos:pos + size]) == own_ip:
                return candidate
            pos += size
    except (OSError, AttributeError, IndexError, struct.error):
        pass
    return 'unavailable'


def read_state():
    path = ROOT / 'state.json'
    if not path.exists():
        return None
    try:
        state = json.loads(path.read_text())
        if state['phase'] not in ('armed', 'running', 'expired', 'stopped', 'failed'):
            raise ValueError('unknown_phase')
        if not re.fullmatch(r'(unknown|[a-f0-9]{32})', state['runId']):
            raise ValueError('unknown_run')
        return dict(phase=state['phase'], runId=state['runId'], deadlineUtc=state.get('deadlineUtc'),
                    heartbeatUtc=state.get('heartbeatUtc'), expired=time.time() >= state.get('deadlineEpoch', 0))
    except (ValueError, KeyError, TypeError, OSError):
        return dict(phase='unknown')


def write_state(state, phase):
    state['phase'] = phase
    state['heartbeatUtc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    (ROOT / 'state.json').write_text(json.dumps(state, separators=(',', ':')) + '\n')


def cpu_observation():
    unit = unit_observation('lab-cpu-simulation.service')
    state, stale, healthy = None, True, False
    pid = 0
    try:
        pid = int(command('systemctl', 'show', 'lab-cpu-simulation.service', '--property=MainPID', '--value') or '0') if unit['exists'] else 0
        path = pathlib.Path('/var/lib/lab-cpu-simulation/state.json')
        if path.stat().st_size > 16384:
            raise ValueError('cpu_state_too_large')
        stored = json.loads(path.read_text())
        names = ('runId', 'pid', 'status', 'phase', 'heartbeatUtc', 'expiresUtc', 'targetTotalCpuPercent',
                 'targetWorkerCpuPercent', 'measuredTotalCpuPercent', 'measuredWorkerCpuPercent',
                 'baselineCpuPercent', 'baselineAboveGoal', 'guard', 'cooldownRemainingSeconds', 'reason')
        state = {name: stored.get(name) for name in names}
        import datetime
        age = time.time() - datetime.datetime.fromisoformat(stored['heartbeatUtc']).timestamp()
        stale = not 0 <= age <= 10
        config = json.loads(pathlib.Path('/opt/lab-cpu-simulation/config.json').read_text())
        identity = pathlib.Path('/proc/{}/stat'.format(pid)).read_text().split(') ', 1)[1].split()[19] if pid > 0 else None
        healthy = (unit['active'] == 'active' and pid > 0 and pid == stored['pid'] and not stale and
                   stored['status'] == 'running' and stored['runId'] == config['runId'] and time.time() < config['expiresEpoch'] and
                   stored['bootId'] == pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip() and stored['processStart'] == identity)
    except (OSError, ValueError, KeyError, TypeError, IndexError):
        pass
    return dict(service=unit, pid=pid, healthy=healthy, stale=stale, state=state)


def stop_inherited_cpu():
    name = 'lab-cpu-simulation.service'
    unit = unit_observation(name)
    if unit['exists']:
        if unit['enabled'] not in ('transient', 'disabled', 'masked', 'static', ''):
            command('systemctl', 'disable', name)
        command('systemctl', 'stop', name)
        after = unit_observation(name)
        if after['active'] not in ('inactive', 'failed') or after['enabled'] not in ('transient', 'disabled', 'masked', 'static', ''):
            raise ValueError('cpu_stop_disarm_unverified')
        pid = command('systemctl', 'show', name, '--property=MainPID', '--value', required=False)
        if pid not in ('0', ''):
            raise ValueError('cpu_process_stop_unverified')
    path = pathlib.Path('/var/lib/lab-cpu-simulation/state.json')
    if path.exists():
        path.write_text(json.dumps(dict(status='stopped', targetWorkerCpuPercent=0, heartbeatUtc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))) + '\n')


def pause_generators():
    stop_inherited_cpu()
    timer = unit_observation(DEADLINE_TIMER)
    if timer['exists']:
        command('systemctl', 'disable', '--now', DEADLINE_TIMER)
        timer = unit_observation(DEADLINE_TIMER)
        if timer['active'] != 'inactive' or timer['enabled'] not in ('disabled', 'masked'):
            raise ValueError('deadline_timer_stop_unverified')
    handler = unit_observation(DEADLINE_SERVICE)
    if handler['exists']:
        command('systemctl', 'stop', DEADLINE_SERVICE)
        if unit_observation(DEADLINE_SERVICE)['active'] == 'failed':
            command('systemctl', 'reset-failed', DEADLINE_SERVICE)
        if unit_observation(DEADLINE_SERVICE)['active'] != 'inactive':
            raise ValueError('deadline_handler_stop_unverified')
    for name in UNITS:
        observation = unit_observation(name)
        if observation['exists']:
            command('systemctl', 'disable', '--now', name)
            current = unit_observation(name)
            if current['active'] == 'failed':
                command('systemctl', 'reset-failed', name)
                current = unit_observation(name)
            if current['active'] != 'inactive' or current['enabled'] not in ('disabled', 'masked'):
                raise ValueError('generator_stop_unverified')
    if (ROOT / 'state.json').exists():
        state = dict(runId='unknown', deadlineEpoch=0, deadlineUtc=None)
        try:
            stored = json.loads((ROOT / 'state.json').read_text())
            if isinstance(stored, dict):
                if re.fullmatch(r'[a-f0-9]{32}', str(stored.get('runId', ''))):
                    state['runId'] = stored['runId']
                if isinstance(stored.get('deadlineEpoch'), (int, float)):
                    state['deadlineEpoch'] = stored['deadlineEpoch']
                    state['deadlineUtc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(stored['deadlineEpoch']))
        except (ValueError, OverflowError, OSError):
            pass
        write_state(state, 'stopped')


def observation(config):
    generators = {name: unit_observation(name) for name in UNITS}
    state = read_state()
    interfaces = json.loads(command('ip', '-j', '-4', 'address', 'show'))
    ips = [item['local'] for interface in interfaces for item in interface.get('addr_info', [])]
    service = 'nginx.service' if config['role'] == 'Nginx' else 'contoso-orderdesk.service'
    ports = (80, 8080) if config['role'] == 'Nginx' else (3000,)
    return dict(hostname=socket.gethostname(), fqdn=actual_dns_fqdn(config['ownIP']),
                ownIPMatched=ips.count(config['ownIP']) == 1, aliases=aliases_observation(config),
                service=unit_observation(service)['active'], listeners={str(port): tcp('127.0.0.1', port) for port in ports},
                generators=generators, expiry=dict(timer=unit_observation(DEADLINE_TIMER), handler=unit_observation(DEADLINE_SERVICE)), durableState=state, cpu=cpu_observation())


def prepare(config):
    path = pathlib.Path('/etc/hosts')
    before = path.read_text()
    after = update_hosts_text(before, config['aliases'])
    if before != after:
        shutil.copy2(path, str(path) + '.labtraffic.' + config['nonce'] + '.bak')
        path.write_text(after)
    if config['role'] == 'App':
        # Existing JNDI credentials and CATALINA_BASE are left intact.
        command('systemctl', 'restart', 'contoso-orderdesk.service')
    else:
        command('nginx', '-t')
        command('systemctl', 'reload', 'nginx.service')


def verify_traffic_identity(duration=None):
    fields = 'DynamicUser,User,Group,NoNewPrivileges,ProtectSystem,ProtectHome,MemoryMax,TasksMax,UMask,ExecStart,Restart,RuntimeMaxUSec'
    text = command('systemctl', 'show', UNITS[0], '--property=' + fields)
    values = dict(line.split('=', 1) for line in text.splitlines() if '=' in line)
    expected = dict(DynamicUser='yes', NoNewPrivileges='yes', ProtectSystem='strict',
                    ProtectHome='yes', MemoryMax=str(64 * 1024 * 1024), TasksMax='20', UMask='0077')
    if any(values.get(key) != value for key, value in expected.items()):
        raise ValueError('original_traffic_identity_or_hardening_unverified')
    if values.get('User', '') not in ('', 'contoso-orderdesk-traffic') or values.get('Group', '') not in ('', 'contoso-orderdesk-traffic'):
        raise ValueError('original_dynamic_identity_unverified')
    if not re.search(r'argv\[\]=/usr/bin/python3 /opt/contoso-orderdesk/scripts/traffic\.py(?: ;|$)', values.get('ExecStart', '')):
        raise ValueError('original_traffic_exec_unverified')
    if duration is not None:
        # systemctl renders whole-minute limits as h/min/s; verify the full timespan.
        runtime = values.get('RuntimeMaxUSec', '')
        seconds = 0
        units = {'h': 3600, 'min': 60, 's': 1}
        tokens = re.findall(r'([0-9]+)(h|min|s)', runtime)
        if not tokens or re.sub(r'([0-9]+)(h|min|s)\s*', '', runtime).strip():
            raise ValueError('runtime_limit_unverified')
        for number, unit in tokens:
            seconds += int(number) * units[unit]
        if values.get('Restart') != 'no' or seconds != duration:
            raise ValueError('lifetime_override_unverified')


def write_owned(path, text):
    marker = '# Lab post-migration lifetime control\n'
    if path.exists() and not path.read_text().startswith(marker):
        raise ValueError('unowned_lifetime_file_conflict')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(marker + text)
    os.chown(path, 0, 0); os.chmod(path, 0o644)


def arm(config):
    if config['role'] != 'App' or not aliases_observation(config)['matched']:
        raise ValueError('not_safe_to_arm')
    for name in UNITS:
        state = unit_observation(name)
        if state['active'] != 'inactive' or (state['exists'] and state['enabled'] not in ('disabled', 'masked')):
            raise ValueError('generator_not_paused')
    verify_traffic_identity()
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chown(ROOT, 0, 0); os.chmod(ROOT, 0o700)
    worker = ROOT / 'deadline.py'
    worker.write_bytes(base64.b64decode(config['workerBase64'], validate=True))
    os.chown(worker, 0, 0); os.chmod(worker, 0o700)
    settings = {key: config[key] for key in ('runId', 'deadlineUtc', 'deadlineEpoch', 'intervalSeconds', 'aliases')}
    settings['durationSeconds'] = config['durationSeconds']
    for name, content in (('config.json', settings), ('state.json', dict(settings, phase='armed', heartbeatUtc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())))):
        path = ROOT / name; path.write_text(json.dumps(content))
        os.chown(path, 0, 0); os.chmod(path, 0o600)
    # The installed DynamicUser unit and its ExecStart/security settings are untouched.
    dropin = pathlib.Path('/etc/systemd/system/contoso-orderdesk-traffic.service.d/90-lab-postmigration-lifetime.conf')
    write_owned(dropin, '[Service]\nRuntimeMaxSec={0}\nRestart=no\n'.format(config['durationSeconds']))
    handler = pathlib.Path('/etc/systemd/system') / DEADLINE_SERVICE
    write_owned(handler, '[Unit]\nDescription=Stop expired lab traffic; no HTTP generation\n'
                '[Service]\nType=oneshot\nExecStart=/usr/bin/python3 -B /var/lib/contoso-orderdesk/labtraffic/deadline.py\n'
                'NoNewPrivileges=true\nProtectSystem=strict\nProtectHome=true\n'
                'ReadWritePaths=/var/lib/contoso-orderdesk/labtraffic\n')
    calendar = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(config['deadlineEpoch']))
    timer = pathlib.Path('/etc/systemd/system') / DEADLINE_TIMER
    write_owned(timer, '[Unit]\nDescription=Guest-local lab traffic deadline\n[Timer]\n'
                'OnCalendar={0}\nAccuracySec=1s\nPersistent=true\nUnit={1}\n'
                '[Install]\nWantedBy=timers.target\n'.format(calendar, DEADLINE_SERVICE))
    traffic_config = pathlib.Path('/etc/contoso-orderdesk-traffic.json')
    if traffic_config.exists():
        shutil.copy2(traffic_config, str(traffic_config) + '.labtraffic.' + config['nonce'] + '.bak')
    traffic_config.write_text(json.dumps(dict(baseUrl='http://onprem-nginx:8080', intervalSeconds=config['intervalSeconds'])))
    # No secrets here. DynamicUser must be able to read the installed generator config.
    os.chown(traffic_config, 0, 0); os.chmod(traffic_config, 0o644)
    command('systemctl', 'daemon-reload')
    command('systemctl', 'disable', UNITS[0], DEADLINE_TIMER)
    verify_traffic_identity(config['durationSeconds'])


def launch(config):
    state = read_state()
    if not state or state['phase'] != 'armed' or state['runId'] != config['runId'] or state['expired']:
        raise ValueError('not_armed_for_this_run')
    settings = json.loads((ROOT / 'config.json').read_text())
    if not aliases_observation(config)['matched']:
        raise ValueError('launch_aliases_unverified')
    verify_traffic_identity(settings['durationSeconds'])
    command('systemctl', 'start', DEADLINE_TIMER)
    if unit_observation(DEADLINE_TIMER)['active'] != 'active':
        raise ValueError('deadline_timer_unverified')
    command('systemctl', 'start', UNITS[0])
    time.sleep(2)
    if unit_observation(UNITS[0])['active'] != 'active':
        raise ValueError('launch_unverified')
    state = json.loads((ROOT / 'state.json').read_text())
    if time.time() >= settings['deadlineEpoch'] or state['phase'] != 'armed':
        raise ValueError('launch_expired_or_partial')
    write_state(state, 'running')


def sample_order(config):
    if config['role'] != 'App' or not config['allowApp'] or not aliases_observation(config)['matched']:
        raise ValueError('write_gate_failed')
    base = 'http://onprem-nginx:8080'
    if not all(app_checks(base).values()):
        raise ValueError('write_readiness_failed')
    before = json.loads(http(base, '/api/orders'))
    created = json.loads(http(base, '/api/orders', dict(customerId=before['customers'][0]['customerId'],
                        productName='Order Desk validation', quantity=1, unitPrice='9.99'), expected=201))
    after = json.loads(http(base, '/api/orders'))
    if created.get('status') != 'created' or not isinstance(created.get('orderId'), int):
        raise ValueError('write_outcome_unknown')
    if after['count'] < before['count'] + 1 or not any(str(row['orderId']) == str(created['orderId']) for row in after['orders']):
        raise ValueError('write_readback_unverified')
    return dict(orderId=created['orderId'], beforeCount=before['count'], afterCount=after['count'])


def validate_config(config):
    if config['role'] not in ('App', 'Nginx') or set(config['aliases']) != set(ALIASES):
        raise ValueError('invalid_config')
    if not re.fullmatch(r'[a-f0-9]{32}', config['nonce']):
        raise ValueError('invalid_nonce')
    for ip in list(config['aliases'].values()) + [config['ownIP']]:
        address = ipaddress.IPv4Address(ip)
        if not address.is_private or address.is_loopback or address.is_link_local:
            raise ValueError('non_private_target')


def main(config):
    validate_config(config)
    action = config['action']
    if action in ('Pause', 'Stop'):
        pause_generators()
    if action == 'Prepare':
        prepare(config)
    if action == 'Arm':
        arm(config)
    if action == 'Launch':
        launch(config)
    data = observation(config)
    checks = {}
    sample = None
    if action == 'Check':
        checks['localService'] = data['service'] == 'active'
        checks['localListeners'] = all(data['listeners'].values())
        if config['role'] == 'App':
            checks['appToSql1433'] = tcp(config['aliases']['onprem-sql'], 1433)
            checks['appToNginx8080'] = tcp(config['aliases']['onprem-nginx'], 8080)
            bases = {'tomcat': 'http://127.0.0.1:3000', 'proxy': 'http://onprem-nginx:8080'}
        else:
            checks['nginxToApp3000'] = tcp(config['aliases']['onprem-app'], 3000)
            try:
                checks['nginxPage'] = '<title>TD SYNNEX - Cloud Enablement Services</title>' in http('http://127.0.0.1:80', '/')
            except Exception:
                checks['nginxPage'] = False
            bases = {'upstream': 'http://onprem-app:3000', 'proxy': 'http://127.0.0.1:8080'}
        for label, base in bases.items():
            for check in ('health', 'ready', 'orders', 'page'):
                checks[label + '_' + check] = False
            if config['allowApp'] and data['aliases']['matched'] and data['ownIPMatched']:
                try:
                    checks.update({label + '_' + key: value for key, value in app_checks(base).items()})
                except Exception:
                    pass
    if action == 'Sample':
        sample = sample_order(config)
    return dict(ok=True, nonce=config['nonce'], role=config['role'], action=action,
                observation=data, checks=checks, sample=sample,
                ready=data['ownIPMatched'] and data['aliases']['matched'] and all(checks.values()))


def self_test():
    from unittest.mock import patch
    import copy
    config = dict(role='App', nonce='a' * 32, ownIP='10.1.1.13', allowApp=True,
                  aliases={'onprem-web': '10.1.1.10', 'onprem-sql': '10.1.1.11',
                           'onprem-nginx': '10.1.1.12', 'onprem-app': '10.1.1.13'})
    validate_config(config)
    original = '127.0.0.1 localhost\n192.168.0.11 ONPREM-SQL other # keep\n192.168.0.13 onprem-app # app\n# untouched\n'
    after = update_hosts_text(original, config['aliases'])
    assert '192.168.0.11\tother # keep' in after and '# app' in after and '# untouched' in after
    assert update_hosts_text(after, config['aliases']) == after
    assert '192.168.0.13 onprem-app' not in after and '10.1.1.13\tonprem-app' in after
    for key, bad in (('role', 'App; shell'), ('nonce', '../../bad'), ('ownIP', '127.0.0.1')):
        changed = copy.deepcopy(config); changed[key] = bad
        try:
            validate_config(changed)
        except ValueError:
            pass
        else:
            raise AssertionError('unsafe_config_accepted')
    def address(name, _):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, '', (config['aliases'][name], 0))]
    with patch.dict(aliases_observation.__globals__, socket=socket):
        with patch.object(socket, 'getaddrinfo', side_effect=address):
            assert aliases_observation(config)['matched']
        with patch.object(socket, 'getaddrinfo', return_value=[(2, 1, 6, '', ('192.168.0.11', 0))]):
            assert not aliases_observation(config)['matched']
    for base in ('https://example.invalid', 'http://onprem-nginx:8080@outside.invalid'):
        try:
            http(base, '/')
        except ValueError:
            pass
        else:
            raise AssertionError('non_lab_url_accepted')
    try:
        NoRedirect().redirect_request(None, None, 302, '', {}, 'http://outside.invalid')
    except ValueError:
        pass
    else:
        raise AssertionError('redirect_accepted')
    calls = []; inserted = [False]
    def fake_http(base, path, data=None, expected=200):
        calls.append((path, data, expected))
        if path == '/api/health':
            return json.dumps(dict(app='Contoso Order Desk', status='healthy'))
        if path == '/api/ready':
            return json.dumps(dict(app='Contoso Order Desk', status='ready', database='reachable'))
        if path == '/':
            return '<title>Contoso Order Desk</title>'
        if data is not None:
            inserted[0] = True
            return json.dumps(dict(status='created', orderId=8))
        return json.dumps(dict(count=8 if inserted[0] else 7, customerCount=1, customers=[dict(customerId='1')], orders=[dict(orderId='8' if inserted[0] else '7')]))
    with patch.dict(sample_order.__globals__, http=fake_http, aliases_observation=lambda _: dict(matched=True)):
        assert all(app_checks('http://onprem-nginx:8080').values())
        assert not any(data for _, data, _ in calls), 'read_checks_must_not_post'
        for database in (None, 'unavailable'):
            def wrong_ready(base, path, data=None, expected=200):
                if path == '/api/ready':
                    return json.dumps(dict(app='Contoso Order Desk', status='ready', database=database))
                return fake_http(base, path, data, expected)
            with patch.dict(app_checks.__globals__, http=wrong_ready):
                assert not app_checks('http://onprem-nginx:8080')['ready']
        def wrong_app(base, path, data=None, expected=200):
            if path == '/api/health':
                return json.dumps(dict(app='Different Application', status='healthy'))
            return fake_http(base, path, data, expected)
        with patch.dict(app_checks.__globals__, http=wrong_app):
            assert not app_checks('http://onprem-nginx:8080')['health']
        sample = sample_order(config)
        assert sample['orderId'] == 8 and sample['beforeCount'] == 7 and sample['afterCount'] == 8
        assert sum(data is not None for _, data, _ in calls) == 1
        blocked = dict(config, allowApp=False)
        prior = len(calls)
        try:
            sample_order(blocked)
        except ValueError:
            pass
        else:
            raise AssertionError('write_gate_failed')
        assert len(calls) == prior
    with patch.dict(unit_observation.__globals__, command=lambda *a, **k: ''):
        try:
            unit_observation('lab-traffic.service')
        except ValueError:
            pass
        else:
            raise AssertionError('unknown_unit_accepted')
    identity = dict(DynamicUser='yes', User='contoso-orderdesk-traffic', Group='contoso-orderdesk-traffic',
                    NoNewPrivileges='yes', ProtectSystem='strict', ProtectHome='yes',
                    MemoryMax=str(64 * 1024 * 1024), TasksMax='20', UMask='0077',
                    ExecStart='{ path=/usr/bin/python3 ; argv[]=/usr/bin/python3 /opt/contoso-orderdesk/scripts/traffic.py ; }',
                    Restart='no', RuntimeMaxUSec='1h')
    def properties(values):
        return '\n'.join(key + '=' + value for key, value in values.items())
    with patch.dict(verify_traffic_identity.__globals__, command=lambda *a, **k: properties(identity)):
        verify_traffic_identity(3600)
    for key, value in (('DynamicUser', 'no'), ('User', 'root'), ('ProtectSystem', 'no'), ('MemoryMax', 'infinity'), ('Restart', 'on-failure'), ('RuntimeMaxUSec', 'infinity')):
        changed = dict(identity); changed[key] = value
        with patch.dict(verify_traffic_identity.__globals__, command=lambda *a, **k: properties(changed)):
            try:
                verify_traffic_identity(3600)
            except ValueError:
                pass
            else:
                raise AssertionError('unverified_original_identity_or_lifetime_accepted')
    return 25


if __name__ == '__main__':
    config = json.loads(base64.b64decode('__CONFIG_B64__', validate=True))
    try:
        result = main(config)
        text = json.dumps(result, separators=(',', ':'))
        if len(text.encode('utf-8')) > 3500:
            raise ValueError('result_too_large')
        print('LAB_POSTMIGRATION ' + text)
    except Exception:
        print('LAB_POSTMIGRATION ' + json.dumps(dict(ok=False, nonce=config['nonce'], role=config['role'],
              action=config['action'], code='guest_failed_unknown_or_partial'), separators=(',', ':')))
        sys.exit(1)
'@

$LinuxDeadlineBody = @'
import json
import pathlib
import subprocess
import sys
import time
ROOT = pathlib.Path('/var/lib/contoso-orderdesk/labtraffic')
UNIT = 'contoso-orderdesk-traffic.service'


def command(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, timeout=30, check=False)
    if result.returncode:
        raise ValueError('deadline_command_failed')
    return result.stdout.strip()


def expire(state):
    if state['phase'] not in ('armed', 'running') or time.time() < state['deadlineEpoch']:
        raise ValueError('deadline_not_due_or_state_changed')
    # This privileged handler only stops the installed DynamicUser generator;
    # it never performs HTTP requests or imports/runs traffic.py.
    command('systemctl', 'stop', UNIT)
    active = command('systemctl', 'show', UNIT, '--property=ActiveState', '--value')
    if active == 'failed':
        command('systemctl', 'reset-failed', UNIT)
        active = command('systemctl', 'show', UNIT, '--property=ActiveState', '--value')
    enabled = command('systemctl', 'show', UNIT, '--property=UnitFileState', '--value')
    if active != 'inactive' or enabled not in ('disabled', 'masked'):
        raise ValueError('deadline_stop_unverified')
    state['phase'] = 'expired'
    state['heartbeatUtc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    return state


def main():
    global state
    state = json.loads((ROOT / 'state.json').read_text())
    expire(state)
    (ROOT / 'state.json').write_text(json.dumps(state, separators=(',', ':')))
    print('Guest-local deadline: installed restricted traffic generator stopped.', flush=True)


def self_test():
    from unittest.mock import patch
    state = dict(phase='running', deadlineEpoch=110)
    calls = []
    def stopped(*args):
        calls.append(args)
        if '--property=ActiveState' in args:
            return 'inactive'
        if '--property=UnitFileState' in args:
            return 'disabled'
        return ''
    with patch.dict(expire.__globals__, command=stopped), patch.object(time, 'time', return_value=111):
        assert expire(dict(state))['phase'] == 'expired'
    assert calls[0] == ('systemctl', 'stop', UNIT)
    assert all('start' not in call and 'enable' not in call for call in calls)
    calls.clear()
    with patch.dict(expire.__globals__, command=stopped), patch.object(time, 'time', return_value=100):
        try:
            expire(dict(state))
        except ValueError:
            pass
        else:
            raise AssertionError('premature_deadline_stop')
    assert not calls
    with patch.dict(expire.__globals__, command=lambda *a: 'active'), patch.object(time, 'time', return_value=111):
        try:
            expire(dict(state))
        except ValueError:
            pass
        else:
            raise AssertionError('active_generator_reported_stopped')
    return 3


if __name__ == '__main__':
    try:
        main()
    except Exception:
        if 'state' in globals():
            state['phase'] = 'failed'
            (ROOT / 'state.json').write_text(json.dumps(state, separators=(',', ':')))
        print('Deadline stop unverified; inspect generator/state locally. No raw error recorded.', flush=True)
        sys.exit(1)
'@

function Test-PrivateIPv4 {
    param([string]$Address)
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Address,[ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $bytes = $parsed.GetAddressBytes()
    return ($bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or ($bytes[0] -eq 192 -and $bytes[1] -eq 168))
}
function Test-IPv4Subnet {
    param([string]$Address,[string]$Prefix)
    $parts = $Prefix.Split('/')
    if ($parts.Count -ne 2 -or $parts[1] -notmatch '^([0-9]|[12][0-9]|3[0-2])$') { return $false }
    $network = $null
    if (-not [Net.IPAddress]::TryParse($parts[0],[ref]$network) -or $network.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $ip = [Net.IPAddress]::Parse($Address).GetAddressBytes(); $net=$network.GetAddressBytes(); $bits=[int]$parts[1]
    for ($i=0; $i -lt 4; $i++) {
        $used = [Math]::Min(8,[Math]::Max(0,$bits-8*$i))
        $mask = (255 -shl (8-$used)) -band 255
        if (($ip[$i] -band $mask) -ne ($net[$i] -band $mask)) { return $false }
    }
    return $true
}
function Get-VerifiedRunResult {
    param($View,[string]$Nonce,[string]$Role,[string]$Action)
    if ($null -eq $View -or $View.ExecutionState -ne 'Succeeded' -or ($View.ExitCode -isnot [int] -and $View.ExitCode -isnot [long]) -or $View.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace([string]$View.Error)) { throw 'Guest execution not verified' }
    $text = [string]$View.Output
    if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 4096) { throw 'Truncated/oversized result' }
    $markers = [regex]::Matches($text,'(?m)^LAB_POSTMIGRATION (\{[^\r\n]+\})\r?$')
    if ($markers.Count -ne 1) { throw 'Missing/duplicate result marker' }
    $result = $markers[0].Groups[1].Value | ConvertFrom-Json
    if ($result.ok -isnot [bool] -or $result.ok -ne $true -or $result.nonce -cne $Nonce -or $result.role -cne $Role -or $result.action -cne $Action -or $null -eq $result.observation -or $result.ready -isnot [bool] -or $null -eq $result.checks) { throw 'Result contract failed' }
    return $result
}
function New-GuestSource {
    param([string]$OS,[hashtable]$Config)
    $json = $Config | ConvertTo-Json -Depth 9 -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    if ($OS -eq 'Windows') { $source = $WindowsGuestBody.Replace('__CONFIG_B64__',$encoded) }
    else { $source = "#!/bin/bash`nset -euo pipefail`npython3 -B - <<'LAB_POSTMIGRATION_PY'`n" + $LinuxPythonBody.Replace('__CONFIG_B64__',$encoded) + "`nLAB_POSTMIGRATION_PY`n" }
    if ($source -match '[^\x00-\x7F]' -or $source.Contains('__CONFIG_B64__')) { throw 'Invalid embedded payload' }
    return $source
}
function Invoke-GuestAction {
    param($Target,[string]$Action,[hashtable]$Extra=@{})
    $nonce = [guid]::NewGuid().ToString('N')
    $config = @{nonce=$nonce;role=$Target.Role;action=$Action;ownIP=$Target.IP;aliases=$script:Aliases;allowApp=$false}
    foreach ($key in $Extra.Keys) { $config[$key]=$Extra[$key] }
    $source = New-GuestSource $Target.OS $config
    $name = 'lab-posttraffic-' + $nonce
    $job=$null; $terminal=$false; $verified=$false; $pointer=[IntPtr]::Zero; $protected=$null
    try {
        $parameters = @{ResourceGroupName=$TargetResourceGroup;VMName=$Target.Name;Location=$Target.Location;RunCommandName=$name;SourceScript=$source;TimeoutInSecond=240;AsyncExecution=$true;AsJob=$true;DefaultProfile=$script:Context;ErrorAction='Stop'}
        if ($SqlPassword -and $Target.Role -eq 'Web' -and $Action -in @('Check','Arm')) {
            $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SqlPassword)
            $protected=@(@{Name='SqlPassword';Value=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)})
            $parameters.ProtectedParameter=$protected
        }
        # A write is submitted once. Unknown acceptance/execution is never blindly retried.
        $job = Set-AzVMRunCommand @parameters
        $submitted = Wait-Job -Job $job -Timeout 120
        if (-not $submitted -or $job.State -ne 'Completed') { throw 'Submission unknown' }
        $null = Receive-Job -Job $job -ErrorAction Stop
        $until=[DateTime]::UtcNow.AddSeconds(300)
        while ([DateTime]::UtcNow -lt $until) {
            $run=Get-AzVMRunCommand -ResourceGroupName $TargetResourceGroup -VMName $Target.Name -RunCommandName $name -Expand InstanceView -DefaultProfile $script:Context -ErrorAction Stop
            $view=$run.InstanceView
            if ($null -ne $view -and $view.ExecutionState -in @('Succeeded','Failed','TimedOut','Canceled','Cancelled')) {
                $terminal=$true
                $result=Get-VerifiedRunResult $view $nonce $Target.Role $Action
                $verified=$true
                return $result
            }
            Start-Sleep -Seconds 3
        }
        throw 'Execution unknown'
    } catch {
        throw ("{0}/{1}: outcome UNKNOWN/failed/partial. Inspect Run Command {2}; do not reissue Start. Use Status/Stop or guest-local recovery. No raw errors shown." -f $Target.Name,$Action,$name)
    } finally {
        if ($terminal -and $verified) {
            try { Remove-AzVMRunCommand -ResourceGroupName $TargetResourceGroup -VMName $Target.Name -RunCommandName $name -DefaultProfile $script:Context -ErrorAction Stop | Out-Null }
            catch { Write-Warning ("Terminal Run Command {0} needs manual ARM cleanup; deleting it does not stop traffic." -f $name) }
        }
        if ($job -and $job.State -in @('Completed','Failed','Stopped')) { Remove-Job $job -ErrorAction SilentlyContinue }
        if ($protected) { foreach ($item in $protected) { $item.Value=$null } }
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}
function Get-Targets {
    $rg = Get-AzResourceGroup -Name $TargetResourceGroup -DefaultProfile $script:Context -ErrorAction Stop
    if ($rg.ResourceGroupName -cne $TargetResourceGroup) { throw 'Resource group identity mismatch' }
    $roles = @(
        @{Role='Web';Base='OnPrem-Web';OS='Windows';Alias='onprem-web'},
        @{Role='SQL';Base='OnPrem-SQL';OS='Windows';Alias='onprem-sql'},
        @{Role='Nginx';Base='OnPrem-Linux-Web';OS='Linux';Alias='onprem-nginx'},
        @{Role='App';Base='OnPrem-Linux-App';OS='Linux';Alias='onprem-app'}
    )
    $vms=@(Get-AzVM -ResourceGroupName $TargetResourceGroup -DefaultProfile $script:Context -ErrorAction Stop)
    $targets=@(); $vnetIds=@(); $script:Aliases=@{}
    foreach ($role in $roles) {
        $name=$role.Base; if ($TestMigration) { $name += '-test' }
        $found=@($vms | Where-Object { $_.Name -ceq $name })
        if ($found.Count -ne 1) { throw "Exactly one '$name' is required; no test/cutover fallback." }
        $vm=$found[0]
        $expected="/subscriptions/$($script:Context.Subscription.Id)/resourceGroups/$TargetResourceGroup/providers/Microsoft.Compute/virtualMachines/$name"
        if ($vm.Id -ine $expected -or [string]$vm.StorageProfile.OsDisk.OsType -ne $role.OS) { throw "VM identity/OS mismatch: $name" }
        $status=Get-AzVM -ResourceGroupName $TargetResourceGroup -Name $name -Status -DefaultProfile $script:Context -ErrorAction Stop
        $power=@($status.Statuses | Where-Object { $_.Code -like 'PowerState/*' })
        if ($power.Count -ne 1) { throw "VM power observation unknown: $name" }
        $powerState=[string]$power[0].Code
        if ($powerState -ne 'PowerState/running' -and $Mode -ne 'Stop') { throw "VM must be running for managed execution: $name. No power/agent repair is attempted." }
        $nics=@($vm.NetworkProfile.NetworkInterfaces)
        if ($nics.Count -ne 1) { throw "Ambiguous NIC topology: $name; explicit topology review required." }
        if ($nics[0].Id -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.Network/networkInterfaces/([^/]+)$' -or $Matches[1] -ine $script:Context.Subscription.Id) { throw 'NIC scope invalid' }
        $nic=Get-AzNetworkInterface -ResourceGroupName $Matches[2] -Name $Matches[3] -DefaultProfile $script:Context -ErrorAction Stop
        if ($nic.Id -ine $nics[0].Id -or $nic.VirtualMachine.Id -ine $vm.Id) { throw 'NIC ownership mismatch' }
        $configs=@($nic.IpConfigurations)
        if ($configs.Count -ne 1 -or -not $configs[0].Primary -or $configs[0].PrivateIpAddressVersion -ne 'IPv4' -or -not (Test-PrivateIPv4 $configs[0].PrivateIpAddress)) { throw "Ambiguous/nonprivate primary IPv4: $name" }
        $ipconfig=$configs[0]
        if ($ipconfig.Subnet.Id -notmatch '^(/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.Network/virtualNetworks/([^/]+))/subnets/([^/]+)$' -or $Matches[2] -ine $script:Context.Subscription.Id) { throw 'Subnet scope invalid' }
        $vnetId=$Matches[1]; $networkRg=$Matches[3]; $networkName=$Matches[4]; $subnetName=$Matches[5]
        $vnet=Get-AzVirtualNetwork -ResourceGroupName $networkRg -Name $networkName -DefaultProfile $script:Context -ErrorAction Stop
        $subnets=@($vnet.Subnets | Where-Object { $_.Id -ieq $ipconfig.Subnet.Id -and $_.Name -ceq $subnetName })
        if ($vnet.Id -ine $vnetId -or $subnets.Count -ne 1 -or $vnet.Location -ine $vm.Location) { throw 'VNet/subnet identity or region mismatch' }
        $prefixes=@($subnets[0].AddressPrefix)
        if (@($prefixes | Where-Object { Test-IPv4Subnet $ipconfig.PrivateIpAddress $_ }).Count -ne 1) { throw 'Private IP not in verified subnet' }
        $publicFqdn='unavailable'
        if ($ipconfig.PublicIpAddress -and $ipconfig.PublicIpAddress.Id) {
            if ($ipconfig.PublicIpAddress.Id -notmatch '^/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/Microsoft.Network/publicIPAddresses/([^/]+)$' -or $Matches[1] -ine $script:Context.Subscription.Id) { throw 'Public IP scope invalid' }
            $public=Get-AzPublicIpAddress -ResourceGroupName $Matches[2] -Name $Matches[3] -DefaultProfile $script:Context -ErrorAction Stop
            if ($public.Id -ine $ipconfig.PublicIpAddress.Id) { throw 'Public IP identity mismatch' }
            if ($public.DnsSettings.Fqdn) { $publicFqdn=[string]$public.DnsSettings.Fqdn }
        }
        $targets += [pscustomobject]@{Role=$role.Role;Name=$name;Id=$vm.Id;OS=$role.OS;Location=$vm.Location;PowerState=$powerState;NIC=$nic.Id;IP=[string]$ipconfig.PrivateIpAddress;VNet=$vnetId;Subnet=$ipconfig.Subnet.Id;PublicFqdn=$publicFqdn}
        $vnetIds += $vnetId; $script:Aliases[$role.Alias]=[string]$ipconfig.PrivateIpAddress
    }
    if (@($vnetIds | Sort-Object -Unique).Count -ne 1 -or @($targets.IP | Sort-Object -Unique).Count -ne 4) { throw 'Targets must use one coherent VNet and four distinct private IPv4 addresses' }
    return $targets
}
function Show-GuestResult {
    param($Target,$Result)
    Write-Host ("{0}: hostname={1}; DNS-confirmed guest FQDN={2}; ownIP={3}; aliasesMatch={4}; service={5}" -f $Target.Name,$Result.observation.hostname,$Result.observation.fqdn,$Result.observation.ownIPMatched,$Result.observation.aliases.matched,$Result.observation.service)
    Write-Host ('  observed aliases: ' + ($Result.observation.aliases.observed | ConvertTo-Json -Compress))
    Write-Host ('  listeners: ' + ($Result.observation.listeners | ConvertTo-Json -Compress))
    if ($Target.OS -eq 'Windows') {
        Write-Host ('  generator: ' + ($Result.observation.generator | ConvertTo-Json -Compress) + '; expiry: ' + ($Result.observation.expiry | ConvertTo-Json -Compress))
    } else {
        Write-Host ('  generators (including legacy): ' + ($Result.observation.generators | ConvertTo-Json -Compress))
        Write-Host ('  expiry: ' + ($Result.observation.expiry | ConvertTo-Json -Depth 4 -Compress))
    }
    Write-Host ('  CPU (source capture only; never auto-started here): ' + ($Result.observation.cpu | ConvertTo-Json -Depth 5 -Compress))
    Write-Host ('  durable state: ' + ($Result.observation.durableState | ConvertTo-Json -Compress))
    if (@($Result.checks.PSObject.Properties).Count) { Write-Host ('  checks: ' + ($Result.checks | ConvertTo-Json -Compress)) }
    if ($Result.sqlSnapshot) { Write-Host ('  SQL snapshot: ' + ($Result.sqlSnapshot | ConvertTo-Json -Compress)) }
    if ($Result.sample) { Write-Host ('  explicit sample WRITE/readback: ' + ($Result.sample | ConvertTo-Json -Compress)) }
}
function Invoke-AllInventory {
    param([array]$Targets,[switch]$BestEffort)
    $results=@{}; $failed=@()
    foreach ($target in $Targets) {
        try {
            if ($BestEffort -and $target.PowerState -ne 'PowerState/running') { throw 'Guest unavailable' }
            $result=Invoke-GuestAction $target 'Inventory'
            Show-GuestResult $target $result
            $results[$target.Role]=$result
        } catch {
            $failed += $target.Name
            Write-Warning ("{0}: traffic inventory unverified; continuing inventory of remaining roles. No mutation has been authorized by this probe." -f $target.Name)
        }
    }
    if ($failed.Count -and -not $BestEffort) { throw ('Inventory unverified: ' + ($failed -join ', ') + '; optional mutations are blocked.') }
    return $results
}
function Test-AllAliases {
    param([hashtable]$Inventory)
    foreach ($result in $Inventory.Values) {
        if (-not $result.observation.ownIPMatched -or -not $result.observation.aliases.matched) { return $false }
    }
    return ($Inventory.Count -eq 4)
}
function Assert-NoUnresolvedStart {
    param([hashtable]$Inventory)
    foreach ($role in @('Web','App')) {
        $state=$Inventory[$role].observation.durableState
        if ($state -and $state.phase -in @('unknown','failed','armed','running')) { throw 'Existing controller run is active/unresolved. Use Status then Stop before a new Start; never extend/reissue blindly.' }
    }
}
function Invoke-PrepareTargets {
    param([array]$Targets)
    Write-Host 'PREPARE phase 1: pause/disable inherited and controller generators; application/data/credentials remain.'
    foreach ($target in $Targets) { $null=Invoke-GuestAction $target 'Pause' }
    Write-Host 'PREPARE phase 2: back up hosts, replace only lab aliases on all guests; restart Tomcat and reload Nginx.'
    foreach ($target in $Targets) { $null=Invoke-GuestAction $target 'Prepare' }
}
function Write-PhaseSummary {
    param([array]$Targets,[string]$Text)
    if ($Mode -in @('Check','Status')) {
        Write-Host ('Summary (console only; no guest log/ACL writes): ' + $Text)
        return
    }
    $web=@($Targets | Where-Object { $_.Role -eq 'Web' })[0]
    $null=Invoke-GuestAction $web 'Summary' @{summary=$Text}
}
function Invoke-CheckTargets {
    param([array]$Targets,[hashtable]$Inventory)
    $allow=Test-AllAliases $Inventory
    if (-not $allow) { Write-Warning 'Stale/unavailable aliases or wrong guest IP: application/SQL calls that could follow source aliases are SKIPPED on all guests. TCP checks use verified target IPs only.' }
    $results=@{}; $ready=$true
    foreach ($target in $Targets) {
        $result=Invoke-GuestAction $target 'Check' @{allowApp=$allow}
        Show-GuestResult $target $result; $results[$target.Role]=$result
        if (-not $result.ready) { $ready=$false }
    }
    if (-not $ready) {
        $gates=@($results.Keys | Sort-Object | ForEach-Object { $_ + '=' + [string]$results[$_].ready }) -join '; '
        Write-PhaseSummary $Targets ('Validation FAILED; ' + $gates + '; no generator start authorized. Inspect guest checks/network manually.')
        throw 'Required alias/service/listener/TCP/application/SQL-read gate failed. No generator start authorized; no network/agent repair attempted.'
    }
    return $results
}
function Invoke-OfflineSelfTest {
    $count=0
    foreach ($body in @($WindowsGuestBody,$WindowsWorkerBody)) {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseInput($body,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw 'Embedded PowerShell parser test failed' }
        if ($body -match '[^\x00-\x7F]') { throw 'Embedded ASCII fixture failed' }
        $count++
    }
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($WindowsGuestBody,[ref]$tokens,[ref]$errors)
    foreach ($name in @('Update-LabHostsText','Get-LiteralPassword')) {
        $function=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        . ([scriptblock]::Create($function.Extent.Text))
    }
    $aliases=@{'onprem-web'='10.1.1.10';'onprem-sql'='10.1.1.11';'onprem-nginx'='10.1.1.12';'onprem-app'='10.1.1.13'}
    $original="127.0.0.1 localhost`r`n192.168.0.11 ONPREM-SQL unrelated # keep comment`r`n192.168.0.13 onprem-app # app comment`r`n# untouched`r`n"
    $updated=Update-LabHostsText $original $aliases
    if ($updated -notmatch '192\.168\.0\.11\s+unrelated # keep comment' -or $updated -notmatch '# app comment' -or $updated -notmatch '# untouched' -or $updated -notmatch '10\.1\.1\.11\s+onprem-sql' -or (Update-LabHostsText $updated $aliases) -cne $updated) { throw 'Hosts preservation/idempotence fixture failed' }
    $count++
    $literal='$sqlPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''Zml4dHVyZQ==''))'
    if ((Get-LiteralPassword $literal) -cne 'fixture') { throw 'Exact credential fixture failed' }
    foreach ($bad in @('$sqlPassword = Invoke-Expression ''unsafe''',($literal + "`n" + $literal),($literal + "; Write-Output 'unsafe'"))) {
        $rejected=$false; try { $null=Get-LiteralPassword $bad } catch { $rejected=$true }
        if (-not $rejected) { throw 'Unsafe credential literal accepted' }
        $count++
    }
    foreach ($pair in @(@('10.1.1.10','10.1.1.0/24',$true),@('10.1.2.10','10.1.1.0/24',$false),@('192.168.0.10','192.168.0.0/24',$true))) {
        if ((Test-IPv4Subnet $pair[0] $pair[1]) -ne $pair[2]) { throw 'Subnet fixture failed' }; $count++
    }
    if ((Test-PrivateIPv4 '203.0.113.10') -or -not (Test-PrivateIPv4 '172.16.1.1')) { throw 'Private-IP fixture failed' }; $count++
    $nonce='0123456789abcdef0123456789abcdef'
    $result=@{ok=$true;nonce=$nonce;role='Web';action='Inventory';observation=@{};checks=@{};ready=$true} | ConvertTo-Json -Compress
    $view=[pscustomobject]@{ExecutionState='Succeeded';ExitCode=0;Error='';Output=('LAB_POSTMIGRATION ' + $result)}
    $null=Get-VerifiedRunResult $view $nonce 'Web' 'Inventory'; $count++
    foreach ($case in @('provisioningOnly','badExit','fractionalExit','badNonce','missingMarker','duplicateMarker','oversized','stderr')) {
        $test=[pscustomobject]@{ExecutionState='Succeeded';ExitCode=0;Error='';Output=$view.Output}
        switch ($case) {
            provisioningOnly { $test.ExecutionState='Running' }
            badExit { $test.ExitCode=1 }
            fractionalExit { $test.ExitCode=0.1 }
            badNonce { $test.Output=$test.Output.Replace($nonce,'bad') }
            missingMarker { $test.Output='{}' }
            duplicateMarker { $test.Output += "`n" + $test.Output }
            oversized { $test.Output += ('x' * 4096) }
            stderr { $test.Error='unsafe detail' }
        }
        $rejected=$false; try { $null=Get-VerifiedRunResult $test $nonce 'Web' 'Inventory' } catch { $rejected=$true }
        if (-not $rejected) { throw ('Fail-closed result fixture failed: ' + $case) }; $count++
    }
    foreach ($os in @('Windows','Linux')) {
        $source=New-GuestSource $os @{nonce=$nonce;role='Web';action='Inventory';aliases=$aliases;ownIP='10.1.1.10';label="' ; arbitrary text"}
        if ($source -match '[^\x00-\x7F]' -or $source.Contains("' ; arbitrary text") -or $source.Contains('__CONFIG_B64__')) { throw 'Encoded payload fixture failed' }; $count++
    }
    $inventory=@{}
    foreach ($role in @('Web','SQL','Nginx','App')) { $inventory[$role]=[pscustomobject]@{observation=[pscustomobject]@{ownIPMatched=$true;aliases=[pscustomobject]@{matched=$true};durableState=$null}} }
    if (-not (Test-AllAliases $inventory)) { throw 'Alias gate fixture failed' }
    $inventory.App.observation.aliases.matched=$false
    if (Test-AllAliases $inventory) { throw 'Stale aliases fixture failed' }; $count++
    $inventory.App.observation.durableState=[pscustomobject]@{phase='armed'}
    $rejected=$false; try { Assert-NoUnresolvedStart $inventory } catch { $rejected=$true }
    if (-not $rejected) { throw 'Partial start fixture failed' }; $count++
    Write-Host ("PASS: {0} native offline fixtures; no Az/auth/VM calls. Linux payloads require the separate maintainer bash/Python checks described in the guide." -f $count)
}

if ($SelfTest) { Invoke-OfflineSelfTest; return }
if ([string]::IsNullOrWhiteSpace($TargetResourceGroup)) { $TargetResourceGroup=Read-Host 'Exact target resource group (no source/default group is inferred)' }
if ([string]::IsNullOrWhiteSpace($TargetResourceGroup) -or $TargetResourceGroup -notmatch '^[A-Za-z0-9_.()\-]{1,90}$') { throw 'Supply the exact TargetResourceGroup; no source/default group is inferred.' }
if ($VerifySampleOrder -and $Mode -notin @('Check','Prepare','Start')) { throw 'VerifySampleOrder is available only with Check, Prepare or Start and writes one real order.' }
foreach ($module in @('Az.Accounts','Az.Resources','Az.Compute','Az.Network')) { Import-Module $module -ErrorAction Stop }
foreach ($command in @('Set-AzVMRunCommand','Get-AzVMRunCommand','Remove-AzVMRunCommand')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw 'Managed Run Command prerequisites missing. No package install/agent repair attempted.' }
}
if (-not (Get-Command Set-AzVMRunCommand).Parameters.ContainsKey('ProtectedParameter')) { throw 'Az.Compute ProtectedParameter support is required; no module upgrade attempted.' }
$script:Context=Get-AzContext -ErrorAction Stop
if (-not $script:Context -or -not $script:Context.Subscription.Id) { throw 'Connect-AzAccount and select the intended subscription first.' }
if ($SubscriptionId -and $SubscriptionId -ine $script:Context.Subscription.Id) { throw 'SubscriptionId does not match the active context. Select the intended subscription explicitly, then rerun.' }
$targets=Get-Targets
Write-Host ('Subscription: ' + $script:Context.Subscription.Id + '; target RG: ' + $TargetResourceGroup + '; mode: ' + $Mode + '; test copies: ' + [bool]$TestMigration)
foreach ($target in $targets) {
    Write-Host ("{0} [{1}] {2}`n  NIC {3}; primary private IPv4 {4}`n  VNet {5}; subnet {6}`n  Observed public-IP DNS FQDN {7} (not a lab alias or guest private DNS claim)" -f $target.Name,$target.OS,$target.Id,$target.NIC,$target.IP,$target.VNet,$target.Subnet,$target.PublicFqdn)
    $machineConfirmation=Read-Host ("Confirm THIS machine by typing its exact name '{0}' (or cancel)" -f $target.Name)
    if ($machineConfirmation -cne $target.Name) { throw 'Per-machine confirmation canceled; no guest Run Command submitted.' }
}
Write-Warning 'Check cannot undo traffic inherited before inspection. Test-copy source isolation must exist BEFORE boot. Even Check/Status create privileged managed Run Command resources.'
if ($Mode -in @('Prepare','Start')) { Write-Warning 'This mode authorizes generator pause/disable, hosts backups/repointing, Tomcat restart and Nginx reload. Start additionally creates bounded sample-order traffic; no reboot auto-resume.' }
if ($VerifySampleOrder) { Write-Warning 'EXPLICIT WRITE: one sample order will be inserted/read back, only after every required validation passes. A failed/unknown response can still mean a committed order; do not retry blindly.' }
$confirmation=Read-Host ("Confirm the subscription/resource-group scope shown above by typing '{0}' (or cancel)" -f $TargetResourceGroup)
if ($confirmation -cne $TargetResourceGroup) { throw 'Target confirmation canceled; no Run Command submitted.' }
try {
    Write-Host 'INVENTORY FIRST: inherited tasks/units, durable expiry/state, hostname, DNS and aliases; no app requests.'
    $inventory=Invoke-AllInventory $targets -BestEffort:($Mode -eq 'Stop')
    $preexisting=@()
    foreach ($target in $targets) {
        if (-not $inventory.ContainsKey($target.Role)) { $preexisting += ($target.Role + '=unverified'); continue }
        $observation=$inventory[$target.Role].observation
        $jobs=if ($target.OS -eq 'Windows') { $observation.generator } else { $observation.generators }
        $preexisting += ($target.Role + ' jobs=' + ($jobs | ConvertTo-Json -Depth 4 -Compress) + ' durable=' + ($observation.durableState | ConvertTo-Json -Compress))
    }
    if ($inventory.ContainsKey('Web')) {
        try { Write-PhaseSummary $targets ('First inventory: pre-existing jobs BEFORE generator changes; ' + ($preexisting -join '; ')) }
        catch {
            if ($Mode -ne 'Stop') { throw }
            Write-Warning 'First-inventory logging unverified; the explicitly requested generator Stop still continues.'
        }
    }
    if ($Mode -eq 'Stop') {
        # Inventory is attempted on every role first, but readiness never gates a requested stop.
        $failed=@()
        foreach ($target in $targets) {
            if ($target.PowerState -ne 'PowerState/running') {
                $failed += $target.Name
                Write-Warning ("{0}: powered off/deallocated/transitional VM; generator and disabled-on-next-boot state are NOT verified. Stop on the other selected guests continues." -f $target.Name)
                continue
            }
            try { $result=Invoke-GuestAction $target 'Stop'; Show-GuestResult $target $result }
            catch { $failed += $target.Name; Write-Warning $_.Exception.Message }
        }
        if ($failed.Count) { throw ('Stop partially unverified: ' + ($failed -join ', ') + '. Guest expiry is independent; inspect locally if the agent is unavailable.') }
        Write-PhaseSummary $targets 'Stop verified on four selected guests; application services, SQL data and repointed configuration preserved.'
        return
    }
    if ($Mode -eq 'Status') {
        foreach ($result in $inventory.Values) {
            if ($result.observation.durableState -and $result.observation.durableState.phase -eq 'unknown') { throw 'Status contains unreadable/unknown durable state; Stop before any new Start.' }
        }
        return
    }
    if ($Mode -eq 'Start') { Assert-NoUnresolvedStart $inventory }
    if ($Mode -in @('Prepare','Start')) {
        if (@($inventory.Values | Where-Object { -not $_.observation.ownIPMatched }).Count) { throw 'Guest private-IP identity is unverified; preparation is blocked.' }
        Invoke-PrepareTargets $targets
        $inventory=Invoke-AllInventory $targets
    }
    $checks=Invoke-CheckTargets $targets $inventory
    $snapshot=$checks.Web.sqlSnapshot.count
    Write-PhaseSummary $targets ("{0}: all required four-guest checks passed; SQL orders={1}; testCopies={2}. Detailed Linux insert journal is separate." -f $Mode,$snapshot,[bool]$TestMigration)
    if ($VerifySampleOrder) {
        $app=@($targets | Where-Object { $_.Role -eq 'App' })[0]
        $sample=Invoke-GuestAction $app 'Sample' @{allowApp=$true}
        Show-GuestResult $app $sample
        Write-PhaseSummary $targets ("Explicit single sample WRITE/readback orderId={0}; counts {1}->{2}." -f $sample.sample.orderId,$sample.sample.beforeCount,$sample.sample.afterCount)
    }
    if ($Mode -ne 'Start') { return }
    $runId=[guid]::NewGuid().ToString('N')
    $deadline=[DateTime]::UtcNow.AddMinutes($DurationMinutes)
    $epoch=[long][Math]::Floor(($deadline - [DateTime]::SpecifyKind([DateTime]'1970-01-01',[DateTimeKind]::Utc)).TotalSeconds)
    $shared=@{runId=$runId;deadlineUtc=$deadline.ToString('o');deadlineEpoch=$epoch;durationSeconds=($DurationMinutes*60);intervalSeconds=$IntervalSeconds}
    Write-Host ("ARM then LAUNCH: run {0}; at most one Linux insert/cycle every {1}s; UTC deadline {2}; no automatic reboot resume." -f $runId,$IntervalSeconds,$deadline.ToString('o'))
    foreach ($role in @('Web','App')) {
        $target=@($targets | Where-Object { $_.Role -eq $role })[0]
        $extra=$shared.Clone()
        $body=if ($role -eq 'Web') { $WindowsWorkerBody } else { $LinuxDeadlineBody }
        $extra.workerBase64=[Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($body))
        $null=Invoke-GuestAction $target 'Arm' $extra
    }
    foreach ($role in @('Web','App')) {
        $target=@($targets | Where-Object { $_.Role -eq $role })[0]
        $result=Invoke-GuestAction $target 'Launch' $shared
        Show-GuestResult $target $result
    }
    $final=Invoke-AllInventory $targets
    foreach ($role in @('Web','App')) {
        $state=$final[$role].observation.durableState
        if (-not $state -or $state.runId -cne $runId -or $state.phase -ne 'running' -or $state.expired) { throw 'Guest-local running state/deadline not verified; partial start possible' }
        if ($role -eq 'Web') {
            if ($final.Web.observation.generator.state -ne 'Running' -or $final.Web.observation.generator.startup -or -not $final.Web.observation.expiry.enabled) { throw 'Windows running/no-reboot/expiry task gate failed' }
        } else {
            $units=$final.App.observation.generators
            if ($units.'contoso-orderdesk-traffic.service'.active -ne 'active' -or $units.'contoso-orderdesk-traffic.service'.enabled -ne 'disabled') { throw 'Linux running/no-reboot gate failed' }
            if ($units.'lab-traffic.service'.active -ne 'inactive' -or ($units.'lab-traffic.service'.exists -and $units.'lab-traffic.service'.enabled -notin @('disabled','masked'))) { throw 'Duplicate legacy Linux generator gate failed' }
            $timer=$final.App.observation.expiry.timer
            if ($timer.active -ne 'active' -or $timer.enabled -ne 'disabled') { throw 'Linux guest-local deadline timer gate failed' }
        }
    }
    Write-PhaseSummary $targets ("Start verified: runId={0}; deadlineUtc={1}; intervalSeconds={2}; Windows SQL reads/HTTP health and Linux HTTP-driven inserts. No reboot auto-resume." -f $runId,$deadline.ToString('o'),$IntervalSeconds)
    Write-Host 'Both bounded generators verified. The controller now exits; use Status/Stop, and Check again after Step 6 hardening.'
} catch {
    # Do not automatically issue another write after an unknown result, including cleanup/rollback.
    Write-Warning 'Operation NOT fully verified. Earlier preparation or generator actions may have occurred. Never blindly repeat Start or a sample POST. Inspect Status/Run Command, then Stop; app/SQL/proxy/data remain preserved.'
    throw $_.Exception.Message
}
