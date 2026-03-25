<#
.SYNOPSIS
    Disables all endpoints in Traffic Manager profiles tagged for archive.

.DESCRIPTION
    Finds Traffic Manager profiles tagged with ArchiveProject=ArchiveLegacy,
    backs up endpoint configurations to JSON, then disables all endpoints.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER BackupPath
    Path for JSON backups. Defaults to .\output\backups\traffic-manager.

.PARAMETER WhatIf
    Perform a dry run without making changes.

.EXAMPLE
    .\02-Disable-TrafficManager.ps1 -SubscriptionId "xxxx-xxxx" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [string]$BackupPath = (Join-Path $PSScriptRoot "..\..\output\backups\traffic-manager")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $PSScriptRoot "..\..\output\logs\02-Disable-TrafficManager-$timestamp.log"

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Verbose $entry
    $logDir = Split-Path $logFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $logFile -Value $entry
}

function Export-TrafficManagerBackup {
    param($Profile)

    $backupDir = Join-Path $BackupPath $timestamp
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

    $fileName = "{0}_{1}.json" -f $Profile.ResourceGroupName, $Profile.Name
    $filePath = Join-Path $backupDir $fileName

    $backup = @{
        Name              = $Profile.Name
        ResourceGroupName = $Profile.ResourceGroupName
        ProfileStatus     = $Profile.ProfileStatus
        Endpoints         = $Profile.Endpoints | ForEach-Object {
            @{
                Name             = $_.Name
                Type             = $_.Type
                TargetResourceId = $_.TargetResourceId
                Target           = $_.Target
                EndpointStatus   = $_.EndpointStatus
                Weight           = $_.Weight
                Priority         = $_.Priority
                Location         = $_.EndpointLocation
            }
        }
        BackupTimestamp   = $timestamp
    }

    $backup | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
    Write-Log "Backup saved: $filePath"
    return $filePath
}

function Restore-TrafficManagerFromBackup {
    <#
    .SYNOPSIS
        Restores Traffic Manager endpoint states from a JSON backup.
    .PARAMETER BackupFile
        Path to the JSON backup file.
    #>
    param([Parameter(Mandatory)][string]$BackupFile)

    $data = Get-Content $BackupFile -Raw | ConvertFrom-Json
    $profile = Get-AzTrafficManagerProfile -Name $data.Name -ResourceGroupName $data.ResourceGroupName

    foreach ($ep in $data.Endpoints) {
        $liveEp = $profile.Endpoints | Where-Object { $_.Name -eq $ep.Name }
        if ($liveEp -and $ep.EndpointStatus -eq "Enabled") {
            Enable-AzTrafficManagerEndpoint -Name $ep.Name `
                -ProfileName $data.Name `
                -ResourceGroupName $data.ResourceGroupName `
                -Type $ep.Type | Out-Null
            Write-Log "Restored endpoint '$($ep.Name)' to Enabled"
        }
    }
}

# --- Main ---
Write-Log "Starting Traffic Manager endpoint disable"

$totalProfiles = 0
$totalEndpoints = 0
$totalErrors = 0

foreach ($subId in $SubscriptionId) {
    try {
        Write-Log "Switching to subscription: $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

        $profiles = Get-AzTrafficManagerProfile | Where-Object {
            $_.Tags["ArchiveProject"] -eq "ArchiveLegacy"
        }

        Write-Log "Found $($profiles.Count) Traffic Manager profiles in subscription $subId"

        foreach ($profile in $profiles) {
            try {
                Write-Log "Processing profile: $($profile.Name)"
                Export-TrafficManagerBackup -Profile $profile

                foreach ($endpoint in $profile.Endpoints) {
                    if ($endpoint.EndpointStatus -eq "Enabled") {
                        if ($PSCmdlet.ShouldProcess("$($profile.Name)/$($endpoint.Name)", "Disable endpoint")) {
                            Disable-AzTrafficManagerEndpoint `
                                -Name $endpoint.Name `
                                -ProfileName $profile.Name `
                                -ResourceGroupName $profile.ResourceGroupName `
                                -Type $endpoint.Type `
                                -Force | Out-Null

                            Write-Log "Disabled endpoint: $($endpoint.Name) in profile: $($profile.Name)"
                            $totalEndpoints++
                        }
                    }
                    else {
                        Write-Log "Endpoint '$($endpoint.Name)' already disabled, skipping" -Level WARN
                    }
                }

                $totalProfiles++
            }
            catch {
                $totalErrors++
                Write-Log "Failed to process profile '$($profile.Name)': $_" -Level ERROR
            }
        }
    }
    catch {
        Write-Log "Failed processing subscription '$subId': $_" -Level ERROR
    }
}

Write-Log "Complete. Profiles: $totalProfiles, Endpoints disabled: $totalEndpoints, Errors: $totalErrors"
Write-Output "Traffic Manager disable complete. See log: $logFile"
