<#
.SYNOPSIS
Enable (or stop) the required source lab traffic mesh between the four workshop VMs.
.DESCRIPTION
Run this inside HyperVHost in an elevated Windows PowerShell session after deployment
reports workload readiness. It wires the four independent samples into one small-business
order desk so Azure Migrate dependency analysis has real TCP connections to observe:

    OnPrem-Linux-Web  .12  --> OnPrem-Linux-App .13   HTTP 8080 reverse proxy to the API
    OnPrem-Linux-App  .13  --> OnPrem-SQL       .11   TDS 1433, reads and writes ContosoApp
    OnPrem-Web        .10  --> OnPrem-SQL       .11   TDS 1433, internal order report
    OnPrem-Web        .10  --> OnPrem-Linux-App .13   HTTP 3000, batch call to the API

Nothing that deployment validates is replaced. The IIS site on .10, the Nginx root site on
.12 and the Tomcat order desk on port 3000 keep serving their original pages, so
Assert-LabSourceWorkloads still passes. The initial proxy remains on port 8080, and the generators
are separate scheduled tasks and systemd units.

Windows guests are configured over PowerShell Direct. Linux guests are configured over SSH
from this host; when no SSH client is available the guest scripts are written to
C:\AzMigrateLab\Traffic for the instructor to paste into the Hyper-V console.

Deployment stages this script at C:\AzMigrateLab\enable-lab-traffic.ps1 on HyperVHost and
writes C:\AzMigrateLab\lab-traffic.settings.json beside it with the lab user name and the
guest addresses already filled in. Run it from that folder and the only value you supply is
the lab password. Command-line parameters override the settings file when both are present.

Lab-only. Traffic uses names from each guest's hosts file, not addresses, so the mesh can be
repointed after cutover by editing hosts entries instead of rebuilding the applications.
.PARAMETER AdminPassword
The lab password supplied to deploy-lab.ps1. Used for the Windows guests' Administrator
account, the Linux lab user, and the SQL login the generators authenticate with. You are
prompted for it when it is not supplied.
.PARAMETER LinuxUsername
The Linux lab user created by cloud-init. Read from the settings file, otherwise prompted.
.PARAMETER IntervalSeconds
Seconds between generated request cycles. Keep this low-rate: the goal is a steady trickle
that dependency polling can observe, not a load test that distorts performance-based sizing.
.PARAMETER SettingsPath
Location of the deployment-written settings file. Defaults to the copy beside this script.
.PARAMETER SkipLinux
Configure only the Windows guests and write the Linux scripts to disk without connecting.
.PARAMETER NonInteractive
Requires supplied credentials, valid deployment settings and installed OpenSSH 8.4+.
Fails before generator changes if Linux password/sudo access cannot be driven without prompts.
Emits LAB_TRAFFIC_FULLY_STARTED only when the Windows task, both Linux generators and the proxy check are confirmed;
otherwise reports LAB_TRAFFIC_PARTIAL_OR_FAILED or LAB_TRAFFIC_NOT_STARTED. Intended for the
protected Step 1 host launcher, not direct workstation execution.
.PARAMETER Mode
Start (default), Check/Status (inventory), or Stop. Check is an alias for Status.
.PARAMETER Component
Network or Cpu or Both. Start defaults to Network; Check/Status/Stop and Disable default to
Both. Explicit Component Network leaves CPU unchanged. Component Cpu starts CPU only.
.PARAMETER CpuSimulation
Prompt (interactive default), Start, or Skip. Independent opt-in after the network startup;
NonInteractive Prompt skips CPU. CPU outcomes never replace the network startup result.
.PARAMETER CpuDurationHours
Guest-local CPU lifetime, default 24 hours, range 1-168; separate from network traffic.
.PARAMETER RenewCpu
Explicitly replace the existing CPU run/deadline. Without this switch Start is idempotent
for a healthy active run and refuses to extend an expired/stopped/unresolved deadline.
.PARAMETER Disable
Alias for Stop, defaulting to Both network and CPU generators. Leaves Tomcat, its SQL login,
the Nginx proxy, the firewall rules and the hosts entries in place.
.EXAMPLE
C:\AzMigrateLab\enable-lab-traffic.ps1
.EXAMPLE
$password = Read-Host 'Lab password' -AsSecureString
C:\AzMigrateLab\enable-lab-traffic.ps1 -AdminPassword $password -IntervalSeconds 300
.EXAMPLE
C:\AzMigrateLab\enable-lab-traffic.ps1 -Disable
MODULE COVERAGE
    The scripts and the modules are run separately. This script completes:

      Module 0, section 6   Start the sample business traffic.

    It also supplies what Module 1 section 6 (Interpret the dependency view) needs: without
    traffic between the four workloads, the dependency map is drawn but stays empty.
