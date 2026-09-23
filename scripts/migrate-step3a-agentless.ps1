<#
.SYNOPSIS
    Bridge the lab to the end state of Module 2 (agentless migration).

.DESCRIPTION
    This is a STATE-BRIDGING script, not a teaching script. It performs the
    same lab actions a student performs by hand in Module 2, in one run, for
    that module's two workloads only:

      - OnPrem-Web       (Windows Server + IIS)
      - OnPrem-Linux-Web (Ubuntu + Nginx)

    It runs three existing scripts in order, each narrowed with -Workload Agentless:

      1. migrate-step3-replicate.ps1     -- enable replication
      2. migrate-step4-test-migrate.ps1  -- test migrate, validate, clean up
      3. migrate-step5-cutover.ps1       -- cut over to Azure

    The migration logic is NOT duplicated here. This script only sequences
    those three with a consistent workload filter, so there is one command
    per module.

    WHO THIS IS FOR

    - Instructors who need the lab to match the module a student is on, so
      they can troubleshoot from the same state.
    - Students who had to delete a project for time or quota reasons and need
      to return to a known state without redoing every manual step.

    WHEN TO RUN IT

    Modules 2 and 3 are PARALLEL branches off Module 1 -- Module 3's
    prerequisites list Module 1, not Module 2. Run only the branch you need:

    - Did Module 2 by hand, need Module 3's end state?  Run step3b only.
    - Need both branches complete (Module 5 ready)?     Run step3a then step3b.

    PREREQUISITES

    - migrate-step1-setup-project.ps1 and migrate-step2-discover-assess.ps1
      completed: the project exists and all four VMs are discovered.
    - Connected to Azure (Connect-AzAccount). These scripts read the
      subscription from Get-AzContext; there is no -SubscriptionId parameter.

    WHAT THIS DOES NOT DO

    It does not replace reading Module 2. Cutover shuts the source VMs down on
    the Hyper-V host, so running this forecloses doing Module 2 by hand
    afterwards -- the work is already done.

.PARAMETER SourceResourceGroup
    Resource group holding the Hyper-V host and the nested VMs. Prompted when not supplied.

.PARAMETER TargetResourceGroup
    Resource group the migrated VMs land in.

.PARAMETER MigrateProjectName
    The Azure Migrate project created by step 1.

.PARAMETER Location
    Azure region. Must match the region used in step 1. Prompted when not supplied.

.PARAMETER SkipTestMigration
    Skip the test-migration stage (step 4). Test migration is a safety net and
    is pedagogically important, so it runs by default. Skipping it shortens the
    run and avoids creating temporary test VMs, which can matter on a
    restricted training subscription -- but it also skips the validation that
    would catch a bad replica before cutover.

.EXAMPLE
    .\migrate-step3a-agentless.ps1

.EXAMPLE
    .\migrate-step3a-agentless.ps1 -SkipTestMigration

.NOTES
    Reaches Module 2's END STATE. Module 2 is agentless throughout, so this script's method matches the module exactly.
#>

param(
    [string]$SourceResourceGroup,

    [string]$TargetResourceGroup,

    [string]$MigrateProjectName,

    [string]$Location,

    [Parameter(Mandatory = $false)]
    [switch]$SkipTestMigration
)

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Shared helpers: every value is entered once here (no silent defaults) and passed to each
# stage, so the stages do not prompt again. Subscription and tenant IDs are truncated in output.
. (Join-Path $scriptRoot 'common.ps1')
. (Join-Path $scriptRoot 'migrate-common.ps1')
$null = Enable-LabOutputMasking
trap { Write-LabTerminatingError $_; exit 1 }

Write-Host ""
Write-Host "Enter the values for your lab environment (examples are hints only; Enter does not accept them)." -ForegroundColor Cyan
$SourceResourceGroup = Read-LabParameter -Name 'SourceResourceGroup' -Value $SourceResourceGroup -Kind ResourceGroup -Prompt 'Source resource group (contains HyperVHost)' -Example 'rg-ces-source-01'
$TargetResourceGroup = Read-LabParameter -Name 'TargetResourceGroup' -Value $TargetResourceGroup -Kind ResourceGroup -Prompt 'Target resource group (landing zone for migrated VMs)' -Example 'rg-ces-target-01'
$MigrateProjectName = Read-LabParameter -Name 'MigrateProjectName' -Value $MigrateProjectName -Kind ProjectName -Prompt 'Azure Migrate project name' -Example 'ces-migrate-01'
$Location = Read-LabParameter -Name 'Location' -Value $Location -Kind Region -Prompt 'Azure target region used in step 1' -Example 'eastus'

$workload = "Agentless"
$targetModule = "Module 2"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Bridging lab state to the end of $targetModule" -ForegroundColor Cyan
Write-Host "  Workload group: $workload" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  This runs replicate -> test -> cutover for:" -ForegroundColor White
Write-Host "    - OnPrem-Web       (Windows Server + IIS)" -ForegroundColor White
Write-Host "    - OnPrem-Linux-Web (Ubuntu + Nginx)" -ForegroundColor White
Write-Host ""
Write-Host "  Cutover SHUTS DOWN the matching source VMs on the Hyper-V host." -ForegroundColor Yellow
Write-Host ""

# Confirm before doing anything destructive.
$confirm = Read-Host "Continue? (yes/no)"
if ($confirm -ne "yes") {
    Write-Host "Aborted. No changes made." -ForegroundColor Yellow
    return
}

# Common arguments passed to each stage.
$common = @{
    SourceResourceGroup = $SourceResourceGroup
    TargetResourceGroup = $TargetResourceGroup
    MigrateProjectName  = $MigrateProjectName
    Location            = $Location
    Workload            = $workload
}

function Invoke-LabStage {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][hashtable]$Arguments
    )

    $path = Join-Path $scriptRoot $ScriptName
    if (-not (Test-Path $path)) {
        throw "Required script not found: $path"
    }

    Write-Host ""
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  $Description" -ForegroundColor White
    Write-Host "  ($ScriptName)" -ForegroundColor DarkGray
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray

    $global:LASTEXITCODE = 0   # strict mode: make sure it is defined before the check below
    & $path @Arguments

    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "$ScriptName exited with code $LASTEXITCODE. Stopping before the next stage."
    }
}

Invoke-LabStage -ScriptName "migrate-step3-replicate.ps1" `
                -Description "Stage 1 of 3 - Enable replication" `
                -Arguments $common

if ($SkipTestMigration) {
    Write-Host ""
    Write-Host "  Skipping test migration (-SkipTestMigration)." -ForegroundColor Yellow
    Write-Host "  Cutover will proceed without a validated test failover." -ForegroundColor Yellow
} else {
    Invoke-LabStage -ScriptName "migrate-step4-test-migrate.ps1" `
                    -Description "Stage 2 of 3 - Test migration and cleanup" `
                    -Arguments $common
}

$cutoverArgs = $common.Clone()
$cutoverArgs["TurnOffSourceVMs"] = "Yes"
Invoke-LabStage -ScriptName "migrate-step5-cutover.ps1" `
                -Description "Stage 3 of 3 - Cutover to Azure" `
                -Arguments $cutoverArgs

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Lab state now matches the end of $targetModule." -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Next: Module 3 by hand, or migrate-step3b-agent-based.ps1 to bridge it." -ForegroundColor White
Write-Host ""
