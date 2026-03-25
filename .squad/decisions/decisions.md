# Decisions & Findings Registry

## Overview
This document consolidates all audit findings, recommendations, and decisions for the Chubb Archive Project. Findings are merged from individual agent reports and deduplicated by category.

**Last Updated:** 2026-03-25  
**Status:** Initial audit findings from Haise (Tester) & Swigert (Validator)

---

## 🔴 CRITICAL ISSUES (Must Fix)

### E1. Phase 5 Folder Name Mismatch — Orchestrator Will Fail
**Source:** Swigert Validation (E1)  
**Severity:** Critical — Runtime failure  
**Description:** Orchestrator maps Phase 5 to `phase5-monitoring` but actual folder is `phase5-monitoring-seeBicepTerraform`. Running `Invoke-ArchivePhase.ps1 -Phase 5` will error with "Phase folder not found."

**Fix:** Update `Invoke-ArchivePhase.ps1` line 78 from `5 = 'phase5-monitoring'` to `5 = 'phase5-monitoring-seeBicepTerraform'` (or rename the folder).

**Impacted:** `Invoke-ArchivePhase.ps1`

---

### E2. Phase 4 — Orchestrator Cannot Invoke Any Child Script
**Source:** Swigert Validation (E2)  
**Severity:** Critical — Runtime failure  
**Description:** All 7 Phase 4 scripts require Mandatory parameters the orchestrator never passes:
- `ArchiveStorageAccountName` (all 7 scripts)
- `SqlAdminLogin` + `SqlAdminPassword` (02-Archive-SQLDatabases.ps1)
- `PgAdminUser` + `PgAdminPassword` (04-Archive-PostgreSQL.ps1)
- `CloudEngTeamObjectId` (06-Protect-KeyVaults.ps1)

Running `Invoke-ArchivePhase.ps1 -Phase 4` will always fail with mandatory parameter errors.

**Fix:** Either:
1. Add these parameters to the orchestrator with per-phase splatting logic, OR
2. Remove the `Mandatory` attribute and add validation logic inside the scripts.

**Impacted:** All 7 Phase 4 scripts (01-07)

---

### E3. Hardcoded Wrong Project Path in Phase 1 Scripts
**Source:** Swigert Validation (E3)  
**Severity:** Critical — Silent data loss  
**Description:** All 4 Phase 1 scripts default `OutputPath` to `c:\dev\AzureArchiveProject\output\inventory` — this is a different project name than `ChubbArchiveProject`. Inventory output will go to the wrong location.

**Affected files:**
- `scripts/phase1-discovery/01-Tag-Resources.ps1` (line 48)
- `scripts/phase1-discovery/02-Export-ResourceInventory.ps1` (line 28)
- `scripts/phase1-discovery/03-Capture-TrafficBaseline.ps1` (line 34)
- `scripts/phase1-discovery/04-Audit-Dependencies.ps1` (line 31)

**Fix:** Use `$PSScriptRoot`-relative paths: `Join-Path $PSScriptRoot '..\..\output\inventory'`

---

## 🟡 WARNINGS (Should Fix)

### W1. Missing `#Requires -Modules` (23 scripts)
**Source:** Haise Test (W1)  
**Severity:** High — Unclear failure modes  
**Description:** Only Phase 1 scripts (01-04) have `#Requires -Modules`. All Phase 2, 3, 4, and 6 scripts are missing this. If Az modules aren't installed, scripts fail with cryptic errors.

**Affected:** All scripts in phase2/, phase3/, phase4/, phase6/, plus Invoke-ArchivePhase.ps1 and Restore-ArchivedResource.ps1

**Recommendation:** Add `#Requires -Modules Az.Accounts, Az.Compute, Az.Storage, Az.Sql` (etc.) to each script based on which Az modules it imports.

---

### W2. Missing `SubscriptionListPath` Parameter (12 scripts)
**Source:** Haise Test (W2)  
**Severity:** Medium — Consistency  
**Description:** Phase 1 (all 4) and Phase 6 (all 4) scripts don't support `-SubscriptionListPath` for CSV import. Phases 2–4 and orchestrator all support this parameter, creating an inconsistency. Users must manually pass subscription arrays to these scripts.

**Affected:** phase1-discovery/01-04, phase6-cleanup/01-04

**Recommendation:** Add `-SubscriptionListPath` parameter to Phase 1 and 6 scripts for consistency.

---

