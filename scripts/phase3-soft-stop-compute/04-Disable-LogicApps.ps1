<#
.SYNOPSIS
    Disables Logic Apps tagged for the Azure Archive Project.

.DESCRIPTION
    Phase 3 - Soft-Stop Compute: Disables all Logic Apps tagged
    ArchiveProject=ArchiveLegacy. Exports workflow definitions to
    JSON backup before making changes.

.PARAMETER SubscriptionId
    Target Azure subscription ID. If omitted, uses the current context.

.PARAMETER TagName
    Tag name to filter resources. Default: ArchiveProject

.PARAMETER TagValue
    Tag value to filter resources. Default: ArchiveLegacy

.PARAMETER BackupPath
    Directory for JSON state backups. Default: .\backups\phase3\logicapps

.EXAMPLE
    .\04-Disable-LogicApps.ps1 -WhatIf
    .\04-Disable-LogicApps.ps1 -SubscriptionId "xxxx" -Verbose
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
    [string]$BackupPath = ".\backups\phase3\logicapps"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $BackupPath "disable-logicapps-$timestamp.log"

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
    Write-Log "Phase 3 - Disable Logic Apps started"

    if ($subId) {
        Write-Log "Setting subscription to $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
    }

    # Discover Logic Apps
    Write-Log "Discovering Logic Apps with tag $TagName=$TagValue"
    $logicApps = Get-AzResource -ResourceType "Microsoft.Logic/workflows" -TagName $TagName -TagValue $TagValue
    Write-Log "Found $($logicApps.Count) Logic Apps"

    if ($logicApps.Count -eq 0) {
        Write-Host "No Logic Apps found matching tag filter." -ForegroundColor Yellow
        return
    }

    # Export workflow definitions
    $backupData = @()
    foreach ($la in $logicApps) {
        Write-Log "Exporting workflow definition for $($la.Name)"
        $workflow = Get-AzLogicApp -ResourceGroupName $la.ResourceGroupName -Name $la.Name -ErrorAction Stop

        $backupData += [PSCustomObject]@{
            Name              = $workflow.Name
            ResourceGroupName = $la.ResourceGroupName
            Location          = $workflow.Location
            State             = $workflow.State
            CreatedTime       = $workflow.CreatedTime
            ChangedTime       = $workflow.ChangedTime
            Version           = $workflow.Version
            Definition        = $workflow.Definition | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            Parameters        = $workflow.Parameters
            Tags              = $la.Tags
        }
    }

    $backupFile = Join-Path $BackupPath "logicapp-state-$timestamp.json"
    $backupData | ConvertTo-Json -Depth 20 | Set-Content -Path $backupFile -Encoding UTF8
    Write-Log "Logic App state backed up to $backupFile"

    # Disable Logic Apps
    $successCount = 0
    $failCount = 0

    foreach ($la in $logicApps) {
        $workflow = $backupData | Where-Object { $_.Name -eq $la.Name }

        if ($workflow.State -eq "Disabled") {
            Write-Log "Logic App $($la.Name) already disabled. Skipping."
            $successCount++
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($la.ResourceGroupName)/$($la.Name)", "Disable Logic App")) {
            try {
                Set-AzLogicApp -ResourceGroupName $la.ResourceGroupName -Name $la.Name `
                    -State "Disabled" -Force -ErrorAction Stop | Out-Null
                Write-Log "Disabled Logic App $($la.Name)"
                $successCount++
            }
            catch {
                Write-Log "Failed to disable Logic App $($la.Name): $_" -Level "ERROR"
                $failCount++
            }
        }
    }

    Write-Log "Phase 3 - Disable Logic Apps completed. Success: $successCount, Failed: $failCount"
    Write-Host "Logic Apps disabled. Success: $successCount, Failed: $failCount. Log: $logFile" -ForegroundColor Green
}
catch {
    Write-Log "Fatal error: $_" -Level "ERROR"
    Write-Error "Phase 3 Logic Apps disable failed: $_"
    throw
}
} # end foreach
