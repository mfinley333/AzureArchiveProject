<#
.SYNOPSIS
    Protects Azure Key Vaults tagged for the Legacy decommission.
.DESCRIPTION
    For each Key Vault tagged ArchiveProject=ArchiveLegacy:
      - Enables soft-delete if not already
      - Enables purge protection
      - Exports secret/key/certificate names (NOT values) to inventory CSV
      - Removes all access policies except cloud engineering team
      - Sets read-only access via RBAC for the engineering team
.PARAMETER SubscriptionId
    Target Azure subscription ID.
.PARAMETER CloudEngTeamObjectId
    Azure AD Object ID of the cloud engineering team group to retain access.
.PARAMETER ArchiveStorageAccountName
    Storage account for inventory exports.
.PARAMETER ArchiveContainerName
    Container for Key Vault inventory.
.EXAMPLE
    .\06-Protect-KeyVaults.ps1 -SubscriptionId "xxxx" -CloudEngTeamObjectId "guid" -ArchiveStorageAccountName "azurearchive"
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
    [string]$CloudEngTeamObjectId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ArchiveStorageAccountName,

    [Parameter()]
    [string]$ArchiveContainerName = "keyvault-inventory",

    [Parameter()]
    [string]$TagName = "ArchiveProject",

    [Parameter()]
    [string]$TagValue = "ArchiveLegacy",

    [Parameter()]
    [string]$LogPath = ".\logs\phase4-keyvault-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
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

    $keyVaults = Get-AzKeyVault | Where-Object { $_.Tags[$TagName] -eq $TagValue }
    Write-Log "Found $($keyVaults.Count) Key Vaults tagged $TagName=$TagValue"

    $summary = [System.Collections.Generic.List[PSObject]]::new()

    foreach ($kv in $keyVaults) {
        $kvName = $kv.VaultName
        $kvRg = $kv.ResourceGroupName
        Write-Log "Processing Key Vault: $kvName (RG: $kvRg)"

        try {
            $vault = Get-AzKeyVault -VaultName $kvName -ResourceGroupName $kvRg

            # 1. Enable soft-delete
            if (-not $vault.EnableSoftDelete) {
                if ($PSCmdlet.ShouldProcess($kvName, "Enable soft-delete")) {
                    Update-AzKeyVault -VaultName $kvName -ResourceGroupName $kvRg -EnableSoftDelete $true
                    Write-Log "  Enabled soft-delete on $kvName"
                }
            }
            else {
                Write-Log "  Soft-delete already enabled on $kvName"
            }

            # 2. Enable purge protection
            if (-not $vault.EnablePurgeProtection) {
                if ($PSCmdlet.ShouldProcess($kvName, "Enable purge protection")) {
                    Update-AzKeyVault -VaultName $kvName -ResourceGroupName $kvRg -EnablePurgeProtection $true
                    Write-Log "  Enabled purge protection on $kvName"
                }
            }
            else {
                Write-Log "  Purge protection already enabled on $kvName"
            }

            # 3. Export inventory (names only, NOT values)
            $inventory = [System.Collections.Generic.List[PSObject]]::new()

            $secrets = Get-AzKeyVaultSecret -VaultName $kvName
            foreach ($s in $secrets) {
                $inventory.Add([PSCustomObject]@{
                    VaultName    = $kvName
                    ItemType     = "Secret"
                    Name         = $s.Name
                    Enabled      = $s.Enabled
                    Created      = $s.Created
                    Updated      = $s.Updated
                    Expires      = $s.Expires
                    ContentType  = $s.ContentType
                })
            }

            $keys = Get-AzKeyVaultKey -VaultName $kvName
            foreach ($k in $keys) {
                $inventory.Add([PSCustomObject]@{
                    VaultName    = $kvName
                    ItemType     = "Key"
                    Name         = $k.Name
                    Enabled      = $k.Enabled
                    Created      = $k.Created
                    Updated      = $k.Updated
                    Expires      = $k.Expires
                    ContentType  = $k.KeyType
                })
            }

            $certs = Get-AzKeyVaultCertificate -VaultName $kvName
            foreach ($c in $certs) {
                $inventory.Add([PSCustomObject]@{
                    VaultName    = $kvName
                    ItemType     = "Certificate"
                    Name         = $c.Name
                    Enabled      = $c.Enabled
                    Created      = $c.Created
                    Updated      = $c.Updated
                    Expires      = $c.Expires
                    ContentType  = $c.CertificateType
                })
            }

            $csvBlobName = "$kvName-inventory-$(Get-Date -Format 'yyyyMMdd').csv"
            $csvTemp = Join-Path $env:TEMP $csvBlobName
            $inventory | Export-Csv -Path $csvTemp -NoTypeInformation
            Set-AzStorageBlobContent -File $csvTemp -Container $ArchiveContainerName -Blob $csvBlobName -Context $archiveCtx -Force | Out-Null
            Remove-Item $csvTemp -Force
            Write-Log "  Exported inventory for $kvName ($($inventory.Count) items: $($secrets.Count) secrets, $($keys.Count) keys, $($certs.Count) certs)"

            # 4. Remove all access policies except cloud engineering team
            if ($PSCmdlet.ShouldProcess($kvName, "Remove non-engineering access policies")) {
                $policiesToRemove = $vault.AccessPolicies | Where-Object { $_.ObjectId -ne $CloudEngTeamObjectId }
                foreach ($policy in $policiesToRemove) {
                    Remove-AzKeyVaultAccessPolicy -VaultName $kvName -ResourceGroupName $kvRg -ObjectId $policy.ObjectId
                    Write-Log "  Removed access policy for ObjectId $($policy.ObjectId)"
                }

                # Ensure engineering team has read-only access policy
                $engPolicy = $vault.AccessPolicies | Where-Object { $_.ObjectId -eq $CloudEngTeamObjectId }
                if (-not $engPolicy) {
                    Set-AzKeyVaultAccessPolicy -VaultName $kvName -ResourceGroupName $kvRg `
                        -ObjectId $CloudEngTeamObjectId `
                        -PermissionsToSecrets Get,List `
                        -PermissionsToKeys Get,List `
                        -PermissionsToCertificates Get,List
                    Write-Log "  Added read-only access policy for cloud engineering team"
                }
            }

            # 5. Set read-only via RBAC (Key Vault Reader role)
            if ($PSCmdlet.ShouldProcess($kvName, "Assign Key Vault Reader RBAC role")) {
                $scope = $vault.ResourceId
                $existing = Get-AzRoleAssignment -ObjectId $CloudEngTeamObjectId -Scope $scope -RoleDefinitionName "Key Vault Reader" -ErrorAction SilentlyContinue
                if (-not $existing) {
                    New-AzRoleAssignment -ObjectId $CloudEngTeamObjectId -Scope $scope -RoleDefinitionName "Key Vault Reader"
                    Write-Log "  Assigned Key Vault Reader role to engineering team on $kvName"
                }
                else {
                    Write-Log "  Key Vault Reader role already assigned on $kvName"
                }
            }

            $summary.Add([PSCustomObject]@{
                KeyVault        = $kvName
                ResourceGroup   = $kvRg
                Items           = $inventory.Count
                PoliciesRemoved = ($policiesToRemove | Measure-Object).Count
                Status          = "Success"
            })
        }
        catch {
            Write-Log "ERROR on ${kvName}: $_" -Level "ERROR"
            $summary.Add([PSCustomObject]@{
                KeyVault        = $kvName
                ResourceGroup   = $kvRg
                Items           = 0
                PoliciesRemoved = 0
                Status          = "Failed: $_"
            })
        }
    }

    Write-Log "=== Key Vault Protection Summary ==="
    $summary | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Log $_ }
    Write-Log "Total: $($summary.Count), Succeeded: $(($summary | Where-Object Status -eq 'Success').Count), Failed: $(($summary | Where-Object Status -ne 'Success').Count)"
}
catch {
    Write-Log "FATAL: $_" -Level "ERROR"
    throw
}
} # end foreach
