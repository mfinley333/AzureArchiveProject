<#
.SYNOPSIS
    Stops Web Apps/slots and scales App Service Plans for the Azure Archive Project.

.DESCRIPTION
    Phase 3 - Soft-Stop Compute: Stops all Web Apps and deployment slots tagged
    ArchiveProject=ArchiveLegacy. Scales App Service Plans to Free tier (or B1 for
    ASE-hosted plans). Exports current tier and configuration to JSON backup first.

.PARAMETER SubscriptionId
    Target Azure subscription ID. If omitted, uses the current context.

.PARAMETER TagName
    Tag name to filter resources. Default: ArchiveProject

.PARAMETER TagValue
    Tag value to filter resources. Default: ArchiveLegacy

.PARAMETER BackupPath
    Directory for JSON state backups. Default: .\backups\phase3\webapps

.EXAMPLE
    .\03-Stop-WebApps.ps1 -WhatIf
    .\03-Stop-WebApps.ps1 -SubscriptionId "xxxx" -Verbose
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
    [string]$BackupPath = ".\backups\phase3\webapps"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $BackupPath "stop-webapps-$timestamp.log"

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
    Write-Log "Phase 3 - Stop Web Apps started"

    if ($subId) {
        Write-Log "Setting subscription to $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
    }

    # ── Discover App Service Plans ──
    Write-Log "Discovering App Service Plans with tag $TagName=$TagValue"
    $plans = Get-AzAppServicePlan | Where-Object { $_.Tags[$TagName] -eq $TagValue }
    Write-Log "Found $($plans.Count) App Service Plans"

    # Backup App Service Plan state
    $planBackup = $plans | ForEach-Object {
        [PSCustomObject]@{
            Name              = $_.Name
            ResourceGroupName = $_.ResourceGroup
            Location          = $_.Location
            Sku               = [PSCustomObject]@{
                Name     = $_.Sku.Name
                Tier     = $_.Sku.Tier
                Size     = $_.Sku.Size
                Capacity = $_.Sku.Capacity
            }
            Kind              = $_.Kind
            IsASE             = ($null -ne $_.HostingEnvironmentProfile)
            ASEName           = $_.HostingEnvironmentProfile.Name
            NumberOfSites     = $_.NumberOfSites
            Tags              = $_.Tags
        }
    }
    $planBackupFile = Join-Path $BackupPath "asp-state-$timestamp.json"
    $planBackup | ConvertTo-Json -Depth 10 | Set-Content -Path $planBackupFile -Encoding UTF8
    Write-Log "App Service Plan state backed up to $planBackupFile"

    # ── Discover Web Apps ──
    Write-Log "Discovering Web Apps with tag $TagName=$TagValue"
    $webApps = Get-AzWebApp | Where-Object { $_.Tags[$TagName] -eq $TagValue }
    Write-Log "Found $($webApps.Count) Web Apps"

    # Backup Web App state
    $webAppBackup = $webApps | ForEach-Object {
        $slots = Get-AzWebAppSlot -ResourceGroupName $_.ResourceGroup -Name $_.Name -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Name              = $_.Name
            ResourceGroupName = $_.ResourceGroup
            Location          = $_.Location
            State             = $_.State
            AppServicePlan    = $_.ServerFarmId
            DefaultHostName   = $_.DefaultHostName
            HttpsOnly         = $_.HttpsOnly
            Kind              = $_.Kind
            Slots             = $slots | ForEach-Object {
                [PSCustomObject]@{
                    Name  = $_.Name
                    State = $_.State
                }
            }
            Tags              = $_.Tags
        }
    }
    $webAppBackupFile = Join-Path $BackupPath "webapp-state-$timestamp.json"
    $webAppBackup | ConvertTo-Json -Depth 10 | Set-Content -Path $webAppBackupFile -Encoding UTF8
    Write-Log "Web App state backed up to $webAppBackupFile"

    # ── Stop Web Apps and Slots ──
    $stopSuccess = 0
    $stopFail = 0

    foreach ($app in $webApps) {
        # Stop the web app
        if ($app.State -eq "Stopped") {
            Write-Log "Web App $($app.Name) already stopped."
            $stopSuccess++
        }
        elseif ($PSCmdlet.ShouldProcess("$($app.ResourceGroup)/$($app.Name)", "Stop Web App")) {
            try {
                Stop-AzWebApp -ResourceGroupName $app.ResourceGroup -Name $app.Name -ErrorAction Stop | Out-Null
                Write-Log "Stopped Web App $($app.Name)"
                $stopSuccess++
            }
            catch {
                Write-Log "Failed to stop Web App $($app.Name): $_" -Level "ERROR"
                $stopFail++
            }
        }

        # Stop deployment slots
        $slots = Get-AzWebAppSlot -ResourceGroupName $app.ResourceGroup -Name $app.Name -ErrorAction SilentlyContinue
        foreach ($slot in $slots) {
            $slotName = ($slot.Name -split "/")[-1]
            if ($slot.State -eq "Stopped") {
                Write-Log "Slot $($app.Name)/$slotName already stopped."
                continue
            }
            if ($PSCmdlet.ShouldProcess("$($app.ResourceGroup)/$($app.Name)/$slotName", "Stop Web App Slot")) {
                try {
                    Stop-AzWebAppSlot -ResourceGroupName $app.ResourceGroup -Name $app.Name -Slot $slotName -ErrorAction Stop | Out-Null
                    Write-Log "Stopped slot $($app.Name)/$slotName"
                }
                catch {
                    Write-Log "Failed to stop slot $($app.Name)/$slotName`: $_" -Level "ERROR"
                }
            }
        }
    }
    Write-Log "Web Apps stopped. Success: $stopSuccess, Failed: $stopFail"

    # ── Scale App Service Plans ──
    $scaleSuccess = 0
    $scaleFail = 0

    foreach ($plan in $plans) {
        $isASE = $null -ne $plan.HostingEnvironmentProfile
        $targetTier = if ($isASE) { "B1" } else { "F1" }
        $targetSkuTier = if ($isASE) { "Basic" } else { "Free" }

        if ($plan.Sku.Name -eq $targetTier) {
            Write-Log "ASP $($plan.Name) already at $targetTier. Skipping."
            $scaleSuccess++
            continue
        }

        if ($PSCmdlet.ShouldProcess("$($plan.ResourceGroup)/$($plan.Name)", "Scale ASP from $($plan.Sku.Name) to $targetTier")) {
            try {
                Write-Log "Scaling ASP $($plan.Name) from $($plan.Sku.Name) to $targetTier (ASE: $isASE)"
                Set-AzAppServicePlan -ResourceGroupName $plan.ResourceGroup -Name $plan.Name `
                    -Tier $targetSkuTier -WorkerSize "Small" -NumberofWorkers 1 -ErrorAction Stop | Out-Null
                Write-Log "Scaled ASP $($plan.Name) to $targetTier"
                $scaleSuccess++
            }
            catch {
                Write-Log "Failed to scale ASP $($plan.Name) to $targetTier`: $_" -Level "ERROR"
                $scaleFail++
            }
        }
    }
    Write-Log "ASP scaling complete. Success: $scaleSuccess, Failed: $scaleFail"

    Write-Log "Phase 3 - Stop Web Apps completed"
    Write-Host "Web Apps stop complete. Apps stopped: $stopSuccess/$($webApps.Count), ASPs scaled: $scaleSuccess/$($plans.Count). Log: $logFile" -ForegroundColor Green
}
catch {
    Write-Log "Fatal error: $_" -Level "ERROR"
    Write-Error "Phase 3 Web Apps stop failed: $_"
    throw
}
} # end foreach
