<#
.SYNOPSIS
    Restores an archived Azure resource to its pre-archive state.

.DESCRIPTION
    Reads a JSON backup file and restores the specified resource type to its
    original configuration. Supports NSG, VM, WebApp, LogicApp, TrafficManager,
    AppGateway, SQL, Alert, Dashboard, and ActionGroup resource types.

.PARAMETER ResourceType
    The type of Azure resource to restore.

.PARAMETER ResourceName
    The name of the resource to restore.

.PARAMETER BackupPath
    Path to the backup directory or specific backup file.

.PARAMETER SubscriptionId
    Azure subscription ID for the target resource.

.PARAMETER ResourceGroupName
    Resource group containing the target resource.

.EXAMPLE
    .\Restore-ArchivedResource.ps1 -ResourceType VM -ResourceName "web-server-01" -BackupPath ".\output\backups"

.EXAMPLE
    .\Restore-ArchivedResource.ps1 -ResourceType NSG -ResourceName "nsg-frontend" -BackupPath ".\output\backups" -SubscriptionId "abc-123" -ResourceGroupName "rg-prod"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('NSG', 'VM', 'WebApp', 'LogicApp', 'TrafficManager',
                 'AppGateway', 'SQL', 'Alert', 'Dashboard', 'ActionGroup')]
    [string]$ResourceType,

    [Parameter(Mandatory)]
    [string]$ResourceName,

    [Parameter(Mandatory)]
    [string]$BackupPath,

    [string]$SubscriptionId,

    [string]$ResourceGroupName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper Functions
function Find-BackupFile {
    <#
    .SYNOPSIS
        Locates the backup JSON file matching the resource name.
    #>
    [CmdletBinding()]
    param(
        [string]$BackupPath,
        [string]$ResourceName
    )

    if (Test-Path $BackupPath -PathType Leaf) {
        return Get-Item $BackupPath
    }

    $candidates = Get-ChildItem -Path $BackupPath -Filter "*$ResourceName*.json" -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    if ($candidates.Count -eq 0) {
        throw "No backup file found matching '$ResourceName' in '$BackupPath'"
    }

    Write-Verbose "Found $($candidates.Count) backup file(s). Using most recent: $($candidates[0].Name)"
    return $candidates[0]
}

function Write-RestoreLog {
    <#
    .SYNOPSIS
        Writes a timestamped log entry for restore operations.
    #>
    [CmdletBinding()]
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Error'   { Write-Error $Message }
        default   { Write-Verbose $Message }
    }

    $logDir = Join-Path $PSScriptRoot '..\output\logs'
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $logFile = Join-Path $logDir "restore-$(Get-Date -Format 'yyyyMMdd').log"
    Add-Content -Path $logFile -Value $entry
}
#endregion

#region Set Azure Context
if ($SubscriptionId) {
    try {
        Write-Verbose "Setting Azure context to subscription: $SubscriptionId"
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "Failed to set subscription context: $_"
        return
    }
}
#endregion

#region Locate Backup File
try {
    $backupFile = Find-BackupFile -BackupPath $BackupPath -ResourceName $ResourceName
    Write-RestoreLog "Found backup file: $($backupFile.FullName)"
    $backup = Get-Content -Path $backupFile.FullName -Raw | ConvertFrom-Json
}
catch {
    Write-Error "Failed to read backup file: $_"
    return
}
#endregion

#region Restore Logic
$restoreStart = Get-Date
Write-RestoreLog "Starting restore of $ResourceType '$ResourceName'"

