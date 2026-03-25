# Legacy Azure Infrastructure Archive Project

Systematic archival of legacy Azure infrastructure , reducing costs while preserving the ability to restore resources when needed.

## Phases Overview

| Phase | Name | Description |
|-------|------|-------------|
| 1 | **Discovery** | Inventory and tag all resources across target subscriptions |
| 2 | **Network Isolation** | Isolate network resources — NSGs, Traffic Manager profiles, Application Gateways |
| 3 | **Soft-Stop Compute** | Stop/deallocate VMs, stop WebApps, disable Logic Apps |
| 4 | **Data Protection** | Backup and tier-down databases and storage accounts |
| 5 | **Monitoring** | Set up lightweight monitoring for archived resources |
| 6 | **Cleanup** | Disable legacy alerts, export dashboards, consolidate Log Analytics workspaces, remove unused action groups |

## Resource Counts

| Resource Type | Count |
|---------------|-------|
| Metric Alerts | 610 |
| Scheduled Query Rules | 2,401 |
| Smart Detector Alert Rules | 164 |
| Activity Log Alerts | 41 |
| Dashboards | 700 |
| Log Analytics Workspaces | 91 |
| Action Groups | 879 |

## Directory Structure

```
AzureArchiveProject/
├── bicep/                              # Bicep templates for infrastructure
├── scripts/
│   ├── phase1-discovery/               # Phase 1 scripts — resource inventory & tagging
│   ├── phase2-network-isolation/       # Phase 2 scripts — NSG, TM, AppGW isolation
│   ├── phase3-soft-stop-compute/       # Phase 3 scripts — VM, WebApp, Logic App shutdown
│   ├── phase4-data-protection/         # Phase 4 scripts — database & storage tiering
│   ├── phase5-monitoring/              # Phase 5 scripts — monitoring setup
│   ├── phase6-cleanup/                 # Phase 6 scripts — alerts, dashboards, Log Analytics
│   ├── Invoke-ArchivePhase.ps1         # Master orchestrator — runs all scripts for a phase
│   └── Restore-ArchivedResource.ps1    # Rollback utility — restores a resource from backup
├── terraform/                          # Terraform configurations
├── output/
│   ├── backups/                        # JSON backups of resource state before changes
│   ├── reports/                        # Phase execution summary reports
│   └── logs/                           # Execution and restore logs
├── AzureResourcesToBeArchived.xlsx
└── README.md
```

## Prerequisites

- **PowerShell 7+**
- **Az PowerShell Modules:**
  - `Az.Accounts`
  - `Az.Resources`
  - `Az.Monitor`
  - `Az.Network`
  - `Az.Compute`
  - `Az.Sql`
  - `Az.OperationalInsights`
  - `Az.Websites`
- **Terraform** >= 1.0
- **Bicep CLI**
- **Azure subscription access** with **Contributor** role (or equivalent)

Install all required Az modules:

```powershell
Install-Module Az.Accounts, Az.Resources, Az.Monitor, Az.Network, Az.Compute, Az.Sql, Az.OperationalInsights, Az.Websites -Scope CurrentUser -Force
```

## Usage

### Running a Phase

```powershell
# Always preview first with -WhatIf
.\scripts\Invoke-ArchivePhase.ps1 -Phase 1 -SubscriptionId "your-sub-id" -WhatIf

# Validate current state without making changes
.\scripts\Invoke-ArchivePhase.ps1 -Phase 1 -SubscriptionId "your-sub-id" -Validate

# Execute the phase
.\scripts\Invoke-ArchivePhase.ps1 -Phase 1 -SubscriptionId "your-sub-id"

# Multiple subscriptions
.\scripts\Invoke-ArchivePhase.ps1 -Phase 3 -SubscriptionId "sub-1","sub-2","sub-3"

# Custom backup path
.\scripts\Invoke-ArchivePhase.ps1 -Phase 4 -SubscriptionId "your-sub-id" -BackupPath "D:\backups"
```

### Restoring a Resource

```powershell
# Restore a VM to its previous running state
.\scripts\Restore-ArchivedResource.ps1 -ResourceType VM -ResourceName "web-server-01" `
    -BackupPath ".\output\backups" -ResourceGroupName "rg-prod" -SubscriptionId "your-sub-id"

# Restore NSG rules
.\scripts\Restore-ArchivedResource.ps1 -ResourceType NSG -ResourceName "nsg-frontend" `
    -BackupPath ".\output\backups" -ResourceGroupName "rg-network"

# Restore a SQL database tier
.\scripts\Restore-ArchivedResource.ps1 -ResourceType SQL -ResourceName "sqldb-legacy" `
    -BackupPath ".\output\backups" -ResourceGroupName "rg-data"

# Re-enable an alert rule
.\scripts\Restore-ArchivedResource.ps1 -ResourceType Alert -ResourceName "high-cpu-alert" `
    -BackupPath ".\output\backups" -ResourceGroupName "rg-monitoring"

# Recreate a dashboard
.\scripts\Restore-ArchivedResource.ps1 -ResourceType Dashboard -ResourceName "ops-dashboard" `
    -BackupPath ".\output\backups" -ResourceGroupName "rg-monitoring"
```

## Important Notes

> **⚠️ Always run with `-WhatIf` first** to preview changes before executing any phase.

- **Backups are created automatically** — each phase script saves resource state to `output\backups\` before making changes.
- **Validation mode** (`-Validate`) checks current state and resource counts without making any changes.
- **Production systems warning** — verify that target resources are confirmed legacy before archiving. Review the resource inventory in `AzureResourcesToBeArchived.xlsx`.
- **Phase execution is sequential** — scripts within each phase run in alphabetical order. If a script fails, the orchestrator logs the error and continues to the next script.
- **Summary reports** are generated after each phase run in `output\reports\`.
- **Restore is per-resource** — use `Restore-ArchivedResource.ps1` to roll back individual resources using their backup files.
