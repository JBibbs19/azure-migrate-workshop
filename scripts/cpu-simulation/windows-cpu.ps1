#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Start','Status','Stop','Worker')][string]$Mode = 'Status',
    [ValidateRange(1,168)][int]$DurationHours = 24,
    [switch]$Renew
)
$ErrorActionPreference = 'Stop'
$root = 'C:\LabCpuSimulation'
$taskName = 'LabCpuSimulation'
$dayHours = 16
$nightHours = 24 - $dayHours
$dayStart = 6
$dayEnd = $dayStart + $dayHours
$dayTarget = 15.0
$nightTarget = 2.0
$expectedCpus = 2
$maxCoreDuty = $dayTarget * $expectedCpus / 100.0
$highCpu = 30.0
$resumeCpu = 20.0
$cooldownSeconds = 60.0
$sampleSeconds = 2.0
$frameSeconds = 0.1
$staleSeconds = $sampleSeconds * 5

function Write-CpuState {
    param($State)
    $pending = Join-Path $root 'state.pending'
    [IO.File]::WriteAllText($pending, ($State | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $path = Join-Path $root 'state.json'
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($pending,$path,$null) }
    else { [IO.File]::Move($pending,$path) }
}
function Get-CpuSnapshot {
    # Raw aggregate counters are locale independent; idle and timestamps use the same 100ns units.
    $rows = @(Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop)
    if ($rows.Count -ne 1 -or $null -eq $rows[0].PercentIdleTime -or $null -eq $rows[0].Timestamp_Sys100NS) { throw 'CPU measurement unavailable' }
    return @{idle=[decimal]$rows[0].PercentIdleTime;stamp=[decimal]$rows[0].Timestamp_Sys100NS}
}
function Get-CpuTotalPercent {
    param($Before,$After)
    $elapsed=$After.stamp-$Before.stamp; $idle=$After.idle-$Before.idle
    if ($elapsed -le 0 -or $idle -lt 0 -or $idle -gt $elapsed -or $After.idle -lt $Before.idle) { throw 'Invalid CPU measurement' }
    return [double](100 * ($elapsed - $idle) / $elapsed)
}
function Get-CpuDecision {
    param($Total,$Worker,[int]$Cpus,[double]$Now,[bool]$Guard,[double]$CooldownUntil,[DateTime]$UtcNow = [DateTime]::UtcNow)
    $phase='night'; $target=$nightTarget
    if ($UtcNow.Hour -ge $dayStart -and $UtcNow.Hour -lt $dayEnd) { $phase='day'; $target=$dayTarget }
    $result=@{phase=$phase;targetTotalCpuPercent=$target;targetWorkerCpuPercent=0.0;measuredTotalCpuPercent=$null;measuredWorkerCpuPercent=$null;baselineCpuPercent=$null;baselineAboveGoal=$false;guard=$Guard;cooldownUntil=$CooldownUntil;cooldownRemainingSeconds=[Math]::Max(0,$CooldownUntil-$Now);reason='measurement_invalid'}
    if ($Cpus -ne $expectedCpus -or $null -eq $Total -or $null -eq $Worker) { return $result }
    foreach ($value in @([double]$Total,[double]$Worker)) { if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt 100) { return $result } }
    if ($Worker -gt 100.0/$Cpus) { return $result }
    $baseline=[Math]::Max(0,$Total-$Worker)
    $result.measuredTotalCpuPercent=$Total; $result.measuredWorkerCpuPercent=$Worker
    $result.baselineCpuPercent=$baseline; $result.baselineAboveGoal=($baseline -ge $target)
    if ($Total -ge $highCpu) { $Guard=$true; $CooldownUntil=$Now+$cooldownSeconds }
    elseif ($Guard -and $Total -ge $resumeCpu) { $CooldownUntil=$Now+$cooldownSeconds }
    elseif ($Guard -and $Now -ge $CooldownUntil) { $Guard=$false }
    $result.guard=$Guard; $result.cooldownUntil=$CooldownUntil; $result.cooldownRemainingSeconds=[Math]::Max(0,$CooldownUntil-$Now)
    if ($Guard) { $result.reason='high_cpu_cooldown' }
    elseif ($baseline -ge $target) { $result.reason='baseline_above_goal' }
    else { $result.reason='running'; $result.targetWorkerCpuPercent=[Math]::Min($maxCoreDuty*100/$Cpus,$target-$baseline) }
    return $result
}
function Get-CpuStatus {
    $tasks=@(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $taskName })
    if ($tasks.Count -gt 1) { throw 'CPU task ambiguous' }
    $task=$null; if ($tasks.Count) { $task=$tasks[0] }
    $state=$null; $stale=$true; $healthy=$false; $actualPid=$null
    try {
        $state=Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json
        $config=Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
        $age=([DateTime]::UtcNow-[DateTime]::Parse($state.heartbeatUtc).ToUniversalTime()).TotalSeconds
        $stale=($age -lt 0 -or $age -gt $staleSeconds)
        if ($state.pid -gt 0) {
            $process=Get-Process -Id $state.pid -ErrorAction Stop
            $identity=Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f [int]$state.pid) -ErrorAction Stop
            if ($process.ProcessName -eq 'powershell' -and $identity.CommandLine -match '(?i)C:\\LabCpuSimulation\\windows-cpu\.ps1.*-Mode Worker' -and
                $process.StartTime.ToUniversalTime().ToString('o') -eq $state.processStartUtc) { $actualPid=[int]$state.pid }
        }
        $healthy=($null -ne $task -and [string]$task.State -eq 'Running' -and $actualPid -eq $state.pid -and $null -ne $actualPid -and
            -not $stale -and $state.status -eq 'running' -and $state.runId -eq $config.runId -and
            [DateTime]::UtcNow -lt [DateTime]::Parse($config.expiresUtc).ToUniversalTime())
    } catch { $healthy=$false }
    $taskState='absent'; $enabled=$false; $triggers=0
    if ($task) { $taskState=[string]$task.State; $enabled=[bool]$task.Settings.Enabled; $triggers=@($task.Triggers).Count }
    return @{task=@{exists=($null -ne $task);state=$taskState;enabled=$enabled;triggers=$triggers};pid=$actualPid;healthy=$healthy;stale=$stale;state=$state}
}
function Stop-CpuWorker {
    $before=Get-CpuStatus
    $tasks=@(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $taskName })
    if ($tasks.Count -gt 1) { throw 'CPU task ambiguous' }
    if ($tasks.Count) {
        if ([string]$tasks[0].State -in @('Running','Queued')) { $tasks[0] | Stop-ScheduledTask -ErrorAction Stop }
        $tasks[0] | Disable-ScheduledTask -ErrorAction Stop | Out-Null
        $wait=[Diagnostics.Stopwatch]::StartNew()
        do {
            $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
            if ([string]$task.State -notin @('Running','Queued') -and -not $task.Settings.Enabled) { break }
            Start-Sleep -Milliseconds 200
        } while ($wait.Elapsed.TotalSeconds -lt 15)
        if ([string]$task.State -in @('Running','Queued') -or $task.Settings.Enabled) { throw 'CPU stop unverified' }
        # Removing the task also disarms any copied/inherited triggers, without touching apps.
        $task | Unregister-ScheduledTask -Confirm:$false -ErrorAction Stop
    }
    $exitWait=[Diagnostics.Stopwatch]::StartNew()
    do {
        $remaining=Get-CpuStatus
        $processes=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object {
            $_.CommandLine -match '(?i)C:\\LabCpuSimulation\\windows-cpu\.ps1.*-Mode Worker'
        })
        if ($null -eq $remaining.pid -and $processes.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    } while ($exitWait.Elapsed.TotalSeconds -lt 15)
    if ($null -ne $remaining.pid -or $processes.Count -gt 0 -or $remaining.task.exists) { throw 'CPU process exit/disarm unverified' }
    if (Test-Path (Join-Path $root 'state.json')) {
        $state=@{}
        try { $stored=Get-Content (Join-Path $root 'state.json') -Raw | ConvertFrom-Json; foreach ($property in $stored.PSObject.Properties) { $state[$property.Name]=$property.Value } } catch { }
        $state.status='stopped'; $state.targetWorkerCpuPercent=0; $state.heartbeatUtc=[DateTime]::UtcNow.ToString('o'); Write-CpuState $state
    }
}
function Invoke-CpuWorker {
    $mutex=[Threading.Mutex]::new($false,'Global\LabCpuSimulationWorker')
    $owns=$false
    try {
        try { $owns=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns=$true }
        if (-not $owns) { throw 'CPU worker already running' }
        $config=Get-Content (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
        if ($config.runId -notmatch '^[a-f0-9]{32}$' -or $config.durationSeconds -lt 3600 -or $config.durationSeconds -gt 168*3600) { throw 'CPU worker configuration invalid' }
        $expiry=[DateTime]::Parse($config.expiresUtc).ToUniversalTime()
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $process=[Diagnostics.Process]::GetCurrentProcess(); $process.PriorityClass='Idle'
        $state=@{runId=$config.runId;pid=$PID;processStartUtc=$process.StartTime.ToUniversalTime().ToString('o');startedUtc=[DateTime]::UtcNow.ToString('o');expiresUtc=$expiry.ToString('o');status='starting';heartbeatUtc=[DateTime]::UtcNow.ToString('o')}
        $cpus=[Environment]::ProcessorCount; $previous=$null; $previousTime=0.0; $previousProcess=0.0
        $duty=0.0; $nextSample=0.0; $guard=$false; $cooldownUntil=0.0; [long]$value=1
        while ([DateTime]::UtcNow -lt $expiry -and $watch.Elapsed.TotalSeconds -lt $config.durationSeconds) {
            $now=$watch.Elapsed.TotalSeconds
            if ($now -ge $nextSample) {
                $total=$null; $measuredWorker=$null
                try {
                    $current=Get-CpuSnapshot
                    $process.Refresh(); $currentProcess=$process.TotalProcessorTime.TotalSeconds
                    if ($null -ne $previous) {
                        $total=Get-CpuTotalPercent $previous $current
                        $wall=$now-$previousTime
                        if ($wall -gt 0) { $measuredWorker=100.0*($currentProcess-$previousProcess)/$wall/$cpus }
                    }
                    $previous=$current; $previousTime=$now; $previousProcess=$currentProcess
                } catch { $previous=$null }
                $report=Get-CpuDecision $total $measuredWorker $cpus $now $guard $cooldownUntil
                $guard=$report.guard; $cooldownUntil=$report.cooldownUntil; $duty=$report.targetWorkerCpuPercent*$cpus/100.0
                foreach ($key in $report.Keys) { if ($key -ne 'cooldownUntil') { $state[$key]=$report[$key] } }
                $state.status='running'; $state.heartbeatUtc=[DateTime]::UtcNow.ToString('o'); Write-CpuState $state
                $nextSample=$now+$sampleSeconds
            }
            $frame=$watch.Elapsed.TotalSeconds
            $busyEnd=[Math]::Min($frame+$frameSeconds*[Math]::Min($maxCoreDuty,$duty),$config.durationSeconds)
            while ($watch.Elapsed.TotalSeconds -lt $busyEnd -and [DateTime]::UtcNow -lt $expiry) { $value=($value*1664525+1013904223) -band 0xffffffffL }
            $sleep=[Math]::Min($frame+$frameSeconds-$watch.Elapsed.TotalSeconds, [Math]::Min(($expiry-[DateTime]::UtcNow).TotalSeconds,$config.durationSeconds-$watch.Elapsed.TotalSeconds))
            if ($sleep -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Max(1,[Math]::Floor($sleep*1000))) }
        }
        $state.status='expired'; $state.targetWorkerCpuPercent=0; $state.heartbeatUtc=[DateTime]::UtcNow.ToString('o'); Write-CpuState $state
    } catch {
        if ($null -ne (Get-Variable state -ErrorAction SilentlyContinue)) { $state.status='failed'; $state.reason='worker_failed_closed'; $state.targetWorkerCpuPercent=0; $state.heartbeatUtc=[DateTime]::UtcNow.ToString('o'); Write-CpuState $state }
        throw 'CPU worker failed closed. Inspect guest-local state; no raw error recorded.'
    } finally { if ($owns) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

if ($Mode -eq 'Worker') { Invoke-CpuWorker; return }
if ($Mode -eq 'Status') { Get-CpuStatus; return }
$controlMutex=[Threading.Mutex]::new($false,'Global\LabCpuSimulationControl')
$ownsControl=$false
try {
    try { $ownsControl=$controlMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsControl=$true }
    if (-not $ownsControl) { throw 'CPU control operation already in progress' }
    if ($Mode -eq 'Stop') { Stop-CpuWorker; Get-CpuStatus; return }
    $observed=Get-CpuStatus
    if (-not $Renew) {
        if ($observed.task.state -in @('Running','Queued')) {
            if (-not $observed.healthy) { throw 'Existing CPU run unresolved; inspect Status, Stop or explicitly Renew' }
            $observed; return
        }
        if (Test-Path (Join-Path $root 'config.json')) { throw 'Existing CPU deadline; use explicit Renew to replace it' }
    }
    Stop-CpuWorker
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'CPU state ACL failed' }
    $seconds=$DurationHours*60*60
    @{runId=[guid]::NewGuid().ToString('N');durationSeconds=$seconds;expiresUtc=[DateTime]::UtcNow.AddSeconds($seconds).ToString('o')} | ConvertTo-Json -Compress | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
    $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\LabCpuSimulation\windows-cpu.ps1 -Mode Worker'
    $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $seconds) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    # No trigger, no restart policy: deliberate Start only, never copied/reboot auto-resume.
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    $wait=[Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 250
        $observed=Get-CpuStatus
        if ($observed.healthy) { $observed; return }
    } while ($wait.Elapsed.TotalSeconds -lt 15)
    throw 'CPU start unverified; inspect Status before retrying'
} finally { if ($ownsControl) { $controlMutex.ReleaseMutex() }; $controlMutex.Dispose() }
