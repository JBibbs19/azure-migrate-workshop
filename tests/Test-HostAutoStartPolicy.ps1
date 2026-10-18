# Offline native PowerShell regressions. No Pester, Hyper-V module, host-main execution or live VM calls.
[CmdletBinding()]
param([string]$HostScript = (Join-Path $PSScriptRoot '..\scripts\host\configure-host.ps1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    [IO.Path]::GetFullPath($HostScript), [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count) { throw ($parseErrors | Out-String) }
$functions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Set-LabSourceBootPolicy'
}, $true))
if ($functions.Count -ne 1) { throw 'Expected exactly one production boot-policy helper.' }
# Compile only the actual function definition, never dot-source or invoke the provisioning script.
. ([scriptblock]::Create($functions[0].Extent.Text))
$source = [IO.File]::ReadAllText([IO.Path]::GetFullPath($HostScript))
$tailStart = $source.LastIndexOf('# A download/verifier can take time:')
$marker = "Write-Output 'LAB_WORKLOADS_READY'"
$tailEnd = $source.IndexOf($marker, $tailStart)
if ($tailStart -lt 0 -or $tailEnd -lt $tailStart) { throw 'Missing actual final completion tail.' }
$tailText = $source.Substring($tailStart, $tailEnd + $marker.Length - $tailStart)
$script:completionTail = [scriptblock]::Create($tailText)

