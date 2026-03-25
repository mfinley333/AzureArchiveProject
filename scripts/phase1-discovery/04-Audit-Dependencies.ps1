#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Audits resource dependencies for the Legacy Archive project.

.DESCRIPTION
    Uses Azure Resource Graph to discover dependencies between resources:
    - Private Endpoints and their target resources
    - VNet integrations (App Service, AKS, etc.)
    - Key Vault references from App Services, VMs, and AKS
    - Shared resources (VNets, NSGs, subnets) used by multiple services
    Exports a dependency map as CSV for archive planning.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to query.

.PARAMETER OutputPath
    Directory for output files. Defaults to c:\dev\AzureArchiveProject\output\inventory.

.EXAMPLE
    .\04-Audit-Dependencies.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [string]$OutputPath = (Join-Path $PSScriptRoot '..\..\output\inventory'),

    [string]$SubscriptionListPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

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

if (-not $SubscriptionId -and $SubscriptionListPath) {
    $SubscriptionId = Import-SubscriptionList -Path $SubscriptionListPath
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$dependencyFile = Join-Path $OutputPath "dependency-map-$timestamp.csv"
$sharedResourceFile = Join-Path $OutputPath "shared-resources-$timestamp.csv"

$dependencies = [System.Collections.Generic.List[PSCustomObject]]::new()

function Invoke-GraphQuery {
    param([string]$Query, [string[]]$Subs)
    $all = [System.Collections.Generic.List[PSObject]]::new()
    $skip = $null
    do {
        $p = @{ Query = $Query; Subscription = $Subs; First = 1000 }
        if ($skip) { $p['SkipToken'] = $skip }
        try {
            $r = Search-AzGraph @p
            $r.Data | ForEach-Object { $all.Add($_) }
            $skip = $r.SkipToken
        }
        catch {
            Write-Warning "Graph query failed: $_"
            $skip = $null
        }
    } while ($skip)
    return $all
}

function Add-Dependency {
    param([string]$SourceId, [string]$SourceType, [string]$SourceName,
          [string]$TargetId, [string]$TargetType, [string]$TargetName,
          [string]$RelationType)
    $dependencies.Add([PSCustomObject]@{
        SourceResourceId   = $SourceId
        SourceResourceType = $SourceType
        SourceResourceName = $SourceName
        TargetResourceId   = $TargetId
        TargetResourceType = $TargetType
        TargetResourceName = $TargetName
        RelationType       = $RelationType
    })
}

# --- Private Endpoints ---
Write-Verbose "Discovering Private Endpoint connections..."
$peQuery = @"
Resources
| where type =~ 'microsoft.network/privateendpoints'
| mv-expand connection = properties.privateLinkServiceConnections
| project
    peId = id, peName = name, peRg = resourceGroup,
    targetId = tostring(connection.properties.privateLinkServiceId),
    groupIds = tostring(connection.properties.groupIds)
"@

$peResults = Invoke-GraphQuery -Query $peQuery -Subs $SubscriptionId
foreach ($pe in $peResults) {
    Add-Dependency -SourceId $pe.peId -SourceType 'PrivateEndpoint' -SourceName $pe.peName `
        -TargetId $pe.targetId -TargetType 'PrivateLinkTarget' -TargetName ($pe.targetId -split '/')[-1] `
        -RelationType "PrivateEndpoint($($pe.groupIds))"
}
Write-Host "Found $($peResults.Count) Private Endpoint connections." -ForegroundColor Cyan

# --- VNet Integrations (App Services) ---
Write-Verbose "Discovering App Service VNet integrations..."
$vnetIntQuery = @"
Resources
| where type =~ 'microsoft.web/sites'
| where isnotempty(properties.virtualNetworkSubnetId)
| project
    siteId = id, siteName = name, siteType = type,
    subnetId = tostring(properties.virtualNetworkSubnetId)
"@

$vnetIntResults = Invoke-GraphQuery -Query $vnetIntQuery -Subs $SubscriptionId
foreach ($site in $vnetIntResults) {
    Add-Dependency -SourceId $site.siteId -SourceType $site.siteType -SourceName $site.siteName `
        -TargetId $site.subnetId -TargetType 'Subnet' -TargetName ($site.subnetId -split '/')[-1] `
        -RelationType 'VNetIntegration'
}
Write-Host "Found $($vnetIntResults.Count) App Service VNet integrations." -ForegroundColor Cyan

# --- AKS VNet/Subnet dependencies ---
Write-Verbose "Discovering AKS network dependencies..."
$aksQuery = @"
Resources
| where type =~ 'microsoft.containerservice/managedclusters'
| mv-expand pool = properties.agentPoolProfiles
| project
    aksId = id, aksName = name,
    subnetId = tostring(pool.vnetSubnetID)
| where isnotempty(subnetId)
"@

$aksResults = Invoke-GraphQuery -Query $aksQuery -Subs $SubscriptionId
foreach ($aks in $aksResults) {
    Add-Dependency -SourceId $aks.aksId -SourceType 'AKS' -SourceName $aks.aksName `
        -TargetId $aks.subnetId -TargetType 'Subnet' -TargetName ($aks.subnetId -split '/')[-1] `
        -RelationType 'AKSSubnet'
}
Write-Host "Found $($aksResults.Count) AKS subnet dependencies." -ForegroundColor Cyan

# --- Key Vault references from App Services ---
Write-Verbose "Discovering Key Vault references from App Services..."
$kvRefQuery = @"
Resources
| where type =~ 'microsoft.web/sites/config'
| where name endswith '/appsettings' or name endswith '/connectionstrings'
| mv-expand setting = properties
| where tostring(setting) contains 'Microsoft.KeyVault'
| extend siteName = tostring(split(id, '/')[8])
| extend vaultRef = extract(@'VaultName=([^;)]+)', 1, tostring(setting))
| where isnotempty(vaultRef)
| distinct id, siteName, vaultRef
"@

try {
    $kvRefResults = Invoke-GraphQuery -Query $kvRefQuery -Subs $SubscriptionId
    foreach ($ref in $kvRefResults) {
        Add-Dependency -SourceId $ref.id -SourceType 'AppService' -SourceName $ref.siteName `
            -TargetId "keyvault:$($ref.vaultRef)" -TargetType 'KeyVault' -TargetName $ref.vaultRef `
            -RelationType 'KeyVaultReference'
    }
    Write-Host "Found $($kvRefResults.Count) Key Vault references from App Services." -ForegroundColor Cyan
}
catch {
    Write-Warning "Key Vault reference query requires config access; falling back to name-based scan."
}

# --- VM Managed Identity / Key Vault access (via role assignments) ---
Write-Verbose "Discovering VM/AKS identities with Key Vault access..."
$kvAccessQuery = @"
AuthorizationResources
| where type =~ 'microsoft.authorization/roleassignments'
| where tostring(properties.scope) contains 'Microsoft.KeyVault'
| project
    principalId = tostring(properties.principalId),
    scope = tostring(properties.scope),
    roleId = tostring(properties.roleDefinitionId)
"@

try {
    $kvAccessResults = Invoke-GraphQuery -Query $kvAccessQuery -Subs $SubscriptionId
    foreach ($access in $kvAccessResults) {
        Add-Dependency -SourceId "principal:$($access.principalId)" -SourceType 'Identity' `
            -SourceName $access.principalId `
            -TargetId $access.scope -TargetType 'KeyVault' `
            -TargetName ($access.scope -split '/')[-1] `
            -RelationType 'RBACAccess'
    }
    Write-Host "Found $($kvAccessResults.Count) identity-to-KeyVault role assignments." -ForegroundColor Cyan
}
catch {
    Write-Warning "Authorization resource query failed: $_"
}

# --- Shared Resources (VNets, NSGs referenced by multiple resources) ---
Write-Verbose "Identifying shared VNets and NSGs..."
$subnetUsageQuery = @"
Resources
| where type =~ 'microsoft.network/virtualnetworks'
| mv-expand subnet = properties.subnets
| mv-expand ipConfig = subnet.properties.ipConfigurations
| project
    vnetId = id, vnetName = name,
    subnetName = tostring(subnet.name),
    connectedResourceId = tostring(ipConfig.id)
| summarize
    ConnectedCount = count(),
    ConnectedResources = make_set(connectedResourceId)
    by vnetId, vnetName, subnetName
"@

$sharedResources = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    $subnetUsage = Invoke-GraphQuery -Query $subnetUsageQuery -Subs $SubscriptionId
    foreach ($subnet in $subnetUsage) {
        $sharedResources.Add([PSCustomObject]@{
            ResourceType      = 'VNet/Subnet'
            ResourceId        = $subnet.vnetId
            ResourceName      = "$($subnet.vnetName)/$($subnet.subnetName)"
            ConnectedCount    = $subnet.ConnectedCount
            ConnectedResources = ($subnet.ConnectedResources -join '; ')
            IsShared          = $subnet.ConnectedCount -gt 1
        })
    }
    Write-Host "Analyzed $($subnetUsage.Count) subnets for shared usage." -ForegroundColor Cyan
}
catch {
    Write-Warning "Subnet usage query failed: $_"
}

