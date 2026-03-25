<#
.SYNOPSIS
    Disables legacy monitoring alerts tagged for the Azure Archive Project.

.DESCRIPTION
    Backs up current alert state to JSON, then disables (not deletes) all metric alerts,
    scheduled query rules, smart detector alert rules, and activity log alerts tagged
    ArchiveProject=ArchiveLegacy. Processes in batches to avoid API throttling.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER BackupPath
    Directory for JSON backup of alert states. Defaults to .\output\backups\alerts.

.PARAMETER BatchSize
    Number of alerts to process per batch. Defaults to 50.

.PARAMETER ThrottleDelaySeconds
    Seconds to sleep between batches to avoid API throttling. Defaults to 5.

.EXAMPLE
    .\01-Disable-LegacyAlerts.ps1 -SubscriptionId "aaaa-bbbb-cccc" -WhatIf

.EXAMPLE
    .\01-Disable-LegacyAlerts.ps1 -SubscriptionId @("sub1","sub2") -BatchSize 25 -Verbose
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [ValidateNotNullOrEmpty()]
    [string]$BackupPath = ".\output\backups\alerts",

    [ValidateRange(1, 200)]
    [int]$BatchSize = 50,

    [ValidateRange(1, 60)]
    [int]$ThrottleDelaySeconds = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tagName = 'ArchiveProject'
$tagValue = 'ArchiveLegacy'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$summary = @{
    MetricAlerts         = @{ Total = 0; Disabled = 0; Errors = 0 }
    ScheduledQueryRules  = @{ Total = 0; Disabled = 0; Errors = 0 }
    SmartDetectorRules   = @{ Total = 0; Disabled = 0; Errors = 0 }
    ActivityLogAlerts    = @{ Total = 0; Disabled = 0; Errors = 0 }
}

function Invoke-BatchProcess {
    <#
    .SYNOPSIS
        Processes a collection of resources in batches, invoking a script block for each.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ResourceTypeName,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Resources,
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][int]$Size,
        [Parameter(Mandatory)][int]$Delay
    )

    $total = $Resources.Count
    if ($total -eq 0) {
        Write-Verbose "No $ResourceTypeName found to process."
        return @{ Disabled = 0; Errors = 0 }
    }

    Write-Verbose "Processing $total $ResourceTypeName in batches of $Size..."
    $disabled = 0
    $errors = 0

    for ($i = 0; $i -lt $total; $i += $Size) {
        $batch = $Resources[$i..[Math]::Min($i + $Size - 1, $total - 1)]
        $batchNum = [Math]::Floor($i / $Size) + 1
        $totalBatches = [Math]::Ceiling($total / $Size)
        Write-Verbose "  Batch $batchNum/$totalBatches ($($batch.Count) items)"

        foreach ($resource in $batch) {
            try {
                $result = & $Action $resource
                if ($result) { $disabled++ }
            }
            catch {
                $errors++
                Write-Warning "Failed to disable $ResourceTypeName '$($resource.Name)': $_"
            }
        }

        if ($i + $Size -lt $total) {
            Write-Verbose "  Throttle delay: ${Delay}s"
            Start-Sleep -Seconds $Delay
        }
    }

    return @{ Disabled = $disabled; Errors = $errors }
}

function Export-AlertBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][AllowEmptyCollection()][array]$Resources,
        [Parameter(Mandatory)][string]$BasePath
    )

    $dir = Join-Path $BasePath $Category
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $backupFile = Join-Path $dir "${Category}-backup-${timestamp}.json"
    $backupData = $Resources | ForEach-Object {
        @{
            ResourceId   = $_.ResourceId
            Name         = $_.Name
            ResourceType = $_.ResourceType
            Properties   = $_.Properties
        }
    }
    $backupData | ConvertTo-Json -Depth 20 | Set-Content -Path $backupFile -Encoding UTF8
    Write-Verbose "Backed up $($Resources.Count) $Category to $backupFile"
}