function Assert-Equal {
    param($Actual, $Expected, [string]$Message = '')
    if ($Actual -cne $Expected) { throw "$Message Expected <$Expected>; actual <$Actual>." }
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-Failure {
    param([scriptblock]$Action)
    try { & $Action | Out-Null } catch { return $_.Exception.Message }
    throw 'Expected failure, but the action succeeded.'
}
function Reset-Mocks {
    $script:store = @{}; $script:original = @{}
    $script:desired = [ordered]@{ 'OnPrem-SQL' = 30; 'OnPrem-Linux-App' = 60; 'OnPrem-Linux-Web' = 90; 'OnPrem-Web' = 120 }
    $delay = 3
    foreach ($name in $script:desired.Keys) {
        $vm = [pscustomobject]@{ Name = $name; Id = [guid]::NewGuid(); State = 'Running';
            AutomaticStartAction = 'Nothing'; AutomaticStartDelay = $delay; AutomaticStopAction = 'Save' }
        if ($name -ceq 'OnPrem-SQL') { $vm.AutomaticStartAction = 'StartIfRunning' }
        $script:store[$name] = $vm
        $script:original[$name] = $vm | Select-Object *
        $delay += 4
    }
    $script:store['Unrelated-Appliance'] = [pscustomobject]@{ Name = 'Unrelated-Appliance'; Id = [guid]::NewGuid();
        State = 'Off'; AutomaticStartAction = 'Nothing'; AutomaticStartDelay = 0; AutomaticStopAction = 'ShutDown' }
    $script:writes = [Collections.Generic.List[object]]::new()
    $script:events = [Collections.Generic.List[string]]::new()
    $script:logs = [Collections.Generic.List[string]]::new()
    $script:contentWrites = [Collections.Generic.List[string]]::new()
    $script:preflightFault = ''; $script:readbackFault = ''; $script:readbackFaultFired = $false
    $script:setFault = ''; $script:setFaultName = 'OnPrem-Linux-App'; $script:setFaultFired = $false
    $script:rollbackFault = ''; $script:rollbackFaultName = 'OnPrem-SQL'; $script:rollbackPhase = $false
    $script:guestReady = $true; $script:workloadsReady = $true
    $script:hostPrep = [ordered]@{}; $script:labRoot = 'MockLabRoot'
    $script:allVMs = @('OnPrem-Web', 'OnPrem-SQL', 'OnPrem-Linux-Web', 'OnPrem-Linux-App')
    $script:WorkshopTitle = 'Mock workshop'; $script:trafficScriptPath = 'MockTraffic.ps1'
}
function Write-Log {
    param([string]$Message)
    $script:logs.Add($Message)
}
function Get-VM {
    [CmdletBinding()]
    param([string]$Name, [guid]$Id)
    if ($PSBoundParameters.ContainsKey('Name')) {
        if ($Name -match '[*?\[\]]' -or -not $script:desired.Contains($Name)) { throw 'Unexpected/wildcard name lookup.' }
        $script:events.Add("get-name:$Name")
        $vm = $script:store[$Name] | Select-Object *
        if ($Name -ceq 'OnPrem-Linux-App') {
            switch ($script:preflightFault) {
                'Missing' { return }
                'Duplicate' { return @($vm, ($vm | Select-Object *)) }
                'WrongCase' { $vm.Name = 'onprem-linux-app' }
                'WrongName' { $vm.Name = 'Unrelated-Appliance' }
                'Off' { $vm.State = 'Off' }
                'Saved' { $vm.State = 'Saved' }
                'DuplicateId' { $vm.Id = $script:store['OnPrem-SQL'].Id }
                'EmptyId' { $vm.Id = [guid]::Empty }
                'NullId' { $vm.Id = $null }
                'ReadError' { throw 'Injected preflight read failure.' }
            }
        }
        return $vm
    }
    if (-not $PSBoundParameters.ContainsKey('Id')) { throw 'Unscoped VM lookup forbidden.' }
    $script:events.Add("get-id:$Id")
    $found = @($script:store.Values | Where-Object { $_.Id -eq $Id })
    if ($found.Count -eq 0) { return }
    $vm = $found[0] | Select-Object *
    if ($script:rollbackPhase -and $vm.Name -ceq $script:rollbackFaultName -and $script:rollbackFault -ceq 'ReadError') {
        throw 'Injected rollback read failure.'
    }
    if (-not $script:rollbackPhase -and -not $script:readbackFaultFired -and $script:readbackFault) {
        $script:readbackFaultFired = $true
        switch ($script:readbackFault) {
            'ReadError' { throw 'Injected verification read failure.' }
            'Missing' { return }
            'Duplicate' { return @($vm, ($vm | Select-Object *)) }
            'WrongId' { $vm.Id = [guid]::NewGuid() }
            'WrongName' { $vm.Name = 'Unrelated-Appliance' }
            'WrongCase' { $vm.Name = $vm.Name.ToLowerInvariant() }
            'Off' { $script:store[$vm.Name].State = 'Off'; $vm.State = 'Off' }
            'WrongAction' { $vm.AutomaticStartAction = 'StartIfRunning' }
            'WrongDelay' { $vm.AutomaticStartDelay = 999 }
            'Replacement' {
                $script:store[$vm.Name].Id = [guid]::NewGuid()
                $script:store[$vm.Name].AutomaticStartAction = 'Nothing'
                return
            }
        }
    }
    return $vm
}
function Set-VM {
    [CmdletBinding()]
    param($VM, [string]$AutomaticStartAction, [int]$AutomaticStartDelay)
    $found = @($script:store.Values | Where-Object { $_.Id -eq $VM.Id })
    $isArm = $AutomaticStartAction -ceq 'Start' -and $AutomaticStartDelay -eq $script:desired[$VM.Name]
    $script:writes.Add([pscustomobject]@{ Name = $VM.Name; Id = $VM.Id; Action = $AutomaticStartAction;
        Delay = $AutomaticStartDelay; IsArm = $isArm })
    $script:events.Add("set:$($VM.Name):$AutomaticStartAction")
    if ($found.Count -ne 1) { throw 'Saved VM identity no longer exists; refusing replacement.' }
    if ($ErrorActionPreference -cne 'Stop') { throw 'Every policy write must use ErrorAction Stop.' }
    $actual = $found[0]
    if (-not $isArm) {
        $script:rollbackPhase = $true
        if ($VM.Name -ceq $script:rollbackFaultName) {
            if ($script:rollbackFault -ceq 'Throw') { throw 'Injected rollback write failure.' }
            if ($script:rollbackFault -ceq 'Ignore') { return }
        }
    }
    $inject = $isArm -and -not $script:setFaultFired -and $VM.Name -ceq $script:setFaultName -and $script:setFault
    if ($inject) { $script:setFaultFired = $true }
    if ($inject -and $script:setFault -ceq 'Before') { throw 'Injected set failure before mutation.' }
    $actual.AutomaticStartAction = $AutomaticStartAction
    $actual.AutomaticStartDelay = $AutomaticStartDelay
    if ($inject -and $script:setFault -ceq 'After') { throw 'Injected set failure after mutation.' }
}
function Assert-LabGuestCommunication {
    $script:events.Add('ready:guest')
    if (-not $script:guestReady) { throw 'Injected guest communication readiness failure.' }
    foreach ($name in $script:desired.Keys) { [pscustomobject]@{ Name = $name; Ready = $true } }
}
function Assert-LabSourceWorkloads {
    $script:events.Add('ready:workloads')
    if (-not $script:workloadsReady) { throw 'Injected source workload readiness failure.' }
}
function Set-Content {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Path, [Parameter(ValueFromPipeline)]$Value, [string]$Encoding)
    process {
        $script:events.Add("file:$Path")
        $script:contentWrites.Add($Path)
    }
}
function Start-VM { throw 'VM power writes forbidden in boot-policy helper/tail.' }
function Stop-VM { throw 'VM power writes forbidden in boot-policy helper/tail.' }
function Restart-VM { throw 'VM power writes forbidden in boot-policy helper/tail.' }
function Restart-Computer { throw 'Host reboot forbidden.' }
function Restart-Service { throw 'Service restart forbidden.' }
function Register-ScheduledTask { throw 'New scheduled tasks forbidden.' }
function Assert-OriginalPolicies {
    foreach ($name in $script:desired.Keys) {
        Assert-Equal $script:store[$name].AutomaticStartAction $script:original[$name].AutomaticStartAction $name
        Assert-Equal $script:store[$name].AutomaticStartDelay $script:original[$name].AutomaticStartDelay $name
        Assert-Equal $script:store[$name].AutomaticStopAction $script:original[$name].AutomaticStopAction $name
    }
}
function Assert-NoCompletion {
    Assert-Equal $script:contentWrites.Count 0 'Readiness/policy failure must prevent completion writes.'
}
$script:passed = 0; $script:failures = [Collections.Generic.List[string]]::new()
function Invoke-Test {
    param([string]$Name, [scriptblock]$Test)
    Reset-Mocks
    try {
        & $Test
        $script:passed++
        Write-Host "PASS $Name"
    } catch {
        $script:failures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "FAIL ${Name}: $($_.Exception.Message)"
    }
}

