<#
.SYNOPSIS
    Removes the Azure Migrate Workshop lab environment.

.DESCRIPTION
    Deletes the specified Azure Resource Group and all resources within it,
    including the Hyper-V host VM, networking, and disks.

.PARAMETER ResourceGroupName
    Name of the Azure Resource Group to delete.

.PARAMETER Force
    Skip the confirmation prompt and delete immediately.

.EXAMPLE
    .\cleanup-lab.ps1 -ResourceGroupName "rg-ces-source-01"

.EXAMPLE
    .\cleanup-lab.ps1 -ResourceGroupName "rg-ces-source-01" -Force
MODULE COVERAGE
    The scripts and the modules are run separately. This script completes:

      Module 0, section 4   The teardown at the end of the workshop, and the Finish/Cleanup
                            row of the README module table.

    It does not touch the Azure Migrate project, its key vault or its recovery services vault.
    Remove those from the portal, or they will hold their names against a future lab.
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

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message" -ForegroundColor Cyan
}

# Verify Azure context
try {
    $context = Get-AzContext
    if (-not $context) {
        throw "Not logged in to Azure. Run Connect-AzAccount first."
    }
} catch {
    throw "Azure authentication required. Run Connect-AzAccount before executing this script. Error: $_"
}

# Check if resource group exists
$rg = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Log "Resource Group '$ResourceGroupName' does not exist. Nothing to clean up."
    return
}

# Confirm deletion
if (-not $Force) {
    Write-Log "WARNING: This will permanently delete Resource Group '$ResourceGroupName' and ALL resources within it."
    Write-Log "Location: $($rg.Location)"
    $confirmation = Read-Host "Are you sure you want to proceed? (yes/no)"
    if ($confirmation -ne "yes") {
        Write-Log "Cleanup cancelled."
        return
    }
}

# Delete the resource group
Write-Log "Deleting Resource Group '$ResourceGroupName'..."
try {
    Remove-AzResourceGroup -Name $ResourceGroupName -Force -ErrorAction Stop | Out-Null
    Write-Log "Resource Group '$ResourceGroupName' deleted successfully."
} catch {
    throw "Failed to delete Resource Group: $_"
}

Write-Log "Cleanup complete."
