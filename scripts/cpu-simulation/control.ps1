# Dot-sourced by enable-lab-traffic.ps1; shares its protected PS Direct/SSH transports.
function Show-LabCpuNotice {
    Write-Host 'Optional CPU Simulation: UTC 06:00-22:00 day (~15% TOTAL guest CPU), 22:00-06:00 night (~2%); no peaks.' -ForegroundColor Yellow
    Write-Host 'One low-priority CPU-only worker per guest; measured application load reduces simulation. At >=30% total CPU it rests; resume requires <20% and a 60-second cooldown. This cannot cap real application CPU.'
    Write-Host 'No additional VM, VM size or paid service is created. CPU activity on existing fixed-price VMs has no separate charge; extending uptime for capture continues normal lab charges.'
    Write-Host 'Allow a complete 24-hour capture for the full day/night profile (or the longer selected history), then use/recalculate a performance-based portal assessment. Earlier data can be partial; no recommendation change is guaranteed. Step 2 AsOnPremises does not use CPU history.'
    Write-Host 'Default expiry: 24 hours (configurable 1-168). No reboot auto-resume. Repeated Start never extends a deadline; use -RenewCpu explicitly.'
}
function Invoke-RequestedCpuStart {
    if ($CpuSimulation -eq 'Skip') { return }
    Show-LabCpuNotice
    if ($CpuSimulation -eq 'Prompt') {
        if ($NonInteractive) { return }
        $answer=Read-Host 'Would you like to turn on optional CPU Simulation? [y/N]'
        if ($answer -notmatch '^(?i:y|yes)$') { Write-Host 'CPU Simulation not initiated; existing CPU workers are unchanged.'; return }
    }
    try { Invoke-LabCpuSimulation -Action Start }
    catch { Write-Warning 'CPU startup unverified; network outcome is unchanged. Inspect CPU-only Status/Stop.'; Write-Output 'LAB_CPU_PARTIAL_OR_FAILED' }
}
function Invoke-LabCpuSimulation {
    param([ValidateSet('Start','Status','Stop')][string]$Action)
    $windows = Get-Content (Join-Path $cpuAssetsPath 'windows-cpu.ps1') -Raw -Encoding UTF8 -ErrorAction Stop
    $linux = Get-Content (Join-Path $cpuAssetsPath 'linux-cpu.py') -Raw -Encoding UTF8 -ErrorAction Stop
    $confirmed = 0
    foreach ($name in @('OnPrem-Web','OnPrem-SQL')) {
        try {
            $result = Invoke-Command -VMName $name -Credential $credential -ErrorAction Stop -ScriptBlock {
                param($Text,$Action,$Hours,$Renew)
                $ErrorActionPreference='Stop'
                if ($Action -eq 'Start') {
                    $root='C:\LabCpuSimulation'
                    New-Item -ItemType Directory -Path $root -Force | Out-Null
                    & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw 'CPU asset ACL failed' }
                    [IO.File]::WriteAllText((Join-Path $root 'windows-cpu.ps1'),$Text,[Text.UTF8Encoding]::new($false))
                }
                & ([scriptblock]::Create($Text)) -Mode $Action -DurationHours $Hours -Renew:$Renew
            } -ArgumentList $windows,$Action,$CpuDurationHours,[bool]$RenewCpu
            if ($Action -eq 'Start' -and ($null -eq $result -or -not $result.healthy)) { throw 'CPU start unverified' }
            if ($Action -eq 'Stop' -and ($null -eq $result -or $null -ne $result.pid -or $result.task.exists)) { throw 'CPU stop unverified' }
            Write-Host ($name + ' CPU: ' + ($result | ConvertTo-Json -Depth 6 -Compress))
            $confirmed++
        } catch { Write-Warning "$name CPU $Action unverified; inspect CPU-only Status/Stop. No application services were changed; no raw error recorded." }
    }
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($linux -replace "`r`n","`n")))
    $renewArg=''; if ($RenewCpu) { $renewArg=' --renew' }
    $install=''
    if ($Action -eq 'Start') {
        $install="install -d -m 0755 /opt/lab-cpu-simulation`nprintf '%s' '$encoded' | base64 -d > /opt/lab-cpu-simulation/linux-cpu.py`nchmod 0644 /opt/lab-cpu-simulation/linux-cpu.py`n"
    }
    # Status/Stop execute the reviewed controller in memory: no installed asset is required.
    $payload="set -e`n"+$install+"python3 -c `"import base64; exec(compile(base64.b64decode('$encoded'), '<cpu-control>', 'exec'))`" --mode $Action --duration-hours $CpuDurationHours$renewArg"
    foreach ($guest in @(@{Name='OnPrem-Linux-Web';Address=$labHosts['onprem-nginx']},@{Name='OnPrem-Linux-App';Address=$labHosts['onprem-app']})) {
        try {
            if (Invoke-LabLinuxPayload -VMName ($guest.Name + '-cpu') -Address $guest.Address -Payload $payload -Marker 'LAB_CPU_CONFIRMED') { $confirmed++ }
        } catch { Write-Warning "$($guest.Name) CPU $Action unverified; inspect guest-local state. No raw error recorded." }
    }
    if ($Action -eq 'Start') {
        if ($confirmed -eq 4) { Write-Output 'LAB_CPU_FULLY_STARTED' }
        else { Write-Output 'LAB_CPU_PARTIAL_OR_FAILED' }
    } elseif ($confirmed -eq 4) { Write-Output ('LAB_CPU_' + $Action.ToUpperInvariant() + '_CONFIRMED') }
    else { Write-Output 'LAB_CPU_PARTIAL_OR_FAILED' }
}