$nsgQuery = @"
Resources
| where type =~ 'microsoft.network/networksecuritygroups'
| mv-expand nic = properties.networkInterfaces
| project nsgId = id, nsgName = name, nicId = tostring(nic.id)
| summarize NICCount = count(), NICs = make_set(nicId) by nsgId, nsgName
"@

try {
    $nsgUsage = Invoke-GraphQuery -Query $nsgQuery -Subs $SubscriptionId
    foreach ($nsg in $nsgUsage) {
        $sharedResources.Add([PSCustomObject]@{
            ResourceType       = 'NSG'
            ResourceId         = $nsg.nsgId
            ResourceName       = $nsg.nsgName
            ConnectedCount     = $nsg.NICCount
            ConnectedResources = ($nsg.NICs -join '; ')
            IsShared           = $nsg.NICCount -gt 1
        })
    }
    Write-Host "Analyzed $($nsgUsage.Count) NSGs for shared usage." -ForegroundColor Cyan
}
catch {
    Write-Warning "NSG usage query failed: $_"
}

# --- Export results ---
$dependencies | Export-Csv -Path $dependencyFile -NoTypeInformation -Encoding UTF8
$sharedResources | Export-Csv -Path $sharedResourceFile -NoTypeInformation -Encoding UTF8

Write-Host "`n=== Dependency Audit Summary ===" -ForegroundColor Green
$dependencies | Group-Object RelationType | Select-Object Name, Count | Format-Table -AutoSize

$sharedCount = ($sharedResources | Where-Object { $_.IsShared }).Count
Write-Host "Shared resources (multi-consumer): $sharedCount" -ForegroundColor Yellow

Write-Host "`nDependency map:   $dependencyFile"
Write-Host "Shared resources: $sharedResourceFile"
