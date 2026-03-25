<#
.SYNOPSIS
    Archives Azure Redis Cache instances tagged for the Legacy decommission.
.DESCRIPTION
    For each Redis cache tagged ArchiveProject=ArchiveLegacy:
      - Exports RDB snapshot to archive storage account
      - Logs current tier/size
      - Scales to Basic C0 (or flags for deletion if export successful)
.PARAMETER SubscriptionId
    Target Azure subscription ID.
.PARAMETER ArchiveStorageAccountName
    Storage account for RDB exports.
.PARAMETER ArchiveContainerName
    Container for Redis RDB snapshots.
.PARAMETER FlagForDeletion
    If set, flags successfully exported caches for deletion instead of scaling down.
.EXAMPLE
    .\05-Archive-Redis.ps1 -SubscriptionId "xxxx" -ArchiveStorageAccountName "azurearchive"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [string]$SubscriptionListPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveStorageAccountName,

    [Parameter()]
    [string]$ArchiveContainerName = "redis-snapshots",

    [Parameter()]
    [switch]$FlagForDeletion,

    [Parameter()]
    [string]$TagName = "ArchiveProject",

    [Parameter()]
    [string]$TagValue = "ArchiveLegacy",

    [Parameter()]
    [string]$LogPath = ".\logs\phase4-redis-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Verbose $entry
    $logDir = Split-Path $LogPath -Parent
    if ($logDir -and !(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $entry
}

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

foreach ($subId in $SubscriptionId) {
try {
    Write-Log "Setting subscription context to $subId"
    Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

    $archiveSa = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $ArchiveStorageAccountName }
    if (-not $archiveSa) { throw "Archive storage account '$ArchiveStorageAccountName' not found." }
    $archiveCtx = $archiveSa.Context

    if (-not (Get-AzStorageContainer -Context $archiveCtx -Name $ArchiveContainerName -ErrorAction SilentlyContinue)) {
        New-AzStorageContainer -Context $archiveCtx -Name $ArchiveContainerName -Permission Off | Out-Null
    }

    # Generate SAS for Redis export
    $sasToken = New-AzStorageContainerSASToken -Context $archiveCtx -Name $ArchiveContainerName `
        -Permission rwl -ExpiryTime (Get-Date).AddHours(12)
    $sasUri = "https://$ArchiveStorageAccountName.blob.core.windows.net/$ArchiveContainerName$sasToken"

    $redisCaches = Get-AzRedisCache | Where-Object { $_.Tag[$TagName] -eq $TagValue }
    Write-Log "Found $($redisCaches.Count) Redis caches tagged $TagName=$TagValue"

    $summary = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($cache in $redisCaches) {
        $cacheName = $cache.Name
        $cacheRg = $cache.ResourceGroupName
        $currentSku = "$($cache.Sku)/$($cache.Size)"
        Write-Log "Processing Redis cache: $cacheName (RG: $cacheRg, SKU: $currentSku)"

        try {
            # 1. Export RDB snapshot
            $exportPrefix = "$cacheName-$(Get-Date -Format 'yyyyMMdd')"
            $exportSucceeded = $false

            if ($cache.Sku -eq "Basic") {
                Write-Log "  Basic tier does not support export for $cacheName — skipping RDB export" -Level "WARN"
            }
            else {
                if ($PSCmdlet.ShouldProcess($cacheName, "Export RDB snapshot")) {
                    Export-AzRedisCache -ResourceGroupName $cacheRg -Name $cacheName `
                        -Prefix $exportPrefix -Container $sasUri -Format "rdb"
                    Write-Log "  RDB export initiated for $cacheName (prefix: $exportPrefix)"
                    $exportSucceeded = $true

                    # Poll for export completion
                    $timeout = (Get-Date).AddMinutes(30)
                    do {
                        Start-Sleep -Seconds 15
                        $cacheStatus = Get-AzRedisCache -ResourceGroupName $cacheRg -Name $cacheName
                    } while ($cacheStatus.ProvisioningState -ne "Succeeded" -and (Get-Date) -lt $timeout)

                    if ($cacheStatus.ProvisioningState -eq "Succeeded") {
                        Write-Log "  RDB export completed for $cacheName"
                    }
                    else {
                        Write-Log "  RDB export may still be in progress for $cacheName" -Level "WARN"
                    }
                }
            }

            # 2. Scale down or flag for deletion
            if ($FlagForDeletion -and $exportSucceeded) {
                if ($PSCmdlet.ShouldProcess($cacheName, "Tag for deletion")) {
                    $tags = $cache.Tag
                    $tags["ArchiveStatus"] = "ReadyForDeletion"
                    $tags["RdbExportDate"] = (Get-Date -Format "yyyy-MM-dd")
                    Update-AzRedisCache -ResourceGroupName $cacheRg -Name $cacheName -Tag $tags
                    Write-Log "  Tagged $cacheName for deletion"
                }
            }
            elseif ($cache.Sku -ne "Basic" -or $cache.Size -ne "C0") {
                if ($PSCmdlet.ShouldProcess($cacheName, "Scale to Basic C0")) {
                    # Premium/Standard must go through Standard first if Premium
                    if ($cache.Sku -eq "Premium") {
                        Write-Log "  Premium caches cannot scale to Basic directly — flagging for manual action" -Level "WARN"
                        $tags = $cache.Tag
                        $tags["ArchiveStatus"] = "ManualScaleRequired"
                        Update-AzRedisCache -ResourceGroupName $cacheRg -Name $cacheName -Tag $tags
                    }
                    else {
                        Set-AzRedisCache -ResourceGroupName $cacheRg -Name $cacheName -Sku "Basic" -Size "C0"
                        Write-Log "  Scaled $cacheName to Basic C0"
                    }
                }
            }
            else {
                Write-Log "  $cacheName already at Basic C0"
            }

            $summary.Add([PSCustomObject]@{
                Cache         = $cacheName
                ResourceGroup = $cacheRg
                OriginalSKU   = $currentSku
                Exported      = $exportSucceeded
                Status        = "Success"
            })
        }
        catch {
            Write-Log "ERROR on ${cacheName}: $_" -Level "ERROR"
            $summary.Add([PSCustomObject]@{
                Cache         = $cacheName
                ResourceGroup = $cacheRg
                OriginalSKU   = $currentSku
                Exported      = $false
                Status        = "Failed: $_"
            })
        }
    }

    Write-Log "=== Redis Cache Archive Summary ==="
    $summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }
    Write-Log "Total: $($summary.Count), Succeeded: $(($summary | Where-Object Status -eq 'Success').Count), Failed: $(($summary | Where-Object Status -ne 'Success').Count)"
}
catch {
    Write-Log "FATAL: $_" -Level "ERROR"
    throw
}
} # end foreach