try {
    if (-not (Test-Path $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    }

    foreach ($subId in $SubscriptionId) {
        Write-Verbose "=== Processing subscription: $subId ==="
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

        # --- Metric Alerts ---
        Write-Verbose "Gathering metric alerts..."
        $metricAlerts = @(Get-AzResource -ResourceType "Microsoft.Insights/metricAlerts" `
            -TagName $tagName -TagValue $tagValue -ErrorAction Stop)
        $summary.MetricAlerts.Total += $metricAlerts.Count
        Write-Verbose "Found $($metricAlerts.Count) metric alerts."

        Export-AlertBackup -Category 'metric-alerts' -Resources $metricAlerts -BasePath $BackupPath

        $result = Invoke-BatchProcess -ResourceTypeName 'metric alerts' -Resources $metricAlerts `
            -Size $BatchSize -Delay $ThrottleDelaySeconds -Action {
            param($alert)
            $resource = Get-AzResource -ResourceId $alert.ResourceId -ExpandProperties -ErrorAction Stop
            if ($resource.Properties.enabled -eq $true) {
                if ($PSCmdlet.ShouldProcess($alert.Name, "Disable metric alert")) {
                    $resource.Properties.enabled = $false
                    Set-AzResource -ResourceId $alert.ResourceId -Properties $resource.Properties -Force -ErrorAction Stop | Out-Null
                    return $true
                }
            }
            else {
                Write-Verbose "  Metric alert '$($alert.Name)' already disabled."
            }
            return $false
        }
        $summary.MetricAlerts.Disabled += $result.Disabled
        $summary.MetricAlerts.Errors += $result.Errors

        # --- Scheduled Query Rules ---
        Write-Verbose "Gathering scheduled query rules..."
        $queryRules = @(Get-AzResource -ResourceType "Microsoft.Insights/scheduledQueryRules" `
            -TagName $tagName -TagValue $tagValue -ErrorAction Stop)
        $summary.ScheduledQueryRules.Total += $queryRules.Count
        Write-Verbose "Found $($queryRules.Count) scheduled query rules."

        Export-AlertBackup -Category 'scheduled-query-rules' -Resources $queryRules -BasePath $BackupPath

        $result = Invoke-BatchProcess -ResourceTypeName 'scheduled query rules' -Resources $queryRules `
            -Size $BatchSize -Delay $ThrottleDelaySeconds -Action {
            param($rule)
            $resource = Get-AzResource -ResourceId $rule.ResourceId -ExpandProperties -ErrorAction Stop
            if ($resource.Properties.enabled -eq 'true' -or $resource.Properties.enabled -eq $true) {
                if ($PSCmdlet.ShouldProcess($rule.Name, "Disable scheduled query rule")) {
                    $resource.Properties.enabled = 'false'
                    Set-AzResource -ResourceId $rule.ResourceId -Properties $resource.Properties -Force -ErrorAction Stop | Out-Null
                    return $true
                }
            }
            else {
                Write-Verbose "  Scheduled query rule '$($rule.Name)' already disabled."
            }
            return $false
        }
        $summary.ScheduledQueryRules.Disabled += $result.Disabled
        $summary.ScheduledQueryRules.Errors += $result.Errors

        # --- Smart Detector Alert Rules ---
        Write-Verbose "Gathering smart detector alert rules..."
        $smartDetectors = @(Get-AzResource -ResourceType "microsoft.alertsManagement/smartDetectorAlertRules" `
            -TagName $tagName -TagValue $tagValue -ErrorAction Stop)
        $summary.SmartDetectorRules.Total += $smartDetectors.Count
        Write-Verbose "Found $($smartDetectors.Count) smart detector alert rules."

        Export-AlertBackup -Category 'smart-detector-rules' -Resources $smartDetectors -BasePath $BackupPath

        $result = Invoke-BatchProcess -ResourceTypeName 'smart detector rules' -Resources $smartDetectors `
            -Size $BatchSize -Delay $ThrottleDelaySeconds -Action {
            param($rule)
            $resource = Get-AzResource -ResourceId $rule.ResourceId -ExpandProperties -ErrorAction Stop
            if ($resource.Properties.state -eq 'Enabled') {
                if ($PSCmdlet.ShouldProcess($rule.Name, "Disable smart detector rule")) {
                    $resource.Properties.state = 'Disabled'
                    Set-AzResource -ResourceId $rule.ResourceId -Properties $resource.Properties -Force -ErrorAction Stop | Out-Null
                    return $true
                }
            }
            else {
                Write-Verbose "  Smart detector rule '$($rule.Name)' already disabled."
            }
            return $false
        }
        $summary.SmartDetectorRules.Disabled += $result.Disabled
        $summary.SmartDetectorRules.Errors += $result.Errors

        # --- Activity Log Alerts ---
        Write-Verbose "Gathering activity log alerts..."
        $activityAlerts = @(Get-AzResource -ResourceType "Microsoft.Insights/activityLogAlerts" `
            -TagName $tagName -TagValue $tagValue -ErrorAction Stop)
        $summary.ActivityLogAlerts.Total += $activityAlerts.Count
        Write-Verbose "Found $($activityAlerts.Count) activity log alerts."

        Export-AlertBackup -Category 'activity-log-alerts' -Resources $activityAlerts -BasePath $BackupPath

        $result = Invoke-BatchProcess -ResourceTypeName 'activity log alerts' -Resources $activityAlerts `
            -Size $BatchSize -Delay $ThrottleDelaySeconds -Action {
            param($alert)
            $resource = Get-AzResource -ResourceId $alert.ResourceId -ExpandProperties -ErrorAction Stop
            if ($resource.Properties.enabled -eq $true) {
                if ($PSCmdlet.ShouldProcess($alert.Name, "Disable activity log alert")) {
                    $resource.Properties.enabled = $false
                    Set-AzResource -ResourceId $alert.ResourceId -Properties $resource.Properties -Force -ErrorAction Stop | Out-Null
                    return $true
                }
            }
            else {
                Write-Verbose "  Activity log alert '$($alert.Name)' already disabled."
            }
            return $false
        }
        $summary.ActivityLogAlerts.Disabled += $result.Disabled
        $summary.ActivityLogAlerts.Errors += $result.Errors
    }

    # --- Summary ---
    Write-Host "`n===== Disable Legacy Alerts Summary =====" -ForegroundColor Cyan
    foreach ($type in $summary.Keys) {
        $s = $summary[$type]
        $color = if ($s.Errors -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host ("  {0,-25} Total: {1,5}  Disabled: {2,5}  Errors: {3,4}" -f $type, $s.Total, $s.Disabled, $s.Errors) -ForegroundColor $color
    }
    Write-Host "========================================`n" -ForegroundColor Cyan

    $summaryFile = Join-Path $BackupPath "disable-summary-${timestamp}.json"
    $summary | ConvertTo-Json -Depth 5 | Set-Content -Path $summaryFile -Encoding UTF8
    Write-Verbose "Summary saved to $summaryFile"
}
catch {
    Write-Error "Fatal error in Disable-LegacyAlerts: $_"
    throw
}
