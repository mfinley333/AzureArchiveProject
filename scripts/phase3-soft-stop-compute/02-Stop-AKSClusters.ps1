<#
.SYNOPSIS
    Stops AKS clusters tagged for the Azure Archive Project.

.DESCRIPTION
    Phase 3 - Soft-Stop Compute: Stops all AKS clusters tagged
    ArchiveProject=ArchiveLegacy using 'az aks stop'. Exports cluster
    configurations (node pools, networking, RBAC) to JSON backup first.

.PARAMETER SubscriptionId
    Target Azure subscription ID. If omitted, uses the current context.

.PARAMETER TagName
    Tag name to filter resources. Default: ArchiveProject

.PARAMETER TagValue
    Tag value to filter resources. Default: ArchiveLegacy

.PARAMETER BackupPath
    Directory for JSON state backups. Default: .\backups\phase3\aks

.EXAMPLE
    .\02-Stop-AKSClusters.ps1 -Verbose
    .\02-Stop-AKSClusters.ps1 -SubscriptionId "xxxx"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [string]$SubscriptionListPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TagName = "ArchiveProject",

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TagValue = "ArchiveLegacy",

    [Parameter()]
    [string]$BackupPath = ".\backups\phase3\aks"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $BackupPath "stop-aks-$timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[$timestamp] [$Level] $Message"
    Write-Verbose $entry
    if (Test-Path (Split-Path $logFile -Parent)) {
        Add-Content -Path $logFile -Value $entry
    }
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
    $SubscriptionId = @('')
}

foreach ($subId in $SubscriptionId) {
try {
    if (-not (Test-Path $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    }
    Write-Log "Phase 3 - Stop AKS Clusters started"

    if ($subId) {
        Write-Log "Setting subscription to $subId"
        az account set --subscription $subId
    }

    # Discover AKS clusters with tag
    Write-Log "Discovering AKS clusters with tag $TagName=$TagValue"
    $clustersJson = az aks list --query "[?tags.$TagName=='$TagValue']" -o json 2>&1
    $clusters = $clustersJson | ConvertFrom-Json

    if (-not $clusters -or $clusters.Count -eq 0) {
        Write-Log "No AKS clusters found matching tag filter."
        Write-Host "No AKS clusters found. Exiting." -ForegroundColor Yellow
        return
    }
    Write-Log "Found $($clusters.Count) AKS clusters"

    # Export detailed config for each cluster
    $clusterBackups = @()
    foreach ($cluster in $clusters) {
        $rgName = $cluster.resourceGroup
        $clusterName = $cluster.name

        Write-Log "Exporting config for AKS cluster $rgName/$clusterName"

        $nodePoolsJson = az aks nodepool list --resource-group $rgName --cluster-name $clusterName -o json 2>&1
        $nodePools = $nodePoolsJson | ConvertFrom-Json

        $clusterBackups += [PSCustomObject]@{
            Name                = $clusterName
            ResourceGroup       = $rgName
            Location            = $cluster.location
            KubernetesVersion   = $cluster.kubernetesVersion
            PowerState          = $cluster.powerState.code
            NodePools           = $nodePools | ForEach-Object {
                [PSCustomObject]@{
                    Name       = $_.name
                    VmSize     = $_.vmSize
                    Count      = $_.count
                    MinCount   = $_.minCount
                    MaxCount   = $_.maxCount
                    Mode       = $_.mode
                    OsType     = $_.osType
                    PowerState = $_.powerState.code
                }
            }
            NetworkProfile      = [PSCustomObject]@{
                NetworkPlugin = $cluster.networkProfile.networkPlugin
                NetworkPolicy = $cluster.networkProfile.networkPolicy
                PodCidr       = $cluster.networkProfile.podCidr
                ServiceCidr   = $cluster.networkProfile.serviceCidr
                DnsServiceIP  = $cluster.networkProfile.dnsServiceIP
            }
            EnableRBAC          = $cluster.enableRbac
            AadProfile          = $cluster.aadProfile
            Sku                 = $cluster.sku
            Tags                = $cluster.tags
        }
    }

    $backupFile = Join-Path $BackupPath "aks-state-$timestamp.json"
    $clusterBackups | ConvertTo-Json -Depth 10 | Set-Content -Path $backupFile -Encoding UTF8
    Write-Log "AKS cluster state backed up to $backupFile"

    # Stop each cluster
    $successCount = 0
    $failCount = 0

    foreach ($cluster in $clusters) {
        $rgName = $cluster.resourceGroup
        $clusterName = $cluster.name

        if ($cluster.powerState.code -eq "Stopped") {
            Write-Log "AKS cluster $clusterName already stopped. Skipping."
            $successCount++
            continue
        }

        if ($PSCmdlet.ShouldProcess("$rgName/$clusterName", "Stop AKS cluster")) {
            try {
                Write-Log "Stopping AKS cluster $rgName/$clusterName"
                $result = az aks stop --resource-group $rgName --name $clusterName 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "az aks stop failed: $result"
                }
                Write-Log "AKS cluster $clusterName stopped successfully"
                $successCount++
            }
            catch {
                Write-Log "Failed to stop AKS cluster $clusterName`: $_" -Level "ERROR"
                $failCount++
            }
        }
    }

    Write-Log "Phase 3 - Stop AKS Clusters completed. Success: $successCount, Failed: $failCount"
    Write-Host "AKS stop complete. Success: $successCount, Failed: $failCount. Log: $logFile" -ForegroundColor Green
}
catch {
    Write-Log "Fatal error: $_" -Level "ERROR"
    Write-Error "Phase 3 AKS stop failed: $_"
    throw
}
} # end foreach
