<#
.SYNOPSIS
    Disables Automation Account schedules and exports runbook content for the Azure Archive Project.

.DESCRIPTION
    Phase 3 - Soft-Stop Compute: Disables all schedules on Automation Accounts
    tagged ArchiveProject=ArchiveLegacy. Exports runbook content and schedule
    configurations to backup before making changes.

.PARAMETER SubscriptionId
    Target Azure subscription ID. If omitted, uses the current context.

.PARAMETER TagName
    Tag name to filter resources. Default: ArchiveProject

.PARAMETER TagValue
    Tag value to filter resources. Default: ArchiveLegacy

.PARAMETER BackupPath
    Directory for JSON state backups. Default: .\backups\phase3\automation

.EXAMPLE
    .\05-Disable-AutomationRunbooks.ps1 -WhatIf
    .\05-Disable-AutomationRunbooks.ps1 -SubscriptionId "xxxx" -Verbose
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
    [string]$BackupPath = ".\backups\phase3\automation"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $BackupPath "disable-automation-$timestamp.log"

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
    Write-Log "Phase 3 - Disable Automation Runbooks started"

    if ($subId) {
        Write-Log "Setting subscription to $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
    }

    # Discover Automation Accounts
    Write-Log "Discovering Automation Accounts with tag $TagName=$TagValue"
    $accounts = Get-AzResource -ResourceType "Microsoft.Automation/automationAccounts" `
        -TagName $TagName -TagValue $TagValue
    Write-Log "Found $($accounts.Count) Automation Accounts"

    if ($accounts.Count -eq 0) {
        Write-Host "No Automation Accounts found matching tag filter." -ForegroundColor Yellow
        return
    }

    $allBackupData = @()
    $scheduleDisabled = 0
    $scheduleFailed = 0

    foreach ($account in $accounts) {
        $rgName = $account.ResourceGroupName
        $acctName = $account.Name
        Write-Log "Processing Automation Account $rgName/$acctName"

        # Export runbooks
        $runbooks = Get-AzAutomationRunbook -ResourceGroupName $rgName -AutomationAccountName $acctName -ErrorAction Stop
        Write-Log "Found $($runbooks.Count) runbooks in $acctName"

        $runbookBackups = @()
        foreach ($rb in $runbooks) {
            # Export runbook content
            $contentPath = Join-Path $BackupPath "runbooks\$acctName"
            if (-not (Test-Path $contentPath)) {
                New-Item -ItemType Directory -Path $contentPath -Force | Out-Null
            }

            try {
                Export-AzAutomationRunbook -ResourceGroupName $rgName `
                    -AutomationAccountName $acctName -Name $rb.Name `
                    -OutputFolder $contentPath -Force -ErrorAction Stop | Out-Null
                Write-Log "Exported runbook content: $($rb.Name)"
            }
            catch {
                Write-Log "Failed to export runbook $($rb.Name): $_" -Level "WARN"
            }

            $runbookBackups += [PSCustomObject]@{
                Name           = $rb.Name
                RunbookType    = $rb.RunbookType
                State          = $rb.State
                LogVerbose     = $rb.LogVerbose
                LogProgress    = $rb.LogProgress
                CreationTime   = $rb.CreationTime
                LastModifiedTime = $rb.LastModifiedTime
            }
        }

        # Export and disable schedules
        $schedules = Get-AzAutomationSchedule -ResourceGroupName $rgName -AutomationAccountName $acctName -ErrorAction Stop
        Write-Log "Found $($schedules.Count) schedules in $acctName"

        $scheduleBackups = @()
        foreach ($schedule in $schedules) {
            $scheduleBackups += [PSCustomObject]@{
                Name            = $schedule.Name
                IsEnabled       = $schedule.IsEnabled
                StartTime       = $schedule.StartTime
                ExpiryTime      = $schedule.ExpiryTime
                Frequency       = $schedule.Frequency
                Interval        = $schedule.Interval
                TimeZone        = $schedule.TimeZone
                Description     = $schedule.Description
            }

            if (-not $schedule.IsEnabled) {
                Write-Log "Schedule $($schedule.Name) already disabled. Skipping."
                $scheduleDisabled++
                continue
            }

            if ($PSCmdlet.ShouldProcess("$acctName/$($schedule.Name)", "Disable Automation Schedule")) {
                try {
                    Set-AzAutomationSchedule -ResourceGroupName $rgName `
                        -AutomationAccountName $acctName -Name $schedule.Name `
                        -IsEnabled $false -ErrorAction Stop | Out-Null
                    Write-Log "Disabled schedule $($schedule.Name) in $acctName"
                    $scheduleDisabled++
                }
                catch {
                    Write-Log "Failed to disable schedule $($schedule.Name): $_" -Level "ERROR"
                    $scheduleFailed++
                }
            }
        }

        # Export schedule-to-runbook links
        $links = @()
        foreach ($rb in $runbooks) {
            $rbSchedules = Get-AzAutomationScheduledRunbook -ResourceGroupName $rgName `
                -AutomationAccountName $acctName -RunbookName $rb.Name -ErrorAction SilentlyContinue
            foreach ($link in $rbSchedules) {
                $links += [PSCustomObject]@{
                    RunbookName  = $link.RunbookName
                    ScheduleName = $link.ScheduleName
                    Parameters   = $link.Parameters
                }
            }
        }

        $allBackupData += [PSCustomObject]@{
            AccountName       = $acctName
            ResourceGroupName = $rgName
            Runbooks          = $runbookBackups
            Schedules         = $scheduleBackups
            ScheduleLinks     = $links
            Tags              = $account.Tags
        }
    }

    $backupFile = Join-Path $BackupPath "automation-state-$timestamp.json"
    $allBackupData | ConvertTo-Json -Depth 15 | Set-Content -Path $backupFile -Encoding UTF8
    Write-Log "Automation state backed up to $backupFile"

    Write-Log "Phase 3 - Disable Automation completed. Schedules disabled: $scheduleDisabled, Failed: $scheduleFailed"
    Write-Host "Automation disabled. Schedules disabled: $scheduleDisabled, Failed: $scheduleFailed. Log: $logFile" -ForegroundColor Green
}
catch {
    Write-Log "Fatal error: $_" -Level "ERROR"
    Write-Error "Phase 3 Automation disable failed: $_"
    throw
}
} # end foreach
