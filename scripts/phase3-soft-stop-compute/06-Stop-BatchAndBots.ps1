<#
.SYNOPSIS
    Disables Batch Account jobs/schedules and Bot Services for the Azure Archive Project.

.DESCRIPTION
    Phase 3 - Soft-Stop Compute: Disables Batch account job schedules and
    Bot Services tagged ArchiveProject=ArchiveLegacy. Backs up configurations
    to JSON before making changes.

.PARAMETER SubscriptionId
    Target Azure subscription ID. If omitted, uses the current context.

.PARAMETER TagName
    Tag name to filter resources. Default: ArchiveProject

.PARAMETER TagValue
    Tag value to filter resources. Default: ArchiveLegacy

.PARAMETER BackupPath
    Directory for JSON state backups. Default: .\backups\phase3\batch-bots

.EXAMPLE
    .\06-Stop-BatchAndBots.ps1 -WhatIf
    .\06-Stop-BatchAndBots.ps1 -SubscriptionId "xxxx" -Verbose
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
    [string]$BackupPath = ".\backups\phase3\batch-bots"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $BackupPath "stop-batch-bots-$timestamp.log"

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
    Write-Log "Phase 3 - Stop Batch and Bots started"

    if ($subId) {
        Write-Log "Setting subscription to $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
    }

    # ══════════════════════════════════════════
    # BATCH ACCOUNTS
    # ══════════════════════════════════════════
    Write-Log "Discovering Batch Accounts with tag $TagName=$TagValue"
    $batchAccounts = Get-AzResource -ResourceType "Microsoft.Batch/batchAccounts" `
        -TagName $TagName -TagValue $TagValue
    Write-Log "Found $($batchAccounts.Count) Batch Accounts"

    $batchBackup = @()
    $batchSuccess = 0
    $batchFail = 0

    foreach ($ba in $batchAccounts) {
        $rgName = $ba.ResourceGroupName
        $acctName = $ba.Name
        Write-Log "Processing Batch Account $rgName/$acctName"

        $batchContext = Get-AzBatchAccount -ResourceGroupName $rgName -AccountName $acctName -ErrorAction Stop

        # Export pools
        $pools = Get-AzBatchPool -BatchContext $batchContext -ErrorAction SilentlyContinue
        $poolData = $pools | ForEach-Object {
            [PSCustomObject]@{
                Id                    = $_.Id
                State                 = $_.State
                AllocationState       = $_.AllocationState
                VmSize                = $_.VmSize
                TargetDedicatedNodes  = $_.TargetDedicatedComputeNodes
                TargetLowPriorityNodes = $_.TargetLowPriorityComputeNodes
                CurrentDedicatedNodes = $_.CurrentDedicatedComputeNodes
                AutoScaleEnabled      = $_.AutoScaleEnabled
            }
        }

        # Export job schedules
        $jobSchedules = Get-AzBatchJobSchedule -BatchContext $batchContext -ErrorAction SilentlyContinue
        $scheduleData = $jobSchedules | ForEach-Object {
            [PSCustomObject]@{
                Id    = $_.Id
                State = $_.State
                Schedule = [PSCustomObject]@{
                    DoNotRunAfter  = $_.Schedule.DoNotRunAfter
                    DoNotRunUntil  = $_.Schedule.DoNotRunUntil
                    RecurrenceInterval = $_.Schedule.RecurrenceInterval
                    StartWindow    = $_.Schedule.StartWindow
                }
            }
        }

        $batchBackup += [PSCustomObject]@{
            AccountName       = $acctName
            ResourceGroupName = $rgName
            Location          = $ba.Location
            Pools             = $poolData
            JobSchedules      = $scheduleData
            Tags              = $ba.Tags
        }

        # Disable (terminate) active job schedules
        foreach ($js in $jobSchedules) {
            if ($js.State -eq "Active") {
                if ($PSCmdlet.ShouldProcess("$acctName/$($js.Id)", "Disable Batch Job Schedule")) {
                    try {
                        Disable-AzBatchJobSchedule -Id $js.Id -BatchContext $batchContext -ErrorAction Stop
                        Write-Log "Disabled Batch job schedule $($js.Id) in $acctName"
                        $batchSuccess++
                    }
                    catch {
                        Write-Log "Failed to disable job schedule $($js.Id): $_" -Level "ERROR"
                        $batchFail++
                    }
                }
            }
            else {
                Write-Log "Job schedule $($js.Id) state is $($js.State). Skipping."
            }
        }

        # Scale pools to 0
        foreach ($pool in $pools) {
            if ($pool.CurrentDedicatedComputeNodes -eq 0 -and $pool.CurrentLowPriorityComputeNodes -eq 0) {
                Write-Log "Batch pool $($pool.Id) already at 0 nodes. Skipping."
                continue
            }
            if ($PSCmdlet.ShouldProcess("$acctName/$($pool.Id)", "Scale Batch pool to 0 nodes")) {
                try {
                    # Disable autoscale first if enabled
                    if ($pool.AutoScaleEnabled) {
                        Disable-AzBatchAutoScale -Id $pool.Id -BatchContext $batchContext -ErrorAction Stop
                        Write-Log "Disabled autoscale on pool $($pool.Id)"
                    }
                    Stop-AzBatchPoolResize -Id $pool.Id -BatchContext $batchContext -ErrorAction SilentlyContinue
                    $pool.TargetDedicatedComputeNodes = 0
                    $pool.TargetLowPriorityComputeNodes = 0
                    $pool | Set-AzBatchPool -BatchContext $batchContext -ErrorAction Stop
                    Write-Log "Scaled Batch pool $($pool.Id) to 0 nodes"
                    $batchSuccess++
                }
                catch {
                    Write-Log "Failed to scale pool $($pool.Id): $_" -Level "ERROR"
                    $batchFail++
                }
            }
        }
    }

    if ($batchBackup.Count -gt 0) {
        $batchBackupFile = Join-Path $BackupPath "batch-state-$timestamp.json"
        $batchBackup | ConvertTo-Json -Depth 15 | Set-Content -Path $batchBackupFile -Encoding UTF8
        Write-Log "Batch state backed up to $batchBackupFile"
    }

    # ══════════════════════════════════════════
    # BOT SERVICES
    # ══════════════════════════════════════════
    Write-Log "Discovering Bot Services with tag $TagName=$TagValue"
    $botServices = Get-AzResource -ResourceType "Microsoft.BotService/botServices" `
        -TagName $TagName -TagValue $TagValue
    Write-Log "Found $($botServices.Count) Bot Services"

    $botBackup = @()
    $botSuccess = 0
    $botFail = 0

    foreach ($bot in $botServices) {
        $rgName = $bot.ResourceGroupName
        $botName = $bot.Name
        Write-Log "Processing Bot Service $rgName/$botName"

        # Get full bot resource details via REST
        $botResource = Get-AzResource -ResourceId $bot.ResourceId -ExpandProperties -ErrorAction Stop

        $botBackup += [PSCustomObject]@{
            Name              = $botName
            ResourceGroupName = $rgName
            Location          = $bot.Location
            Kind              = $botResource.Kind
            Sku               = $botResource.Sku
            Properties        = $botResource.Properties
            Tags              = $bot.Tags
        }

        # Disable bot by setting it to disabled via properties update
        if ($PSCmdlet.ShouldProcess("$rgName/$botName", "Disable Bot Service")) {
            try {
                $botResource.Properties.isEnabled = $false
                $botResource | Set-AzResource -Force -ErrorAction Stop | Out-Null
                Write-Log "Disabled Bot Service $botName"
                $botSuccess++
            }
            catch {
                Write-Log "Failed to disable Bot Service $botName`: $_" -Level "ERROR"
                $botFail++
            }
        }
    }

    if ($botBackup.Count -gt 0) {
        $botBackupFile = Join-Path $BackupPath "bot-state-$timestamp.json"
        $botBackup | ConvertTo-Json -Depth 15 | Set-Content -Path $botBackupFile -Encoding UTF8
        Write-Log "Bot Service state backed up to $botBackupFile"
    }

    Write-Log "Phase 3 - Stop Batch and Bots completed. Batch: $batchSuccess ok/$batchFail fail. Bots: $botSuccess ok/$botFail fail"
    Write-Host "Batch & Bots complete. Batch: $batchSuccess ok/$batchFail fail. Bots: $botSuccess ok/$botFail fail. Log: $logFile" -ForegroundColor Green
}
catch {
    Write-Log "Fatal error: $_" -Level "ERROR"
    Write-Error "Phase 3 Batch/Bots stop failed: $_"
    throw
}
} # end foreach
