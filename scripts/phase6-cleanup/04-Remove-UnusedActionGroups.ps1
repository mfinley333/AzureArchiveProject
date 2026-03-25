<#
.SYNOPSIS
    Identifies and removes unused action groups tagged for the Azure Archive Project.

.DESCRIPTION
    Gets all action groups tagged ArchiveProject=ArchiveLegacy, cross-references them against
    active alert rules (metric alerts, scheduled query rules, activity log alerts), identifies
    unreferenced action groups, backs up their configs to JSON, and removes them with
    WhatIf/Confirm support.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER BackupPath
    Directory for JSON backup of action group configs. Defaults to .\output\backups\action-groups.

.EXAMPLE
    .\04-Remove-UnusedActionGroups.ps1 -SubscriptionId "aaaa-bbbb-cccc" -WhatIf

.EXAMPLE
    .\04-Remove-UnusedActionGroups.ps1 -SubscriptionId @("sub1","sub2") -Verbose -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$BackupPath = ".\output\backups\action-groups",

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

function Get-ReferencedActionGroupIds {
    <#
    .SYNOPSIS
        Collects all action group resource IDs referenced by active alert rules.
    #>
    [CmdletBinding()]
    param()

    $referenced = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    # Metric alerts
    Write-Verbose "  Scanning metric alerts for action group references..."
    $metricAlerts = @(Get-AzResource -ResourceType "Microsoft.Insights/metricAlerts" -ExpandProperties -ErrorAction SilentlyContinue)
    foreach ($alert in $metricAlerts) {
        if ($alert.Properties.enabled -eq $false) { continue }
        $actions = $alert.Properties.actions
        if ($actions) {
            foreach ($action in $actions) {
                if ($action.actionGroupId) {
                    [void]$referenced.Add($action.actionGroupId)
                }
            }
        }
    }
    Write-Verbose "    Metric alerts scanned: $($metricAlerts.Count)"

    # Scheduled query rules
    Write-Verbose "  Scanning scheduled query rules for action group references..."
    $queryRules = @(Get-AzResource -ResourceType "Microsoft.Insights/scheduledQueryRules" -ExpandProperties -ErrorAction SilentlyContinue)
    foreach ($rule in $queryRules) {
        $enabled = $rule.Properties.enabled
        if ($enabled -eq $false -or $enabled -eq 'false') { continue }
        $action = $rule.Properties.action
        if ($action -and $action.aznsAction -and $action.aznsAction.actionGroup) {
            foreach ($agId in $action.aznsAction.actionGroup) {
                [void]$referenced.Add($agId)
            }
        }
        # V2 scheduled query rules
        if ($rule.Properties.actions -and $rule.Properties.actions.actionGroups) {
            foreach ($ag in $rule.Properties.actions.actionGroups) {
                if ($ag.actionGroupId) {
                    [void]$referenced.Add($ag.actionGroupId)
                }
            }
        }
    }
    Write-Verbose "    Scheduled query rules scanned: $($queryRules.Count)"

    # Activity log alerts
    Write-Verbose "  Scanning activity log alerts for action group references..."
    $activityAlerts = @(Get-AzResource -ResourceType "Microsoft.Insights/activityLogAlerts" -ExpandProperties -ErrorAction SilentlyContinue)
    foreach ($alert in $activityAlerts) {
        if ($alert.Properties.enabled -eq $false) { continue }
        $actionGroups = $alert.Properties.actions.actionGroups
        if ($actionGroups) {
            foreach ($ag in $actionGroups) {
                if ($ag.actionGroupId) {
                    [void]$referenced.Add($ag.actionGroupId)
                }
            }
        }
    }
    Write-Verbose "    Activity log alerts scanned: $($activityAlerts.Count)"

    return $referenced
}