try {
    switch ($ResourceType) {
        'NSG' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Restore NSG security rules")) {
                Write-Verbose "Restoring NSG rules for '$ResourceName'..."
                $nsg = Get-AzNetworkSecurityGroup -Name $ResourceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop

                $nsg.SecurityRules = @()
                foreach ($rule in $backup.SecurityRules) {
                    $ruleParams = @{
                        Name                     = $rule.Name
                        Description              = $rule.Description
                        Protocol                 = $rule.Protocol
                        SourcePortRange          = $rule.SourcePortRange
                        DestinationPortRange     = $rule.DestinationPortRange
                        SourceAddressPrefix      = $rule.SourceAddressPrefix
                        DestinationAddressPrefix = $rule.DestinationAddressPrefix
                        Access                   = $rule.Access
                        Priority                 = $rule.Priority
                        Direction                = $rule.Direction
                    }
                    $nsg | Add-AzNetworkSecurityRuleConfig @ruleParams | Out-Null
                }

                $nsg | Set-AzNetworkSecurityGroup | Out-Null
                Write-RestoreLog "NSG '$ResourceName' rules restored successfully."
            }
        }

        'VM' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Restore VM power state")) {
                Write-Verbose "Restoring VM '$ResourceName' power state..."
                $previousState = $backup.PowerState

                if ($previousState -match 'running') {
                    Start-AzVM -Name $ResourceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
                    Write-RestoreLog "VM '$ResourceName' started (previous state: $previousState)."
                }
                else {
                    Write-RestoreLog "VM '$ResourceName' previous state was '$previousState'. No action needed."
                }
            }
        }

        'WebApp' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Restore WebApp state")) {
                Write-Verbose "Restoring WebApp '$ResourceName'..."
                $previousState = $backup.State

                if ($previousState -eq 'Running') {
                    Start-AzWebApp -Name $ResourceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
                    Write-RestoreLog "WebApp '$ResourceName' started (previous state: $previousState)."
                }
                else {
                    Write-RestoreLog "WebApp '$ResourceName' previous state was '$previousState'. No action needed."
                }
            }
        }

        'LogicApp' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Re-enable Logic App")) {
                Write-Verbose "Re-enabling Logic App '$ResourceName'..."
                $previousState = $backup.State

                if ($previousState -eq 'Enabled') {
                    $resourceId = $backup.ResourceId
                    if (-not $resourceId) {
                        $resource = Get-AzResource -Name $ResourceName -ResourceGroupName $ResourceGroupName `
                            -ResourceType 'Microsoft.Logic/workflows' -ErrorAction Stop
                        $resourceId = $resource.ResourceId
                    }

                    Invoke-AzResourceAction -ResourceId $resourceId -Action 'enable' -Force -ErrorAction Stop
                    Write-RestoreLog "Logic App '$ResourceName' re-enabled (previous state: $previousState)."
                }
                else {
                    Write-RestoreLog "Logic App '$ResourceName' previous state was '$previousState'. No action needed."
                }
            }
        }

        'TrafficManager' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Restore Traffic Manager endpoints")) {
                Write-Verbose "Restoring Traffic Manager endpoints for '$ResourceName'..."

                foreach ($endpoint in $backup.Endpoints) {
                    if ($endpoint.EndpointStatus -eq 'Enabled') {
                        Enable-AzTrafficManagerEndpoint -Name $endpoint.Name `
                            -ProfileName $ResourceName `
                            -ResourceGroupName $ResourceGroupName `
                            -Type $endpoint.Type `
                            -ErrorAction Stop
                        Write-RestoreLog "Traffic Manager endpoint '$($endpoint.Name)' re-enabled on profile '$ResourceName'."
                    }
                }
                Write-RestoreLog "Traffic Manager '$ResourceName' endpoints restored."
            }
        }

        'AppGateway' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Restore Application Gateway configuration")) {
                Write-Verbose "Restoring Application Gateway '$ResourceName'..."
                $appGw = Get-AzApplicationGateway -Name $ResourceName -ResourceGroupName $ResourceGroupName -ErrorAction Stop

                if ($backup.Sku) {
                    $appGw.Sku.Name = $backup.Sku.Name
                    $appGw.Sku.Tier = $backup.Sku.Tier
                    $appGw.Sku.Capacity = $backup.Sku.Capacity
                }

                if ($backup.OperationalState -eq 'Running') {
                    Start-AzApplicationGateway -ApplicationGateway $appGw -ErrorAction Stop
                }

                Set-AzApplicationGateway -ApplicationGateway $appGw -ErrorAction Stop | Out-Null
                Write-RestoreLog "Application Gateway '$ResourceName' restored."
            }
        }

        'SQL' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Restore SQL Database tier")) {
                Write-Verbose "Restoring SQL Database '$ResourceName' to original tier..."
                $serverName = $backup.ServerName
                $edition = $backup.Edition
                $requestedServiceObjectiveName = $backup.ServiceObjective

                $sqlParams = @{
                    DatabaseName = $ResourceName
                    ServerName   = $serverName
                    ResourceGroupName = $ResourceGroupName
                    Edition      = $edition
                    RequestedServiceObjectiveName = $requestedServiceObjectiveName
                    ErrorAction  = 'Stop'
                }

                Set-AzSqlDatabase @sqlParams | Out-Null
                Write-RestoreLog "SQL Database '$ResourceName' restored to $edition/$requestedServiceObjectiveName."
            }
        }

        'Alert' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Re-enable alert rule")) {
                Write-Verbose "Re-enabling alert rule '$ResourceName'..."
                $resourceId = $backup.ResourceId

                if ($backup.AlertType -eq 'MetricAlert') {
                    $alert = Get-AzMetricAlertRuleV2 -ResourceGroupName $ResourceGroupName -Name $ResourceName -ErrorAction Stop
                    $alert.Enabled = $true
                    Add-AzMetricAlertRuleV2 -InputObject $alert -ErrorAction Stop | Out-Null
                }
                elseif ($backup.AlertType -eq 'ScheduledQueryRule') {
                    Update-AzScheduledQueryRule -ResourceGroupName $ResourceGroupName -Name $ResourceName `
                        -Enabled -ErrorAction Stop | Out-Null
                }
                elseif ($backup.AlertType -eq 'ActivityLogAlert') {
                    $resource = Get-AzResource -ResourceId $resourceId -ErrorAction Stop
                    $resource.Properties.enabled = $true
                    $resource | Set-AzResource -Force -ErrorAction Stop | Out-Null
                }

                Write-RestoreLog "Alert '$ResourceName' re-enabled."
            }
        }

        'Dashboard' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Recreate dashboard from ARM template")) {
                Write-Verbose "Recreating dashboard '$ResourceName'..."

                $dashboardJson = $backup | ConvertTo-Json -Depth 50
                $tempFile = Join-Path $env:TEMP "dashboard-$ResourceName-$(Get-Date -Format 'yyyyMMddHHmmss').json"
                $dashboardJson | Set-Content -Path $tempFile -Encoding UTF8

                New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
                    -TemplateFile $tempFile `
                    -ErrorAction Stop | Out-Null

                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                Write-RestoreLog "Dashboard '$ResourceName' recreated from ARM template."
            }
        }

        'ActionGroup' {
            if ($PSCmdlet.ShouldProcess($ResourceName, "Recreate action group")) {
                Write-Verbose "Recreating action group '$ResourceName'..."
                $shortName = $backup.GroupShortName
                $receivers = @()

                foreach ($r in $backup.EmailReceivers) {
                    $receivers += New-AzActionGroupEmailReceiverObject -Name $r.Name -EmailAddress $r.EmailAddress
                }
                foreach ($r in $backup.WebhookReceivers) {
                    $receivers += New-AzActionGroupWebhookReceiverObject -Name $r.Name -ServiceUri $r.ServiceUri
                }

                New-AzActionGroup -Name $ResourceName `
                    -ResourceGroupName $ResourceGroupName `
                    -ShortName $shortName `
                    -EmailReceiver $receivers `
                    -ErrorAction Stop | Out-Null

                Write-RestoreLog "Action group '$ResourceName' recreated."
            }
        }
    }

    $restoreEnd = Get-Date
    $duration = $restoreEnd - $restoreStart
    Write-RestoreLog "Restore of $ResourceType '$ResourceName' completed in $($duration.ToString())."
    Write-Host "Restore complete: $ResourceType '$ResourceName' ($($duration.ToString()))" -ForegroundColor Green
}
catch {
    $restoreEnd = Get-Date
    Write-RestoreLog "Restore of $ResourceType '$ResourceName' failed: $($_.Exception.Message)" -Level 'Error'
    Write-Error "Restore failed for $ResourceType '$ResourceName': $_"
}
#endregion
