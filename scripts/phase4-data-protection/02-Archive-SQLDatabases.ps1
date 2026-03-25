<#
.SYNOPSIS
    Archives Azure SQL Databases tagged for the Legacy decommission.
.DESCRIPTION
    For each SQL Server tagged ArchiveProject=ArchiveLegacy:
      - Exports each database as BACPAC to archive storage
      - Enables long-term backup retention (W=4, M=12, Y=1)
      - Scales databases down to Basic or S0
      - Exports current SKU/config to JSON backup
.PARAMETER SubscriptionId
    Target Azure subscription ID.
.PARAMETER ArchiveStorageAccountName
    Storage account for BACPAC exports.
.PARAMETER ArchiveContainerName
    Container for BACPAC files.
.PARAMETER StorageKeyType
    Storage key type for BACPAC export. Default: StorageAccessKey.
.EXAMPLE
    .\02-Archive-SQLDatabases.ps1 -SubscriptionId "xxxx" -ArchiveStorageAccountName "azurearchive"
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
    [string]$ArchiveContainerName = "sql-bacpac",

    [Parameter()]
    [string]$TagName = "ArchiveProject",

    [Parameter()]
    [string]$TagValue = "ArchiveLegacy",

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SqlAdminLogin,

    [Parameter(Mandatory)]
    [SecureString]$SqlAdminPassword,

    [Parameter()]
    [ValidateSet("StorageAccessKey", "SharedAccessKey")]
    [string]$StorageKeyType = "StorageAccessKey",

    [Parameter()]
    [string]$LogPath = ".\logs\phase4-sql-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
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

    # Get archive storage key
    $archiveSa = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $ArchiveStorageAccountName }
    if (-not $archiveSa) { throw "Archive storage account '$ArchiveStorageAccountName' not found." }
    $storageKey = (Get-AzStorageAccountKey -ResourceGroupName $archiveSa.ResourceGroupName -Name $ArchiveStorageAccountName)[0].Value
    $archiveCtx = $archiveSa.Context

    # Ensure container exists
    if (-not (Get-AzStorageContainer -Context $archiveCtx -Name $ArchiveContainerName -ErrorAction SilentlyContinue)) {
        New-AzStorageContainer -Context $archiveCtx -Name $ArchiveContainerName -Permission Off | Out-Null
    }

    $sqlServers = Get-AzSqlServer | Where-Object { $_.Tags[$TagName] -eq $TagValue }
    Write-Log "Found $($sqlServers.Count) SQL Servers tagged $TagName=$TagValue"

    $summary = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($server in $sqlServers) {
        $serverName = $server.ServerName
        $serverRg = $server.ResourceGroupName
        Write-Log "Processing SQL Server: $serverName (RG: $serverRg)"

        $databases = Get-AzSqlDatabase -ServerName $serverName -ResourceGroupName $serverRg |
            Where-Object { $_.DatabaseName -ne "master" }

        foreach ($db in $databases) {
            $dbName = $db.DatabaseName
            Write-Log "  Processing database: $dbName"

            try {
                # Export current config to JSON
                $configExport = [PSCustomObject]@{
                    ServerName        = $serverName
                    DatabaseName      = $dbName
                    ResourceGroup     = $serverRg
                    Edition           = $db.Edition
                    ServiceObjective  = $db.CurrentServiceObjectiveName
                    MaxSizeBytes      = $db.MaxSizeBytes
                    ElasticPoolName   = $db.ElasticPoolName
                    ZoneRedundant     = $db.ZoneRedundant
                    ReadScale         = $db.ReadScale
                    ExportDate        = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                }
                $configJson = $configExport | ConvertTo-Json -Depth 5
                $configBlobName = "$serverName/$dbName-config-$(Get-Date -Format 'yyyyMMdd').json"
                $configTemp = Join-Path $env:TEMP "$serverName-$dbName-config.json"
                $configJson | Out-File -FilePath $configTemp -Encoding utf8
                Set-AzStorageBlobContent -File $configTemp -Container $ArchiveContainerName -Blob $configBlobName -Context $archiveCtx -Force | Out-Null
                Remove-Item $configTemp -Force
                Write-Log "  Exported config for $dbName to $configBlobName"

                # Export BACPAC
                $bacpacName = "$serverName/$dbName-$(Get-Date -Format 'yyyyMMdd').bacpac"
                $storageUri = "https://$ArchiveStorageAccountName.blob.core.windows.net/$ArchiveContainerName/$bacpacName"

                if ($PSCmdlet.ShouldProcess($dbName, "Export BACPAC to $storageUri")) {
                    $exportRequest = New-AzSqlDatabaseExport `
                        -ResourceGroupName $serverRg `
                        -ServerName $serverName `
                        -DatabaseName $dbName `
                        -StorageKeyType $StorageKeyType `
                        -StorageKey $storageKey `
                        -StorageUri $storageUri `
                        -AdministratorLogin $SqlAdminLogin `
                        -AdministratorLoginPassword $SqlAdminPassword

                    Write-Log "  BACPAC export initiated for $dbName (OperationStatusLink: $($exportRequest.OperationStatusLink))"

                    # Poll for completion (timeout 60 min)
                    $timeout = (Get-Date).AddMinutes(60)
                    do {
                        Start-Sleep -Seconds 30
                        $status = Get-AzSqlDatabaseImportExportStatus -OperationStatusLink $exportRequest.OperationStatusLink
                        Write-Log "  Export status for ${dbName}: $($status.Status)"
                    } while ($status.Status -eq "InProgress" -and (Get-Date) -lt $timeout)

                    if ($status.Status -ne "Succeeded") {
                        Write-Log "  BACPAC export did not succeed for ${dbName}: $($status.StatusMessage)" -Level "ERROR"
                        continue
                    }
                    Write-Log "  BACPAC export completed for $dbName"
                }

                # Enable long-term backup retention
                if ($PSCmdlet.ShouldProcess($dbName, "Set LTR policy W=4,M=12,Y=1")) {
                    Set-AzSqlDatabaseBackupLongTermRetentionPolicy `
                        -ServerName $serverName `
                        -ResourceGroupName $serverRg `
                        -DatabaseName $dbName `
                        -WeeklyRetention "P4W" `
                        -MonthlyRetention "P12M" `
                        -YearlyRetention "P1Y" `
                        -WeekOfYear 1
                    Write-Log "  Set LTR policy on $dbName"
                }

                # Scale down to Basic (skip elastic pool DBs)
                if (-not $db.ElasticPoolName) {
                    $targetEdition = "Basic"
                    $targetObjective = "Basic"
                    if ($db.Edition -eq "DataWarehouse") {
                        Write-Log "  Skipping scale-down for DataWarehouse DB: $dbName" -Level "WARN"
                    }
                    elseif ($db.Edition -ne $targetEdition) {
                        if ($PSCmdlet.ShouldProcess($dbName, "Scale to $targetEdition")) {
                            Set-AzSqlDatabase -ResourceGroupName $serverRg -ServerName $serverName -DatabaseName $dbName `
                                -Edition $targetEdition -RequestedServiceObjectiveName $targetObjective
                            Write-Log "  Scaled $dbName to $targetEdition"
                        }
                    }
                    else {
                        Write-Log "  $dbName already at $targetEdition tier"
                    }
                }
                else {
                    Write-Log "  $dbName is in elastic pool '$($db.ElasticPoolName)', skipping individual scale-down" -Level "WARN"
                }

                $summary.Add([PSCustomObject]@{
                    Server   = $serverName
                    Database = $dbName
                    OldSKU   = "$($db.Edition)/$($db.CurrentServiceObjectiveName)"
                    Status   = "Success"
                })
            }
            catch {
                Write-Log "  ERROR on ${dbName}: $_" -Level "ERROR"
                $summary.Add([PSCustomObject]@{
                    Server   = $serverName
                    Database = $dbName
                    OldSKU   = "$($db.Edition)/$($db.CurrentServiceObjectiveName)"
                    Status   = "Failed: $_"
                })
            }
        }
    }

    Write-Log "=== SQL Database Archive Summary ==="
    $summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }
    Write-Log "Total: $($summary.Count), Succeeded: $(($summary | Where-Object Status -eq 'Success').Count), Failed: $(($summary | Where-Object Status -ne 'Success').Count)"
}
catch {
    Write-Log "FATAL: $_" -Level "ERROR"
    throw
}
} # end foreach