#>
[CmdletBinding()]
param(
    [SecureString]$AdminPassword,
    [ValidatePattern('^[a-z][a-z0-9]{2,18}$')][string]$LinuxUsername,
    [ValidateRange(20,600)][int]$IntervalSeconds,
    [string]$SettingsPath,
    [switch]$SkipLinux,
    [switch]$Disable,
    [switch]$NonInteractive,
    [ValidateSet('Start','Check','Status','Stop')][string]$Mode = 'Start',
    [ValidateSet('Network','Cpu','Both')][string]$Component = 'Network',
    [ValidateSet('Prompt','Start','Skip')][string]$CpuSimulation = 'Prompt',
    [ValidateRange(1,168)][int]$CpuDurationHours = 24,
    [switch]$RenewCpu
)
$ErrorActionPreference = 'Stop'
if ($Disable) { $Mode = 'Stop' }
if ($Mode -eq 'Check') { $Mode = 'Status' }
if ($Mode -ne 'Start' -and -not $PSBoundParameters.ContainsKey('Component')) { $Component = 'Both' }
if ($NonInteractive -and $CpuSimulation -eq 'Prompt') { $CpuSimulation = 'Skip' }
if ($Mode -eq 'Start' -and $Component -in @('Cpu','Both')) {
    if ($PSBoundParameters.ContainsKey('CpuSimulation') -and $CpuSimulation -eq 'Skip') { throw 'Component Cpu/Both conflicts with CpuSimulation Skip.' }
    $CpuSimulation = 'Start'
}
$cpuAssetsPath = Join-Path $PSScriptRoot 'cpu-simulation'
foreach ($asset in @('control.ps1','windows-cpu.ps1','linux-cpu.py')) {
    if (-not (Test-Path -LiteralPath (Join-Path $cpuAssetsPath $asset))) { throw 'CPU assets missing. Refresh enable-lab-traffic.ps1 AND the cpu-simulation folder together.' }
}
. (Join-Path $cpuAssetsPath 'control.ps1')

$labRoot     = 'C:\AzMigrateLab'
$trafficRoot = Join-Path $labRoot 'Traffic'
$sqlLogin    = 'labapp'
$labHosts = [ordered]@{
    'onprem-web'   = '192.168.0.10'
    'onprem-sql'   = '192.168.0.11'
    'onprem-nginx' = '192.168.0.12'
    'onprem-app'   = '192.168.0.13'
}

