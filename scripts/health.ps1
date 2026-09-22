# Shared by the deployment client and the embedded Windows host payload.
# Progress is observational: a running process is not proof of workload health.
$script:LabProgress = $null

function Initialize-LabProgress {
    param([string]$Activity = 'Workshop installation', [string[]]$Steps = @(),
        [ValidateSet('Auto','Plain','Interactive')][string]$Mode = 'Auto', [switch]$EmitMarkers)
    $interactive = $Mode -eq 'Interactive'
    if ($Mode -eq 'Auto') {
        # Run Command, redirected logs and CI need durable text, not console control records.
        try {
            $interactive = $Host.Name -eq 'ConsoleHost' -and [Environment]::UserInteractive -and
                -not [Console]::IsOutputRedirected -and -not $env:CI -and
                $env:TERM -ne 'dumb' -and $env:CES_LAB_PROGRESS -ne 'plain' -and
                [string]$ProgressPreference -ne 'SilentlyContinue'
        } catch { $interactive = $false }
    }
    $script:LabProgress = @{ Activity=$Activity; Steps=$Steps; Interactive=$interactive; LastEvent=''; Active=$false;
        EmitMarkers=[bool]$EmitMarkers; Snapshot=$null; ProgressStyle=$null; PreviousView=$null }
}

function Complete-LabProgress {
    if ($null -ne $script:LabProgress -and $script:LabProgress.Active) {
        try { Write-Progress -Id 4700 -Activity $script:LabProgress.Activity -Completed -ErrorAction Stop }
        catch { $script:LabProgress.Interactive = $false }
        finally {
            if ($null -ne $script:LabProgress.ProgressStyle) {
                $script:LabProgress.ProgressStyle.View = $script:LabProgress.PreviousView
                $script:LabProgress.ProgressStyle = $null
            }
        }
        $script:LabProgress.Active = $false
    }
}

