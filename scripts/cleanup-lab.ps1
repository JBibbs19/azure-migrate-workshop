<#
.SYNOPSIS
    Removes one Azure Migrate Workshop lab resource group.

.DESCRIPTION
    Lists what is in the named resource group, confirms, deletes the group and everything in
    it, then reports what went and what is left behind elsewhere.

    The lab uses TWO resource groups - a source group for the Hyper-V host and a target group
    for the migrated VMs. This script takes one at a time, so run it twice.

.PARAMETER ResourceGroupName
    Name of the Azure Resource Group to delete.

.PARAMETER Force
    Skip the confirmation prompt and delete immediately. The inventory is still printed.

.EXAMPLE
    .\cleanup-lab.ps1 -ResourceGroupName "rg-ces-source-01"

.EXAMPLE
    .\cleanup-lab.ps1 -ResourceGroupName "rg-ces-target-01" -Force

.NOTES
MODULE COVERAGE
    The scripts and the modules are run separately. This script completes:

      Module 0, section 4   The teardown at the end of the workshop, and the Finish/Cleanup
                            row of the README module table.

    It deletes a resource group and its contents. It does not reach Microsoft Entra ID, and it
    does not purge soft-deleted key vaults. Those are listed at the end of every run.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ================================================================
# Launch resilience
# ================================================================
# This deletes things, so losing the record of what it did is the one outcome worth designing
# against. A right-click "Run with PowerShell" window closes the moment the script ends, which
# would take the list of deleted resources with it. Both launch paths are handled here.

# A migrate-step script installs its own Write-Host and Write-Warning to mask subscription IDs.
# Those are functions and can outlive the script that defined them, shadowing the real cmdlet
# for everything that runs afterwards in the same window. Any leftover is removed.
foreach ($shadowed in @('Write-Host', 'Write-Warning', 'Write-Error')) {
    try {
        if (Test-Path "Function:\$shadowed") { Remove-Item "Function:\$shadowed" -Force -ErrorAction SilentlyContinue }
    } catch { }
}

$script:LabScriptPath = $PSCommandPath

function Wait-LabBeforeExit {
    # Holds a right-click window open. Set LAB_NO_PAUSE=1 for an unattended run.
    if ($env:LAB_NO_PAUSE -eq '1') { return }
    try {
        if (-not [Environment]::UserInteractive) { return }
        Write-Host ''
        $null = Read-Host 'Press Enter to close this window'
    } catch { }
}

function Save-LabCleanupError {
    # Writes the failure beside the script so it survives a closing window. GUIDs are redacted.
    param([Parameter(Mandatory = $true)]$ErrorRecord)
    try {
        $folder = if ($script:LabScriptPath) { Split-Path -Parent $script:LabScriptPath } else { [IO.Path]::GetTempPath() }
        $path = Join-Path $folder ("cleanup-lab-error-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        try {
            Set-Content -Path (Join-Path $folder '.lab-write-test') -Value 'x' -ErrorAction Stop
            Remove-Item (Join-Path $folder '.lab-write-test') -Force -ErrorAction SilentlyContinue
        } catch { $path = Join-Path ([IO.Path]::GetTempPath()) (Split-Path -Leaf $path) }

        $invocation = $ErrorRecord.InvocationInfo
        $report = @(
            "Time       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
            "Resource group: $ResourceGroupName"
            "PowerShell : $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)"
            ''
            "Message    : $([string]$ErrorRecord.Exception.Message)"
            "ErrorId    : $($ErrorRecord.FullyQualifiedErrorId)"
            "Failed at  : line $($invocation.ScriptLineNumber)"
            "Statement  : $(([string]$invocation.Line).Trim())"
            ''
            'Stack trace:'
            ([string]$ErrorRecord.ScriptStackTrace)
        )
        $redacted = $report | ForEach-Object {
            [regex]::Replace([string]$_, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<guid-redacted>')
        }
        Set-Content -Path $path -Value $redacted -Encoding UTF8 -ErrorAction Stop
        Write-Host ''
        Write-Host "A full error report was saved to: $path" -ForegroundColor Yellow
    } catch {
        Write-Host "  (the error report could not be saved: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

function Write-LabLeftovers {
    # Printed on every exit path, including a cancelled run. Deleting a resource group does not
    # reach any of these, and each one causes a specific, confusing failure in a LATER lab if it
    # is left behind - so they are named, with what they break.
    Write-Host ''
    Write-Host '================================================================' -ForegroundColor Yellow
    Write-Host '  STILL TO REMOVE BY HAND' -ForegroundColor Yellow
    Write-Host '================================================================' -ForegroundColor Yellow
    Write-Host '  Deleting a resource group does not reach these. Each one breaks a later lab' -ForegroundColor White
    Write-Host '  in a way that is hard to recognise, so clear them before you finish.' -ForegroundColor White
    Write-Host ''
    Write-Host '  1. The OTHER lab resource group.' -ForegroundColor White
    Write-Host '     This lab uses two - a source group and a target group. This script takes' -ForegroundColor Gray
    Write-Host '     one at a time. Run it again for the other one.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  2. Soft-deleted key vaults.' -ForegroundColor White
    Write-Host '     Generating the appliance project key creates a key vault. Deleting its' -ForegroundColor Gray
    Write-Host '     resource group only SOFT-deletes it, and the name stays reserved for the' -ForegroundColor Gray
    Write-Host '     retention period. A later lab that reuses the project name then fails to' -ForegroundColor Gray
    Write-Host '     generate a key, with no obvious reason. Check and purge:' -ForegroundColor Gray
    Write-Host '       Get-AzKeyVault -InRemovedState' -ForegroundColor Cyan
    Write-Host '       Remove-AzKeyVault -InRemovedState -VaultName <name> -Location <region>' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  3. Recovery Services vaults that still hold backup items.' -ForegroundColor White
    Write-Host '     Created by the project key, and again by Module 5 if you enabled backup.' -ForegroundColor Gray
    Write-Host '     A vault with protected items refuses deletion, which makes the whole group' -ForegroundColor Gray
    Write-Host '     deletion fail. Stop protection and delete the backup data in the portal' -ForegroundColor Gray
    Write-Host '     first, then delete the vault.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  4. The Microsoft Entra application for the appliance.' -ForegroundColor White
    Write-Host '     Appliance registration creates an app registration in Entra ID. It is not' -ForegroundColor Gray
    Write-Host '     an Azure resource and no resource group deletion touches it. Remove it in' -ForegroundColor Gray
    Write-Host '     Entra ID > App registrations if your tenant policy expects that.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  5. The Azure Migrate project, if it sits outside the groups you deleted.' -ForegroundColor White
    Write-Host '     Check the portal before you close: an orphaned project keeps its name and' -ForegroundColor Gray
    Write-Host '     its appliance can still be registered and calling home.' -ForegroundColor Gray
    Write-Host ''
}

trap {
    Write-Host ''
    Write-Host ($_ | Out-String) -ForegroundColor Red
    Save-LabCleanupError -ErrorRecord $_
    Write-LabLeftovers
    Wait-LabBeforeExit
    exit 1
}

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

# ================================================================
# Verify Azure context
# ================================================================
$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context -or -not $context.Account) {
    throw "Not signed in to Azure. Run Connect-AzAccount, select the workshop subscription with Set-AzContext, then rerun."
}
Write-Log "Azure account : $($context.Account.Id)"
Write-Log "Subscription  : $($context.Subscription.Name)"

# ================================================================
# Inventory before deleting
# ================================================================
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Log "Resource group '$ResourceGroupName' does not exist. Nothing to delete here."
    Write-LabLeftovers
    Wait-LabBeforeExit
    return
}

Write-Log "Reading the contents of '$ResourceGroupName' ($($rg.Location))..."
$resources = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue)

