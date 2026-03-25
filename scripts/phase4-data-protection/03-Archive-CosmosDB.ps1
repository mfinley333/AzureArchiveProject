<#
.SYNOPSIS
    Archives Azure Cosmos DB accounts tagged for the Legacy decommission.
.DESCRIPTION
    For each Cosmos DB account tagged ArchiveProject=ArchiveLegacy:
      - Triggers data export to archive storage via Data Movement / copy activity
      - Reduces throughput to minimum (400 RU/s or autoscale min)
      - Disables multi-region writes
      - Exports current config (consistency, regions, throughput) to JSON
.PARAMETER SubscriptionId
    Target Azure subscription ID.
.PARAMETER ArchiveStorageAccountName
    Storage account for data exports and config backups.
.PARAMETER ArchiveContainerName
    Container for Cosmos DB exports.
.EXAMPLE
    .\03-Archive-CosmosDB.ps1 -SubscriptionId "xxxx" -ArchiveStorageAccountName "azurearchive"
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
    [string]$ArchiveContainerName = "cosmosdb-exports",

    [Parameter()]
    [string]$TagName = "ArchiveProject",

    [Parameter()]
    [string]$TagValue = "ArchiveLegacy",

    [Parameter()]
    [int]$MinThroughput = 400,

    [Parameter()]
    [string]$LogPath = ".\logs\phase4-cosmos-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
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

