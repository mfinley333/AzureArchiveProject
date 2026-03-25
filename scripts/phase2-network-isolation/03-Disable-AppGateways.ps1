<#
.SYNOPSIS
    Stops Application Gateways tagged for archive.

.DESCRIPTION
    Finds Application Gateways tagged with ArchiveProject=ArchiveLegacy,
    backs up configuration (including WAF policies) to JSON, then stops them.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER BackupPath
    Path for JSON backups. Defaults to .\output\backups\app-gateway.

.PARAMETER WhatIf
    Perform a dry run without making changes.

.EXAMPLE
    .\03-Disable-AppGateways.ps1 -SubscriptionId "xxxx-xxxx" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [string]$BackupPath = (Join-Path $PSScriptRoot "..\..\output\backups\app-gateway")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $PSScriptRoot "..\..\output\logs\03-Disable-AppGateways-$timestamp.log"

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Verbose $entry
    $logDir = Split-Path $logFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $logFile -Value $entry
}

function Export-AppGatewayBackup {
    param($Gateway)

    $backupDir = Join-Path $BackupPath $timestamp
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

    $fileName = "{0}_{1}.json" -f $Gateway.ResourceGroupName, $Gateway.Name
    $filePath = Join-Path $backupDir $fileName

    # Capture WAF policy if present
    $wafPolicy = $null
    if ($Gateway.FirewallPolicy.Id) {
        try {
            $wafResource = Get-AzResource -ResourceId $Gateway.FirewallPolicy.Id -ErrorAction Stop
            $wafPolicy = @{
                ResourceId = $Gateway.FirewallPolicy.Id
                Name       = $wafResource.Name
            }
        }
        catch {
            Write-Log "Could not retrieve WAF policy for '$($Gateway.Name)': $_" -Level WARN
        }
    }

    $backup = @{
        Name                = $Gateway.Name
        ResourceGroupName   = $Gateway.ResourceGroupName
        Location            = $Gateway.Location
        OperationalState    = $Gateway.OperationalState
        Sku                 = @{
            Name     = $Gateway.Sku.Name
            Tier     = $Gateway.Sku.Tier
            Capacity = $Gateway.Sku.Capacity
        }
        WafPolicy           = $wafPolicy
        BackendAddressPools = $Gateway.BackendAddressPools | ForEach-Object {
            @{ Name = $_.Name; BackendAddresses = $_.BackendAddresses }
        }
        HttpListeners       = $Gateway.HttpListeners | ForEach-Object {
            @{ Name = $_.Name; Protocol = $_.Protocol; HostName = $_.HostName }
        }
        RequestRoutingRules = $Gateway.RequestRoutingRules | ForEach-Object {
            @{ Name = $_.Name; RuleType = $_.RuleType }
        }
        BackupTimestamp     = $timestamp
    }

    $backup | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
    Write-Log "Backup saved: $filePath"
    return $filePath
}

function Restore-AppGatewayFromBackup {
    <#
    .SYNOPSIS
        Starts a previously stopped Application Gateway.
    .PARAMETER BackupFile
        Path to the JSON backup file (used to identify the gateway).
    #>
    param([Parameter(Mandatory)][string]$BackupFile)

    $data = Get-Content $BackupFile -Raw | ConvertFrom-Json
    $gw = Get-AzApplicationGateway -Name $data.Name -ResourceGroupName $data.ResourceGroupName
    Start-AzApplicationGateway -ApplicationGateway $gw
    Write-Log "Restored (started) Application Gateway: $($data.Name)"
}

# --- Main ---
Write-Log "Starting Application Gateway disable"

$totalProcessed = 0
$totalErrors = 0

foreach ($subId in $SubscriptionId) {
    try {
        Write-Log "Switching to subscription: $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

        $gateways = Get-AzApplicationGateway | Where-Object {
            $_.Tags["ArchiveProject"] -eq "ArchiveLegacy"
        }

        Write-Log "Found $($gateways.Count) Application Gateways in subscription $subId"

        foreach ($gw in $gateways) {
            try {
                Write-Log "Processing gateway: $($gw.Name) (State: $($gw.OperationalState))"

                if ($gw.OperationalState -eq "Stopped") {
                    Write-Log "Gateway '$($gw.Name)' already stopped, skipping" -Level WARN
                    continue
                }

                Export-AppGatewayBackup -Gateway $gw

                # Log WAF policy association
                if ($gw.FirewallPolicy.Id) {
                    Write-Log "Gateway '$($gw.Name)' has WAF policy: $($gw.FirewallPolicy.Id)"
                }

                if ($PSCmdlet.ShouldProcess($gw.Name, "Stop Application Gateway")) {
                    Stop-AzApplicationGateway -ApplicationGateway $gw | Out-Null
                    Write-Log "Stopped Application Gateway: $($gw.Name)"
                }

                $totalProcessed++
            }
            catch {
                $totalErrors++
                Write-Log "Failed to process gateway '$($gw.Name)': $_" -Level ERROR
            }
        }
    }
    catch {
        Write-Log "Failed processing subscription '$subId': $_" -Level ERROR
    }
}

Write-Log "Complete. Processed: $totalProcessed, Errors: $totalErrors"
Write-Output "Application Gateway disable complete. See log: $logFile"
