<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant Addon — Production-Readiness Implementation Report

**Date:** May 30, 2026
**Scope:** Implement HIGH priority items from `PRODUCTION-READINESS-REVIEW.md`

---

## Summary

All HIGH priority production-readiness gaps identified in the review have been resolved. No new features, runtime architecture changes, routing behavior changes, or model changes were introduced.

---

## Items Implemented

### 1. AI Assistant addon documentation added to docs site (R1 — HIGH)

**File:** `docs/user-guide/addons.md`

**Changes:**
- Added `ai-assistant` row to the "Available Addons" table
- Added full `### ai-assistant` configuration section with:
  - Provider overview table (copilot vs ollama)
  - Enable flag table (--provider, --model, --github-token, --gpu)
  - Disable flag table (--keep-model-data) with corrected semantics (R5)
  - Prerequisites summary
  - Quick start CLI examples
  - Kagent UI access instructions (ingress + port-forward)
  - Link to addon README for full details

**Rationale:** Without this entry, the addon was invisible to users browsing the official docs site. The section follows the established format (table + code blocks) used by other addons like `dashboard`, `security`, and `rollout`.

---

### 2. Ingress prerequisite validation in Enable.ps1 (R2 — HIGH)

**File:** `addons/ai-assistant/Enable.ps1`

**Changes:**
- Added ingress addon check after the "already enabled?" guard (line ~83)
- Checks all three implementations: `nginx`, `traefik`, `nginx-gw`
- On failure: emits structured error via `Send-ToCli` (CLI mode) or `Write-Log -Error` (direct mode)
- Error message includes:
  - Clear statement of what's missing
  - Remediation command: `k2s addons enable ingress nginx`
  - Alternative: port-forward instructions for users who don't want ingress
- Uses `Get-ErrCodeAddonEnableFailed` error code (consistent with other addon failures)

**Pattern followed:** `addons/viewer/Enable.ps1` lines 74-79 (same `Test-IsAddonEnabled` pattern for ingress check). Made the error a hard-fail (unlike viewer's warning-only approach) since the Kagent UI is the primary AI interface and requires ingress for the documented access URL.

---

### 3. Ollama-not-installed structured error (R3 — MEDIUM, escalated to scope)

**File:** `addons/ai-assistant/Enable.ps1`

**Changes:**
- Added `try/catch` around `Get-OllamaExePath` call before `Install-OllamaWindowsService`
- On catch: emits structured error with:
  - Clear statement: "Ollama is not installed on this machine"
  - Step-by-step installation instructions with download URL
  - Verification command: `ollama --version`
  - Re-run command after installation
- Uses `Get-ErrCodeAddonEnableFailed` error code
- Raw PowerShell stack trace is never shown to the user

**Before:** `Get-OllamaExePath` threw `'[AI-Assistant] Ollama is not installed...'` which surfaced as a raw exception with stack trace.

**After:** User sees a structured, actionable error message.

---

### 4. Living architecture/status documentation updated

**Files:** `addons/ai-assistant/ai-assistant-status.md`, `addons/ai-assistant/README.md`

**Changes:**
- **ai-assistant-status.md:**
  - Updated last-updated note to reflect production-readiness fixes
  - Removed stale `manifests/ollama/ollama.yaml` from Section 3 manifest table
  - Updated Section 5 Quick Reference: replaced K8s Ollama commands (`kubectl exec deployment/ollama`) with Windows service commands (`Get-Service K2sOllama`, `ollama list`)
  - Removed stale `manifests/ollama/ollama.yaml` from Section 8 file state table
  - Updated Enable.ps1 description in Section 8 to mention ingress validation and Ollama error handling
  - Added fix entry 6.0 to Section 7 "What Has Been Fixed"

- **README.md:**
  - Removed stale `manifests/ollama/ollama.yaml` from Files table (R9)

---

### 5. Unit tests added and all tests passing

**File:** `addons/ai-assistant/ai-assistant.module.unit.tests.ps1`

**New tests added:**
- `Get-OllamaExePath` — 3 test cases:
  - Throws descriptive error with download URL when Ollama is not installed
  - Returns PATH-based location when on PATH
  - Returns default install path when found at default location
- Module export tests — 3 additional:
  - `Get-OllamaExePath`
  - `Test-OllamaWindowsHealth`
  - `Remove-OllamaWindowsService`

**Test results:**
```
Tests Passed: 35, Failed: 0, Skipped: 0
```

---

## Files Modified

| File | Change |
|------|--------|
| `docs/user-guide/addons.md` | Added ai-assistant to Available Addons table + configuration section |
| `addons/ai-assistant/Enable.ps1` | Added ingress prerequisite check + Ollama-not-installed structured error |
| `addons/ai-assistant/ai-assistant.module.unit.tests.ps1` | Added 6 new unit tests (Get-OllamaExePath + exports) |
| `addons/ai-assistant/ai-assistant-status.md` | Removed stale references, updated status, added fix entry |
| `addons/ai-assistant/README.md` | Removed stale manifests/ollama/ollama.yaml from Files table |

## Files NOT Modified (by design)

| File | Reason |
|------|--------|
| `ai-assistant.module.psm1` | No runtime changes needed; `Get-OllamaExePath` error message is already adequate for the catch handler in Enable.ps1 |
| `addon.manifest.yaml` | No flag or metadata changes |
| `Get-Status.ps1` | Already accurate |
| `Disable.ps1` | No changes needed |
| `Update.ps1` | No changes needed |
| `manifests/*` | No routing, architecture, or model changes |

---

## Remaining Items (from PRODUCTION-READINESS-REVIEW.md)

| # | Gap | Status | Notes |
|---|-----|--------|-------|
| R1 | No docs/ site entry | ✅ DONE | Added to `docs/user-guide/addons.md` |
| R2 | Ingress prerequisite not validated | ✅ DONE | Hard-fail with guidance in `Enable.ps1` |
| R3 | Ollama-not-installed error | ✅ DONE | Structured error with download URL |
| R4 | `--gpu` flag unused | NOT IN SCOPE | Low priority, no-op flag |
| R5 | `--keep-model-data` semantics | ✅ CLARIFIED | In docs/user-guide/addons.md disable flag table |
| R6 | Hardcoded Ollama IP | NOT IN SCOPE | Medium priority, tracked in PRODUCTION-HARDENING-ROADMAP.md |
| R7 | Smoke test devstral check | NOT IN SCOPE | Low priority |
| R8 | No CI integration test | NOT IN SCOPE | Medium priority |
| R9 | Stale manifests/ollama reference | ✅ DONE | Removed from README.md and ai-assistant-status.md |

---

## Updated Review Scores

| Category | Before | After | Notes |
|----------|--------|-------|-------|
| **Documentation Readiness** | 8/10 | **9/10** | Docs site entry added, stale references fixed |
| **Installation Readiness** | 7/10 | **9/10** | Ingress validated, Ollama error is user-friendly |
| **Production Readiness** | 8/10 | **8/10** | Unchanged (SPOFs and hardcoded IP remain) |
| **Operator Readiness** | 8/10 | **8/10** | Unchanged |

---

## Release Recommendation Update

**GO** — All "before GA" blockers from the review are resolved:
- ✅ Addon is documented in the docs site
- ✅ Ingress prerequisite is validated at enable time
- ✅ Ollama-not-installed error is user-friendly
- ✅ All 35 unit tests passing

