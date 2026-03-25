<#
.SYNOPSIS
    Generates a consolidation plan for Log Analytics workspaces tagged for the Azure Archive Project.

.DESCRIPTION
    Read-only script that inventories Log Analytics workspaces tagged ArchiveProject=ArchiveLegacy.
    For each workspace, exports saved searches, solutions, linked services, data source configs,
    usage/ingestion volume, SKU, and retention settings. Produces a JSON consolidation plan and
    a human-readable console summary. Does NOT modify or delete anything.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER OutputPath
    Directory for the consolidation plan report. Defaults to .\output\reports\log-analytics.

.PARAMETER Tag
    Hashtable of tag name/value to filter workspaces. Defaults to @{ArchiveProject="ArchiveLegacy"}.

.EXAMPLE
    .\03-Consolidate-LogAnalytics.ps1 -SubscriptionId "aaaa-bbbb-cccc" -Verbose

.EXAMPLE
    .\03-Consolidate-LogAnalytics.ps1 -SubscriptionId @("sub1","sub2") -Tag @{Environment="Legacy"}
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = ".\output\reports\log-analytics",

    [ValidateNotNullOrEmpty()]
    [hashtable]$Tag = @{ ArchiveProject = "ArchiveLegacy" }
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tagName = ($Tag.Keys | Select-Object -First 1)
$tagValue = $Tag[$tagName]

function Get-WorkspaceDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Workspace
    )

    $rgName = $Workspace.ResourceGroupName
    $wsName = $Workspace.Name

    Write-Verbose "  Gathering details for workspace: $wsName"

    # Saved searches
    $savedSearches = @()
    try {
        $savedSearches = @(Get-AzOperationalInsightsSavedSearch -ResourceGroupName $rgName -WorkspaceName $wsName -ErrorAction Stop)
        Write-Verbose "    Saved searches: $($savedSearches.Count)"
    }
    catch {
        Write-Warning "    Failed to get saved searches for '$wsName': $_"
    }

    # Solutions / Intelligence Packs
    $solutions = @()
    try {
        $solutions = @(Get-AzOperationalInsightsIntelligencePack -ResourceGroupName $rgName -WorkspaceName $wsName -ErrorAction Stop)
        Write-Verbose "    Solutions: $($solutions.Count)"
    }
    catch {
        Write-Warning "    Failed to get solutions for '$wsName': $_"
    }

    # Linked services
    $linkedServices = @()
    try {
        $wsResourceId = $Workspace.ResourceId
        $linkedServices = @(Get-AzResource -ResourceId "$wsResourceId/linkedServices" -ApiVersion '2020-08-01' -ErrorAction Stop)
        Write-Verbose "    Linked services: $($linkedServices.Count)"
    }
    catch {
        Write-Verbose "    No linked services found for '$wsName' (or access denied)."
    }

    # Data sources
    $dataSources = @()
    try {
        $dataSources = @(Get-AzOperationalInsightsDataSource -ResourceGroupName $rgName -WorkspaceName $wsName -Kind 'WindowsEvent' -ErrorAction SilentlyContinue)
        $dataSources += @(Get-AzOperationalInsightsDataSource -ResourceGroupName $rgName -WorkspaceName $wsName -Kind 'WindowsPerformanceCounter' -ErrorAction SilentlyContinue)
        $dataSources += @(Get-AzOperationalInsightsDataSource -ResourceGroupName $rgName -WorkspaceName $wsName -Kind 'LinuxSyslog' -ErrorAction SilentlyContinue)
        Write-Verbose "    Data sources: $($dataSources.Count)"
    }
    catch {
        Write-Warning "    Failed to get data sources for '$wsName': $_"
    }

    # Usage
    $usage = @()
    try {
        $usage = @(Get-AzOperationalInsightsUsage -ResourceGroupName $rgName -WorkspaceName $wsName -ErrorAction Stop)
        Write-Verbose "    Usage metrics: $($usage.Count)"
    }
    catch {
        Write-Warning "    Failed to get usage for '$wsName': $_"
    }

    return @{
        Name              = $wsName
        ResourceGroupName = $rgName
        ResourceId        = $Workspace.ResourceId
        Location          = $Workspace.Location
        Sku               = $Workspace.Sku
        RetentionInDays   = $Workspace.RetentionInDays
        Tags              = $Workspace.Tags
        SavedSearches     = $savedSearches | ForEach-Object {
            @{ Id = $_.Id; DisplayName = $_.Properties.DisplayName; Category = $_.Properties.Category; Query = $_.Properties.Query }
        }
        Solutions         = $solutions | ForEach-Object {
            @{ Name = $_.Name; Enabled = $_.Enabled }
        }
        LinkedServices    = $linkedServices | ForEach-Object {
            @{ Name = $_.Name; ResourceId = $_.ResourceId }
        }
        DataSources       = $dataSources | ForEach-Object {
            @{ Name = $_.Name; Kind = $_.Kind }
        }
        Usage             = $usage | ForEach-Object {
            @{ Name = $_.Id; CurrentValue = $_.CurrentValue; Limit = $_.Limit; Unit = $_.Unit }
        }
    }
}