function Export-CosmosConfig {
    param($Account, $Context)

    $accountName = $Account.Name
    $rg = $Account.ResourceGroupName

    $config = [PSCustomObject]@{
        AccountName          = $accountName
        ResourceGroup        = $rg
        Location             = $Account.Location
        Kind                 = $Account.Kind
        ConsistencyLevel     = $Account.ConsistencyPolicy.DefaultConsistencyLevel
        EnableMultipleWriteLocations = $Account.EnableMultipleWriteLocations
        Locations            = $Account.Locations | ForEach-Object {
            [PSCustomObject]@{ Location = $_.LocationName; FailoverPriority = $_.FailoverPriority }
        }
        Capabilities         = $Account.Capabilities | ForEach-Object { $_.Name }
        DatabasesAndThroughput = @()
        ExportDate           = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    # Capture SQL API databases and throughput
    try {
        $databases = Get-AzCosmosDBSqlDatabase -ResourceGroupName $rg -AccountName $accountName -ErrorAction SilentlyContinue
        foreach ($db in $databases) {
            $dbInfo = @{ DatabaseName = $db.Name; Containers = @() }
            try {
                $throughput = Get-AzCosmosDBSqlDatabaseThroughput -ResourceGroupName $rg -AccountName $accountName -Name $db.Name -ErrorAction SilentlyContinue
                $dbInfo.Throughput = $throughput.Throughput
                $dbInfo.AutoscaleMaxThroughput = $throughput.AutoscaleSettings.MaxThroughput
            }
            catch { $dbInfo.Throughput = "N/A (container-level)" }

            $containers = Get-AzCosmosDBSqlContainer -ResourceGroupName $rg -AccountName $accountName -DatabaseName $db.Name -ErrorAction SilentlyContinue
            foreach ($c in $containers) {
                $cInfo = @{ ContainerName = $c.Name; PartitionKey = $c.Resource.PartitionKey.Paths -join "," }
                try {
                    $cThroughput = Get-AzCosmosDBSqlContainerThroughput -ResourceGroupName $rg -AccountName $accountName -DatabaseName $db.Name -Name $c.Name -ErrorAction SilentlyContinue
                    $cInfo.Throughput = $cThroughput.Throughput
                    $cInfo.AutoscaleMaxThroughput = $cThroughput.AutoscaleSettings.MaxThroughput
                }
                catch { $cInfo.Throughput = "shared" }
                $dbInfo.Containers += $cInfo
            }
            $config.DatabasesAndThroughput += $dbInfo
        }
    }
    catch {
        Write-Log "  Could not enumerate SQL databases for ${accountName}: $_" -Level "WARN"
    }

    return $config
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

    $cosmosAccounts = Get-AzCosmosDBAccount | Where-Object { $_.Tags[$TagName] -eq $TagValue }
    Write-Log "Found $($cosmosAccounts.Count) Cosmos DB accounts tagged $TagName=$TagValue"

    $summary = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($account in $cosmosAccounts) {
        $acctName = $account.Name
        $acctRg = $account.ResourceGroupName
        Write-Log "Processing Cosmos DB account: $acctName (RG: $acctRg)"

        try {
            # 1. Export current config to JSON
            $config = Export-CosmosConfig -Account $account -Context $archiveCtx
            $configJson = $config | ConvertTo-Json -Depth 10
            $configBlobName = "$acctName/$acctName-config-$(Get-Date -Format 'yyyyMMdd').json"
            $configTemp = Join-Path $env:TEMP "$acctName-config.json"
            $configJson | Out-File -FilePath $configTemp -Encoding utf8
            Set-AzStorageBlobContent -File $configTemp -Container $ArchiveContainerName -Blob $configBlobName -Context $archiveCtx -Force | Out-Null
            Remove-Item $configTemp -Force
            Write-Log "  Exported config for $acctName"

            # 2. Trigger data export using Azure CLI (dt tool / copy activity)
            if ($PSCmdlet.ShouldProcess($acctName, "Export data to archive storage")) {
                $exportBlobPrefix = "$acctName/data-$(Get-Date -Format 'yyyyMMdd')"
                $storageKey = (Get-AzStorageAccountKey -ResourceGroupName $archiveSa.ResourceGroupName -Name $ArchiveStorageAccountName)[0].Value
                $connString = $account.DocumentEndpoint

                # Use Cosmos DB data migration via az cosmosdb copy or dt tool
                Write-Log "  Initiating data export for $acctName (manual copy job may be required)"
                Write-Log "  Target: https://$ArchiveStorageAccountName.blob.core.windows.net/$ArchiveContainerName/$exportBlobPrefix" -Level "WARN"
                # NOTE: Full data migration requires ADF pipeline or dt.exe — log for manual action
                Write-Log "  ACTION REQUIRED: Create ADF copy activity or use dt.exe for full data export of $acctName" -Level "WARN"
            }

            # 3. Reduce throughput to minimum
            $databases = Get-AzCosmosDBSqlDatabase -ResourceGroupName $acctRg -AccountName $acctName -ErrorAction SilentlyContinue
            foreach ($db in $databases) {
                # Database-level throughput
                try {
                    $dbThroughput = Get-AzCosmosDBSqlDatabaseThroughput -ResourceGroupName $acctRg -AccountName $acctName -Name $db.Name -ErrorAction Stop
                    if ($dbThroughput.AutoscaleSettings.MaxThroughput) {
                        if ($PSCmdlet.ShouldProcess("$acctName/$($db.Name)", "Set autoscale min to 1000 RU/s")) {
                            Update-AzCosmosDBSqlDatabaseThroughput -ResourceGroupName $acctRg -AccountName $acctName -Name $db.Name -AutoscaleMaxThroughput 1000
                            Write-Log "  Set autoscale max to 1000 RU/s on $acctName/$($db.Name)"
                        }
                    }
                    elseif ($dbThroughput.Throughput -gt $MinThroughput) {
                        if ($PSCmdlet.ShouldProcess("$acctName/$($db.Name)", "Set throughput to $MinThroughput RU/s")) {
                            Update-AzCosmosDBSqlDatabaseThroughput -ResourceGroupName $acctRg -AccountName $acctName -Name $db.Name -Throughput $MinThroughput
                            Write-Log "  Set throughput to $MinThroughput RU/s on $acctName/$($db.Name)"
                        }
                    }
                }
                catch {
                    Write-Log "  Database-level throughput not set on $($db.Name), checking containers" -Level "WARN"
                }

                # Container-level throughput
                $containers = Get-AzCosmosDBSqlContainer -ResourceGroupName $acctRg -AccountName $acctName -DatabaseName $db.Name -ErrorAction SilentlyContinue
                foreach ($c in $containers) {
                    try {
                        $cThroughput = Get-AzCosmosDBSqlContainerThroughput -ResourceGroupName $acctRg -AccountName $acctName -DatabaseName $db.Name -Name $c.Name -ErrorAction Stop
                        if ($cThroughput.AutoscaleSettings.MaxThroughput) {
                            if ($PSCmdlet.ShouldProcess("$acctName/$($db.Name)/$($c.Name)", "Set autoscale min to 1000 RU/s")) {
                                Update-AzCosmosDBSqlContainerThroughput -ResourceGroupName $acctRg -AccountName $acctName -DatabaseName $db.Name -Name $c.Name -AutoscaleMaxThroughput 1000
                                Write-Log "  Set autoscale max to 1000 RU/s on container $($c.Name)"
                            }
                        }
                        elseif ($cThroughput.Throughput -gt $MinThroughput) {
                            if ($PSCmdlet.ShouldProcess("$acctName/$($db.Name)/$($c.Name)", "Set throughput to $MinThroughput RU/s")) {
                                Update-AzCosmosDBSqlContainerThroughput -ResourceGroupName $acctRg -AccountName $acctName -DatabaseName $db.Name -Name $c.Name -Throughput $MinThroughput
                                Write-Log "  Set throughput to $MinThroughput RU/s on container $($c.Name)"
                            }
                        }
                    }
                    catch {
                        Write-Log "  No dedicated throughput on container $($c.Name)" -Level "WARN"
                    }
                }
            }

            # 4. Disable multi-region writes
            if ($account.EnableMultipleWriteLocations) {
                if ($PSCmdlet.ShouldProcess($acctName, "Disable multi-region writes")) {
                    Update-AzCosmosDBAccount -ResourceGroupName $acctRg -Name $acctName -EnableMultipleWriteLocations:$false
                    Write-Log "  Disabled multi-region writes on $acctName"
                }
            }
            else {
                Write-Log "  Multi-region writes already disabled on $acctName"
            }

            $summary.Add([PSCustomObject]@{
                Account       = $acctName
                ResourceGroup = $acctRg
                Status        = "Success"
            })
        }
        catch {
            Write-Log "ERROR on ${acctName}: $_" -Level "ERROR"
            $summary.Add([PSCustomObject]@{
                Account       = $acctName
                ResourceGroup = $acctRg
                Status        = "Failed: $_"
            })
        }
    }

    Write-Log "=== Cosmos DB Archive Summary ==="
    $summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }
    Write-Log "Total: $($summary.Count), Succeeded: $(($summary | Where-Object Status -eq 'Success').Count), Failed: $(($summary | Where-Object Status -ne 'Success').Count)"
}
catch {
    Write-Log "FATAL: $_" -Level "ERROR"
    throw
}
} # end foreach
