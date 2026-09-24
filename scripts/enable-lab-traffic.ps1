<#
.SYNOPSIS
Enable (or remove) the optional lab traffic mesh between the four workshop VMs.
.DESCRIPTION
Run this inside HyperVHost in an elevated Windows PowerShell session after deployment
reports workload readiness. It wires the four independent samples into one small-business
order desk so Azure Migrate dependency analysis has real TCP connections to observe:

    OnPrem-Linux-Web  .12  --> OnPrem-Linux-App .13   HTTP 8080 reverse proxy to the API
    OnPrem-Linux-App  .13  --> OnPrem-SQL       .11   TDS 1433, reads and writes ContosoApp
    OnPrem-Web        .10  --> OnPrem-SQL       .11   TDS 1433, internal order report
    OnPrem-Web        .10  --> OnPrem-Linux-App .13   HTTP 3000, batch call to the API

Nothing that deployment validates is replaced. The IIS site on .10, the Nginx root site on
.12 and the Node service on port 3000 keep serving their original pages, so
Assert-LabSourceWorkloads still passes. The proxy is added on port 8080, and the generators
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
The Linux lab user created by cloud-init. Read from the settings file, otherwise labadmin.
.PARAMETER IntervalSeconds
Seconds between generated request cycles. Keep this low-rate: the goal is a steady trickle
that dependency polling can observe, not a load test that distorts performance-based sizing.
.PARAMETER SettingsPath
Location of the deployment-written settings file. Defaults to the copy beside this script.
.PARAMETER SkipLinux
Configure only the Windows guests and write the Linux scripts to disk without connecting.
.PARAMETER Disable
Stop and remove the generators, the proxy and the SQL login. Leaves the sample workloads,
the firewall rules and the hosts entries in place.
.EXAMPLE
C:\AzMigrateLab\enable-lab-traffic.ps1
.EXAMPLE
$password = Read-Host 'Lab password' -AsSecureString
C:\AzMigrateLab\enable-lab-traffic.ps1 -AdminPassword $password -IntervalSeconds 30
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
    [ValidateRange(5,600)][int]$IntervalSeconds,
    [string]$SettingsPath,
    [switch]$SkipLinux,
    [switch]$Disable
)
$ErrorActionPreference = 'Stop'

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
if (-not $LinuxUsername) {
    $configured = Get-LabSetting 'LinuxUsername'
    $LinuxUsername = if ($configured) { [string]$configured } else { 'labadmin' }
}
if (-not $PSBoundParameters.ContainsKey('IntervalSeconds')) {
    $configured = Get-LabSetting 'IntervalSeconds'
    $IntervalSeconds = if ($configured) { [int]$configured } else { 20 }
}
$configuredLogin = Get-LabSetting 'SqlLogin'
if ($configuredLogin) { $sqlLogin = [string]$configuredLogin }
$configuredAddresses = Get-LabSetting 'WorkloadAddresses'
if ($null -ne $configuredAddresses) {
    foreach ($key in @($labHosts.Keys)) {
        $value = $configuredAddresses.PSObject.Properties[$key]
        if ($null -ne $value -and $value.Value -match '^\d{1,3}(\.\d{1,3}){3}$') { $labHosts[$key] = [string]$value.Value }
    }
}
if (-not $AdminPassword) {
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
$required = @('OnPrem-Web','OnPrem-SQL','OnPrem-Linux-Web','OnPrem-Linux-App')
foreach ($name in $required) {
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM '$name' was not found. Complete deployment before enabling lab traffic." }
    if ($vm.State -ne 'Running') { throw "VM '$name' is $($vm.State). Start every workload VM first." }
}
New-Item -ItemType Directory -Path $trafficRoot -Force | Out-Null
& icacls.exe $trafficRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

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

$enableSqlLogin = {
    param([string]$Login,[string]$Password)
    $ErrorActionPreference = 'Stop'
    # The Node generator runs on Linux and cannot use Windows authentication, so the
    # instance is switched to mixed mode and given one lab-only login limited to ContosoApp.
    $instance = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').SQLEXPRESS
    $settings = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instance\MSSQLServer"
    if ((Get-ItemProperty $settings -Name LoginMode).LoginMode -ne 2) {
        Set-ItemProperty $settings -Name LoginMode -Value 2
        Restart-Service 'MSSQL$SQLEXPRESS' -Force
        Start-Sleep -Seconds 10
    }
    Import-Module SqlServer -ErrorAction Stop
    $escaped = $Password.Replace("'","''")
    $query = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$Login')
    CREATE LOGIN [$Login] WITH PASSWORD = '$escaped', CHECK_POLICY = OFF;
ELSE
    ALTER LOGIN [$Login] WITH PASSWORD = '$escaped', CHECK_POLICY = OFF;
ALTER LOGIN [$Login] ENABLE;
USE ContosoApp;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$Login')
    CREATE USER [$Login] FOR LOGIN [$Login];
ALTER ROLE db_datareader ADD MEMBER [$Login];
ALTER ROLE db_datawriter ADD MEMBER [$Login];
"@
    Invoke-Sqlcmd -TrustServerCertificate -ServerInstance '.\SQLEXPRESS' -Query $query -ErrorAction Stop
    Write-Output "SQL login '$Login' is ready for lab traffic."
}

$removeSqlLogin = {
    param([string]$Login)
    $ErrorActionPreference = 'Continue'
    try {
        Import-Module SqlServer -ErrorAction Stop
        Invoke-Sqlcmd -TrustServerCertificate -ServerInstance '.\SQLEXPRESS' -ErrorAction Stop -Query @"
USE ContosoApp;
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$Login') DROP USER [$Login];
USE master;
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$Login') DROP LOGIN [$Login];
"@
        Write-Output "SQL login '$Login' removed."
    } catch { Write-Output "Could not remove the lab SQL login: $($_.Exception.Message)" }
}

# Generator for OnPrem-Web. System.Data.SqlClient avoids depending on the SqlServer module,
# which deployment installs only on the database guest.
$webGeneratorTemplate = @'
$ErrorActionPreference = 'Continue'
$interval = __INTERVAL__
$log = 'C:\LabTraffic\traffic.log'
function Write-TrafficLog { param($Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $log -Value $line -ErrorAction SilentlyContinue
    $file = Get-Item $log -ErrorAction SilentlyContinue
    if ($file -and $file.Length -gt 5MB) { Set-Content -Path $log -Value '' -ErrorAction SilentlyContinue }
}
Write-TrafficLog 'Order desk generator started.'
while ($true) {
    try {
        # Internal order report: OnPrem-Web -> OnPrem-SQL over TDS 1433.
        $connection = New-Object System.Data.SqlClient.SqlConnection
        $connection.ConnectionString = "Server=onprem-sql,1433;Database=ContosoApp;User ID=__LOGIN__;Password=__PASSWORD__;TrustServerCertificate=True;Connect Timeout=10"
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = 'SELECT TOP 5 o.OrderID, c.LastName, o.ProductName, o.Quantity FROM dbo.Orders o INNER JOIN dbo.Customers c ON c.CustomerID = o.CustomerID ORDER BY o.OrderDate DESC'
        $reader = $command.ExecuteReader()
        $rows = 0
        while ($reader.Read()) { $rows++ }
        $reader.Close(); $connection.Close()
        Write-TrafficLog "Order report read $rows rows from onprem-sql."
    } catch { Write-TrafficLog "SQL report failed: $($_.Exception.Message)" }
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
HOSTS_MARKER="# --- CES lab traffic mesh ---"
sed -i "/${HOSTS_MARKER}/,/${HOSTS_MARKER}/d" /etc/hosts
printf '%s\n__HOSTS__\n%s\n' "${HOSTS_MARKER}" "${HOSTS_MARKER}" >> /etc/hosts
# Port 8080 keeps the deployment-validated root site on port 80 untouched.
cat > /etc/nginx/conf.d/lab-order-desk.conf <<'NGINXEOF'
server {
    listen 8080;
    server_name _;
    location /api/ {
        proxy_pass http://onprem-app:3000/api/;
        proxy_set_header Host $host;
        proxy_connect_timeout 5s;
    }
    location / {
        return 200 'TD SYNNEX order desk proxy. Try /api/health\n';
        add_header Content-Type text/plain;
    }
}
NGINXEOF
nginx -t
systemctl reload nginx
echo LAB_TRAFFIC_NGINX_READY
'@

$nginxRemovePayload = @'
set -e
rm -f /etc/nginx/conf.d/lab-order-desk.conf
nginx -t && systemctl reload nginx
echo LAB_TRAFFIC_NGINX_REMOVED
'@

$appPayload = @'
set -e
HOSTS_MARKER="# --- CES lab traffic mesh ---"
sed -i "/${HOSTS_MARKER}/,/${HOSTS_MARKER}/d" /etc/hosts
printf '%s\n__HOSTS__\n%s\n' "${HOSTS_MARKER}" "${HOSTS_MARKER}" >> /etc/hosts
cd /opt/contoso-app
npm install mssql@11 --omit=dev --no-audit --no-fund
cat > /opt/contoso-app/lab-traffic.js <<'NODEEOF'
// Lab-only order desk simulator. Reads and writes the ContosoApp sample database over
// TDS 1433 and calls the Nginx proxy, so dependency analysis sees sustained connections.
const sql = require('mssql');
const http = require('http');
const INTERVAL = Number(process.env.LAB_INTERVAL || 20) * 1000;
const config = {
  server: process.env.LAB_SQL_HOST || 'onprem-sql',
  port: 1433,
  database: 'ContosoApp',
  user: process.env.LAB_SQL_USER,
  password: process.env.LAB_SQL_PASSWORD,
  options: { trustServerCertificate: true, encrypt: false },
  pool: { max: 4, min: 0, idleTimeoutMillis: 30000 }
};
const products = ['Azure Certification Guide','Cloud Architecture Poster','DevOps Handbook',
  'Kubernetes Stickers','Serverless Cookbook'];
let pool = null;
async function getPool() {
  if (!pool) { pool = await new sql.ConnectionPool(config).connect(); }
  return pool;
}
async function cycle() {
  try {
    const active = await getPool();
    const customers = await active.request().query('SELECT CustomerID FROM dbo.Customers');
    if (customers.recordset.length) {
      const customer = customers.recordset[Math.floor(Math.random() * customers.recordset.length)].CustomerID;
      const product = products[Math.floor(Math.random() * products.length)];
      await active.request()
        .input('customer', sql.Int, customer)
        .input('product', sql.NVarChar(100), product)
        .input('quantity', sql.Int, 1 + Math.floor(Math.random() * 4))
        .input('price', sql.Decimal(10, 2), 19.99)
        .query('INSERT INTO dbo.Orders (CustomerID, ProductName, Quantity, UnitPrice) VALUES (@customer, @product, @quantity, @price)');
      const totals = await active.request().query('SELECT COUNT(*) AS Orders FROM dbo.Orders');
      console.log(`order placed; ContosoApp now holds ${totals.recordset[0].Orders} orders`);
    }
  } catch (error) {
    console.error(`sql cycle failed: ${error.message}`);
    if (pool) { try { await pool.close(); } catch (ignored) {} }
    pool = null;
  }
  // Also exercise the reverse proxy so the .13 -> .12 -> .13 path appears in discovery.
  http.get('http://onprem-nginx:8080/api/health', response => {
    response.resume();
    console.log(`proxy health returned ${response.statusCode}`);
  }).on('error', error => console.error(`proxy call failed: ${error.message}`));
}
setInterval(cycle, INTERVAL);
cycle();
NODEEOF
chown -R contosoapp:contosoapp /opt/contoso-app
cat > /etc/systemd/system/lab-traffic.service <<'SVCEOF'
[Unit]
Description=CES lab order desk traffic generator
After=network-online.target contoso-app.service
Wants=network-online.target

[Service]
Type=simple
User=contosoapp
NoNewPrivileges=true
WorkingDirectory=/opt/contoso-app
EnvironmentFile=/etc/lab-traffic.env
ExecStart=/usr/bin/node lab-traffic.js
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
SVCEOF
cat > /etc/lab-traffic.env <<'ENVEOF'
LAB_SQL_USER=__LOGIN__
LAB_SQL_PASSWORD=__PASSWORD__
LAB_INTERVAL=__INTERVAL__
ENVEOF
chmod 600 /etc/lab-traffic.env
chown root:root /etc/lab-traffic.env
systemctl daemon-reload
systemctl enable lab-traffic
systemctl restart lab-traffic
echo LAB_TRAFFIC_APP_READY
'@

$appRemovePayload = @'
set -e
systemctl disable --now lab-traffic || true
rm -f /etc/systemd/system/lab-traffic.service /etc/lab-traffic.env /opt/contoso-app/lab-traffic.js
systemctl daemon-reload
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
            '__PASSWORD__' { return $passwordText }
            '__INTERVAL__' { return [string]$IntervalSeconds }
            default        { throw "Unexpected token $($match.Value)" }
        }
    })
}

