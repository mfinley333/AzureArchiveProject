<#
.SYNOPSIS
    Master orchestrator for the Azure Infrastructure Archive Project.

.DESCRIPTION
    Executes archive phase scripts in order for the specified phase (1-6).
    Each phase targets a specific aspect of the archival process:
      1 - Discovery: Inventory and tag all resources
      2 - Network Isolation: Isolate NSGs, Traffic Manager, App Gateway
      3 - Soft-Stop Compute: Stop/deallocate VMs, WebApps, Logic Apps
      4 - Data Protection: Backup and tier-down databases, storage
      5 - Monitoring: Set up monitoring for archived resources
      6 - Cleanup: Disable alerts, export dashboards, consolidate Log Analytics

.PARAMETER Phase
    The archive phase to execute (1-6).

.PARAMETER SubscriptionId
    One or more Azure subscription IDs to process. If omitted, subscriptions
    are resolved from the CSV file specified by SubscriptionListPath.

.PARAMETER SubscriptionListPath
    Path to a CSV file containing a SubscriptionName column. Each name is
    resolved to a subscription ID via Get-AzSubscription. Defaults to
    ..\UniqueSubscriptions.csv relative to the script directory.

.PARAMETER WhatIf
    Preview changes without applying them.

.PARAMETER BackupPath
    Path for backup files. Defaults to .\output\backups.

.PARAMETER Validate
    Check current state and list what would be done without executing.

.EXAMPLE
    .\Invoke-ArchivePhase.ps1 -Phase 1 -SubscriptionId "abc-123"

.EXAMPLE
    .\Invoke-ArchivePhase.ps1 -Phase 3 -SubscriptionId "abc-123","def-456" -WhatIf

.EXAMPLE
    .\Invoke-ArchivePhase.ps1 -Phase 2 -SubscriptionId "abc-123" -Validate

.EXAMPLE
    .\Invoke-ArchivePhase.ps1 -Phase 1
    # Uses the default UniqueSubscriptions.csv to resolve subscription IDs.

.EXAMPLE
    .\Invoke-ArchivePhase.ps1 -Phase 4 -SubscriptionListPath ".\MySubscriptions.csv"
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 6)]
    [int]$Phase,

    [Parameter()]
    [string[]]$SubscriptionId,

    [Parameter()]
    [string]$SubscriptionListPath = (Join-Path $PSScriptRoot '..\UniqueSubscriptions.csv'),

    [string]$BackupPath = ".\output\backups",

    [switch]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Phase Mapping
$PhaseMap = @{
    1 = 'phase1-discovery'
    2 = 'phase2-network-isolation'
    3 = 'phase3-soft-stop-compute'
    4 = 'phase4-data-protection'
    5 = 'phase5-monitoring'
    6 = 'phase6-cleanup'
}
#endregion

#region Helper Functions
function Import-SubscriptionList {
    <#
    .SYNOPSIS
        Resolves subscription names from a CSV file to subscription IDs.
    #>
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

function Test-Prerequisites {
    <#
    .SYNOPSIS
        Validates that all required Az modules and Azure context are available.
    #>
    [CmdletBinding()]
    param(
        [string[]]$SubscriptionId
    )

    $requiredModules = @(
        'Az.Accounts',
        'Az.Resources',
        'Az.Monitor',
        'Az.Network',
        'Az.Compute',
        'Az.Sql',
        'Az.OperationalInsights',
        'Az.Websites'
    )

    Write-Verbose "Checking required Az modules..."
    $missing = @()
    foreach ($mod in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $mod)) {
            $missing += $mod
        }
    }
    if ($missing.Count -gt 0) {
        throw "Missing required modules: $($missing -join ', '). Install with: Install-Module $($missing -join ', ')"
    }
    Write-Verbose "All required modules are installed."

    Write-Verbose "Checking Azure context..."
    $context = Get-AzContext
    if (-not $context) {
        throw "No Azure context found. Run Connect-AzAccount first."
    }
    Write-Verbose "Azure context: $($context.Account.Id) / $($context.Subscription.Name)"

    Write-Verbose "Checking subscription access..."
    foreach ($subId in $SubscriptionId) {
        try {
            $null = Set-AzContext -SubscriptionId $subId -ErrorAction Stop
            Write-Verbose "Access confirmed for subscription: $subId"
        }
        catch {
            throw "Cannot access subscription '$subId'. Verify permissions. Error: $_"
        }
    }
}
#endregion

#region Main Execution
# Resolve subscriptions from CSV if not explicitly provided
if (-not $SubscriptionId) {
    if ($SubscriptionListPath -and (Test-Path $SubscriptionListPath)) {
        Write-Verbose "Resolving subscriptions from $SubscriptionListPath"
        $SubscriptionId = Import-SubscriptionList -Path $SubscriptionListPath
    }
    else {
        throw "No subscriptions specified. Provide -SubscriptionId or ensure '$SubscriptionListPath' exists."
    }
}

$phaseStart = Get-Date
$phaseFolderName = $PhaseMap[$Phase]
$scriptRoot = $PSScriptRoot
$phaseFolder = Join-Path $scriptRoot $phaseFolderName

