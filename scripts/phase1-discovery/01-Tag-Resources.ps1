#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Tags Azure resources for the Legacy Archive project.

.DESCRIPTION
    Finds all resources in specified subscriptions (optionally filtered by resource group pattern)
    and applies archive-tracking tags. Supports -WhatIf for dry runs. Logs results to CSV.

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process.

.PARAMETER TagSet
    Hashtable of tags to apply. Defaults to ArchiveProject=ArchiveLegacy, ArchivePhase=Discovery,
    ArchiveDate=<today>.

.PARAMETER ResourceGroupFilter
    Optional wildcard pattern to filter resource groups (e.g., 'rg-legacy-*').

.PARAMETER WhatIf
    Perform a dry run without applying any tags.

.PARAMETER OutputPath
    Directory for the results CSV. Defaults to c:\dev\AzureArchiveProject\output\inventory.

.EXAMPLE
    .\01-Tag-Resources.ps1 -SubscriptionId 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' -WhatIf

.EXAMPLE
    .\01-Tag-Resources.ps1 -SubscriptionId @('sub1','sub2') -ResourceGroupFilter 'rg-legacy-*'
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SubscriptionId,

    [hashtable]$TagSet = @{
        ArchiveProject = 'ArchiveLegacy'
        ArchivePhase   = 'Discovery'
        ArchiveDate    = (Get-Date -Format 'yyyy-MM-dd')
    },

    [string]$ResourceGroupFilter,

    [string]$OutputPath = 'c:\dev\AzureArchiveProject\output\inventory'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $OutputPath "tagging-results-$timestamp.csv"
$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($subId in $SubscriptionId) {
    Write-Verbose "Setting subscription context to $subId"
    try {
        Set-AzContext -SubscriptionId $subId -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Failed to set context for subscription $subId : $_"
        continue
    }

    $queryParams = @{ ErrorAction = 'Stop' }
    if ($ResourceGroupFilter) {
        $resourceGroups = Get-AzResourceGroup @queryParams |
            Where-Object { $_.ResourceGroupName -like $ResourceGroupFilter }
        $resources = $resourceGroups | ForEach-Object {
            Get-AzResource -ResourceGroupName $_.ResourceGroupName @queryParams
        }
        Write-Verbose "Filtered to $($resources.Count) resources matching RG pattern '$ResourceGroupFilter'"
    }
    else {
        $resources = Get-AzResource @queryParams
        Write-Verbose "Found $($resources.Count) resources in subscription $subId"
    }

    foreach ($resource in $resources) {
        $status = 'Success'
        $errorMessage = ''

        try {
            $mergedTags = @{}
            if ($resource.Tags) {
                $resource.Tags.GetEnumerator() | ForEach-Object { $mergedTags[$_.Key] = $_.Value }
            }
            $TagSet.GetEnumerator() | ForEach-Object { $mergedTags[$_.Key] = $_.Value }

            if ($PSCmdlet.ShouldProcess($resource.ResourceId, "Apply tags: $($TagSet.Keys -join ', ')")) {
                Set-AzResource -ResourceId $resource.ResourceId -Tag $mergedTags -Force -ErrorAction Stop | Out-Null
            }
            else {
                $status = 'WhatIf'
            }
        }
        catch {
            $status = 'Failed'
            $errorMessage = $_.Exception.Message
            Write-Warning "Failed to tag $($resource.ResourceId): $errorMessage"
        }

        $results.Add([PSCustomObject]@{
            SubscriptionId = $subId
            ResourceGroup  = $resource.ResourceGroupName
            ResourceType   = $resource.ResourceType
            ResourceName   = $resource.Name
            ResourceId     = $resource.ResourceId
            Status         = $status
            Error          = $errorMessage
            Timestamp      = Get-Date -Format 'o'
        })
    }
}

$results | Export-Csv -Path $logFile -NoTypeInformation -Encoding UTF8
Write-Host "Tagging complete. Results logged to $logFile" -ForegroundColor Green

$summary = $results | Group-Object Status | Select-Object Name, Count
$summary | Format-Table -AutoSize
Write-Host "Total resources processed: $($results.Count)"
