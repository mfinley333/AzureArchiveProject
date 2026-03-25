#Requires -Modules Az.Accounts, Az.ResourceGraph, Az.Monitor

<#
.SYNOPSIS
    Captures traffic/request metrics for high-risk Azure resources over the last 30 days.

.DESCRIPTION
    Queries Azure Monitor metrics for Storage, SQL, Cosmos DB, Event Hub, Service Bus,
    Web Apps, and API Management resources. Classifies each resource as ZeroTraffic
    (safe to archive) or ActiveTraffic (needs coordination).

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to query.

.PARAMETER LookbackDays
    Number of days to look back for metrics. Defaults to 30.

.PARAMETER OutputPath
    Directory for output files. Defaults to c:\dev\AzureArchiveProject\output\inventory.

.EXAMPLE
    .\03-Capture-TrafficBaseline.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [ValidateRange(1, 90)]
    [int]$LookbackDays = 30,

    [string]$OutputPath = (Join-Path $PSScriptRoot '..\..\output\inventory'),

    [string]$SubscriptionListPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

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

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputFile = Join-Path $OutputPath "traffic-baseline-$timestamp.csv"
$startTime = (Get-Date).AddDays(-$LookbackDays)
$endTime = Get-Date

# Resource types and their primary traffic metrics
$metricMap = @{
    'microsoft.storage/storageaccounts'             = 'Transactions'
    'microsoft.sql/servers/databases'               = 'dtu_consumption_percent'
    'microsoft.documentdb/databaseaccounts'         = 'TotalRequests'
    'microsoft.eventhub/namespaces'                 = 'IncomingMessages'
    'microsoft.servicebus/namespaces'               = 'IncomingMessages'
    'microsoft.web/sites'                           = 'Requests'
    'microsoft.apimanagement/service'               = 'TotalRequests'
    'microsoft.cache/redis'                         = 'totalcommandsprocessed'
    'microsoft.logic/workflows'                     = 'TotalBillableExecutions'
}

$resourceTypeFilter = ($metricMap.Keys | ForEach-Object { "'$_'" }) -join ', '

$query = @"
Resources
| where type in~ ($resourceTypeFilter)
| project id, name, type, resourceGroup, subscriptionId, location
"@

Write-Verbose "Querying Resource Graph for high-risk resource types..."

$resources = [System.Collections.Generic.List[PSObject]]::new()
$skipToken = $null

do {
    $graphParams = @{
        Query        = $query
        Subscription = $SubscriptionId
        First        = 1000
    }
    if ($skipToken) { $graphParams['SkipToken'] = $skipToken }

    $result = Search-AzGraph @graphParams
    $result.Data | ForEach-Object { $resources.Add($_) }
    $skipToken = $result.SkipToken
} while ($skipToken)

Write-Host "Found $($resources.Count) high-risk resources to analyze." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()
$counter = 0

foreach ($res in $resources) {
    $counter++
    if ($counter % 50 -eq 0) {
        Write-Host "Processing $counter / $($resources.Count)..." -ForegroundColor DarkGray
    }

    $typeLower = $res.type.ToLower()
    $metricName = $metricMap[$typeLower]

    if (-not $metricName) {
        Write-Verbose "No metric mapping for $typeLower, skipping $($res.name)"
        continue
    }

    $totalValue = 0
    $metricStatus = 'Unknown'
    $errorMsg = ''

    try {
        Set-AzContext -SubscriptionId $res.subscriptionId -ErrorAction Stop | Out-Null

        $metric = Get-AzMetric -ResourceId $res.id `
            -MetricName $metricName `
            -StartTime $startTime `
            -EndTime $endTime `
            -TimeGrain '1.00:00:00' `
            -AggregationType Total `
            -ErrorAction Stop

        $totalValue = ($metric.Data | Measure-Object -Property Total -Sum).Sum
        if ($null -eq $totalValue) { $totalValue = 0 }

        $metricStatus = if ($totalValue -eq 0) { 'ZeroTraffic' } else { 'ActiveTraffic' }
    }
    catch {
        $metricStatus = 'MetricUnavailable'
        $errorMsg = $_.Exception.Message
        Write-Verbose "Could not retrieve metrics for $($res.id): $errorMsg"
    }

    $results.Add([PSCustomObject]@{
        SubscriptionId      = $res.subscriptionId
        ResourceGroup       = $res.resourceGroup
        ResourceType        = $res.type
        ResourceName        = $res.name
        Location            = $res.location
        MetricName          = $metricName
        MetricTotal30d      = [math]::Round($totalValue, 2)
        TrafficClass        = $metricStatus
        LookbackDays        = $LookbackDays
        Error               = $errorMsg
    })
}

$results | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

$classSummary = $results | Group-Object TrafficClass | Select-Object Name, Count
Write-Host "`nTraffic Classification Summary:" -ForegroundColor Green
$classSummary | Format-Table -AutoSize

$typeSummary = $results |
    Group-Object ResourceType, TrafficClass |
    Select-Object @{N='ResourceType';E={($_.Name -split ', ')[0]}},
                  @{N='TrafficClass';E={($_.Name -split ', ')[1]}},
                  Count |
    Sort-Object ResourceType, TrafficClass

Write-Host "Breakdown by Type:" -ForegroundColor Green
$typeSummary | Format-Table -AutoSize

Write-Host "Results exported to $outputFile" -ForegroundColor Green
