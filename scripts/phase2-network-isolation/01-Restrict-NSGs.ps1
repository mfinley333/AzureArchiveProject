<#
.SYNOPSIS
    Restricts NSGs tagged for archive by adding DenyAll inbound/outbound rules.

.DESCRIPTION
    For each NSG tagged with ArchiveProject=ArchiveLegacy, exports current rules
    to JSON backup then adds DenyAllInbound and DenyAllOutbound rules at priority 100.
    Supports -WhatIf for dry-run validation.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER ResourceGroupFilter
    Optional wildcard filter for resource group names (e.g. "rg-prod-*").

.PARAMETER ExcludeNsgNames
    NSG names to skip.

.PARAMETER BackupPath
    Path for JSON backups. Defaults to .\output\backups\nsg.

.PARAMETER WhatIf
    Perform a dry run without making changes.

.EXAMPLE
    .\01-Restrict-NSGs.ps1 -SubscriptionId "xxxx-xxxx" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [string]$ResourceGroupFilter = "*",

    [string[]]$ExcludeNsgNames = @(),

    [string]$BackupPath = (Join-Path $PSScriptRoot "..\..\output\backups\nsg")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $PSScriptRoot "..\..\output\logs\01-Restrict-NSGs-$timestamp.log"

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Verbose $entry
    $logDir = Split-Path $logFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $logFile -Value $entry
}

function Export-NsgBackup {
    param([Microsoft.Azure.Commands.Network.Models.PSNetworkSecurityGroup]$Nsg)

    $backupDir = Join-Path $BackupPath $timestamp
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

    $fileName = "{0}_{1}.json" -f $Nsg.ResourceGroupName, $Nsg.Name
    $filePath = Join-Path $backupDir $fileName

    $backup = @{
        Name              = $Nsg.Name
        ResourceGroupName = $Nsg.ResourceGroupName
        Location          = $Nsg.Location
        SecurityRules     = $Nsg.SecurityRules | ForEach-Object {
            @{
                Name                     = $_.Name
                Priority                 = $_.Priority
                Direction                = $_.Direction
                Access                   = $_.Access
                Protocol                 = $_.Protocol
                SourcePortRange          = $_.SourcePortRange
                DestinationPortRange     = $_.DestinationPortRange
                SourceAddressPrefix      = $_.SourceAddressPrefix
                DestinationAddressPrefix = $_.DestinationAddressPrefix
            }
        }
        BackupTimestamp   = $timestamp
    }

    $backup | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
    Write-Log "Backup saved: $filePath"
    return $filePath
}

function Restore-NsgFromBackup {
    <#
    .SYNOPSIS
        Restores NSG rules from a JSON backup file.
    .PARAMETER BackupFile
        Path to the JSON backup file.
    #>
    param([Parameter(Mandatory)][string]$BackupFile)

    $data = Get-Content $BackupFile -Raw | ConvertFrom-Json
    $nsg = Get-AzNetworkSecurityGroup -Name $data.Name -ResourceGroupName $data.ResourceGroupName

    # Remove deny rules added by this script
    $nsg.SecurityRules = $nsg.SecurityRules | Where-Object {
        $_.Name -notin @("DenyAllInbound_Archive", "DenyAllOutbound_Archive")
    }

    foreach ($rule in $data.SecurityRules) {
        $params = @{
            Name                     = $rule.Name
            Priority                 = $rule.Priority
            Direction                = $rule.Direction
            Access                   = $rule.Access
            Protocol                 = $rule.Protocol
            SourcePortRange          = $rule.SourcePortRange
            DestinationPortRange     = $rule.DestinationPortRange
            SourceAddressPrefix      = $rule.SourceAddressPrefix
            DestinationAddressPrefix = $rule.DestinationAddressPrefix
            NetworkSecurityGroup     = $nsg
        }
        Add-AzNetworkSecurityRuleConfig @params | Out-Null
    }

    Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg | Out-Null
    Write-Log "Restored NSG '$($data.Name)' from backup: $BackupFile"
}

# --- Main ---
Write-Log "Starting NSG restriction. Subscriptions: $($SubscriptionId -join ', ')"

$totalProcessed = 0
$totalSkipped = 0
$totalErrors = 0

foreach ($subId in $SubscriptionId) {
    try {
        Write-Log "Switching to subscription: $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

        $nsgs = Get-AzNetworkSecurityGroup | Where-Object {
            $_.Tags["ArchiveProject"] -eq "ArchiveLegacy" -and
            $_.ResourceGroupName -like $ResourceGroupFilter -and
            $_.Name -notin $ExcludeNsgNames
        }

        Write-Log "Found $($nsgs.Count) NSGs to process in subscription $subId"

        foreach ($nsg in $nsgs) {
            try {
                Write-Log "Processing NSG: $($nsg.Name) in RG: $($nsg.ResourceGroupName)"

                Export-NsgBackup -Nsg $nsg

                if ($PSCmdlet.ShouldProcess($nsg.Name, "Add DenyAllInbound and DenyAllOutbound rules")) {
                    # Remove existing archive deny rules to avoid duplicates
                    $nsg.SecurityRules = @($nsg.SecurityRules | Where-Object {
                        $_.Name -notin @("DenyAllInbound_Archive", "DenyAllOutbound_Archive")
                    })

                    $nsg | Add-AzNetworkSecurityRuleConfig `
                        -Name "DenyAllInbound_Archive" `
                        -Priority 100 `
                        -Direction Inbound `
                        -Access Deny `
                        -Protocol "*" `
                        -SourcePortRange "*" `
                        -DestinationPortRange "*" `
                        -SourceAddressPrefix "*" `
                        -DestinationAddressPrefix "*" | Out-Null

                    $nsg | Add-AzNetworkSecurityRuleConfig `
                        -Name "DenyAllOutbound_Archive" `
                        -Priority 100 `
                        -Direction Outbound `
                        -Access Deny `
                        -Protocol "*" `
                        -SourcePortRange "*" `
                        -DestinationPortRange "*" `
                        -SourceAddressPrefix "*" `
                        -DestinationAddressPrefix "*" | Out-Null

                    $nsg | Set-AzNetworkSecurityGroup | Out-Null
                    Write-Log "Applied deny rules to NSG: $($nsg.Name)"
                }

                $totalProcessed++
            }
            catch {
                $totalErrors++
                Write-Log "Failed to process NSG '$($nsg.Name)': $_" -Level ERROR
            }
        }
    }
    catch {
        Write-Log "Failed processing subscription '$subId': $_" -Level ERROR
    }
}

Write-Log "Complete. Processed: $totalProcessed, Skipped: $totalSkipped, Errors: $totalErrors"
Write-Output "NSG restriction complete. See log: $logFile"