function Write-LabProgressDisplay {
    param([string]$Stage, [string]$State, [double]$ElapsedSeconds, [string]$Message,
        [int]$PercentComplete = -1, [int]$TimeoutSeconds = 0, [string]$EventKey = '',
        [ValidateSet('Normal','Warning')][string]$Tone = 'Normal')
    if ($null -eq $script:LabProgress) { Initialize-LabProgress }
    $display = $script:LabProgress
    $display.Snapshot = @{ Stage=$Stage; State=$State; ElapsedSeconds=$ElapsedSeconds; Message=$Message;
        PercentComplete=$PercentComplete; TimeoutSeconds=$TimeoutSeconds; EventKey=$EventKey; Tone=$Tone }
    $step = [array]::IndexOf($display.Steps, $Stage)
    $title = if ($step -ge 0) { "Step $($step + 1)/$($display.Steps.Count) - $Stage" } else { $Stage }
    $elapsed = [TimeSpan]::FromSeconds($ElapsedSeconds).ToString('hh\:mm\:ss')
    $status = "$State | elapsed $elapsed"
    if ($TimeoutSeconds -gt 0) { $status += " | limit $([TimeSpan]::FromSeconds($TimeoutSeconds).ToString('hh\:mm\:ss'))" }
    $terminal = $State -in @('Completed','Succeeded','NeedsReview','Failed','TimedOut','Canceled','Cancelled')
    $color = switch ($State) {
        { $_ -in @('Completed','Succeeded') } { 'Green'; break }
        { $_ -in @('NeedsReview','Failed','TimedOut','Canceled','Cancelled') } { 'Red'; break }
        { $_ -in @('StatusUnavailable','TransientError','Warning','Paused') } { 'Yellow'; break }
        default { 'Cyan' }
    }
    if ($Tone -eq 'Warning' -and -not $terminal) { $color = 'Yellow' }
    if ($display.Interactive) {
        if ($terminal) { Complete-LabProgress }
        else {
            try {
                # A time limit is not an ETA; step counts are not completion percentages.
                $display.Active = $true
                # Use the multiline Windows console view while active, then restore the user's view.
                # Unix console hosts can lack Classic's screen-buffer rendering; retain their native view.
                if ($null -eq $display.ProgressStyle -and [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    $styleVariable = Get-Variable -Name PSStyle -ErrorAction SilentlyContinue
                    if ($null -ne $styleVariable -and $null -ne $styleVariable.Value.PSObject.Properties['Progress']) {
                        $style = $styleVariable.Value.Progress
                        if ($null -ne $style.PSObject.Properties['View']) {
                            $display.PreviousView = $style.View
                            $display.ProgressStyle = $style
                            $style.View = 'Classic'
                        }
                    }
                }
                $paneStatus = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { $status } else { "$status | $Message" }
                Write-Progress -Id 4700 -Activity "$title | $($display.Activity)" -Status $paneStatus `
                    -CurrentOperation $Message -PercentComplete $PercentComplete -SecondsRemaining -1 -ErrorAction Stop
            } catch {
                Complete-LabProgress
                $display.Interactive = $false
            }
        }
    }
    $key = if ($EventKey) { "$Stage|$State|$Tone|$EventKey" } else { "$Stage|$State|$Tone|$Message" }
    if (-not $display.Interactive -or $key -cne $display.LastEvent) {
        $label = if ($Tone -eq 'Warning' -and -not $terminal) { "$State / Warning" } else { $State }
        $line = "[{0:HH:mm:ss}] [{1}] {2} | {3}. {4}" -f (Get-Date),$label,$title,$status,$Message
        if ($display.Interactive -and -not $env:NO_COLOR) { Write-Host $line -ForegroundColor $color }
        else { Write-Host $line }
        $display.LastEvent = $key
    }
}

function Wait-LabProgressDelay {
    param([int]$Seconds, [Diagnostics.Stopwatch]$Clock, $Job = $null, $Process = $null)
    $until = $Clock.Elapsed.TotalSeconds + $Seconds
    do {
        $slice = [int][math]::Max(1,[math]::Ceiling($until - $Clock.Elapsed.TotalSeconds))
        if ($null -ne $script:LabProgress -and $script:LabProgress.Interactive) { $slice = 1 }
        if ($null -ne $Job) {
            $null = Wait-Job -Job $Job -Timeout $slice
            if ([string]$Job.State -notin @('Running','NotStarted')) { return }
        } elseif ($null -ne $Process) {
            if ($Process.WaitForExit($slice * 1000)) { return }
        } else { Start-Sleep -Seconds $slice }
        if ($null -ne $script:LabProgress -and $script:LabProgress.Interactive -and $script:LabProgress.Active) {
            # Redraw the last observation locally. This does not poll Azure or renew its timestamp.
            $snapshot = $script:LabProgress.Snapshot.Clone()
            $snapshot.ElapsedSeconds = $Clock.Elapsed.TotalSeconds
            Write-LabProgressDisplay @snapshot
        }
    } while ($Clock.Elapsed.TotalSeconds -lt $until)
}

function Get-LabInstallStageNames {
    # Only these non-secret operation names can cross the Run Command output boundary.
    return @{
        adk='Install ADK'; chocolatey='Install Chocolatey'; qemu='Install QEMU'; ubuntu='Download Ubuntu image'
        'ubuntu-convert'='Convert Ubuntu image'; windows='Download Windows image'; 'windows-convert'='Convert Windows image'
        'disk-web'='Create OnPrem-Web disk'; 'disk-sql'='Create OnPrem-SQL disk'
        'disk-linux-web'='Create OnPrem-Linux-Web disk'; 'disk-linux-app'='Create OnPrem-Linux-App disk'
        'signin-web'='Sign in to OnPrem-Web'; 'signin-sql'='Sign in to OnPrem-SQL'
        iis='Install IIS sample'; sql='Install SQL sample'
    }
}

function Get-LabProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Write-LabHealth {
    param([string]$Stage, [string]$State, [double]$ElapsedSeconds, [string]$Message, [string]$Path = '',
        [ValidateRange(-1,100)][int]$PercentComplete = -1, [int]$TimeoutSeconds = 0, [string]$EventKey = '',
        [ValidateSet('Normal','Warning')][string]$Tone = 'Normal')
    $record = [ordered]@{ SchemaVersion=1; UpdatedUtc=[DateTimeOffset]::UtcNow.ToString('o'); Stage=$Stage;
        State=$State; ElapsedSeconds=[int]$ElapsedSeconds; Message=$Message }
    Write-LabProgressDisplay $Stage $State $ElapsedSeconds $Message -PercentComplete $PercentComplete -TimeoutSeconds $TimeoutSeconds -EventKey $EventKey -Tone $Tone
    if ($script:LabProgress.EmitMarkers -and $State -match '^[A-Za-z]{1,32}$') {
        $names = Get-LabInstallStageNames
        foreach ($key in $names.Keys) {
            if ($names[$key] -ceq $Stage) {
                # Never relay raw messages, arguments, URLs or error output to the client UI.
                Write-Host ("LAB_PROGRESS|{0}|{1}|{2}|{3}|{4}" -f $key,$State,$PercentComplete,
                    ([int][math]::Min(999999,[math]::Max(0,$ElapsedSeconds))),([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')))
                break
            }
        }
    }
    if ($Path) {
        # Only caller-supplied, non-secret stage/status summaries go in this file.
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($resolved))
        $temporary = $resolved + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        try {
            [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporary -Destination $resolved -Force -ErrorAction Stop
        } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
    }
}

function Wait-LabJob {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$Stage,
        [ValidateRange(1,18000)][int]$TimeoutSeconds = 3600,
        [ValidateRange(1,60)][int]$PollSeconds = 30, [string]$HealthPath = '')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ([string]$Job.State -notin @('Completed','Failed','Stopped','Suspended','Disconnected','Blocked')) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "$Stage exceeded its $TimeoutSeconds second limit. The underlying operation may still be running; inspect it before retrying." }
            Write-LabHealth $Stage ([string]$Job.State) $clock.Elapsed.TotalSeconds 'Waiting for the operation result.' $HealthPath -TimeoutSeconds $TimeoutSeconds
            $remaining = [math]::Max(1,[math]::Ceiling($TimeoutSeconds - $clock.Elapsed.TotalSeconds))
            Wait-LabProgressDelay -Seconds ([math]::Min($PollSeconds,$remaining)) -Clock $clock -Job $Job
        }
        if ([string]$Job.State -ne 'Completed') {
            try { $null = Receive-Job -Job $Job -ErrorAction Stop }
            catch { throw "$Stage failed: $($_.Exception.Message)" }
            throw "$Stage job ended in state $($Job.State). Inspect the Azure operation or host setup logs for the underlying error."
        }
        # A Completed job can still contain non-terminating PowerShell errors.
        $result = @(Receive-Job -Job $Job -ErrorAction Stop)
        Write-LabHealth $Stage Completed $clock.Elapsed.TotalSeconds 'Operation returned; its result is checked by the next validation.' $HealthPath
        return $result
    } catch {
        Write-LabHealth $Stage NeedsReview $clock.Elapsed.TotalSeconds 'Operation failed or exceeded its limit. Inspect service/host diagnostics before retrying.' $HealthPath
        throw
    } finally {
        Complete-LabProgress
        if ([string]$Job.State -notin @('Completed','Failed','Stopped')) { Stop-Job -Job $Job -ErrorAction SilentlyContinue }
        Remove-Job -Job $Job -Force -ErrorAction SilentlyContinue
    }
}

# Kept beside its only caller so this file stands alone: deploy-lab.ps1 dot-sources it
# after common.ps1, and configure-host.ps1 embeds it without common.ps1 at all.
function Assert-LabManagedRunResult {
    param([Parameter(Mandatory)]$InstanceView)
    if ($InstanceView.ExecutionState -ne 'Succeeded' -or $null -eq $InstanceView.ExitCode -or $InstanceView.ExitCode -ne 0 -or
        $InstanceView.Output -cnotmatch '(?m)^LAB_WORKLOADS_READY\r?$') {
        throw 'Guest setup did not pass. Inspect the managed Run Command instance view and C:\AzMigrateLab\setup-log.txt.'
    }
}

function Wait-LabManagedSetup {
    param([Parameter(Mandatory)][scriptblock]$ReadStatus, [Parameter(Mandatory)][hashtable]$Observation,
        [ValidateRange(1,18000)][int]$TimeoutSeconds = 15000,
        [ValidateRange(60,7200)][int]$StatusFailureSeconds = 900,
        [ValidateRange(1,3600)][int]$StartupSeconds = 900,
        [ValidateRange(1,60)][int]$PollSeconds = 30, [string]$HealthPath = '')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $unavailableSince = $null
    $readError = $null
    $started = $false
    $phase = 'Waiting for host phase information'
    $install = $null
    $Observation.Terminal = $false
    $phaseNames = @{network='Host networking';images='Downloading and converting images';guests='Creating nested VMs';
        boot='Guest first boot';workloads='Installing workloads';iis='Installing IIS';sql='Installing SQL';validation='Validating sample applications'}
    $installNames = Get-LabInstallStageNames
    try {
        while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $command = $null; $readFailed = $false
            try { $command = & $ReadStatus; $readError = $null }
            catch {
                $readFailed = $true
                # Never discard why the read failed. An expired token, a throttle and a
                # network fault all look identical without it, and only one of them is
                # worth waiting out.
                $readError = $_.Exception.Message
            }
            $view = Get-LabProperty $command InstanceView
            $provisioning = [string](Get-LabProperty $command ProvisioningState '')
            $execution = [string](Get-LabProperty $view ExecutionState '')
            if ($provisioning -in @('Failed','Canceled','Cancelled')) {
                # Extension provisioning failure does not prove that an already-started script stopped.
                throw "Guest setup provisioning reported $provisioning. Inspect ConfigureWorkshop and the VM agent now."
            }
            if ($execution -in @('Succeeded','Failed','TimedOut','Canceled','Cancelled')) {
                $Observation.Terminal = $true
                if ($execution -ne 'Succeeded') { throw "Guest setup reported $execution (exit code $(Get-LabProperty $view ExitCode 'unknown')). Inspect ConfigureWorkshop and C:\AzMigrateLab\setup-log.txt." }
                Assert-LabManagedRunResult $view
                Write-LabHealth 'Guest setup' Succeeded $clock.Elapsed.TotalSeconds 'All required workload evidence was returned.' $HealthPath
                return $view
            }
            if ($readFailed -or $null -eq $command -or ($started -and $execution -ne 'Running')) {
                if ($null -eq $unavailableSince) { $unavailableSince = $clock.Elapsed.TotalSeconds }
                # A sign-in failure does not heal by waiting: the token needs renewing, and
                # setup runs asynchronously on the host regardless. Say so at once rather
                # than after the full window.
                $authFailure = $readError -and ($readError -match '(?i)token|expired|authentication|unauthorized|credential|re-?authenticate|AADSTS|Connect-AzAccount')
                $reason = if ($readError) { " Azure reported: $readError" } else { '' }
                if ($authFailure -or ($clock.Elapsed.TotalSeconds - $unavailableSince) -ge $StatusFailureSeconds) {
                    $waited = if ($authFailure) { 'Azure sign-in is no longer valid' } else { "Setup status has been unavailable for $StatusFailureSeconds seconds" }
                    throw ("$waited, so monitoring has stopped. Guest setup runs asynchronously on the host and is almost certainly still going: it is not cancelled by this message.$reason Reconnect with Connect-AzAccount and Set-AzContext, then reattach with:" +
                        [Environment]::NewLine +
                        '  Get-AzVMRunCommand -ResourceGroupName <rg> -VMName HyperVHost -RunCommandName ConfigureWorkshop -Expand InstanceView' +
                        [Environment]::NewLine +
                        'or read C:\AzMigrateLab\setup-log.txt on the host. Do not redeploy until you have confirmed the run actually failed.')
                }
                Write-LabHealth 'Guest setup' StatusUnavailable $clock.Elapsed.TotalSeconds "Unable to read Azure status; retrying within the $StatusFailureSeconds second monitoring limit.$reason" $HealthPath -TimeoutSeconds $TimeoutSeconds
            } else {
                $unavailableSince = $null
                if ($execution -in @('Running','Succeeded')) { $started = $true }
                if (-not $started -and $clock.Elapsed.TotalSeconds -ge $StartupSeconds) { throw "Guest setup did not report Running within $StartupSeconds seconds. Check the VM agent and ConfigureWorkshop provisioning; the script may still start later." }
                $output = [string](Get-LabProperty $view Output '')
                $markers = [regex]::Matches($output, '(?m)^(?:LAB_STAGE\|(?<phase>[a-z]+)|LAB_PROGRESS\|(?<step>[a-z-]+)\|(?<state>[A-Za-z]{1,32})\|(?<percent>-?\d{1,3})\|(?<elapsed>\d{1,6})\|(?<updated>\d{8}T\d{6}Z))\r?$')
                foreach ($marker in $markers) {
                    $phaseKey = $marker.Groups['phase'].Value
                    if ($phaseNames.ContainsKey($phaseKey)) { $phase = $phaseNames[$phaseKey]; $install = $null; continue }
                    $stepKey = $marker.Groups['step'].Value
                    $stepState = $marker.Groups['state'].Value
                    if (-not $installNames.ContainsKey($stepKey) -or $stepState -notin @('Running','NotStarted','Queued','Connecting','Transferring','TransientError','Completed','NeedsReview')) { continue }
                    $percent = [int]$marker.Groups['percent'].Value
                    if ($percent -lt -1 -or $percent -gt 100) { continue }
                    $updated = [DateTime]::MinValue
                    if (-not [DateTime]::TryParseExact($marker.Groups['updated'].Value,'yyyyMMddTHHmmssZ',
                        [Globalization.CultureInfo]::InvariantCulture,([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal),[ref]$updated)) { continue }
                    $install = @{ Name=$installNames[$stepKey]; State=$stepState; Updated=$updated; Percent=-1 }
                    # Only BITS reports measurable byte progress; this is not overall setup percent.
                    if ($stepKey -eq 'ubuntu') { $install.Percent = $percent }
                }
                $state = if ($execution) { $execution } else { 'WaitingForInstanceView' }
                $detail = $phase
                $event = $phase
                $tone = 'Normal'
                if ($null -ne $install) {
                    $detail = "Last reported: $($install.Name) - $($install.State)"
                    if ($install.Percent -ge 0) { $detail += " ($($install.Percent)% of download)" }
                    $detail += "; host update $($install.Updated.ToString('HH:mm:ss')) UTC"
                    $event = "$($install.Name)|$($install.State)"
                    if ($install.State -in @('TransientError','NeedsReview')) { $tone = 'Warning' }
                }
                Write-LabHealth 'Guest setup' $state $clock.Elapsed.TotalSeconds "$detail. Azure output may be delayed." $HealthPath -TimeoutSeconds $TimeoutSeconds -EventKey $event -Tone $tone
            }
            Wait-LabProgressDelay -Seconds $PollSeconds -Clock $clock
        }
        throw "Guest setup exceeded its $TimeoutSeconds second monitoring limit. Inspect ConfigureWorkshop before retrying; the remote operation may still be running."
    } catch {
        Write-LabHealth 'Guest setup' NeedsReview $clock.Elapsed.TotalSeconds "$phase. Inspect ConfigureWorkshop instance view and the host setup log; no later stage will run." $HealthPath
        throw
    } finally { Complete-LabProgress }
}

function Invoke-LabDownload {
    param([string]$Uri, [string]$Destination, [string]$Stage,
        [ValidateRange(1,14400)][int]$TimeoutSeconds = 3600,
        [ValidateRange(1,3600)][int]$StallSeconds = 300,
        [ValidateRange(1,60)][int]$PollSeconds = 30)
    $transfer = Start-BitsTransfer -Source $Uri -Destination $Destination -Asynchronous -ErrorAction Stop
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $lastBytes = [long]0; $lastProgress = 0.0
    try {
        while ($true) {
            $transfer = Get-BitsTransfer -Id $transfer.JobId -ErrorAction Stop
            if ($transfer.JobState -eq 'Transferred') {
                Complete-BitsTransfer -BitsJob $transfer -ErrorAction Stop
                Write-LabHealth $Stage Completed $clock.Elapsed.TotalSeconds 'Download returned; checksum validation follows.' -PercentComplete 100
                return
            }
            if ($transfer.JobState -in @('Error','Cancelled','Acknowledged','Suspended')) { throw "$Stage transfer reported $($transfer.JobState). Inspect BITS and network access." }
            if ($transfer.BytesTransferred -gt $lastBytes) { $lastBytes = $transfer.BytesTransferred; $lastProgress = $clock.Elapsed.TotalSeconds }
            if ($clock.Elapsed.TotalSeconds - $lastProgress -ge $StallSeconds) { throw "$Stage transferred no additional bytes for $StallSeconds seconds. Check outbound connectivity before retrying." }
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw "$Stage exceeded its $TimeoutSeconds second download limit." }
            $total = [double](Get-LabProperty $transfer BytesTotal 0)
            $percent = -1
            if ($total -gt 0 -and $total -lt [double][uint64]::MaxValue) {
                $percent = [int][math]::Min(99,[math]::Floor(100 * $lastBytes / $total))
            }
            Write-LabHealth $Stage ([string]$transfer.JobState) $clock.Elapsed.TotalSeconds ("{0:N1} MiB downloaded; checksum validation follows." -f ($lastBytes / 1MB)) `
                -PercentComplete $percent -TimeoutSeconds $TimeoutSeconds -EventKey 'Download bytes'
            Wait-LabProgressDelay -Seconds $PollSeconds -Clock $clock
        }
    } catch {
        Write-LabHealth $Stage NeedsReview $clock.Elapsed.TotalSeconds 'Download failed or exceeded its limit. Inspect BITS and network access.'
        throw
    } finally {
        Complete-LabProgress
        # BITS jobs survive their creating PowerShell process unless completed/removed.
        if ($transfer.JobState -ne 'Acknowledged') { Remove-BitsTransfer -BitsJob $transfer -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

function Invoke-LabProcess {
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)][string]$LogDirectory,
        [ValidateRange(1,14400)][int]$TimeoutSeconds = 3600, [int[]]$SuccessCodes = @(0))
    $log = Join-Path $LogDirectory ('process-' + [guid]::NewGuid().ToString('N'))
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -ErrorAction Stop `
        -RedirectStandardOutput ($log + '.out.log') -RedirectStandardError ($log + '.err.log')
    # Windows PowerShell may return a process wrapper without an open handle.
    # Hold it before exit so the exit code remains available after termination.
    $null = $process.Handle
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $process.HasExited) {
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                # Stop this process tree, not unrelated installers or cloud resources.
                & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
                throw "$Stage exceeded its $TimeoutSeconds second limit. Inspect the host and installer logs before retrying."
            }
            Write-LabHealth $Stage Running $clock.Elapsed.TotalSeconds 'Waiting for the installer or tool to finish.' -TimeoutSeconds $TimeoutSeconds
            Wait-LabProgressDelay -Seconds ([int][math]::Min(30,[math]::Max(1,$TimeoutSeconds - $clock.Elapsed.TotalSeconds))) -Clock $clock -Process $process
        }
        # Ensure redirected streams are drained before checking the exit code.
        $process.WaitForExit()
        if ($process.ExitCode -notin $SuccessCodes) { throw "$Stage failed with exit code $($process.ExitCode). Inspect $log.*.log locally; redact credentials and URLs before sharing." }
        Write-LabHealth $Stage Completed $clock.Elapsed.TotalSeconds "Exit code $($process.ExitCode); the next check verifies the installed files/service."
    } catch {
        Write-LabHealth $Stage NeedsReview $clock.Elapsed.TotalSeconds 'Installer or tool failed or exceeded its limit. Inspect its local logs.'
        throw
    } finally { Complete-LabProgress; $process.Dispose() }
}