### W3. Missing `SupportsShouldProcess` (4 scripts)
**Source:** Haise Test (W3)  
**Severity:** Low (mostly read-only)  
**Description:** These scripts use `[CmdletBinding()]` without `SupportsShouldProcess`:
- phase1-discovery/02-Export-ResourceInventory.ps1 (read-only — export) ✅ acceptable
- phase1-discovery/03-Capture-TrafficBaseline.ps1 (read-only — query) ✅ acceptable
- phase1-discovery/04-Audit-Dependencies.ps1 (read-only — query) ✅ acceptable
- phase6-cleanup/03-Consolidate-LogAnalytics.ps1 (writes output/consolidation plan) ⚠️ consider WhatIf

**Recommendation:** Add `SupportsShouldProcess` to 03-Consolidate-LogAnalytics.ps1 if it will ever perform actual workspace merges.

---

### W4. Restore Script Uses Scalar `$SubscriptionId`
**Source:** Haise Test (W4)  
**Severity:** Low — Intentional pattern break  
**Description:** `Restore-ArchivedResource.ps1` uses scalar `[string]$SubscriptionId` while all other 26 scripts use `[string[]]$SubscriptionId` (array). This is likely intentional (restoring a single resource), but breaks the pattern and could confuse automation.

**Recommendation:** Document the intentional scalar design in script comments.

---

### W5. Orchestrator Splats Only 3 Params — Many Child Params Ignored
**Source:** Swigert Validation (W4)  
**Severity:** Medium — Loss of control  
**Description:** Orchestrator uniformly splats only `SubscriptionId`, `BackupPath`, `WhatIf` to every child script. Many scripts accept additional optional parameters that can only be controlled when calling scripts directly:
- Phase 1: `OutputPath`, `TagSet`, `ResourceGroupFilter`, `LookbackDays`
- Phase 2: `ResourceGroupFilter`, `ExcludeNsgNames`
- Phase 3: `TagName`, `TagValue`, `ThrottleLimit`, `SubscriptionListPath`
- Phase 6: `BatchSize`, `ThrottleDelaySeconds`, `OutputPath`, `Tag`

**Impact:** Not a runtime failure (defaults exist), but users lose fine-grained control via orchestrator.

**Recommendation:** Document which parameters can be customized (direct script invocation only) vs. orchestrator control in README.

---

### W6. Phase 1 Scripts Use `OutputPath`, Orchestrator Passes `BackupPath`
**Source:** Swigert Validation (W5)  
**Severity:** High — Silent parameter loss  
**Description:** Phase 1 scripts accept `OutputPath` (not `BackupPath`). The orchestrator splats `BackupPath` — this param is silently ignored by Phase 1 scripts, so output goes to the hardcoded (wrong) default path.

**Impact:** Combined with E3, Phase 1 output goes to hardcoded wrong location and orchestrator `BackupPath` is ignored.

**Fix:** Either rename Phase 1 parameter to `BackupPath` or have orchestrator splat `OutputPath` for Phase 1 specifically.

---

### W7. Inconsistent `BackupPath` Defaults Across Scripts
**Source:** Swigert Validation (W6)  
**Severity:** Medium — Deployment confusion  
**Description:** Different scripts use different default paths:
- Phase 2: `..\..\output\backups\{type}` (relative to script)
- Phase 3: `.\backups\phase3\{type}` (relative to CWD)
- Phase 6: `.\output\backups\{type}` (relative to CWD)

These will create backup files in different locations depending on where you run from.

**Recommendation:** Use `$PSScriptRoot`-relative paths consistently across all phases.

---

### W8. Terraform `archive-policy` Hardcodes Tag Values in Policy Rules
**Source:** Swigert Validation (W7)  
**Severity:** Medium — Future-proofing  
**Description:** `terraform/modules/archive-policy/main.tf` hardcodes `ArchiveProject = "ArchiveLegacy"` directly in policy rule JSON. The `tags` variable is accepted but only applied as resource tags, not used in policy logic. If the tag value ever changes, Terraform policies won't match.

**Recommendation:** Parameterize the tag value in policy rules or document that policy rules and script tags must be manually synchronized.

---

### W9. Terraform `subscription_ids` Variable Declared But Unused
**Source:** Swigert Validation (W8)  
**Severity:** Low — Code cleanliness  
**Description:** `terraform/modules/archive-policy/variables.tf` defines `subscription_ids` but `main.tf` uses `data.azurerm_subscription.current` instead.

**Recommendation:** Either use the variable or remove it.

---