function Invoke-LabLinuxPayload {
    param([string]$VMName,[string]$Address,[string]$Payload,[string]$Marker)
    $expanded = Expand-LabPayload $Payload
    $scriptPath = Join-Path $trafficRoot "$VMName.sh"
    # LF endings only; bash rejects the CRLF a Windows editor would introduce.
    [IO.File]::WriteAllText($scriptPath, ($expanded -replace "`r`n","`n"), [Text.UTF8Encoding]::new($false))
    if ($SkipLinux) {
        Write-Step "SkipLinux: wrote $scriptPath for manual execution on $VMName."
        return $false
    }
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if (-not $ssh) {
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
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($expanded -replace "`r`n","`n")))
    Write-Step "Connecting to $VMName ($Address). Enter the lab password for $LinuxUsername when prompted."
    $remote = "echo $encoded | base64 -d | sudo bash"
    # ssh writes progress and host-key notices to stderr even on success. Merging that stream
    # with 2>&1 while ErrorActionPreference is 'Stop' turns each line into a terminating
    # NativeCommandError, so the run aborts on a benign warning. Relax the preference for the
    # duration of the native call and judge the result by exit code and marker instead.
    # LogLevel=ERROR also suppresses the 'Permanently added ... to the list of known hosts'
    # notice, which is emitted on every run because the throwaway known-hosts file never
    # retains the key.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $ssh.Source '-o' 'StrictHostKeyChecking=no' '-o' 'UserKnownHostsFile=NUL' `
            '-o' 'LogLevel=ERROR' '-o' 'ConnectTimeout=15' "$LinuxUsername@$Address" $remote 2>&1
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    $text = @($output | ForEach-Object { [string]$_ }) -join "`n"
    $output | ForEach-Object { Write-Host "  $_" }
    if ($exitCode -ne 0 -or $text -notmatch [regex]::Escape($Marker)) {
        Write-Warning "$VMName did not report $Marker (ssh exit code $exitCode). Review the output above, or run $scriptPath from its console."
        return $false
    }
    Write-Step "$VMName configured."
    return $true
}

