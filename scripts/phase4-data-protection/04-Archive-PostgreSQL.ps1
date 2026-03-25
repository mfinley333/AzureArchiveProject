<#
.SYNOPSIS
    Archives Azure PostgreSQL Flexible Servers tagged for the Legacy decommission.
.DESCRIPTION
    For each PostgreSQL Flexible Server tagged ArchiveProject=ArchiveLegacy:
      - Triggers pg_dump backup to archive storage
      - Scales to Burstable B1ms
      - Stops server after backup completes
      - Exports current config to JSON
.PARAMETER SubscriptionId
    Target Azure subscription ID.
.PARAMETER ArchiveStorageAccountName
    Storage account for backup exports.
.PARAMETER ArchiveContainerName
    Container for PostgreSQL backups.
.PARAMETER PgDumpPath
    Path to pg_dump executable. Default: pg_dump (must be in PATH).
.EXAMPLE
    .\04-Archive-PostgreSQL.ps1 -SubscriptionId "xxxx" -ArchiveStorageAccountName "azurearchive" -PgAdminUser "pgadmin"
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
    [string]$ArchiveContainerName = "postgresql-backups",

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PgAdminUser,

    [Parameter(Mandatory)]
    [SecureString]$PgAdminPassword,

    [Parameter()]
    [string]$PgDumpPath = "pg_dump",

    [Parameter()]
    [string]$TagName = "ArchiveProject",

    [Parameter()]
    [string]$TagValue = "ArchiveLegacy",

    [Parameter()]
    [string]$LogPath = ".\logs\phase4-postgresql-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
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

    $pgServers = Get-AzPostgreSqlFlexibleServer | Where-Object { $_.Tag[$TagName] -eq $TagValue }
    Write-Log "Found $($pgServers.Count) PostgreSQL Flexible Servers tagged $TagName=$TagValue"

    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($PgAdminPassword)
    )

    $summary = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($server in $pgServers) {
        $serverName = $server.Name
        $serverRg = $server.ResourceGroupName
        $fqdn = $server.FullyQualifiedDomainName
        Write-Log "Processing PostgreSQL server: $serverName (RG: $serverRg)"

        try {
            # 1. Export current config to JSON
            $config = [PSCustomObject]@{
                ServerName    = $serverName
                ResourceGroup = $serverRg
                FQDN          = $fqdn
                Location      = $server.Location
                Sku           = $server.SkuName
                SkuTier       = $server.SkuTier
                StorageSizeGb = $server.StorageSizeGb
                Version       = $server.Version
                State         = $server.State
                ExportDate    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            }
            $configJson = $config | ConvertTo-Json -Depth 5
            $configBlobName = "$serverName/$serverName-config-$(Get-Date -Format 'yyyyMMdd').json"
            $configTemp = Join-Path $env:TEMP "$serverName-config.json"
            $configJson | Out-File -FilePath $configTemp -Encoding utf8
            Set-AzStorageBlobContent -File $configTemp -Container $ArchiveContainerName -Blob $configBlobName -Context $archiveCtx -Force | Out-Null
            Remove-Item $configTemp -Force
            Write-Log "  Exported config for $serverName"

            # 2. pg_dump backup
            if ($PSCmdlet.ShouldProcess($serverName, "Run pg_dump backup")) {
                $dumpFile = Join-Path $env:TEMP "$serverName-$(Get-Date -Format 'yyyyMMdd-HHmmss').dump"
                $env:PGPASSWORD = $plainPassword

                $pgArgs = @(
                    "--host=$fqdn"
                    "--port=5432"
                    "--username=$PgAdminUser"
                    "--format=custom"
                    "--file=$dumpFile"
                    "--verbose"
                    "postgres"
                )

                Write-Log "  Starting pg_dump for $serverName"
                $process = Start-Process -FilePath $PgDumpPath -ArgumentList $pgArgs -Wait -PassThru -NoNewWindow -RedirectStandardError (Join-Path $env:TEMP "$serverName-pgdump-err.log")

                if ($process.ExitCode -ne 0) {
                    $errLog = Get-Content (Join-Path $env:TEMP "$serverName-pgdump-err.log") -Raw
                    throw "pg_dump failed with exit code $($process.ExitCode): $errLog"
                }

                # Upload dump to archive storage
                $dumpBlobName = "$serverName/$serverName-$(Get-Date -Format 'yyyyMMdd').dump"
                Set-AzStorageBlobContent -File $dumpFile -Container $ArchiveContainerName -Blob $dumpBlobName -Context $archiveCtx -Force | Out-Null
                Remove-Item $dumpFile -Force
                Write-Log "  Uploaded pg_dump for $serverName to $dumpBlobName"
            }

            # 3. Scale to Burstable B1ms
            if ($server.SkuName -ne "Standard_B1ms" -or $server.SkuTier -ne "Burstable") {
                if ($PSCmdlet.ShouldProcess($serverName, "Scale to Burstable B1ms")) {
                    Update-AzPostgreSqlFlexibleServer -ResourceGroupName $serverRg -Name $serverName `
                        -SkuName "Standard_B1ms" -SkuTier "Burstable"
                    Write-Log "  Scaled $serverName to Burstable B1ms"
                }
            }
            else {
                Write-Log "  $serverName already at Burstable B1ms"
            }

            # 4. Stop server
            if ($PSCmdlet.ShouldProcess($serverName, "Stop server")) {
                Stop-AzPostgreSqlFlexibleServer -ResourceGroupName $serverRg -Name $serverName -Confirm:$false
                Write-Log "  Stopped server $serverName"
            }

            $summary.Add([PSCustomObject]@{
                Server        = $serverName
                ResourceGroup = $serverRg
                OldSku        = "$($config.SkuTier)/$($config.Sku)"
                Status        = "Success"
            })
        }
        catch {
            Write-Log "ERROR on ${serverName}: $_" -Level "ERROR"
            $summary.Add([PSCustomObject]@{
                Server        = $serverName
                ResourceGroup = $serverRg
                OldSku        = "N/A"
                Status        = "Failed: $_"
            })
        }
        finally {
            $env:PGPASSWORD = $null
        }
    }

    Write-Log "=== PostgreSQL Archive Summary ==="
    $summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }
    Write-Log "Total: $($summary.Count), Succeeded: $(($summary | Where-Object Status -eq 'Success').Count), Failed: $(($summary | Where-Object Status -ne 'Success').Count)"
}
catch {
    Write-Log "FATAL: $_" -Level "ERROR"
    throw
}
} # end foreach
finally {
    $env:PGPASSWORD = $null
    if ($plainPassword) { $plainPassword = $null }
}
