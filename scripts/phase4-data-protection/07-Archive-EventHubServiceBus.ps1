<#
.SYNOPSIS
    Archives Azure Event Hub and Service Bus namespaces tagged for the Legacy decommission.
.DESCRIPTION
    For each Event Hub and Service Bus namespace tagged ArchiveProject=ArchiveLegacy:
      - Captures current consumer groups, topics, queues, subscriptions
      - Disables send/listen on entities where possible
      - Scales to Basic tier
      - Exports configs to JSON
.PARAMETER SubscriptionId
    Target Azure subscription ID.
.PARAMETER ArchiveStorageAccountName
    Storage account for config exports.
.PARAMETER ArchiveContainerName
    Container for messaging config exports.
.EXAMPLE
    .\07-Archive-EventHubServiceBus.ps1 -SubscriptionId "xxxx" -ArchiveStorageAccountName "azurearchive"
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [string]$SubscriptionListPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveStorageAccountName,

    [Parameter()]
    [string]$ArchiveContainerName = "messaging-configs",

    [Parameter()]
    [string]$TagName = "ArchiveProject",

    [Parameter()]
    [string]$TagValue = "ArchiveLegacy",

    [Parameter()]
    [string]$LogPath = ".\logs\phase4-messaging-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Verbose $entry
    $logDir = Split-Path $LogPath -Parent
    if ($logDir -and !(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $entry
}

function Export-EventHubNamespace {
    param($Namespace, $ArchiveCtx, $ContainerName)

    $nsName = $Namespace.Name
    $nsRg = $Namespace.ResourceGroupName
    Write-Log "  Exporting Event Hub namespace config: $nsName"

    $config = [PSCustomObject]@{
        Type          = "EventHub"
        NamespaceName = $nsName
        ResourceGroup = $nsRg
        Location      = $Namespace.Location
        Sku           = $Namespace.Sku.Name
        Capacity      = $Namespace.Sku.Capacity
        EventHubs     = @()
        ExportDate    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    $eventHubs = Get-AzEventHub -NamespaceName $nsName -ResourceGroupName $nsRg
    foreach ($eh in $eventHubs) {
        $ehInfo = @{
            Name            = $eh.Name
            PartitionCount  = $eh.PartitionCount
            MessageRetention = $eh.MessageRetentionInDays
            Status          = $eh.Status
            ConsumerGroups  = @()
        }

        $cgs = Get-AzEventHubConsumerGroup -NamespaceName $nsName -ResourceGroupName $nsRg -EventHubName $eh.Name
        foreach ($cg in $cgs) {
            $ehInfo.ConsumerGroups += [PSCustomObject]@{
                Name = $cg.Name
            }
        }
        $config.EventHubs += $ehInfo
    }

    $configJson = $config | ConvertTo-Json -Depth 10
    $blobName = "eventhub/$nsName-config-$(Get-Date -Format 'yyyyMMdd').json"
    $tempFile = Join-Path $env:TEMP "$nsName-eh-config.json"
    $configJson | Out-File -FilePath $tempFile -Encoding utf8
    Set-AzStorageBlobContent -File $tempFile -Container $ContainerName -Blob $blobName -Context $ArchiveCtx -Force | Out-Null
    Remove-Item $tempFile -Force
    Write-Log "  Exported Event Hub config to $blobName"

    return $config
}

function Export-ServiceBusNamespace {
    param($Namespace, $ArchiveCtx, $ContainerName)

    $nsName = $Namespace.Name
    $nsRg = $Namespace.ResourceGroupName
    Write-Log "  Exporting Service Bus namespace config: $nsName"

    $config = [PSCustomObject]@{
        Type          = "ServiceBus"
        NamespaceName = $nsName
        ResourceGroup = $nsRg
        Location      = $Namespace.Location
        Sku           = $Namespace.Sku.Name
        Queues        = @()
        Topics        = @()
        ExportDate    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    # Queues
    $queues = Get-AzServiceBusQueue -NamespaceName $nsName -ResourceGroupName $nsRg
    foreach ($q in $queues) {
        $config.Queues += [PSCustomObject]@{
            Name                  = $q.Name
            Status                = $q.Status
            MaxSizeInMegabytes    = $q.MaxSizeInMegabytes
            MessageCount          = $q.CountDetails.ActiveMessageCount
            DeadLetterCount       = $q.CountDetails.DeadLetterMessageCount
            EnablePartitioning    = $q.EnablePartitioning
            RequiresSession       = $q.RequiresSession
        }
    }

    # Topics & subscriptions
    $topics = Get-AzServiceBusTopic -NamespaceName $nsName -ResourceGroupName $nsRg
    foreach ($t in $topics) {
        $topicInfo = @{
            Name               = $t.Name
            Status             = $t.Status
            MaxSizeInMegabytes = $t.MaxSizeInMegabytes
            EnablePartitioning = $t.EnablePartitioning
            Subscriptions      = @()
        }

        $subs = Get-AzServiceBusSubscription -NamespaceName $nsName -ResourceGroupName $nsRg -TopicName $t.Name
        foreach ($s in $subs) {
            $topicInfo.Subscriptions += [PSCustomObject]@{
                Name         = $s.Name
                Status       = $s.Status
                MessageCount = $s.CountDetails.ActiveMessageCount
            }
        }
        $config.Topics += $topicInfo
    }

    $configJson = $config | ConvertTo-Json -Depth 10
    $blobName = "servicebus/$nsName-config-$(Get-Date -Format 'yyyyMMdd').json"
    $tempFile = Join-Path $env:TEMP "$nsName-sb-config.json"
    $configJson | Out-File -FilePath $tempFile -Encoding utf8
    Set-AzStorageBlobContent -File $tempFile -Container $ContainerName -Blob $blobName -Context $ArchiveCtx -Force | Out-Null
    Remove-Item $tempFile -Force
    Write-Log "  Exported Service Bus config to $blobName"

    return $config
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
    throw "No subscriptions specified. Provide -SubscriptionId or -SubscriptionListPath."
}

foreach ($subId in $SubscriptionId) {
try {
    Write-Log "Setting subscription context to $subId"
    Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

    $archiveSa = Get-AzStorageAccount | Where-Object { $_.StorageAccountName -eq $ArchiveStorageAccountName }
    if (-not $archiveSa) { throw "Archive storage account '$ArchiveStorageAccountName' not found." }
    $archiveCtx = $archiveSa.Context

    if (-not (Get-AzStorageContainer -Context $archiveCtx -Name $ArchiveContainerName -ErrorAction SilentlyContinue)) {
        New-AzStorageContainer -Context $archiveCtx -Name $ArchiveContainerName -Permission Off | Out-Null
    }

    $summary = [System.Collections.Generic.List[PSObject]]::new()

    #region Event Hubs
    Write-Log "=== Processing Event Hub Namespaces ==="
    $ehNamespaces = Get-AzEventHubNamespace | Where-Object { $_.Tags[$TagName] -eq $TagValue }
    Write-Log "Found $($ehNamespaces.Count) Event Hub namespaces tagged $TagName=$TagValue"

    foreach ($ns in $ehNamespaces) {
        $nsName = $ns.Name
        $nsRg = $ns.ResourceGroupName
        Write-Log "Processing Event Hub namespace: $nsName"

        try {
            $config = Export-EventHubNamespace -Namespace $ns -ArchiveCtx $archiveCtx -ContainerName $ArchiveContainerName

            # Disable send/listen by removing authorization rules (except RootManageSharedAccessKey)
            if ($PSCmdlet.ShouldProcess($nsName, "Remove non-root authorization rules")) {
                $authRules = Get-AzEventHubAuthorizationRule -NamespaceName $nsName -ResourceGroupName $nsRg
                foreach ($rule in $authRules) {
                    if ($rule.Name -ne "RootManageSharedAccessKey") {
                        Remove-AzEventHubAuthorizationRule -NamespaceName $nsName -ResourceGroupName $nsRg -Name $rule.Name -Force
                        Write-Log "  Removed auth rule '$($rule.Name)' from $nsName"
                    }
                }
            }

            # Scale to Basic (if Standard/Premium)
            if ($ns.Sku.Name -ne "Basic") {
                if ($ns.Sku.Name -eq "Premium") {
                    Write-Log "  Premium Event Hub namespaces cannot be scaled to Basic — flagging for manual action" -Level "WARN"
                }
                elseif ($PSCmdlet.ShouldProcess($nsName, "Scale to Basic tier")) {
                    # Check for features incompatible with Basic (capture, partitioned consumers)
                    $hasCapture = $config.EventHubs | Where-Object { $_.CaptureEnabled }
                    if ($hasCapture) {
                        Write-Log "  Namespace $nsName has capture enabled — disable capture before scaling to Basic" -Level "WARN"
                    }
                    else {
                        Set-AzEventHubNamespace -ResourceGroupName $nsRg -Name $nsName -SkuName "Basic" -SkuCapacity 1
                        Write-Log "  Scaled $nsName to Basic tier"
                    }
                }
            }
            else {
                Write-Log "  $nsName already at Basic tier"
            }

            $summary.Add([PSCustomObject]@{
                Type          = "EventHub"
                Namespace     = $nsName
                ResourceGroup = $nsRg
                OriginalSku   = $ns.Sku.Name
                Status        = "Success"
            })
        }
        catch {
            Write-Log "ERROR on Event Hub ${nsName}: $_" -Level "ERROR"
            $summary.Add([PSCustomObject]@{
                Type          = "EventHub"
                Namespace     = $nsName
                ResourceGroup = $nsRg
                OriginalSku   = $ns.Sku.Name
                Status        = "Failed: $_"
            })
        }
    }
    #endregion

    #region Service Bus
    Write-Log "=== Processing Service Bus Namespaces ==="
    $sbNamespaces = Get-AzServiceBusNamespace | Where-Object { $_.Tags[$TagName] -eq $TagValue }
    Write-Log "Found $($sbNamespaces.Count) Service Bus namespaces tagged $TagName=$TagValue"

    foreach ($ns in $sbNamespaces) {
        $nsName = $ns.Name
        $nsRg = $ns.ResourceGroupName
        Write-Log "Processing Service Bus namespace: $nsName"

        try {
            $config = Export-ServiceBusNamespace -Namespace $ns -ArchiveCtx $archiveCtx -ContainerName $ArchiveContainerName

            # Disable send/listen by updating entity status
            if ($PSCmdlet.ShouldProcess($nsName, "Disable send on queues and topics")) {
                $queues = Get-AzServiceBusQueue -NamespaceName $nsName -ResourceGroupName $nsRg
                foreach ($q in $queues) {
                    if ($q.Status -ne "SendDisabled") {
                        Set-AzServiceBusQueue -NamespaceName $nsName -ResourceGroupName $nsRg -Name $q.Name -Status "SendDisabled"
                        Write-Log "  Disabled send on queue '$($q.Name)'"
                    }
                }

                $topics = Get-AzServiceBusTopic -NamespaceName $nsName -ResourceGroupName $nsRg
                foreach ($t in $topics) {
                    if ($t.Status -ne "SendDisabled") {
                        Set-AzServiceBusTopic -NamespaceName $nsName -ResourceGroupName $nsRg -Name $t.Name -Status "SendDisabled"
                        Write-Log "  Disabled send on topic '$($t.Name)'"
                    }
                }
            }

            # Remove non-root authorization rules
            if ($PSCmdlet.ShouldProcess($nsName, "Remove non-root authorization rules")) {
                $authRules = Get-AzServiceBusAuthorizationRule -NamespaceName $nsName -ResourceGroupName $nsRg
                foreach ($rule in $authRules) {
                    if ($rule.Name -ne "RootManageSharedAccessKey") {
                        Remove-AzServiceBusAuthorizationRule -NamespaceName $nsName -ResourceGroupName $nsRg -Name $rule.Name -Force
                        Write-Log "  Removed auth rule '$($rule.Name)' from $nsName"
                    }
                }
            }

            # Scale to Basic (if Standard/Premium)
            if ($ns.Sku.Name -ne "Basic") {
                if ($ns.Sku.Name -eq "Premium") {
                    Write-Log "  Premium Service Bus namespaces cannot be directly scaled to Basic — flagging for manual action" -Level "WARN"
                }
                elseif ($config.Topics.Count -gt 0) {
                    Write-Log "  Namespace $nsName has topics — Basic tier does not support topics, skipping scale-down" -Level "WARN"
                }
                elseif ($PSCmdlet.ShouldProcess($nsName, "Scale to Basic tier")) {
                    Set-AzServiceBusNamespace -ResourceGroupName $nsRg -Name $nsName -SkuName "Basic" -SkuCapacity 1
                    Write-Log "  Scaled $nsName to Basic tier"
                }
            }
            else {
                Write-Log "  $nsName already at Basic tier"
            }

            $summary.Add([PSCustomObject]@{
                Type          = "ServiceBus"
                Namespace     = $nsName
                ResourceGroup = $nsRg
                OriginalSku   = $ns.Sku.Name
                Status        = "Success"
            })
        }
        catch {
            Write-Log "ERROR on Service Bus ${nsName}: $_" -Level "ERROR"
            $summary.Add([PSCustomObject]@{
                Type          = "ServiceBus"
                Namespace     = $nsName
                ResourceGroup = $nsRg
                OriginalSku   = $ns.Sku.Name
                Status        = "Failed: $_"
            })
        }
    }
    #endregion

    Write-Log "=== Event Hub & Service Bus Archive Summary ==="
    $summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }
    Write-Log "Total: $($summary.Count), Succeeded: $(($summary | Where-Object Status -eq 'Success').Count), Failed: $(($summary | Where-Object Status -ne 'Success').Count)"
}
catch {
    Write-Log "FATAL: $_" -Level "ERROR"
    throw
}
} # end foreach
