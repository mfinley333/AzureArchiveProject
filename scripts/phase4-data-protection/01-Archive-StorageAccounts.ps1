<#
.SYNOPSIS
    Archives Azure Storage Accounts tagged for the Legacy decommission.
.DESCRIPTION
    For each storage account tagged ArchiveProject=ArchiveLegacy:
      - Enables blob soft-delete (14 days) and versioning
      - Sets default access tier to Cool
      - Exports storage inventory (containers, sizes, last accessed)
      - Identifies containers > 1TB for Archive tier migration
.PARAMETER SubscriptionId
    Target Azure subscription ID.
.PARAMETER ResourceGroupName
    Optional filter to a specific resource group.
.PARAMETER ArchiveStorageAccountName
    Storage account used for exporting inventory reports.
.PARAMETER ArchiveContainerName
    Container in the archive storage account for inventory exports.
.PARAMETER WhatIf
    Preview changes without applying them.
.EXAMPLE
    .\01-Archive-StorageAccounts.ps1 -SubscriptionId "xxxx" -ArchiveStorageAccountName "azurearchive"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [string]$SubscriptionListPath,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveStorageAccountName,

    [Parameter()]
    [string]$ArchiveContainerName = "storage-inventory",

    [Parameter()]
    [string]$TagName = "ArchiveProject",

    [Parameter()]
    [string]$TagValue = "ArchiveLegacy",

    [Parameter()]
    [string]$LogPath = ".\logs\phase4-storage-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