try {
    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        Write-Verbose "Created output directory: $OutputPath"
    }

    $allWorkspaces = @()

    foreach ($subId in $SubscriptionId) {
        Write-Verbose "=== Processing subscription: $subId ==="
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

        $workspaces = @(Get-AzOperationalInsightsWorkspace -ErrorAction Stop |
            Where-Object { $_.Tags[$tagName] -eq $tagValue })
        Write-Verbose "Found $($workspaces.Count) tagged workspaces in subscription $subId."

        foreach ($ws in $workspaces) {
            try {
                $details = Get-WorkspaceDetails -Workspace $ws
                $details['SubscriptionId'] = $subId
                $allWorkspaces += $details
            }
            catch {
                Write-Warning "Failed to gather details for workspace '$($ws.Name)': $_"
            }
        }
    }

    # --- Build consolidation plan ---
    $locationGroups = $allWorkspaces | Group-Object -Property Location
    $skuGroups = $allWorkspaces | Group-Object -Property { $_.Sku }

    $plan = @{
        GeneratedAt         = $timestamp
        TotalWorkspaces     = $allWorkspaces.Count
        ByLocation          = @{}
        BySku               = @{}
        Workspaces          = $allWorkspaces
    }

    foreach ($group in $locationGroups) {
        $plan.ByLocation[$group.Name] = @{
            Count      = $group.Count
            Workspaces = $group.Group | ForEach-Object { $_.Name }
        }
    }

    foreach ($group in $skuGroups) {
        $plan.BySku[$group.Name] = @{
            Count      = $group.Count
            Workspaces = $group.Group | ForEach-Object { $_.Name }
        }
    }

    # --- Export JSON ---
    $reportFile = Join-Path $OutputPath "consolidation-plan-${timestamp}.json"
    $plan | ConvertTo-Json -Depth 30 | Set-Content -Path $reportFile -Encoding UTF8
    Write-Verbose "Consolidation plan saved to $reportFile"

    # --- Console Summary ---
    Write-Host "`n===== Log Analytics Consolidation Summary =====" -ForegroundColor Cyan
    Write-Host "  Total workspaces: $($allWorkspaces.Count)" -ForegroundColor White
    Write-Host ""
    Write-Host "  By Location:" -ForegroundColor White
    foreach ($loc in $plan.ByLocation.Keys | Sort-Object) {
        $info = $plan.ByLocation[$loc]
        Write-Host ("    {0,-25} {1} workspace(s)" -f $loc, $info.Count) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  By SKU:" -ForegroundColor White
    foreach ($sku in $plan.BySku.Keys | Sort-Object) {
        $info = $plan.BySku[$sku]
        Write-Host ("    {0,-25} {1} workspace(s)" -f $sku, $info.Count) -ForegroundColor Gray
    }
    Write-Host ""
    Write-Host "  Retention Settings:" -ForegroundColor White
    $retentionGroups = $allWorkspaces | Group-Object -Property RetentionInDays
    foreach ($rg in $retentionGroups | Sort-Object Name) {
        Write-Host ("    {0,5} days:  {1} workspace(s)" -f $rg.Name, $rg.Count) -ForegroundColor Gray
    }
    Write-Host ""

    $totalSavedSearches = ($allWorkspaces | ForEach-Object { $_.SavedSearches.Count } | Measure-Object -Sum).Sum
    $totalSolutions = ($allWorkspaces | ForEach-Object { ($_.Solutions | Where-Object { $_.Enabled }).Count } | Measure-Object -Sum).Sum
    Write-Host "  Total saved searches:   $totalSavedSearches" -ForegroundColor White
    Write-Host "  Total enabled solutions: $totalSolutions" -ForegroundColor White
    Write-Host "  Report: $reportFile" -ForegroundColor White
    Write-Host "================================================`n" -ForegroundColor Cyan
}
catch {
    Write-Error "Fatal error in Consolidate-LogAnalytics: $_"
    throw
}