try {
    if (-not (Test-Path $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
        Write-Verbose "Created backup directory: $BackupPath"
    }

    $totalActionGroups = 0
    $totalReferenced = 0
    $totalUnused = 0
    $totalRemoved = 0
    $totalErrors = 0

    foreach ($subId in $SubscriptionId) {
        Write-Verbose "=== Processing subscription: $subId ==="
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

        # Get tagged action groups
        Write-Verbose "Gathering action groups..."
        $actionGroups = @(Get-AzResource -ResourceType "Microsoft.Insights/actionGroups" `
            -TagName $tagName -TagValue $tagValue -ErrorAction Stop)
        $totalActionGroups += $actionGroups.Count
        Write-Verbose "Found $($actionGroups.Count) tagged action groups."

        if ($actionGroups.Count -eq 0) { continue }

        # Get referenced action group IDs from all active alerts
        Write-Verbose "Scanning active alert rules for action group references..."
        $referencedIds = Get-ReferencedActionGroupIds

        # Partition into referenced vs unused
        $unused = @()
        $referencedCount = 0
        foreach ($ag in $actionGroups) {
            if ($referencedIds.Contains($ag.ResourceId)) {
                $referencedCount++
            }
            else {
                $unused += $ag
            }
        }

        $totalReferenced += $referencedCount
        $totalUnused += $unused.Count
        Write-Verbose "Referenced: $referencedCount, Unused: $($unused.Count)"

        if ($unused.Count -eq 0) {
            Write-Verbose "No unused action groups in subscription $subId."
            continue
        }

        # Backup unused action groups
        $subBackupDir = Join-Path $BackupPath $subId
        if (-not (Test-Path $subBackupDir)) {
            New-Item -ItemType Directory -Path $subBackupDir -Force | Out-Null
        }

        Write-Verbose "Backing up $($unused.Count) unused action groups..."
        $backupData = @()
        foreach ($ag in $unused) {
            try {
                $full = Get-AzResource -ResourceId $ag.ResourceId -ExpandProperties -ErrorAction Stop
                $backupData += @{
                    ResourceId        = $full.ResourceId
                    Name              = $full.Name
                    ResourceGroupName = $full.ResourceGroupName
                    Location          = $full.Location
                    Tags              = $full.Tags
                    Properties        = $full.Properties
                }
            }
            catch {
                Write-Warning "Failed to backup action group '$($ag.Name)': $_"
                $backupData += @{
                    ResourceId = $ag.ResourceId
                    Name       = $ag.Name
                    Error      = $_.ToString()
                }
            }
        }

        $backupFile = Join-Path $subBackupDir "unused-action-groups-${timestamp}.json"
        $backupData | ConvertTo-Json -Depth 20 | Set-Content -Path $backupFile -Encoding UTF8
        Write-Verbose "Backup saved to $backupFile"

        # Remove unused action groups
        foreach ($ag in $unused) {
            try {
                if ($PSCmdlet.ShouldProcess($ag.Name, "Remove unused action group")) {
                    $rgName = $ag.ResourceId -replace '.*resourceGroups/([^/]+)/.*', '$1'
                    Remove-AzActionGroup -ResourceGroupName $rgName -Name $ag.Name -ErrorAction Stop
                    $totalRemoved++
                    Write-Verbose "  Removed: $($ag.Name)"
                }
            }
            catch {
                $totalErrors++
                Write-Warning "Failed to remove action group '$($ag.Name)': $_"
            }
        }
    }

    # --- Summary ---
    Write-Host "`n===== Remove Unused Action Groups Summary =====" -ForegroundColor Cyan
    Write-Host "  Total action groups (tagged): $totalActionGroups" -ForegroundColor White
    Write-Host "  Referenced by active alerts:  $totalReferenced" -ForegroundColor Green
    Write-Host "  Unused (not referenced):      $totalUnused" -ForegroundColor Yellow
    Write-Host "  Removed:                      $totalRemoved" -ForegroundColor $(if ($totalRemoved -gt 0) { 'Green' } else { 'White' })
    if ($totalErrors -gt 0) {
        Write-Host "  Errors:                       $totalErrors" -ForegroundColor Red
    }
    else {
        Write-Host "  Errors:                       0" -ForegroundColor Green
    }
    Write-Host "  Backups:                      $BackupPath" -ForegroundColor White
    Write-Host "================================================`n" -ForegroundColor Cyan

    $summaryFile = Join-Path $BackupPath "removal-summary-${timestamp}.json"
    @{
        Timestamp      = $timestamp
        TotalTagged    = $totalActionGroups
        Referenced     = $totalReferenced
        Unused         = $totalUnused
        Removed        = $totalRemoved
        Errors         = $totalErrors
    } | ConvertTo-Json | Set-Content -Path $summaryFile -Encoding UTF8
    Write-Verbose "Summary saved to $summaryFile"
}
catch {
    Write-Error "Fatal error in Remove-UnusedActionGroups: $_"
    throw
}
