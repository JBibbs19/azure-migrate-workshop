#requires -Version 5.1
# Offline native fixtures only: no guest, scheduler, services or cloud actions.
$ErrorActionPreference='Stop'
$path=Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/cpu-simulation/windows-cpu.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw 'CPU worker parser failure' }
$variables=@('dayHours','nightHours','dayStart','dayEnd','dayTarget','nightTarget','expectedCpus','maxCoreDuty','highCpu','resumeCpu','cooldownSeconds','sampleSeconds','frameSeconds','staleSeconds','root','taskName')
foreach ($node in $ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst]},$false)) {
    if ($node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -in $variables) { . ([scriptblock]::Create($node.Extent.Text)) }
}
foreach ($name in @('Get-CpuDecision','Get-CpuSnapshot','Get-CpuTotalPercent','Get-CpuStatus','Stop-CpuWorker')) {
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($node.Extent.Text))
}
function Assert-Cpu { param([bool]$Value) if (-not $Value) { throw 'CPU fixture failed' } }
$day=[DateTime]::Parse('2026-10-16T12:00:00Z').ToUniversalTime()
Assert-Cpu ($dayHours -eq 16 -and $nightHours -eq 8 -and $maxCoreDuty -eq .30)
$r=Get-CpuDecision 14 9 2 0 $false 0 $day
Assert-Cpu ($r.baselineCpuPercent -eq 5 -and $r.targetWorkerCpuPercent -eq 10)
$r=Get-CpuDecision 0 0 2 0 $false 0 $day.AddHours(10)
Assert-Cpu ($r.phase -eq 'night' -and $r.targetWorkerCpuPercent -eq 2)
foreach ($value in @($null,[double]::NaN,[double]::PositiveInfinity,-1,101)) {
    $r=Get-CpuDecision $value 0 2 0 $false 0 $day
    Assert-Cpu ($r.targetWorkerCpuPercent -eq 0 -and $r.reason -eq 'measurement_invalid')
}
$r=Get-CpuDecision 30 0 2 0 $false 0 $day
Assert-Cpu ($r.guard -and $r.targetWorkerCpuPercent -eq 0 -and $r.cooldownUntil -eq 60)
$r=Get-CpuDecision 20 0 2 59 $r.guard $r.cooldownUntil $day
Assert-Cpu ($r.guard -and $r.cooldownUntil -eq 119)
$r=Get-CpuDecision 10 0 2 118 $r.guard $r.cooldownUntil $day
Assert-Cpu ($r.guard)
$r=Get-CpuDecision 10 0 2 119 $r.guard $r.cooldownUntil $day
Assert-Cpu (-not $r.guard -and $r.targetWorkerCpuPercent -eq 5)
Assert-Cpu ((Get-CpuTotalPercent @{idle=80;stamp=100} @{idle=160;stamp=200}) -eq 20)
$rejected=$false
try { $null=Get-CpuTotalPercent @{idle=80;stamp=100} @{idle=79;stamp=200} } catch { $rejected=$true }
Assert-Cpu $rejected
function Get-ScheduledTask { [CmdletBinding()]param() throw 'fixture: scheduler enumeration unavailable' }
$rejected=$false
try { Stop-CpuWorker } catch { $rejected=$true }
Assert-Cpu $rejected
Write-Host 'PASS native CPU parser/pure-logic/fail-closed scheduler fixtures; no VM or scheduler mutations.'