Invoke-Test 'Definition alone never arms any VM' {
    Assert-Equal $script:writes.Count 0
    Assert-OriginalPolicies
}
Invoke-Test 'Success changes exactly four actual VMs and returns verified rows' {
    $rows = @(Set-LabSourceBootPolicy)
    Assert-Equal $rows.Count 4
    Assert-Equal $script:writes.Count 4
    foreach ($row in $rows) {
        Assert-Equal $row.Action 'Start'; Assert-Equal $row.DelaySeconds $script:desired[$row.Name]
        Assert-Equal $row.State 'Running'
        Assert-Equal $script:store[$row.Name].AutomaticStopAction 'Save'
    }
    Assert-Equal $script:store['Unrelated-Appliance'].AutomaticStartAction 'Nothing'
    Assert-Equal $script:store['Unrelated-Appliance'].State 'Off'
    Assert-True ($script:logs[-1] -match 'future host boots, not RDP') 'Missing honest policy summary.'
}
Invoke-Test 'All preflight reads precede all writes; all final reads follow all writes' {
    Set-LabSourceBootPolicy | Out-Null
    Assert-Equal (($script:events.GetRange(0, 4) | Where-Object { $_ -like 'get-name:*' }).Count) 4
    Assert-Equal (($script:events.GetRange(4, 4) | Where-Object { $_ -like 'set:*' }).Count) 4
    Assert-Equal (($script:events.GetRange(8, 4) | Where-Object { $_ -like 'get-id:*' }).Count) 4
}
Invoke-Test 'Already-correct policy is verified without a write' {
    foreach ($name in $script:desired.Keys) {
        $script:store[$name].AutomaticStartAction = 'Start'
        $script:store[$name].AutomaticStartDelay = $script:desired[$name]
    }
    $rows = @(Set-LabSourceBootPolicy)
    Assert-Equal $rows.Count 4; Assert-Equal $script:writes.Count 0
    Assert-Equal $script:events.Count 8
}
Invoke-Test 'Missing preflight VM causes zero writes' {
    $script:preflightFault = 'Missing'; Get-Failure { Set-LabSourceBootPolicy } | Out-Null
    Assert-Equal $script:writes.Count 0; Assert-OriginalPolicies
}
Invoke-Test 'Ambiguous preflight VM causes zero writes' {
    $script:preflightFault = 'Duplicate'; Get-Failure { Set-LabSourceBootPolicy } | Out-Null
    Assert-Equal $script:writes.Count 0; Assert-OriginalPolicies
}
Invoke-Test 'Wrong-case or wrong-name preflight VM is never adopted' {
    foreach ($fault in @('WrongCase', 'WrongName')) {
        Reset-Mocks; $script:preflightFault = $fault
        Get-Failure { Set-LabSourceBootPolicy } | Out-Null; Assert-Equal $script:writes.Count 0
    }
}
Invoke-Test 'Off or Saved preflight VM remains untouched' {
    foreach ($fault in @('Off', 'Saved')) {
        Reset-Mocks; $script:preflightFault = $fault
        Get-Failure { Set-LabSourceBootPolicy } | Out-Null
        Assert-Equal $script:writes.Count 0; Assert-OriginalPolicies
    }
}
Invoke-Test 'Duplicate null or empty identity causes zero writes' {
    foreach ($fault in @('DuplicateId', 'NullId', 'EmptyId')) {
        Reset-Mocks; $script:preflightFault = $fault
        Get-Failure { Set-LabSourceBootPolicy } | Out-Null
        Assert-Equal $script:writes.Count 0; Assert-OriginalPolicies
    }
}
Invoke-Test 'Preflight read error causes zero writes' {
    $script:preflightFault = 'ReadError'; Get-Failure { Set-LabSourceBootPolicy } | Out-Null
    Assert-Equal $script:writes.Count 0; Assert-OriginalPolicies
}
Invoke-Test 'Partial set failure restores attempted policies in reverse order' {
    $script:setFault = 'Before'
    $message = Get-Failure { Set-LabSourceBootPolicy }
    Assert-True ($message -match 'Prior policies restored for all 2 attempted changes') 'Restoration not reported.'
    Assert-Equal $script:writes.Count 4
    Assert-Equal $script:writes[2].Name 'OnPrem-Linux-App'
    Assert-Equal $script:writes[3].Name 'OnPrem-SQL'
    Assert-OriginalPolicies
}
Invoke-Test 'Mutation then throw restores the failed attempted write too' {
    $script:setFault = 'After'
    Get-Failure { Set-LabSourceBootPolicy } | Out-Null
    Assert-Equal $script:writes.Count 4; Assert-OriginalPolicies
}
Invoke-Test 'Verification read exception restores all four original policies' {
    $script:readbackFault = 'ReadError'
    Get-Failure { Set-LabSourceBootPolicy } | Out-Null
    Assert-Equal $script:writes.Count 8; Assert-OriginalPolicies
}
Invoke-Test 'Missing or ambiguous verification result restores all four' {
    foreach ($fault in @('Missing', 'Duplicate')) {
        Reset-Mocks; $script:readbackFault = $fault
        Get-Failure { Set-LabSourceBootPolicy } | Out-Null
        Assert-Equal $script:writes.Count 8; Assert-OriginalPolicies
    }
}
Invoke-Test 'Verification rejects identity and exact-name mismatch' {
    foreach ($fault in @('WrongId', 'WrongName', 'WrongCase')) {
        Reset-Mocks; $script:readbackFault = $fault
        Get-Failure { Set-LabSourceBootPolicy } | Out-Null
        Assert-Equal $script:writes.Count 8; Assert-OriginalPolicies
    }
}
Invoke-Test 'Verification rejects StartIfRunning or wrong delay' {
    foreach ($fault in @('WrongAction', 'WrongDelay')) {
        Reset-Mocks; $script:readbackFault = $fault
        Get-Failure { Set-LabSourceBootPolicy } | Out-Null
        Assert-Equal $script:writes.Count 8; Assert-OriginalPolicies
    }
}
Invoke-Test 'State change blocks completion without a power-state rollback' {
    $script:readbackFault = 'Off'
    Get-Failure { Set-LabSourceBootPolicy } | Out-Null
    Assert-OriginalPolicies; Assert-Equal $script:store['OnPrem-SQL'].State 'Off'
}
Invoke-Test 'Unchanged prior correct policy is not rewritten during rollback' {
    $script:store['OnPrem-SQL'].AutomaticStartAction = 'Start'
    $script:store['OnPrem-SQL'].AutomaticStartDelay = 30
    $script:readbackFault = 'WrongDelay'
    Get-Failure { Set-LabSourceBootPolicy } | Out-Null
    Assert-Equal (@($script:writes | Where-Object { $_.Name -ceq 'OnPrem-SQL' }).Count) 0
    Assert-Equal $script:store['OnPrem-SQL'].AutomaticStartAction 'Start'
    Assert-Equal $script:store['OnPrem-SQL'].AutomaticStartDelay 30
}
Invoke-Test 'Rollback write failure is explicitly incomplete, with no success claim' {
    $script:setFault = 'After'; $script:rollbackFault = 'Throw'
    $message = Get-Failure { Set-LabSourceBootPolicy }
    Assert-True ($message -match 'Rollback incomplete for: OnPrem-SQL') 'Incomplete rollback hidden.'
    Assert-True ($message -notmatch 'Prior policies restored') 'False restoration claim.'
    Assert-True ((($script:logs | Where-Object { $_ -like 'WARNING:*' }) -join ';') -match 'OnPrem-SQL') 'Missing rollback warning.'
}
Invoke-Test 'Rollback ignored write is detected by restoration readback' {
    $script:setFault = 'After'; $script:rollbackFault = 'Ignore'
    $message = Get-Failure { Set-LabSourceBootPolicy }
    Assert-True ($message -match 'Rollback incomplete for: OnPrem-SQL') 'Unverified restoration accepted.'
}
Invoke-Test 'Rollback read failure is explicitly incomplete' {
    $script:setFault = 'After'; $script:rollbackFault = 'ReadError'
    $message = Get-Failure { Set-LabSourceBootPolicy }
    Assert-True ($message -match 'Rollback incomplete for: OnPrem-SQL') 'Rollback read failure hidden.'
}
Invoke-Test 'Replacement same-name VM is never targeted by rollback' {
    $oldId = $script:store['OnPrem-SQL'].Id; $script:readbackFault = 'Replacement'
    $message = Get-Failure { Set-LabSourceBootPolicy }
    Assert-True ($message -match 'Rollback incomplete for: OnPrem-SQL') 'Disappeared identity not reported.'
    Assert-Equal $script:store['OnPrem-SQL'].AutomaticStartAction 'Nothing'
    foreach ($write in @($script:writes | Where-Object { $_.Name -ceq 'OnPrem-SQL' })) { Assert-Equal $write.Id $oldId }
}
Invoke-Test 'Actual final tail arms only after both readiness gates and before files/marker' {
    Assert-Equal $script:writes.Count 0
    $output = @(& $script:completionTail)
    Assert-Equal $script:events[0] 'ready:guest'; Assert-Equal $script:events[1] 'ready:workloads'
    Assert-Equal $script:contentWrites.Count 2
    Assert-Equal $script:contentWrites[0] 'MockLabRoot\hyperv-prep.json'
    Assert-Equal $script:contentWrites[1] 'MockLabRoot\setup-complete.json'
    Assert-Equal $output.Count 1; Assert-Equal $output[0] 'LAB_WORKLOADS_READY'
    Assert-Equal $script:hostPrep['AutomaticStartPolicy'].Count 4
    Assert-Equal $script:events[14] 'file:MockLabRoot\hyperv-prep.json'
    Assert-Equal $script:events[15] 'file:MockLabRoot\setup-complete.json'
}
Invoke-Test 'Actual tail guest-readiness failure never arms or completes' {
    $script:guestReady = $false
    Get-Failure { & $script:completionTail } | Out-Null
    Assert-Equal $script:writes.Count 0; Assert-NoCompletion; Assert-OriginalPolicies
}
Invoke-Test 'Actual tail workload-readiness failure never arms or completes' {
    $script:workloadsReady = $false
    Get-Failure { & $script:completionTail } | Out-Null
    Assert-Equal $script:writes.Count 0; Assert-NoCompletion; Assert-OriginalPolicies
}
Invoke-Test 'Actual tail failed partial/resumed guest preflight never arms or completes' {
    $script:preflightFault = 'Saved'
    Get-Failure { & $script:completionTail } | Out-Null
    Assert-Equal $script:writes.Count 0; Assert-NoCompletion; Assert-OriginalPolicies
}
Invoke-Test 'Actual tail set failure restores policies and suppresses completion' {
    $script:setFault = 'After'
    Get-Failure { & $script:completionTail } | Out-Null
    Assert-NoCompletion; Assert-OriginalPolicies
}
Invoke-Test 'Actual tail readback failure restores policies and suppresses completion' {
    $script:readbackFault = 'WrongDelay'
    Get-Failure { & $script:completionTail } | Out-Null
    Assert-NoCompletion; Assert-OriginalPolicies
}
Invoke-Test 'Actual tail rollback failure suppresses completion and reports inspection required' {
    $script:setFault = 'After'; $script:rollbackFault = 'Throw'
    $message = Get-Failure { & $script:completionTail }
    Assert-NoCompletion
    Assert-True ($message -match 'inspect these VM policies before any host reboot') 'Inspection requirement missing.'
}

Write-Host "Native mocked boot-policy regressions: $script:passed passed, $($script:failures.Count) failed."
if ($script:failures.Count) { throw ($script:failures -join [Environment]::NewLine) }