### W10. README Missing Phase 5 Folder Name Detail
**Source:** Swigert Validation (W9)  
**Severity:** Low — Documentation  
**Description:** README describes Phase 5 as "Monitoring" via IaC but doesn't mention the actual folder is `phase5-monitoring-seeBicepTerraform` (an empty placeholder folder).

**Recommendation:** Update README to clarify Phase 5 folder name and status (placeholder).

---

### W11. .gitignore Excludes Tracked Data Files
**Source:** Swigert Validation (W10)  
**Severity:** Low — Future-proofing  
**Description:** `.gitignore` excludes `*.xlsx` and `*.csv`, but `UniqueSubscriptions.csv` and `AzureResourcesToBeArchived.xlsx` are tracked in git. This works because they were added before the gitignore rule, but new data files won't be tracked.

**Recommendation:** Use explicit inclusions: `!UniqueSubscriptions.csv` and `!AzureResourcesToBeArchived.xlsx` in .gitignore.

---

## ✅ CONFIRMATIONS (Looks Good)

### Code Quality
- ✅ **Zero syntax errors** across all 27 scripts (Haise)
- ✅ All 27 scripts have `[CmdletBinding()]` attribute
- ✅ All 27 scripts have `try/catch` error handling around Azure operations
- ✅ All 27 scripts set `$ErrorActionPreference`
- ✅ All 27 scripts have `.SYNOPSIS` documentation
- ✅ All 27 scripts use `Test-Path`/`New-Item` for output directory creation
- ✅ No hardcoded GUIDs, subscription IDs, or tenant IDs
- ✅ No bare catch blocks — all catch blocks have error handling/logging
- ✅ 26/27 scripts use `[string[]]$SubscriptionId` (array pattern)
- ✅ 23/27 scripts support WhatIf via `SupportsShouldProcess` (4 exceptions are read-only)
- ✅ Consistent logging patterns across all scripts
- ✅ Backup paths are configurable (not hardcoded) — except Phase 1

### Security & Credentials
- ✅ No hardcoded secrets, passwords, or credentials
- ✅ No hardcoded subscription IDs or tenant IDs
- ✅ No plain-text credential handling (all use managed identity concepts)

### IaC & Infrastructure
- ✅ Tag `ArchiveProject=ArchiveLegacy` consistent across all scripts
- ✅ Bicep module references (`../modules/*.bicep`) resolve correctly
- ✅ Terraform module sources (`../modules/*`) resolve correctly
- ✅ Provider version `~> 4.0` is current (Terraform)
- ✅ No hardcoded credentials in Bicep or Terraform

### Documentation & Structure
- ✅ 6 phases described and exist
- ✅ Phase folder contents match task descriptions
- ✅ Script numbered prefixes (01-, 02-) ensure correct execution order
- ✅ Orchestrator uses `Sort-Object Name` for ordered execution
- ✅ Restore script covers all resource types modified by phases
- ✅ README prerequisites match orchestrator's module checks
- ✅ .gitignore covers Terraform state, secrets, IDE files, output
- ✅ Bicep/Terraform parameter definitions are well-structured
- ✅ Phase folder structure is correct (6 phase folders + root scripts)

---

## Summary Table: Issue Categories

| Category | Count | Priority |
|----------|-------|----------|
| 🔴 Critical Errors | 3 | MUST FIX |
| 🟡 Warnings | 8 | SHOULD FIX |
| ✅ Confirmations | 25+ | OK |

**Verdict:** The codebase is well-structured with no security issues. 3 critical runtime failures must be addressed before Phase 4 & 5 can be invoked. All other phases will execute, though Phase 1 output will go to an incorrect hardcoded path until E3 is fixed.

---

## Recommendations (Priority Order)

1. **Fix E3** (Phase 1 hardcoded path) — data loss risk
2. **Fix E2** (Phase 4 mandatory params) — Phase 4 will always fail
3. **Fix E1** (Phase 5 folder name) — Phase 5 will always fail
4. **Fix W6** (Phase 1 `BackupPath` mismatch) — silent param loss
5. **Add W1** (`#Requires -Modules`) — prevent cryptic failures
6. **Fix W7** (Inconsistent `BackupPath` defaults) — deployment clarity
7. **Add W2** (`SubscriptionListPath` to Phase 1/6) — consistency

---

## Audit Sources

- **Haise (Tester):** `.squad/orchestration-log/2026-03-25T21-16-32Z-haise-tester.md`
- **Swigert (Validator):** `.squad/orchestration-log/2026-03-25T21-16-32Z-swigert-validator.md`
