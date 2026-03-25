# Swigert — Project History

## Project Context
- **Project:** ChubbArchiveProject — Azure resource archival automation
- **Stack:** PowerShell, Bicep, Terraform, Azure CLI
- **User:** Mike Finley
- **Description:** Multi-phase Azure resource archive pipeline (6 phases: discovery, network isolation, compute shutdown, data protection, monitoring, cleanup). Orchestrator + child scripts + IaC templates.

## Learnings

### 2025 — Full Cross-Reference Validation Audit

**Architecture Pattern:** Orchestrator (`Invoke-ArchivePhase.ps1`) dynamically discovers child scripts via `Get-ChildItem` on phase folders sorted by name prefix (01-, 02-, etc.). It splats only `SubscriptionId`, `BackupPath`, and `WhatIf` to ALL child scripts uniformly — no per-phase parameter customization.

**Critical Finding — Phase 4 Broken:** All 7 Phase 4 (data-protection) scripts have Mandatory parameters (`ArchiveStorageAccountName`, `SqlAdminLogin`, `SqlAdminPassword`, `PgAdminUser`, `PgAdminPassword`, `CloudEngTeamObjectId`) that the orchestrator never passes. Phase 4 execution via orchestrator will always fail with missing mandatory parameter errors.

**Phase 5 Folder Mismatch:** Orchestrator maps Phase 5 to `phase5-monitoring` but the actual folder is `phase5-monitoring-seeBicepTerraform`. The orchestrator would fail with "Phase folder not found" for Phase 5.

**Hardcoded Paths:** All 4 Phase 1 scripts default `OutputPath` to `c:\dev\AzureArchiveProject\output\inventory` — wrong project name (should be `ChubbArchiveProject` or use relative `$PSScriptRoot`-based paths).

**Tag Consistency:** `ArchiveProject=ArchiveLegacy` is consistent across all scripts, Bicep, and Terraform. Bicep parameterizes the value; Terraform hardcodes it in policy rules but parameterizes it in variables.tf defaults.

**IaC Module References:** Both Bicep and Terraform module references are correct and point to existing files/directories.

**No hardcoded subscription/tenant IDs found** — good parameterization practice throughout.
