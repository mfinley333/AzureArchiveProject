<#
.SYNOPSIS
    Disables Azure Front Door routing rules tagged for archive.

.DESCRIPTION
    Finds Front Door instances tagged with ArchiveProject=ArchiveLegacy,
    backs up routing configuration to JSON, then disables routing rules.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER BackupPath
    Path for JSON backups. Defaults to .\output\backups\front-door.

.PARAMETER WhatIf
    Perform a dry run without making changes.

.EXAMPLE
    .\04-Disable-FrontDoor.ps1 -SubscriptionId "xxxx-xxxx" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [string]$BackupPath = (Join-Path $PSScriptRoot "..\..\output\backups\front-door")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $PSScriptRoot "..\..\output\logs\04-Disable-FrontDoor-$timestamp.log"

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Verbose $entry
    $logDir = Split-Path $logFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $logFile -Value $entry
}

function Export-FrontDoorBackup {
    param($FrontDoor)

    $backupDir = Join-Path $BackupPath $timestamp
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

    $fileName = "{0}_{1}.json" -f $FrontDoor.ResourceGroupName, $FrontDoor.Name
    $filePath = Join-Path $backupDir $fileName

    $backup = @{
        Name              = $FrontDoor.Name
        ResourceGroupName = $FrontDoor.ResourceGroupName
        FriendlyName      = $FrontDoor.FriendlyName
        EnabledState      = $FrontDoor.EnabledState
        RoutingRules      = $FrontDoor.RoutingRules | ForEach-Object {
            @{
                Name            = $_.Name
                EnabledState    = $_.EnabledState
                AcceptedProtocols = $_.AcceptedProtocols
                PatternsToMatch = $_.PatternsToMatch
                FrontendEndpoints = $_.FrontendEndpoints | ForEach-Object { $_.Id }
                RouteConfiguration = @{
                    OdataType        = $_.RouteConfiguration.OdataType
                    BackendPoolId    = if ($_.RouteConfiguration.BackendPool) { $_.RouteConfiguration.BackendPool.Id } else { $null }
                    ForwardingProtocol = $_.RouteConfiguration.ForwardingProtocol
                }
            }
        }
        FrontendEndpoints = $FrontDoor.FrontendEndpoints | ForEach-Object {
            @{ Name = $_.Name; HostName = $_.HostName; SessionAffinityEnabledState = $_.SessionAffinityEnabledState }
        }
        BackendPools      = $FrontDoor.BackendPools | ForEach-Object {
            @{
                Name     = $_.Name
                Backends = $_.Backends | ForEach-Object {
                    @{ Address = $_.Address; HttpPort = $_.HttpPort; HttpsPort = $_.HttpsPort; EnabledState = $_.EnabledState }
                }
            }
        }
        BackupTimestamp   = $timestamp
    }

    $backup | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
    Write-Log "Backup saved: $filePath"
    return $filePath
}

function Restore-FrontDoorFromBackup {
    <#
    .SYNOPSIS
        Re-enables Front Door routing rules from a JSON backup.
    .PARAMETER BackupFile
        Path to the JSON backup file.
    #>
    param([Parameter(Mandatory)][string]$BackupFile)

    $data = Get-Content $BackupFile -Raw | ConvertFrom-Json
    $fd = Get-AzFrontDoor -Name $data.Name -ResourceGroupName $data.ResourceGroupName

    foreach ($rule in $data.RoutingRules) {
        $liveRule = $fd.RoutingRules | Where-Object { $_.Name -eq $rule.Name }
        if ($liveRule -and $rule.EnabledState -eq "Enabled") {
            $liveRule.EnabledState = "Enabled"
        }
    }

    Set-AzFrontDoor -InputObject $fd | Out-Null
    Write-Log "Restored Front Door '$($data.Name)' routing rules from backup"
}

# --- Main ---
Write-Log "Starting Front Door disable"

$totalProcessed = 0
$totalRulesDisabled = 0
$totalErrors = 0

foreach ($subId in $SubscriptionId) {
    try {
        Write-Log "Switching to subscription: $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

        $frontDoors = Get-AzFrontDoor | Where-Object {
            $_.Tags["ArchiveProject"] -eq "ArchiveLegacy"
        }

        Write-Log "Found $($frontDoors.Count) Front Door instances in subscription $subId"

        foreach ($fd in $frontDoors) {
            try {
                Write-Log "Processing Front Door: $($fd.Name)"
                Export-FrontDoorBackup -FrontDoor $fd

                foreach ($rule in $fd.RoutingRules) {
                    if ($rule.EnabledState -eq "Enabled") {
                        if ($PSCmdlet.ShouldProcess("$($fd.Name)/$($rule.Name)", "Disable routing rule")) {
                            $rule.EnabledState = "Disabled"
                            Write-Log "Marking routing rule '$($rule.Name)' as Disabled"
                            $totalRulesDisabled++
                        }
                    }
                    else {
                        Write-Log "Routing rule '$($rule.Name)' already disabled" -Level WARN
                    }
                }

                if ($PSCmdlet.ShouldProcess($fd.Name, "Apply Front Door configuration")) {
                    Set-AzFrontDoor -InputObject $fd | Out-Null
                    Write-Log "Applied changes to Front Door: $($fd.Name)"
                }

                $totalProcessed++
            }
            catch {
                $totalErrors++
                Write-Log "Failed to process Front Door '$($fd.Name)': $_" -Level ERROR
            }
        }
    }
    catch {
        Write-Log "Failed processing subscription '$subId': $_" -Level ERROR
    }
}

Write-Log "Complete. Front Doors: $totalProcessed, Rules disabled: $totalRulesDisabled, Errors: $totalErrors"
Write-Output "Front Door disable complete. See log: $logFile"
