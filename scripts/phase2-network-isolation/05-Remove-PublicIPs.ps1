<#
.SYNOPSIS
    Dissociates Public IPs tagged for archive from NICs and Load Balancers.

.DESCRIPTION
    Finds Public IPs tagged with ArchiveProject=ArchiveLegacy, backs up their
    associations to JSON, then dissociates them from NICs and Load Balancers.
    Public IPs are NOT deleted — only detached for later cleanup.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER BackupPath
    Path for JSON backups. Defaults to .\output\backups\public-ip.

.PARAMETER WhatIf
    Perform a dry run without making changes.

.EXAMPLE
    .\05-Remove-PublicIPs.ps1 -SubscriptionId "xxxx-xxxx" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [string]$BackupPath = (Join-Path $PSScriptRoot "..\..\output\backups\public-ip")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = Join-Path $PSScriptRoot "..\..\output\logs\05-Remove-PublicIPs-$timestamp.log"

function Write-Log {
    param([string]$Message, [ValidateSet("INFO","WARN","ERROR")][string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Verbose $entry
    $logDir = Split-Path $logFile -Parent
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Add-Content -Path $logFile -Value $entry
}

function Export-PublicIpBackup {
    param($PublicIp)

    $backupDir = Join-Path $BackupPath $timestamp
    if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }

    $fileName = "{0}_{1}.json" -f $PublicIp.ResourceGroupName, $PublicIp.Name
    $filePath = Join-Path $backupDir $fileName

    $backup = @{
        Name              = $PublicIp.Name
        ResourceGroupName = $PublicIp.ResourceGroupName
        Location          = $PublicIp.Location
        IpAddress         = $PublicIp.IpAddress
        PublicIpAllocationMethod = $PublicIp.PublicIpAllocationMethod
        Sku               = $PublicIp.Sku.Name
        AssociatedNic     = if ($PublicIp.IpConfiguration.Id -and $PublicIp.IpConfiguration.Id -match "/networkInterfaces/") {
            @{
                IpConfigurationId = $PublicIp.IpConfiguration.Id
                NicName           = ($PublicIp.IpConfiguration.Id -split "/networkInterfaces/")[1] -split "/ipConfigurations/" | Select-Object -First 1
                IpConfigName      = ($PublicIp.IpConfiguration.Id -split "/ipConfigurations/")[-1]
                ResourceGroupName = ($PublicIp.IpConfiguration.Id -split "/resourceGroups/")[1] -split "/" | Select-Object -First 1
            }
        } else { $null }
        AssociatedLb      = if ($PublicIp.IpConfiguration.Id -and $PublicIp.IpConfiguration.Id -match "/loadBalancers/") {
            @{
                IpConfigurationId  = $PublicIp.IpConfiguration.Id
                LoadBalancerName   = ($PublicIp.IpConfiguration.Id -split "/loadBalancers/")[1] -split "/" | Select-Object -First 1
                FrontendConfigName = ($PublicIp.IpConfiguration.Id -split "/frontendIPConfigurations/")[-1]
                ResourceGroupName  = ($PublicIp.IpConfiguration.Id -split "/resourceGroups/")[1] -split "/" | Select-Object -First 1
            }
        } else { $null }
        BackupTimestamp   = $timestamp
    }

    $backup | ConvertTo-Json -Depth 10 | Set-Content -Path $filePath -Encoding UTF8
    Write-Log "Backup saved: $filePath"
    return $filePath
}

function Restore-PublicIpFromBackup {
    <#
    .SYNOPSIS
        Re-associates a Public IP to its original NIC or Load Balancer from backup.
    .PARAMETER BackupFile
        Path to the JSON backup file.
    #>
    param([Parameter(Mandatory)][string]$BackupFile)

    $data = Get-Content $BackupFile -Raw | ConvertFrom-Json
    $pip = Get-AzPublicIpAddress -Name $data.Name -ResourceGroupName $data.ResourceGroupName

    if ($data.AssociatedNic) {
        $nic = Get-AzNetworkInterface -Name $data.AssociatedNic.NicName -ResourceGroupName $data.AssociatedNic.ResourceGroupName
        $ipConfig = $nic.IpConfigurations | Where-Object { $_.Name -eq $data.AssociatedNic.IpConfigName }
        $ipConfig.PublicIpAddress = $pip
        Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
        Write-Log "Restored Public IP '$($data.Name)' to NIC '$($data.AssociatedNic.NicName)'"
    }
    elseif ($data.AssociatedLb) {
        $lb = Get-AzLoadBalancer -Name $data.AssociatedLb.LoadBalancerName -ResourceGroupName $data.AssociatedLb.ResourceGroupName
        $feConfig = $lb.FrontendIpConfigurations | Where-Object { $_.Name -eq $data.AssociatedLb.FrontendConfigName }
        $feConfig.PublicIpAddress = $pip
        Set-AzLoadBalancer -LoadBalancer $lb | Out-Null
        Write-Log "Restored Public IP '$($data.Name)' to LB '$($data.AssociatedLb.LoadBalancerName)'"
    }
}

# --- Main ---
Write-Log "Starting Public IP dissociation"

$totalProcessed = 0
$totalSkipped = 0
$totalErrors = 0

foreach ($subId in $SubscriptionId) {
    try {
        Write-Log "Switching to subscription: $subId"
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null

        $publicIps = Get-AzPublicIpAddress | Where-Object {
            $_.Tags["ArchiveProject"] -eq "ArchiveLegacy"
        }

        Write-Log "Found $($publicIps.Count) Public IPs in subscription $subId"

        foreach ($pip in $publicIps) {
            try {
                Write-Log "Processing Public IP: $($pip.Name) ($($pip.IpAddress))"

                if (-not $pip.IpConfiguration) {
                    Write-Log "Public IP '$($pip.Name)' has no association, skipping" -Level WARN
                    $totalSkipped++
                    continue
                }

                Export-PublicIpBackup -PublicIp $pip
                $configId = $pip.IpConfiguration.Id

                # Dissociate from NIC
                if ($configId -match "/networkInterfaces/") {
                    $nicName = ($configId -split "/networkInterfaces/")[1] -split "/ipConfigurations/" | Select-Object -First 1
                    $nicRg = ($configId -split "/resourceGroups/")[1] -split "/" | Select-Object -First 1
                    $ipConfigName = ($configId -split "/ipConfigurations/")[-1]

                    if ($PSCmdlet.ShouldProcess("$nicName/$ipConfigName", "Remove Public IP association from NIC")) {
                        $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $nicRg
                        $ipConfig = $nic.IpConfigurations | Where-Object { $_.Name -eq $ipConfigName }
                        $ipConfig.PublicIpAddress = $null
                        Set-AzNetworkInterface -NetworkInterface $nic | Out-Null
                        Write-Log "Dissociated Public IP '$($pip.Name)' from NIC '$nicName'"
                    }
                }
                # Dissociate from Load Balancer
                elseif ($configId -match "/loadBalancers/") {
                    $lbName = ($configId -split "/loadBalancers/")[1] -split "/" | Select-Object -First 1
                    $lbRg = ($configId -split "/resourceGroups/")[1] -split "/" | Select-Object -First 1
                    $feConfigName = ($configId -split "/frontendIPConfigurations/")[-1]

                    if ($PSCmdlet.ShouldProcess("$lbName/$feConfigName", "Remove Public IP association from Load Balancer")) {
                        $lb = Get-AzLoadBalancer -Name $lbName -ResourceGroupName $lbRg
                        $feConfig = $lb.FrontendIpConfigurations | Where-Object { $_.Name -eq $feConfigName }
                        $feConfig.PublicIpAddress = $null
                        Set-AzLoadBalancer -LoadBalancer $lb | Out-Null
                        Write-Log "Dissociated Public IP '$($pip.Name)' from LB '$lbName'"
                    }
                }
                else {
                    Write-Log "Public IP '$($pip.Name)' has unknown association type: $configId" -Level WARN
                    $totalSkipped++
                    continue
                }

                $totalProcessed++
            }
            catch {
                $totalErrors++
                Write-Log "Failed to process Public IP '$($pip.Name)': $_" -Level ERROR
            }
        }
    }
    catch {
        Write-Log "Failed processing subscription '$subId': $_" -Level ERROR
    }
}

Write-Log "Complete. Processed: $totalProcessed, Skipped: $totalSkipped, Errors: $totalErrors"
Write-Output "Public IP dissociation complete. See log: $logFile"