# ---------- Execution ----------
try {
    if ($Disable) {
        Write-Step 'Removing the lab traffic mesh.'
        Invoke-Command -VMName 'OnPrem-Web' -Credential $credential -ScriptBlock $removeWebGenerator |
            ForEach-Object { Write-Host "  $_" }
        Invoke-Command -VMName 'OnPrem-SQL' -Credential $credential -ScriptBlock $removeSqlLogin -ArgumentList $sqlLogin |
            ForEach-Object { Write-Host "  $_" }
        $null = Invoke-LabLinuxPayload -VMName 'OnPrem-Linux-App' -Address $labHosts['onprem-app'] `
            -Payload $appRemovePayload -Marker 'LAB_TRAFFIC_APP_REMOVED'
        $null = Invoke-LabLinuxPayload -VMName 'OnPrem-Linux-Web' -Address $labHosts['onprem-nginx'] `
            -Payload $nginxRemovePayload -Marker 'LAB_TRAFFIC_NGINX_REMOVED'
        Write-Host 'Lab traffic mesh removed. The four sample workloads are unchanged.'
        return
    }

    Write-Step 'Adding hosts entries to the Windows guests.'
    foreach ($name in @('OnPrem-Web','OnPrem-SQL')) {
        Invoke-Command -VMName $name -Credential $credential -ScriptBlock $applyHostsEntries -ArgumentList $hostsBlock
    }

    Write-Step 'Enabling mixed-mode authentication and the lab SQL login on OnPrem-SQL.'
    Invoke-Command -VMName 'OnPrem-SQL' -Credential $credential -ScriptBlock $enableSqlLogin `
        -ArgumentList $sqlLogin,$passwordText | ForEach-Object { Write-Host "  $_" }

    Write-Step 'Installing the order desk generator on OnPrem-Web.'
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
    if ($appReady)   { Write-Host '  OnPrem-Linux-App -> OnPrem-SQL       TDS 1433   systemd unit lab-traffic' }
    if ($appReady)   { Write-Host '  OnPrem-Linux-App -> OnPrem-Linux-Web HTTP 8080  systemd unit lab-traffic' }
    if ($nginxReady) { Write-Host '  OnPrem-Linux-Web -> OnPrem-Linux-App HTTP 3000  Nginx proxy on port 8080' }
    if (-not ($appReady -and $nginxReady)) {
        Write-Warning "One or more Linux guests were not configured. Their scripts are in $trafficRoot."
    }
    Write-Host ''
    Write-Host 'Verify from this host:'
    Write-Host '  Invoke-RestMethod http://192.168.0.12:8080/api/health'
    Write-Host '  Invoke-Sqlcmd -ServerInstance 192.168.0.11 -TrustServerCertificate -Database ContosoApp -Query ''SELECT COUNT(*) FROM dbo.Orders'''
    Write-Host 'Order counts should climb between runs. Leave the mesh running for at least one full'
    Write-Host 'dependency collection interval before expecting a populated map in the portal.'
} finally {
    $passwordText = $null
    $webScript = $null
}