Write-Verbose "=== Azure Archive Project - Phase $Phase ($phaseFolderName) ==="
Write-Verbose "Started at: $phaseStart"
Write-Verbose "Subscriptions: $($SubscriptionId -join ', ')"
Write-Verbose "BackupPath: $BackupPath"
Write-Verbose "WhatIf: $WhatIfPreference"

# Create output directories
$outputDirs = @(
    (Join-Path $scriptRoot '..\output\backups'),
    (Join-Path $scriptRoot '..\output\reports'),
    (Join-Path $scriptRoot '..\output\logs')
)
foreach ($dir in $outputDirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Verbose "Created directory: $dir"
    }
}

# Validate prerequisites
try {
    Test-Prerequisites -SubscriptionId $SubscriptionId
}
catch {
    Write-Error "Prerequisite check failed: $_"
    return
}

# Validate phase folder exists
if (-not (Test-Path $phaseFolder)) {
    Write-Error "Phase folder not found: $phaseFolder"
    return
}

# Get phase scripts
$phaseScripts = Get-ChildItem -Path $phaseFolder -Filter '*.ps1' | Sort-Object Name
if ($phaseScripts.Count -eq 0) {
    Write-Warning "No scripts found in $phaseFolder"
    return
}

Write-Verbose "Found $($phaseScripts.Count) script(s) in $phaseFolderName"

# Validate mode - list what would be done and exit
if ($Validate) {
    Write-Host "`n=== Validation Mode - Phase $Phase ($phaseFolderName) ===" -ForegroundColor Cyan
    Write-Host "Scripts to execute:" -ForegroundColor Yellow
    foreach ($script in $phaseScripts) {
        Write-Host "  - $($script.Name)"
    }

    Write-Host "`nSubscriptions to process:" -ForegroundColor Yellow
    foreach ($subId in $SubscriptionId) {
        Set-AzContext -SubscriptionId $subId -ErrorAction SilentlyContinue | Out-Null
        $resources = Get-AzResource -ErrorAction SilentlyContinue
        Write-Host "  - $subId : $($resources.Count) resources"
    }

    Write-Host "`nBackup path: $BackupPath" -ForegroundColor Yellow
    Write-Host "WhatIf mode: $WhatIfPreference" -ForegroundColor Yellow
    Write-Host "Validation complete. No changes were made.`n" -ForegroundColor Green
    return
}

# Execute phase scripts
$results = @()
$successCount = 0
$failCount = 0

foreach ($script in $phaseScripts) {
    $scriptStart = Get-Date
    $scriptPath = $script.FullName
    $scriptName = $script.Name

    Write-Verbose "--- Executing: $scriptName ---"

    $result = [PSCustomObject]@{
        ScriptName = $scriptName
        Status     = 'Unknown'
        StartTime  = $scriptStart.ToString('o')
        EndTime    = $null
        Duration   = $null
        Error      = $null
    }

    try {
        if ($PSCmdlet.ShouldProcess($scriptName, "Execute archive script")) {
            $scriptParams = @{
                SubscriptionId = $SubscriptionId
                BackupPath     = $BackupPath
            }
            if ($WhatIfPreference) {
                $scriptParams['WhatIf'] = $true
            }

            & $scriptPath @scriptParams
        }

        $result.Status = 'Success'
        $successCount++
        Write-Verbose "Completed: $scriptName (Success)"
    }
    catch {
        $result.Status = 'Failed'
        $result.Error = $_.Exception.Message
        $failCount++
        Write-Warning "Failed: $scriptName - $($_.Exception.Message)"
    }
    finally {
        $scriptEnd = Get-Date
        $result.EndTime = $scriptEnd.ToString('o')
        $result.Duration = ($scriptEnd - $scriptStart).ToString()
        $results += $result
    }
}

# Generate summary report
$phaseEnd = Get-Date
$timestamp = $phaseEnd.ToString('yyyyMMdd-HHmmss')
$reportDir = Join-Path $scriptRoot '..\output\reports'
$reportPath = Join-Path $reportDir "phase$Phase-summary-$timestamp.json"

$summary = [PSCustomObject]@{
    Phase        = $Phase
    PhaseName    = $phaseFolderName
    StartTime    = $phaseStart.ToString('o')
    EndTime      = $phaseEnd.ToString('o')
    Duration     = ($phaseEnd - $phaseStart).ToString()
    WhatIfMode   = [bool]$WhatIfPreference
    Subscriptions = $SubscriptionId
    ScriptsRun   = $results
    SuccessCount = $successCount
    FailCount    = $failCount
    TotalScripts = $phaseScripts.Count
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding UTF8
Write-Verbose "Summary report written to: $reportPath"

Write-Host "`n=== Phase $Phase Complete ===" -ForegroundColor Cyan
Write-Host "Duration: $($summary.Duration)"
Write-Host "Scripts: $($summary.TotalScripts) total, $successCount succeeded, $failCount failed"
Write-Host "Report: $reportPath`n"

if ($failCount -gt 0) {
    Write-Warning "$failCount script(s) failed. Review the summary report for details."
}
#endregion