Write-Host ''
if ($resources.Count -eq 0) {
    Write-Host "  The group is empty; only the group itself will be removed." -ForegroundColor White
} else {
    Write-Host "  $($resources.Count) resource(s) will be deleted:" -ForegroundColor White
    foreach ($group in ($resources | Group-Object ResourceType | Sort-Object Name)) {
        Write-Host ("    {0,-3} {1}" -f $group.Count, $group.Name) -ForegroundColor Gray
        foreach ($item in ($group.Group | Sort-Object Name)) {
            Write-Host "          $($item.Name)" -ForegroundColor DarkGray
        }
    }
}

# A delete lock makes Remove-AzResourceGroup fail partway. Better to say so before confirming
# than to have it fail after the confirmation has been given.
$locks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
           Where-Object { $_.Properties.level -eq 'CanNotDelete' })
if ($locks.Count -gt 0) {
    Write-Host ''
    Write-Warning "$($locks.Count) CanNotDelete lock(s) are present. The deletion will fail until they are removed:"
    foreach ($lock in $locks) { Write-Host "    $($lock.Name) on $($lock.ResourceId)" -ForegroundColor Yellow }
    Write-Host '  Remove them in the portal, or with Remove-AzResourceLock, then rerun.' -ForegroundColor Yellow
    Write-LabLeftovers
    Wait-LabBeforeExit
    return
}

# A Recovery Services vault holding protected items refuses deletion and takes the whole group
# deletion down with it. Worth naming before the attempt rather than after.
$vaults = @($resources | Where-Object { $_.ResourceType -eq 'Microsoft.RecoveryServices/vaults' })
if ($vaults.Count -gt 0) {
    Write-Host ''
    Write-Warning "$($vaults.Count) Recovery Services vault(s) are in this group:"
    foreach ($vault in $vaults) { Write-Host "    $($vault.Name)" -ForegroundColor Yellow }
    Write-Host '  If any still holds backup items, this deletion will fail. Stop protection and' -ForegroundColor Yellow
    Write-Host '  delete the backup data in the portal first.' -ForegroundColor Yellow
}

# ================================================================
# Confirm
# ================================================================
if (-not $Force) {
    Write-Host ''
    Write-Warning "This permanently deletes resource group '$ResourceGroupName' and everything listed above."
    $confirmation = Read-Host "Type 'yes' to proceed"
    if ($confirmation -ne 'yes') {
        Write-Log 'Cleanup cancelled. Nothing was deleted.'
        Write-LabLeftovers
        Wait-LabBeforeExit
        return
    }
}

# ================================================================
# Delete
# ================================================================
Write-Log "Deleting resource group '$ResourceGroupName'. This can take several minutes..."
Remove-AzResourceGroup -Name $ResourceGroupName -Force -ErrorAction Stop | Out-Null

# Confirm rather than assume: the cmdlet returning is not the same as the group being gone.
$stillThere = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if ($stillThere) {
    throw "Azure reported the deletion of '$ResourceGroupName' but the group is still present. Check the portal before rerunning."
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host "  DELETED: $ResourceGroupName" -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
if ($resources.Count -gt 0) {
    Write-Host "  $($resources.Count) resource(s) went with it:" -ForegroundColor White
    foreach ($group in ($resources | Group-Object ResourceType | Sort-Object Name)) {
        Write-Host ("    {0,-3} {1}" -f $group.Count, $group.Name) -ForegroundColor Gray
    }
} else {
    Write-Host '  The group was empty.' -ForegroundColor White
}

Write-LabLeftovers
Write-Log 'Cleanup complete.'
Wait-LabBeforeExit
