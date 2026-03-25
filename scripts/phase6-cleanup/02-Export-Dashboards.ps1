<#
.SYNOPSIS
    Exports Azure dashboards tagged for the Azure Archive Project as ARM JSON templates.

.DESCRIPTION
    Retrieves all dashboards tagged ArchiveProject=ArchiveLegacy and exports each as an
    ARM JSON template to the specified output directory. Processes in batches to avoid
    API throttling.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER OutputPath
    Directory for exported dashboard JSON files. Defaults to .\output\backups\dashboards.

.PARAMETER BatchSize
    Number of dashboards to export per batch. Defaults to 50.

.EXAMPLE
    .\02-Export-Dashboards.ps1 -SubscriptionId "aaaa-bbbb-cccc" -Verbose

.EXAMPLE
    .\02-Export-Dashboards.ps1 -SubscriptionId @("sub1","sub2") -OutputPath "C:\backups\dashboards"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [Alias('BackupPath')]
    [string]$OutputPath = ".\output\backups\dashboards",

    [ValidateRange(1, 200)]
    [int]$BatchSize = 50,

    [string]$SubscriptionListPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

if (-not $SubscriptionId -and $SubscriptionListPath) {
    $SubscriptionId = Import-SubscriptionList -Path $SubscriptionListPath
}

$tagName = 'ArchiveProject'
$tagValue = 'ArchiveLegacy'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Get-SanitizedFileName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    return ($Name -replace '[\\/:*?"<>|]', '_' -replace '\s+', '_').Trim('_')
}

try {
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Verbose "Created output directory: $OutputPath"
    }

    $totalExported = 0
    $totalFailed = 0
    $totalFound = 0

    foreach ($subId in $SubscriptionId) {
        Write-Verbose "=== Processing subscription: $subId ==="
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

        $dashboards = @(Get-AzResource -ResourceType "Microsoft.Portal/dashboards" `
            -TagName $tagName -TagValue $tagValue -ErrorAction Stop)
        $totalFound += $dashboards.Count
        Write-Verbose "Found $($dashboards.Count) dashboards in subscription $subId."

        if ($dashboards.Count -eq 0) { continue }

        $subDir = Join-Path $OutputPath $subId
        if (-not (Test-Path $subDir)) {
            New-Item -ItemType Directory -Path $subDir -Force | Out-Null
        }

        $totalBatches = [Math]::Ceiling($dashboards.Count / $BatchSize)

        for ($i = 0; $i -lt $dashboards.Count; $i += $BatchSize) {
            $batch = $dashboards[$i..[Math]::Min($i + $BatchSize - 1, $dashboards.Count - 1)]
            $batchNum = [Math]::Floor($i / $BatchSize) + 1
            Write-Verbose "  Batch $batchNum/$totalBatches ($($batch.Count) dashboards)"

            foreach ($dashboard in $batch) {
                $safeName = Get-SanitizedFileName -Name $dashboard.Name
                $fileName = "${safeName}_${timestamp}.json"
                $filePath = Join-Path $subDir $fileName

                try {
                    if ($PSCmdlet.ShouldProcess($dashboard.Name, "Export dashboard")) {
                        $fullResource = Get-AzResource -ResourceId $dashboard.ResourceId `
                            -ExpandProperties -ErrorAction Stop

                        $armTemplate = @{
                            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
                            contentVersion = '1.0.0.0'
                            resources      = @(
                                @{
                                    type       = $fullResource.ResourceType
                                    apiVersion = '2020-09-01-preview'
                                    name       = $fullResource.Name
                                    location   = $fullResource.Location
                                    tags       = $fullResource.Tags
                                    properties = $fullResource.Properties
                                }
                            )
                        }

                        $armTemplate | ConvertTo-Json -Depth 50 | Set-Content -Path $filePath -Encoding UTF8
                        $totalExported++
                        Write-Verbose "    Exported: $($dashboard.Name)"
                    }
                }
                catch {
                    $totalFailed++
                    Write-Warning "Failed to export dashboard '$($dashboard.Name)': $_"
                }
            }

            if ($i + $BatchSize -lt $dashboards.Count) {
                Start-Sleep -Seconds 2
            }
        }
    }

    # --- Summary ---
    Write-Host "`n===== Export Dashboards Summary =====" -ForegroundColor Cyan
    Write-Host "  Dashboards found:    $totalFound" -ForegroundColor White
    Write-Host "  Dashboards exported: $totalExported" -ForegroundColor Green
    if ($totalFailed -gt 0) {
        Write-Host "  Dashboards failed:   $totalFailed" -ForegroundColor Yellow
    }
    else {
        Write-Host "  Dashboards failed:   0" -ForegroundColor Green
    }
    Write-Host "  Output directory:    $OutputPath" -ForegroundColor White
    Write-Host "====================================`n" -ForegroundColor Cyan

    $summaryFile = Join-Path $OutputPath "export-summary-${timestamp}.json"
    @{
        Timestamp  = $timestamp
        Found      = $totalFound
        Exported   = $totalExported
        Failed     = $totalFailed
        OutputPath = $OutputPath
    } | ConvertTo-Json | Set-Content -Path $summaryFile -Encoding UTF8
    Write-Verbose "Summary saved to $summaryFile"
}
catch {
    Write-Error "Fatal error in Export-Dashboards: $_"
    throw
}
