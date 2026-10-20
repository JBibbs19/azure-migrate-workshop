<#
.SYNOPSIS
Prepare ONLY the existing ContosoApp labapp login; never invoke the old Node traffic setup.
.DESCRIPTION
Run elevated on HyperVHost. Uses PowerShell Direct into OnPrem-SQL with Administrator
and the prompted lab password. If mixed mode is needed, -AllowSqlRestart explicitly
permits a SQL Express service restart. This interrupts IIS and all other SQL clients.
No VM, database, table, customer or password for a guest account is created/changed.
#>
[CmdletBinding()]
param([switch]$AllowSqlRestart)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run elevated on HyperVHost.'
}
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { throw 'Run on HyperVHost with Hyper-V PowerShell available.' }
$vm = Get-VM -Name 'OnPrem-SQL' -ErrorAction Stop
if ($vm.State -ne 'Running') { throw 'Start the existing OnPrem-SQL VM first.' }
Write-Warning 'This uses the SAME lab password for labapp. It may reset the existing labapp login to that value.'
Write-Warning 'If mixed mode is not already active, SQL Express must restart. No database/table recreation occurs.'
$secure = Read-Host 'Existing lab password (hidden)' -AsSecureString
$credential = New-Object System.Management.Automation.PSCredential ('Administrator', $secure)
$plain = $credential.GetNetworkCredential().Password
if ([string]::IsNullOrWhiteSpace($plain)) { throw 'Lab password cannot be empty.' }
try {
    Invoke-Command -VMName 'OnPrem-SQL' -Credential $credential -ArgumentList $plain, ([bool]$AllowSqlRestart) -ScriptBlock {
        param([string]$Password, [bool]$PermitRestart)
        $ErrorActionPreference = 'Stop'
        if (-not (Get-Module -ListAvailable -Name SqlServer)) {
            throw 'SqlServer module missing on OnPrem-SQL. Install/review it on that guest, or use SSMS login setup as documented.'
        }
        Import-Module SqlServer -ErrorAction Stop
        try {
            Invoke-Sqlcmd -ServerInstance '.\SQLEXPRESS' -TrustServerCertificate -Database 'ContosoApp' -Query @'
SELECT TOP (0) c.CustomerID, c.FirstName, c.LastName, o.OrderID, o.ProductName,
    o.Quantity, o.UnitPrice, o.OrderDate
FROM dbo.Customers c LEFT JOIN dbo.Orders o ON o.CustomerID = c.CustomerID;
'@ -ErrorAction Stop | Out-Null
        } catch { throw 'Existing ContosoApp schema could not be validated. No security changes were made.' }
        $instance = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').SQLEXPRESS
        $registry = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instance\MSSQLServer"
        if ((Get-ItemProperty $registry -Name LoginMode).LoginMode -ne 2) {
            if (-not $PermitRestart) {
                throw 'Mixed mode is required. Schedule the interruption and rerun with -AllowSqlRestart; nothing was changed.'
            }
            Set-ItemProperty $registry -Name LoginMode -Value 2
            Restart-Service 'MSSQL$SQLEXPRESS' -Force
            Start-Sleep -Seconds 10
        }
        $escaped = $Password.Replace("'", "''")
        $query = @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'labapp')
    CREATE LOGIN [labapp] WITH PASSWORD = N'$escaped', CHECK_POLICY = OFF;
ELSE
    ALTER LOGIN [labapp] WITH PASSWORD = N'$escaped', CHECK_POLICY = OFF;
ALTER LOGIN [labapp] ENABLE;
USE ContosoApp;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'labapp')
    CREATE USER [labapp] FOR LOGIN [labapp];
ELSE
    ALTER USER [labapp] WITH LOGIN = [labapp];
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members m
    JOIN sys.database_principals r ON m.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON m.member_principal_id = u.principal_id
    WHERE r.name = N'db_datareader' AND u.name = N'labapp')
    ALTER ROLE db_datareader ADD MEMBER [labapp];
IF NOT EXISTS (SELECT 1 FROM sys.database_role_members m
    JOIN sys.database_principals r ON m.role_principal_id = r.principal_id
    JOIN sys.database_principals u ON m.member_principal_id = u.principal_id
    WHERE r.name = N'db_datawriter' AND u.name = N'labapp')
    ALTER ROLE db_datawriter ADD MEMBER [labapp];
"@
        try {
            Invoke-Sqlcmd -ServerInstance '.\SQLEXPRESS' -TrustServerCertificate -Query $query -ErrorAction Stop | Out-Null
        } catch {
            throw 'Lab SQL login setup failed. Inspect locally on OnPrem-SQL; do not share the expanded password-bearing query.'
        } finally {
            $query = $null
            $escaped = $null
            $Password = $null
        }
        Write-Output 'Existing ContosoApp labapp login mapped with db_datareader and db_datawriter. No seed data was changed.'
    }
} finally {
    $plain = $null
    $secure = $null
    $credential = $null
}
