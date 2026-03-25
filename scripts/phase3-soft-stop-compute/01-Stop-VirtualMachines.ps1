<#
.SYNOPSIS
    Deallocates VMs and scales VMSS to 0 for the Azure Archive Project.

.DESCRIPTION
    Phase 3 - Soft-Stop Compute: Deallocates all Virtual Machines tagged
    ArchiveProject=ArchiveLegacy and scales Virtual Machine Scale Sets to 0 instances.
    Exports VM/VMSS state to JSON backup before making changes.
    Processes VMs in parallel using PowerShell jobs (throttle limit: 10).

.PARAMETER SubscriptionId
    Target Azure subscription ID. If omitted, uses the current context.

.PARAMETER TagName
    Tag name to filter resources. Default: ArchiveProject

.PARAMETER TagValue
    Tag value to filter resources. Default: ArchiveLegacy

.PARAMETER BackupPath
    Directory for JSON state backups. Default: .\backups\phase3\vms

.PARAMETER ThrottleLimit
    Maximum concurrent PowerShell jobs. Default: 10

.PARAMETER WhatIf
    Preview changes without executing them.

.EXAMPLE
    .\01-Stop-VirtualMachines.ps1 -WhatIf
    .\01-Stop-VirtualMachines.ps1 -SubscriptionId "xxxx" -ThrottleLimit 5
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
    [string]$BackupPath = ".\backups\phase3\vms",

    [Parameter()]
    [ValidateRange(1, 50)]
    [int]$ThrottleLimit = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $BackupPath "stop-vms-$timestamp.log"

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
    # Ensure backup directory exists
    if (-not (Test-Path $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    }
    Write-Log "Phase 3 - Stop Virtual Machines started"
    Write-Log "Tag filter: $TagName=$TagValue | ThrottleLimit: $ThrottleLimit"

    # Set subscription context
    if ($subId) {
        Write-Log "Setting subscription context to $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
    }

    # ── Discover VMs ──
    Write-Log "Discovering VMs with tag $TagName=$TagValue"
    $vms = Get-AzVM -Status | Where-Object { $_.Tags[$TagName] -eq $TagValue }
    Write-Log "Found $($vms.Count) VMs"

    if ($vms.Count -eq 0) {
        Write-Log "No VMs found matching tag filter. Skipping VM section."
    }
    else {
        # Export VM state backup
        $vmBackup = $vms | ForEach-Object {
            [PSCustomObject]@{
                Name              = $_.Name
                ResourceGroupName = $_.ResourceGroupName
                Location          = $_.Location
                VmSize            = $_.HardwareProfile.VmSize
                PowerState        = ($_.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
                OsDiskName        = $_.StorageProfile.OsDisk.Name
                OsDiskSizeGB      = $_.StorageProfile.OsDisk.DiskSizeGB
                DataDisks         = $_.StorageProfile.DataDisks | ForEach-Object {
                    [PSCustomObject]@{ Name = $_.Name; SizeGB = $_.DiskSizeGB; Lun = $_.Lun }
                }
                Tags              = $_.Tags
            }
        }

        $vmBackupFile = Join-Path $BackupPath "vm-state-$timestamp.json"
        $vmBackup | ConvertTo-Json -Depth 10 | Set-Content -Path $vmBackupFile -Encoding UTF8
        Write-Log "VM state backed up to $vmBackupFile"

        # Deallocate VMs in parallel
        $runningVMs = $vms | Where-Object {
            ($_.Statuses | Where-Object { $_.Code -like "PowerState/*" }).Code -ne "PowerState/deallocated"
        }
        Write-Log "VMs requiring deallocation: $($runningVMs.Count)"

        $jobs = @()
        foreach ($vm in $runningVMs) {
            if ($PSCmdlet.ShouldProcess("$($vm.ResourceGroupName)/$($vm.Name)", "Deallocate VM")) {
                # Throttle: wait if at limit
                while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $ThrottleLimit) {
                    Start-Sleep -Seconds 5
                }

                $jobs += Start-Job -ScriptBlock {
                    param($rgName, $vmName)
                    Stop-AzVM -ResourceGroupName $rgName -Name $vmName -Force -ErrorAction Stop
                } -ArgumentList $vm.ResourceGroupName, $vm.Name

                Write-Log "Started deallocation job for $($vm.ResourceGroupName)/$($vm.Name)"
            }
        }

        # Wait for all jobs to complete
        if ($jobs.Count -gt 0) {
            Write-Log "Waiting for $($jobs.Count) deallocation jobs to complete..."
            $jobs | Wait-Job | Out-Null

            foreach ($job in $jobs) {
                if ($job.State -eq 'Failed') {
                    $err = $job | Receive-Job -ErrorAction SilentlyContinue 2>&1
                    Write-Log "Job $($job.Id) FAILED: $err" -Level "ERROR"
                }
                else {
                    $job | Receive-Job | Out-Null
                    Write-Log "Job $($job.Id) completed successfully"
                }
            }
            $jobs | Remove-Job -Force
        }
    }

    # ── Discover and scale VMSS to 0 ──
    Write-Log "Discovering VMSS with tag $TagName=$TagValue"
    $vmssList = Get-AzVmss | Where-Object { $_.Tags[$TagName] -eq $TagValue }
    Write-Log "Found $($vmssList.Count) VMSS"

    if ($vmssList.Count -gt 0) {
        $vmssBackup = $vmssList | ForEach-Object {
            [PSCustomObject]@{
                Name              = $_.Name
                ResourceGroupName = $_.ResourceGroup
                Location          = $_.Location
                SkuName           = $_.Sku.Name
                SkuCapacity       = $_.Sku.Capacity
                Tags              = $_.Tags
            }
        }

        $vmssBackupFile = Join-Path $BackupPath "vmss-state-$timestamp.json"
        $vmssBackup | ConvertTo-Json -Depth 10 | Set-Content -Path $vmssBackupFile -Encoding UTF8
        Write-Log "VMSS state backed up to $vmssBackupFile"

        foreach ($vmss in $vmssList) {
            if ($vmss.Sku.Capacity -eq 0) {
                Write-Log "VMSS $($vmss.Name) already at capacity 0. Skipping."
                continue
            }

            if ($PSCmdlet.ShouldProcess("$($vmss.ResourceGroup)/$($vmss.Name)", "Scale VMSS to 0 instances")) {
                try {
                    Write-Log "Scaling VMSS $($vmss.Name) from $($vmss.Sku.Capacity) to 0"
                    Update-AzVmss -ResourceGroupName $vmss.ResourceGroup -VMScaleSetName $vmss.Name `
                        -SkuCapacity 0 -ErrorAction Stop | Out-Null
                    Write-Log "VMSS $($vmss.Name) scaled to 0 successfully"
                }
                catch {
                    Write-Log "Failed to scale VMSS $($vmss.Name): $_" -Level "ERROR"
                }
            }
        }
    }

    Write-Log "Phase 3 - Stop Virtual Machines completed"
    Write-Host "Phase 3 VM deallocation complete. Log: $logFile" -ForegroundColor Green
}
catch {
    Write-Log "Fatal error: $_" -Level "ERROR"
    Write-Error "Phase 3 VM stop failed: $_"
    throw
}
} # end foreach
