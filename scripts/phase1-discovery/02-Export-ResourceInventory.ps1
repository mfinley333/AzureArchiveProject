#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Exports a full Azure resource inventory using Resource Graph.

.DESCRIPTION
    Queries Azure Resource Graph across specified subscriptions to produce a comprehensive
    resource inventory CSV and a grouped summary by ResourceType. Designed for the Legacy
    Legacy Archive project (~9000+ resources across 87 types).

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to query.

.PARAMETER OutputPath
    Directory for output files. Defaults to c:\dev\AzureArchiveProject\output\inventory.

.EXAMPLE
    .\02-Export-ResourceInventory.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [string]$OutputPath = 'c:\dev\AzureArchiveProject\output\inventory'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$inventoryFile = Join-Path $OutputPath "resource-inventory-$timestamp.csv"
$summaryFile = Join-Path $OutputPath "resource-summary-$timestamp.csv"

$query = @"
Resources
| project
    subscriptionId,
    resourceGroup,
    type,
    name,
    location,
    tags,
    sku = coalesce(sku.name, sku.tier, ''),
    createdTime = tostring(properties.creationTime)
| order by type asc, name asc
"@

Write-Verbose "Querying Resource Graph across $($SubscriptionId.Count) subscription(s)..."

$allResources = [System.Collections.Generic.List[PSCustomObject]]::new()
$pageSize = 1000
$skipToken = $null

do {
    $graphParams = @{
        Query        = $query
        Subscription = $SubscriptionId
        First        = $pageSize
    }
    if ($skipToken) {
        $graphParams['SkipToken'] = $skipToken
    }

    try {
        $result = Search-AzGraph @graphParams
    }
    catch {
        Write-Error "Resource Graph query failed: $_"
        return
    }

    foreach ($row in $result.Data) {
        $tagString = ''
        if ($row.tags) {
            $tagString = ($row.tags.PSObject.Properties |
                ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '
        }

        $allResources.Add([PSCustomObject]@{
            SubscriptionId = $row.subscriptionId
            ResourceGroup  = $row.resourceGroup
            ResourceType   = $row.type
            ResourceName   = $row.name
            Location       = $row.location
            Tags           = $tagString
            SKU            = $row.sku
            CreatedDate    = $row.createdTime
        })
    }

    $skipToken = $result.SkipToken
    Write-Verbose "Retrieved $($allResources.Count) resources so far..."
} while ($skipToken)

Write-Host "Total resources discovered: $($allResources.Count)" -ForegroundColor Cyan

$allResources | Export-Csv -Path $inventoryFile -NoTypeInformation -Encoding UTF8
Write-Verbose "Full inventory exported to $inventoryFile"

$summary = $allResources |
    Group-Object ResourceType |
    Select-Object @{N='ResourceType';E={$_.Name}}, Count |
    Sort-Object Count -Descending

$summary | Export-Csv -Path $summaryFile -NoTypeInformation -Encoding UTF8
Write-Verbose "Summary exported to $summaryFile"

Write-Host "`nResource Summary:" -ForegroundColor Green
$summary | Format-Table -AutoSize
Write-Host "Inventory: $inventoryFile"
Write-Host "Summary:   $summaryFile"