# ---------- Values written by deployment ----------
# Setup records the lab user and guest addresses on the host, so running this script inside
# HyperVHost needs no arguments. Explicit parameters still win; the built-in values above are
# the last resort when the file is absent, for example on a hand-built host.
if (-not $SettingsPath) {
    $SettingsPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'lab-traffic.settings.json' }
                    else { Join-Path $labRoot 'lab-traffic.settings.json' }
}
if (-not (Test-Path -LiteralPath $SettingsPath)) { $SettingsPath = Join-Path $labRoot 'lab-traffic.settings.json' }
$settings = $null
if (Test-Path -LiteralPath $SettingsPath) {
    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        Write-Host "Using deployment settings from $SettingsPath"
    } catch {
        Write-Warning "Could not read $SettingsPath. Continuing with built-in lab defaults."
    }
}
function Get-LabSetting {
    param([string]$Name)
    if ($null -ne $settings -and $null -ne $settings.PSObject.Properties[$Name]) { return $settings.$Name }
    return $null
}
if ($NonInteractive -and ($SkipLinux -or $null -eq $settings)) {
    throw 'NonInteractive startup requires deployment settings and all guests; use the elevated host-interactive script for other modes.'
}
if (-not $LinuxUsername) {
    $configured = Get-LabSetting 'LinuxUsername'
    if (-not $configured -and $NonInteractive) { throw 'NonInteractive startup requires LinuxUsername in deployment settings.' }
    $LinuxUsername = if ($configured) { [string]$configured } else { Read-Host 'Linux guest username supplied at deployment' }
}
if ($LinuxUsername -notmatch '^[a-z][a-z0-9]{2,18}$') { throw 'Enter the Linux username supplied to deployment.' }
if (-not $PSBoundParameters.ContainsKey('IntervalSeconds')) {
    $configured = Get-LabSetting 'IntervalSeconds'
    $IntervalSeconds = if ($configured) { [int]$configured } else { 300 }
}
if ($IntervalSeconds -lt 20 -or $IntervalSeconds -gt 600) { throw 'Traffic interval must be 20 to 600 seconds.' }
$configuredLogin = Get-LabSetting 'SqlLogin'
if ($configuredLogin -and $configuredLogin -ne 'labapp') { throw 'This workload uses the initial labapp login; settings disagree.' }
$configuredAddresses = Get-LabSetting 'WorkloadAddresses'
if ($NonInteractive) {
    if ($null -eq $configuredAddresses) { throw 'NonInteractive startup requires workload addresses in deployment settings.' }
    foreach ($key in @($labHosts.Keys)) {
        $property = $configuredAddresses.PSObject.Properties[$key]
        $address = $null
        if ($null -eq $property -or -not [Net.IPAddress]::TryParse([string]$property.Value, [ref]$address) -or
            $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Invalid workload address in deployment settings.' }
    }
    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { throw 'NonInteractive startup requires installed OpenSSH 8.4+; use the elevated host-interactive fallback.' }
}
if ($null -ne $configuredAddresses) {
    foreach ($key in @($labHosts.Keys)) {
        $value = $configuredAddresses.PSObject.Properties[$key]
        if ($null -ne $value -and $value.Value -match '^\d{1,3}(\.\d{1,3}){3}$') { $labHosts[$key] = [string]$value.Value }
    }
}
if (-not $AdminPassword) {
    if ($NonInteractive) { throw 'NonInteractive startup requires a supplied SecureString password; no prompts are allowed.' }
    $AdminPassword = Read-Host 'Lab password used during deployment' -AsSecureString
}

function Write-Step { param([string]$Message) Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" }

# ---------- Preflight ----------
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script in an elevated Windows PowerShell session on HyperVHost.'
}
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    throw 'Hyper-V management cmdlets are unavailable. Run this on HyperVHost, not on your workstation.'
}
function Assert-TrafficWorkloadPower {
    $required = @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App')
    foreach ($name in $required) {
        $vm = @(Get-VM -Name $name -ErrorAction Stop)
        if ($vm.Count -ne 1 -or [string]$vm[0].State -cne 'Running') {
            throw "Workload '$name' must be uniquely present and Running. No nested VM will be started automatically."
        }
    }
}
Assert-TrafficWorkloadPower
New-Item -ItemType Directory -Path $trafficRoot -Force | Out-Null
& icacls.exe $trafficRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not protect the traffic staging directory.' }

$credential   = [pscredential]::new('Administrator',$AdminPassword)
$passwordText = $credential.GetNetworkCredential().Password
if ([string]::IsNullOrWhiteSpace($passwordText)) { throw 'Supply the lab password used during deployment.' }

# ---------- Shared payload fragments ----------
$hostsBlock = ($labHosts.Keys | ForEach-Object { "{0}`t{1}" -f $labHosts[$_], $_ }) -join "`n"

# ---------- Windows guests ----------
$applyHostsEntries = {
    param([string]$Block)
    $ErrorActionPreference = 'Stop'
    $path = "$env:SystemRoot\System32\drivers\etc\hosts"
    $marker = '# --- CES lab traffic mesh ---'
    $current = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)
    $kept = @()
    $inBlock = $false
    foreach ($line in $current) {
        if ($line -eq $marker) { $inBlock = -not $inBlock; continue }
        if (-not $inBlock) { $kept += $line }
    }
    $kept += $marker
    $kept += ($Block -split "`n")
    $kept += $marker
    Set-Content -LiteralPath $path -Value $kept -Encoding ASCII
}

# The shared SQL login is provisioned by the initial host workload phase, never removed here.