#region Logging
function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Verbose $entry
    $logDir = Split-Path $LogPath -Parent
    if ($logDir -and !(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $entry
}
#endregion

function Import-SubscriptionList {
    param([string]$Path)
    $csv = Import-Csv -Path $Path
    $ids = @()
    foreach ($row in $csv) {
        try {
            $sub = Get-AzSubscription -SubscriptionName $row.SubscriptionName -ErrorAction Stop
            $ids += $sub.Id
        }
        catch {
            Write-Warning "Could not resolve subscription '$($row.SubscriptionName)': $_"
        }
    }
    if ($ids.Count -eq 0) { throw "No valid subscriptions resolved from '$Path'" }
    return $ids
}

# Resolve subscriptions from CSV if not explicitly provided
if (-not $SubscriptionId -and $SubscriptionListPath) {
    $SubscriptionId = Import-SubscriptionList -Path $SubscriptionListPath
}

if (-not $SubscriptionId) {
    throw "No subscriptions specified. Provide -SubscriptionId or -SubscriptionListPath."
}

#region Main
foreach ($subId in $SubscriptionId) {
try {
    Write-Log "Setting subscription context to $subId"
    Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

    $filter = @{ $TagName = $TagValue }
    $getParams = @{ Tag = $filter }
    if ($ResourceGroupName) { $getParams.ResourceGroupName = $ResourceGroupName }

    $storageAccounts = Get-AzStorageAccount @getParams
    Write-Log "Found $($storageAccounts.Count) storage accounts tagged $TagName=$TagValue"

    $archiveCtx = (Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $ArchiveStorageAccountName }).Context
    if (-not $archiveCtx) {
        throw "Archive storage account '$ArchiveStorageAccountName' not found in current subscription."
    }

    # Ensure inventory container exists
    $existing = Get-AzStorageContainer -Context $archiveCtx -Name $ArchiveContainerName -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-AzStorageContainer -Context $archiveCtx -Name $ArchiveContainerName -Permission Off | Out-Null
    }

    $summary = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($sa in $storageAccounts) {
        $saName = $sa.StorageAccountName
        $saRg = $sa.ResourceGroupName
        Write-Log "Processing storage account: $saName (RG: $saRg)"

        try {
            # 1. Enable blob soft-delete (14 days)
            $blobService = Get-AzStorageBlobServiceProperty -ResourceGroupName $saRg -StorageAccountName $saName
            if (-not $blobService.DeleteRetentionPolicy.Enabled -or $blobService.DeleteRetentionPolicy.Days -lt 14) {
                if ($PSCmdlet.ShouldProcess($saName, "Enable blob soft-delete (14 days)")) {
                    Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName $saRg -StorageAccountName $saName -RetentionDays 14
                    Write-Log "Enabled blob soft-delete (14 days) on $saName"
                }
            }
            else {
                Write-Log "Blob soft-delete already enabled on $saName (days: $($blobService.DeleteRetentionPolicy.Days))"
            }

            # 2. Enable versioning
            if (-not $blobService.IsVersioningEnabled) {
                if ($PSCmdlet.ShouldProcess($saName, "Enable blob versioning")) {
                    Update-AzStorageBlobServiceProperty -ResourceGroupName $saRg -StorageAccountName $saName -IsVersioningEnabled $true
                    Write-Log "Enabled versioning on $saName"
                }
            }
            else {
                Write-Log "Versioning already enabled on $saName"
            }

            # 3. Set default access tier to Cool
            if ($sa.AccessTier -ne "Cool") {
                if ($PSCmdlet.ShouldProcess($saName, "Set default access tier to Cool")) {
                    Set-AzStorageAccount -ResourceGroupName $saRg -Name $saName -AccessTier Cool
                    Write-Log "Set access tier to Cool on $saName"
                }
            }
            else {
                Write-Log "Access tier already Cool on $saName"
            }

            # 4. Export container inventory
            $ctx = $sa.Context
            $containers = Get-AzStorageContainer -Context $ctx
            $inventory = [System.Collections.Generic.List[PSObject]]::new()
            $largeContainers = [System.Collections.Generic.List[string]]::new()

            foreach ($container in $containers) {
                $blobs = Get-AzStorageBlob -Context $ctx -Container $container.Name
                $totalSize = ($blobs | Measure-Object -Property Length -Sum).Sum
                $lastAccessed = ($blobs | Sort-Object -Property LastModified -Descending | Select-Object -First 1).LastModified

                $inventory.Add([PSCustomObject]@{
                    StorageAccount = $saName
                    Container      = $container.Name
                    BlobCount      = $blobs.Count
                    TotalSizeBytes = $totalSize
                    TotalSizeGB    = [math]::Round($totalSize / 1GB, 2)
                    LastModified   = $lastAccessed
                })

                # 5. Flag containers > 1TB for Archive tier
                if ($totalSize -gt 1TB) {
                    $largeContainers.Add($container.Name)
                }
            }

            $inventoryPath = "$saName-inventory-$(Get-Date -Format 'yyyyMMdd').csv"
            $tempFile = Join-Path $env:TEMP $inventoryPath
            $inventory | Export-Csv -Path $tempFile -NoTypeInformation
            Set-AzStorageBlobContent -File $tempFile -Container $ArchiveContainerName -Blob $inventoryPath -Context $archiveCtx -Force | Out-Null
            Remove-Item $tempFile -Force
            Write-Log "Exported inventory for $saName ($($containers.Count) containers)"

            if ($largeContainers.Count -gt 0) {
                Write-Log "LARGE CONTAINERS (>1TB) in ${saName}: $($largeContainers -join ', ')" -Level "WARN"
            }

            $summary.Add([PSCustomObject]@{
                StorageAccount  = $saName
                ResourceGroup   = $saRg
                Containers      = $containers.Count
                LargeContainers = $largeContainers.Count
                Status          = "Success"
            })
        }
        catch {
            Write-Log "ERROR processing ${saName}: $_" -Level "ERROR"
            $summary.Add([PSCustomObject]@{
                StorageAccount  = $saName
                ResourceGroup   = $saRg
                Containers      = 0
                LargeContainers = 0
                Status          = "Failed: $_"
            })
        }
    }

    Write-Log "=== Storage Account Archive Summary ==="
    $summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }
    Write-Log "Total processed: $($summary.Count), Succeeded: $(($summary | Where-Object Status -eq 'Success').Count), Failed: $(($summary | Where-Object Status -ne 'Success').Count)"
}
catch {
    Write-Log "FATAL: $_" -Level "ERROR"
    throw
}
} # end foreach
#endregion