# Generator for OnPrem-Web. System.Data.SqlClient avoids depending on the SqlServer module,
# which deployment installs only on the database guest.
$webGeneratorTemplate = @'
$ErrorActionPreference = 'Continue'
$interval = __INTERVAL__
$sqlPassword = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PASSWORD_B64__'))
$log = 'C:\LabTraffic\traffic.log'
function Write-TrafficLog { param($Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $log -Value $line -ErrorAction SilentlyContinue
    $file = Get-Item $log -ErrorAction SilentlyContinue
    if ($file -and $file.Length -gt 5MB) { Set-Content -Path $log -Value '' -ErrorAction SilentlyContinue }
}
Write-TrafficLog 'Order desk generator started.'
while ($true) {
    $connection = $null
    try {
        # Internal order report: OnPrem-Web -> OnPrem-SQL over TDS 1433.
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
        $builder.DataSource = 'onprem-sql,1433'
        $builder.InitialCatalog = 'ContosoApp'
        $builder.UserID = 'labapp'
        $builder.Password = $sqlPassword
        $builder.TrustServerCertificate = $true
        $builder.ConnectTimeout = 10
        $connection.ConnectionString = $builder.ConnectionString
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT TOP 5 o.OrderID, c.LastName, o.ProductName, o.Quantity FROM dbo.Orders o INNER JOIN dbo.Customers c ON c.CustomerID = o.CustomerID ORDER BY o.OrderDate DESC'
        $reader = $command.ExecuteReader()
        $rows = 0
        while ($reader.Read()) { $rows++ }
        $reader.Close(); $connection.Close()
        Write-TrafficLog "Order report read $rows rows from onprem-sql."
    } catch { Write-TrafficLog 'SQL report failed; check connectivity and credentials locally.' }
    finally { if ($connection) { $connection.Dispose() } }
    try {
        # Nightly-style batch: OnPrem-Web -> OnPrem-Linux-App over HTTP 3000.
        $response = Invoke-WebRequest 'http://onprem-app:3000/api/health' -UseBasicParsing -TimeoutSec 10
        Write-TrafficLog "API health returned $($response.StatusCode)."
    } catch { Write-TrafficLog "API call failed: $($_.Exception.Message)" }
    Start-Sleep -Seconds $interval
}
'@

$installWebGenerator = {
    param([string]$Script)
    $ErrorActionPreference = 'Stop'
    New-Item -ItemType Directory -Path 'C:\LabTraffic' -Force | Out-Null
    & icacls.exe 'C:\LabTraffic' /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not protect the Windows generator directory; no secret-bearing script was written.' }
    Set-Content -LiteralPath 'C:\LabTraffic\order-desk.ps1' -Value $Script -Encoding UTF8
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\LabTraffic\order-desk.ps1'
    # AtStartup means the generator resumes by itself after test migration and cutover,
    # so the migrated VMs keep producing the same traffic in Azure.
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = 'PT1M'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName 'LabOrderDeskTraffic' -Action $action -Trigger $trigger `
        -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
    Stop-ScheduledTask -TaskName 'LabOrderDeskTraffic' -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName 'LabOrderDeskTraffic'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $task = Get-ScheduledTask -TaskName 'LabOrderDeskTraffic' -ErrorAction Stop
        if ([string]$task.State -eq 'Running') { break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    if ([string]$task.State -ne 'Running') { throw 'Windows traffic scheduled task did not reach Running.' }
    Write-Output 'Order desk generator scheduled and started.'
}

$removeWebGenerator = {
    $ErrorActionPreference = 'Continue'
    Stop-ScheduledTask -TaskName 'LabOrderDeskTraffic' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'LabOrderDeskTraffic' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item 'C:\LabTraffic' -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output 'Order desk generator removed.'
}

# ---------- Linux guest payloads ----------
$nginxPayload = @'
set -e
# The required proxy/hosts belong to initial provisioning; traffic control never rewrites them.
nginx -t
curl --fail --silent --show-error --max-time 20 http://127.0.0.1:8080/api/ready >/dev/null
bash /opt/contoso-employee-orders/control.sh start
echo LAB_TRAFFIC_NGINX_READY
'@

$appPayload = @'
set -e
bash /opt/contoso-orderdesk/scripts/traffic.sh on __INTERVAL__
echo LAB_TRAFFIC_APP_READY
'@

$employeeStopPayload = @'
set -e
bash /opt/contoso-employee-orders/control.sh stop
'@

$employeeStatusPayload = @'
set -e
bash /opt/contoso-employee-orders/control.sh status
'@

$appRemovePayload = @'
set -e
bash /opt/contoso-orderdesk/scripts/traffic.sh off
echo LAB_TRAFFIC_APP_REMOVED
'@

function Expand-LabPayload {
    param([string]$Payload)
    # Single-pass replacement; inserted secrets are never reinterpreted as further tokens.
    return [regex]::Replace($Payload, '__[A-Z][A-Z0-9_]*__', [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        switch ($match.Value) {
            '__HOSTS__'    { return $hostsBlock }
            '__LOGIN__'    { return $sqlLogin }
            '__PASSWORD_B64__' { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($passwordText)) }
            '__INTERVAL__' { return [string]$IntervalSeconds }
            default        { throw "Unexpected token $($match.Value)" }
        }
    })
}

function Initialize-LabSshAskpass {
    <#
      Lets ssh take the lab password without prompting, so the password entered once at the top
      of this script is the only time it is typed.

      Windows has no sshpass. OpenSSH's own mechanism is SSH_ASKPASS: ssh runs the named program
      and reads the password from its output. SSH_ASKPASS_REQUIRE=force, which makes ssh use it
      even when a console is attached, arrived in OpenSSH 8.4 - so the version is checked and
      the interactive prompt is kept when it is older.

      The helper script contains no secret. It echoes an environment variable that is set only
      around the ssh call, so the password stays in process memory and is never written to disk.
    #>
    $version = ''
    $versionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $version = (& ssh.exe -V 2>&1 | Out-String)
    } catch { return $null }
    finally { $ErrorActionPreference = $versionPreference }
    if ($version -notmatch 'OpenSSH[_a-zA-Z]*(\d+)\.(\d+)') { return $null }
    $major = [int]$Matches[1]; $minor = [int]$Matches[2]
    if ($major -lt 8 -or ($major -eq 8 -and $minor -lt 4)) {
        Write-Step "OpenSSH $major.$minor is older than 8.4, so ssh will prompt for the lab password per guest."
        return $null
    }
    $path = Join-Path $trafficRoot 'lab-askpass.cmd'
    $helperPath = Join-Path $trafficRoot 'lab-askpass.ps1'
    # Read the value in PowerShell rather than expanding it in cmd.exe, where password
    # metacharacters would otherwise become command syntax.
    Set-Content -LiteralPath $helperPath -Value @(
        '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)',
        '[Console]::WriteLine([Environment]::GetEnvironmentVariable(''LAB_SSH_PASSWORD'',''Process''))'
    ) -Encoding ASCII
    Set-Content -LiteralPath $path -Value @('@echo off', ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $helperPath)) -Encoding ASCII
    return $path
}

function ConvertTo-LabNativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW quoting, including quotes and trailing backslashes.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-LabSshStdin {
    param([string]$SshPath,[string]$Destination,[string]$Payload,[string]$AskpassPath,
          [string]$Password,[ValidateRange(1,600)][int]$TimeoutSeconds = 120)
    if (-not $AskpassPath -or [string]::IsNullOrWhiteSpace($Password)) {
        throw 'CPU stdin SSH requires reusable askpass authentication; no terminal/password-stdin fallback is permitted.'
    }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $SshPath
    $arguments = @('-T','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL',
        '-o','LogLevel=ERROR','-o','ConnectTimeout=15','-o','NumberOfPasswordPrompts=1',
        '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2',
        $Destination,'base64 -d | sudo -n bash -s')
    $info.Arguments = ($arguments | ForEach-Object { ConvertTo-LabNativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    # Set secrets on this child only; never change the parent's environment.
    $info.EnvironmentVariables['LAB_SSH_PASSWORD'] = $Password
    $info.EnvironmentVariables['SSH_ASKPASS'] = $AskpassPath
    $info.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $started = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $started = $process.Start()
        if (-not $started) { throw 'CPU SSH process did not start.' }
        # Drain BOTH pipes before writing/waiting, including noisy authentication failures.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Payload -replace "`r`n","`n")))
        $bytes = [Text.Encoding]::ASCII.GetBytes($encoded + "`n")
        # BaseStream bypasses Windows PowerShell 5.1's ASCII pipeline/CRLF conversion.
        $write = $process.StandardInput.BaseStream.WriteAsync($bytes,0,$bytes.Length)
        $remaining = [Math]::Max(0,[int]($TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
        if (-not $write.Wait($remaining)) { throw 'CPU SSH stdin timed out; outcome unknown. Inspect Status before any retry.' }
        $process.StandardInput.Close()
        $remaining = [Math]::Max(0,[int]($TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
        if (-not $process.WaitForExit($remaining)) { throw 'CPU SSH execution timed out; outcome unknown. Inspect Status before any retry.' }
        $remaining = [Math]::Max(0,[int]($TimeoutSeconds * 1000 - $clock.ElapsedMilliseconds))
        $reads = [System.Threading.Tasks.Task[]]@($stdout,$stderr)
        if (-not [System.Threading.Tasks.Task]::WaitAll($reads,$remaining)) { throw 'CPU SSH output timed out; outcome unknown. Inspect Status before any retry.' }
        # Stderr is drained but never echoed: it may contain unreviewed remote diagnostics.
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result }
    } finally {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill()
                $null = $process.WaitForExit(5000)
            }
        } finally {
            $info.EnvironmentVariables.Remove('LAB_SSH_PASSWORD')
            $info.EnvironmentVariables.Remove('SSH_ASKPASS')
            $info.EnvironmentVariables.Remove('SSH_ASKPASS_REQUIRE')
            $Password = $null
            $bytes = $null
            $process.Dispose()
        }
    }
}

function Invoke-LabLinuxPayload {
    param([string]$VMName,[string]$Address,[string]$Payload,[string]$Marker,[switch]$StreamInput)
    $expanded = Expand-LabPayload $Payload
    $scriptPath = Join-Path $trafficRoot "$VMName.sh"
    # LF endings only; bash rejects the CRLF a Windows editor would introduce.
    [IO.File]::WriteAllText($scriptPath, ($expanded -replace "`r`n","`n"), [Text.UTF8Encoding]::new($false))
    if ($SkipLinux) {
        Write-Step "SkipLinux: wrote $scriptPath for manual execution on $VMName."
        return $false
    }
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($NonInteractive -and (-not $ssh -or -not $script:LabAskpass)) { throw 'Noninteractive SSH is unavailable; no capability installation or interactive fallback is permitted.' }
    if (-not $ssh -and $Mode -eq 'Start') {
        Write-Step 'No SSH client found. Attempting to add the OpenSSH client capability.'
        try {
            Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' -ErrorAction Stop | Out-Null
            $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
        } catch { Write-Warning "OpenSSH client installation failed: $($_.Exception.Message)" }
    }
    if (-not $ssh) {
        Write-Warning "Cannot reach $VMName over SSH. Open its Hyper-V console and run the contents of $scriptPath with sudo."
        return $false
    }
    if ($StreamInput) {
        if (-not (Test-Path 'Variable:script:LabAskpassResolved')) {
            $script:LabAskpassResolved = $true
            $script:LabAskpass = Initialize-LabSshAskpass
        }
        $result = Invoke-LabSshStdin -SshPath $ssh.Source -Destination "$LinuxUsername@$Address" `
            -Payload $expanded -AskpassPath $script:LabAskpass -Password $passwordText
        $text = [string]$result.Output
        if ($result.ExitCode -ne 0 -or ([regex]::Matches($text, '(?m)^' + [regex]::Escape($Marker) + '\r?$')).Count -ne 1) {
            Write-Warning "$VMName CPU operation unverified (phase=linux-confirmation; sshExit=$($result.ExitCode)). Inspect CPU-only Status/Stop; no raw output recorded."
            return $false
        }
        $text -split '\r?\n' | Where-Object { $_ } | ForEach-Object { Write-Host "  $_" }
        if ($Mode -eq 'Status') { Write-Step "$VMName status query completed (not a healthy-worker assertion)." }
        elseif ($Mode -eq 'Stop') { Write-Step "$VMName CPU stop confirmed." }
        else { Write-Step "$VMName CPU start confirmed." }
        return $true
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($expanded -replace "`r`n","`n")))
    Write-Step "Connecting to $VMName ($Address) as $LinuxUsername."
    $remote = if ($NonInteractive) { "echo $encoded | base64 -d | sudo -n bash" }
              else { "echo $encoded | base64 -d | sudo bash" }
    # ssh writes progress and host-key notices to stderr even on success. Merging that stream
    # with 2>&1 while ErrorActionPreference is 'Stop' turns each line into a terminating
    # NativeCommandError, so the run aborts on a benign warning. Relax the preference for the
    # duration of the native call and judge the result by exit code and marker instead.
    # LogLevel=ERROR also suppresses the 'Permanently added ... to the list of known hosts'
    # notice, which is emitted on every run because the throwaway known-hosts file never
    # retains the key.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # The askpass path is resolved once and reused. $script:LabAskpass stays $null when this
    # build of OpenSSH cannot be driven that way, and ssh then prompts as it always did.
    if (-not (Test-Path 'Variable:script:LabAskpassResolved')) {
        $script:LabAskpassResolved = $true
        $script:LabAskpass = Initialize-LabSshAskpass
    }
    try {
        if ($script:LabAskpass) {
            $env:LAB_SSH_PASSWORD  = $passwordText
            $env:SSH_ASKPASS       = $script:LabAskpass
            $env:SSH_ASKPASS_REQUIRE = 'force'
        }
        $output = & $ssh.Source '-o' 'StrictHostKeyChecking=no' '-o' 'UserKnownHostsFile=NUL' `
            '-o' 'LogLevel=ERROR' '-o' 'ConnectTimeout=15' '-o' 'NumberOfPasswordPrompts=1' `
            '-o' 'ServerAliveInterval=15' '-o' 'ServerAliveCountMax=2' "$LinuxUsername@$Address" $remote 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        # Cleared immediately: the password must not remain in the environment of anything this
        # script runs afterwards.
        Remove-Item Env:LAB_SSH_PASSWORD, Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
    }
    $text = @($output | ForEach-Object { [string]$_ }) -join "`n"
    $output | ForEach-Object { Write-Host "  $_" }
    if ($exitCode -ne 0 -or ([regex]::Matches($text, '(?m)^' + [regex]::Escape($Marker) + '\r?$')).Count -ne 1) {
        Write-Warning "$VMName did not report $Marker (ssh exit code $exitCode). Review the output above, or run $scriptPath from its console."
        return $false
    }
    Write-Step "$VMName configured."
    return $true
}

# ---------- Execution ----------
$generatorChangesAttempted = $false
try {
    if ($NonInteractive) {
        # Verify reusable password/sudo access on BOTH Linux guests before touching generators.
        $script:LabAskpassResolved = $true
        $script:LabAskpass = Initialize-LabSshAskpass
        if (-not $script:LabAskpass) { throw 'Noninteractive SSH is unavailable. Use the elevated host-interactive fallback; no generators were changed.' }
        $sshProbe = "set -e`nsudo -n true`necho LAB_TRAFFIC_SSH_READY"
        foreach ($guest in @(@{ Name='OnPrem-Linux-Web'; Address=$labHosts['onprem-nginx'] },
                             @{ Name='OnPrem-Linux-App'; Address=$labHosts['onprem-app'] })) {
            $sshReady = Invoke-LabLinuxPayload -VMName $guest.Name -Address $guest.Address -Payload $sshProbe -Marker 'LAB_TRAFFIC_SSH_READY'
            if (-not $sshReady) { throw 'Noninteractive Linux authentication/sudo preflight failed. No generators were changed; use the elevated host-interactive fallback.' }
        }
    }
    Assert-TrafficWorkloadPower

    if ($Mode -in @('Status','Stop')) {
        if ($Component -in @('Cpu','Both')) { Invoke-LabCpuSimulation -Action $Mode }
        if ($Component -eq 'Cpu') { return }
        if ($Mode -eq 'Status') {
            $webStatus = @(Invoke-Command -VMName 'OnPrem-Web' -Credential $credential -ScriptBlock {
                Get-ScheduledTask -TaskName LabOrderDeskTraffic -ErrorAction SilentlyContinue | Select-Object TaskName,State
            } -ErrorAction Stop)
            $webStatus | ForEach-Object { Write-Host ($_ | Out-String) }
            $statusPayload = @'
set -e
unit=contoso-orderdesk-traffic.service
systemctl show "$unit" --property=LoadState,ActiveState,SubState,UnitFileState,MainPID
if [ "$(systemctl show "$unit" --property=LoadState --value)" = loaded ] &&
   [ "$(systemctl show "$unit" --property=ActiveState --value)" = active ] &&
   [ "$(systemctl show "$unit" --property=SubState --value)" = running ] &&
   [ "$(systemctl show "$unit" --property=UnitFileState --value)" = enabled ] &&
   [ "$(systemctl show "$unit" --property=MainPID --value)" -gt 0 ] &&
   kill -0 "$(systemctl show "$unit" --property=MainPID --value)"; then
    echo LAB_NETWORK_UNIT_RUNNING
fi
echo LAB_NETWORK_STATUS_CONFIRMED
'@
            $appRunning = Invoke-LabLinuxPayload -VMName 'OnPrem-Linux-App' -Address $labHosts['onprem-app'] -Payload $statusPayload -Marker 'LAB_NETWORK_UNIT_RUNNING'
            $employeeRunning = Invoke-LabLinuxPayload -VMName 'OnPrem-Linux-Web' -Address $labHosts['onprem-nginx'] `
                -Payload $employeeStatusPayload -Marker 'LAB_EMPLOYEE_ORDERS_RUNNING'
            if ($webStatus.Count -eq 1 -and [string]$webStatus[0].TaskName -ceq 'LabOrderDeskTraffic' -and
                [string]$webStatus[0].State -ceq 'Running' -and $appRunning -and $employeeRunning) {
                Write-Output 'LAB_NETWORK_RUNNING_CONFIRMED'
            } else { Write-Output 'LAB_NETWORK_NOT_FULLY_RUNNING' }
            return
        }
        Write-Step 'Stopping network traffic only; initial application dependencies are preserved.'
        Invoke-Command -VMName 'OnPrem-Web' -Credential $credential -ScriptBlock $removeWebGenerator |
            ForEach-Object { Write-Host "  $_" }
        $appStopped = Invoke-LabLinuxPayload -VMName 'OnPrem-Linux-App' -Address $labHosts['onprem-app'] `
            -Payload $appRemovePayload -Marker 'LAB_TRAFFIC_APP_REMOVED'
        $employeeStopped = Invoke-LabLinuxPayload -VMName 'OnPrem-Linux-Web' -Address $labHosts['onprem-nginx'] `
            -Payload $employeeStopPayload -Marker 'LAB_EMPLOYEE_ORDERS_STOPPED'
        if ($appStopped -and $employeeStopped) {
            Write-Host 'Network generators stopped. Tomcat, SQL login, hosts and Nginx proxy are unchanged.'
        } else {
            Write-Warning 'Windows traffic stopped; one or both Linux generator stops were not confirmed. Run the staged Linux command from its console. Primary application dependencies are unchanged.'
        }
        return
    }

    if ($Component -eq 'Cpu') { Invoke-RequestedCpuStart; return }
    Write-Step 'Starting required source network traffic; CPU simulation remains an independent optional choice.'

    Write-Step 'Adding hosts entries to the Windows guests.'
    foreach ($name in @('OnPrem-Web','OnPrem-SQL')) {
        Invoke-Command -VMName $name -Credential $credential -ScriptBlock $applyHostsEntries -ArgumentList $hostsBlock
    }

    Write-Step 'Using the shared SQL login already prepared by deployment.'

    Write-Step 'Installing the order desk generator on OnPrem-Web.'
    $generatorChangesAttempted = $true
    $webScript = Expand-LabPayload $webGeneratorTemplate
    Invoke-Command -VMName 'OnPrem-Web' -Credential $credential -ScriptBlock $installWebGenerator `
        -ArgumentList $webScript | ForEach-Object { Write-Host "  $_" }

    $nginxReady = Invoke-LabLinuxPayload -VMName 'OnPrem-Linux-Web' -Address $labHosts['onprem-nginx'] `
        -Payload $nginxPayload -Marker 'LAB_TRAFFIC_NGINX_READY'
    $appReady = Invoke-LabLinuxPayload -VMName 'OnPrem-Linux-App' -Address $labHosts['onprem-app'] `
        -Payload $appPayload -Marker 'LAB_TRAFFIC_APP_READY'

    Write-Host ''
    Write-Host 'Lab traffic mesh summary:'
    Write-Host '  OnPrem-Web  -> OnPrem-SQL       TDS 1433   scheduled task LabOrderDeskTraffic'
    Write-Host '  OnPrem-Web  -> OnPrem-Linux-App HTTP 3000  scheduled task LabOrderDeskTraffic'
    if ($appReady)   { Write-Host '  OnPrem-Linux-App -> OnPrem-SQL       TDS 1433   Tomcat JVM bounded JDBC pool' }
    if ($appReady)   { Write-Host '  OnPrem-Linux-App -> OnPrem-Linux-Web HTTP 8080  systemd unit contoso-orderdesk-traffic' }
    if ($nginxReady) { Write-Host '  OnPrem-Linux-Web -> local Nginx 8080 -> OnPrem-Linux-App 3000  synthetic employee orders, UTC 06-22, random 2-20 min' }
    if (-not ($appReady -and $nginxReady)) {
        Write-Warning "Traffic is PARTIAL: Windows generator may be running; Linux startup/proxy checks were not all confirmed. Their scripts are in $trafficRoot. Inspect or stop traffic before retrying."
        if ($NonInteractive) { throw 'Full traffic startup was not confirmed.' }
    }
    Write-Host ''
    Write-Host 'Verify from this host:'
    Write-Host '  Invoke-RestMethod http://192.168.0.12:8080/api/health'
    Write-Host '  Invoke-Sqlcmd -ServerInstance 192.168.0.11 -TrustServerCertificate -Database ContosoApp -Query ''SELECT COUNT(*) FROM dbo.Orders'''
    Write-Host 'Order counts should climb between runs. Leave the mesh running for at least one full'
    Write-Host 'dependency collection interval before expecting a populated map in the portal.'
    Write-Host 'Generators persist across console closure/reboot. Lab/script completion alone does not stop them.'
    Write-Host 'Explicitly stop with C:\AzMigrateLab\enable-lab-traffic.ps1 -Disable, or stop/remove VMs during teardown.'
    if ($appReady -and $nginxReady) { Write-Output 'LAB_TRAFFIC_FULLY_STARTED' }
    else { Write-Output 'LAB_TRAFFIC_PARTIAL_OR_FAILED' }
    # CPU has its own outcome; a CPU failure never re-labels confirmed network startup.
    Invoke-RequestedCpuStart
} catch {
    if ($generatorChangesAttempted) { Write-Output 'LAB_TRAFFIC_PARTIAL_OR_FAILED' }
    else { Write-Output 'LAB_TRAFFIC_NOT_STARTED' }
    throw 'Traffic operation was not fully confirmed. Inspect/stop any existing generators on the host and use the host-interactive fallback; no automatic rollback is claimed.'
} finally {
    $passwordText = $null
    $AdminPassword = $null
    $credential = $null
    $webScript = $null
    # The askpass helper holds no secret, but it exists only to serve this run.
    if ((Test-Path 'Variable:script:LabAskpass') -and $script:LabAskpass) {
        Remove-Item -LiteralPath $script:LabAskpass -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $trafficRoot 'lab-askpass.ps1') -Force -ErrorAction SilentlyContinue
    }
    Remove-Item Env:LAB_SSH_PASSWORD, Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
}
