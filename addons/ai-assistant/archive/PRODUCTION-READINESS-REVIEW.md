<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant Addon — Production Readiness & First-Time User Validation Review

**Date:** May 30, 2026
**Reviewer:** Automated review (GitHub Copilot)
**Scope:** Validate that a new engineer can install, enable, access, and use the AI Assistant without tribal knowledge.

---

## Executive Summary

The AI Assistant addon is **functionally complete** and has passed comprehensive acceptance testing. However, documentation drift from the Phase B Ollama-to-Windows migration left several files with stale references that would confuse a first-time user. These have been fixed in this review. Several gaps remain as recommendations.

---

## 1. Scores

| Category | Score | Notes |
|----------|-------|-------|
| **Production Readiness** | **8/10** | All workflows tested and passing. Single-replica SPOFs noted (a2a-proxy, mcp-preprocessor). Hardcoded IP (172.19.1.1) is a risk for non-standard configurations. |
| **Installation Readiness** | **7/10** | Enable/disable/update scripts are solid. Missing: ingress addon is not auto-validated as a prerequisite. Ollama must be pre-installed by user (not bundled). No validation that `k2s.cluster.local` resolves. |
| **Operator Readiness** | **8/10** | Status command covers all components. Smoke test is comprehensive. Service resiliency (nssm auto-restart) is well-designed. Logs are accessible. |
| **Documentation Readiness** | **6/10** → **8/10** (after fixes applied) | README was missing prerequisites, troubleshooting, and the ingress dependency. Testing checklist had 8+ stale references to K8s Ollama. Unit tests tested removed functions. No entry in the main `docs/` site. |

---

## 2. Gap Analysis — Findings & Fixes Applied

### 2.1 Fixes Applied (this review)

| # | Gap | File(s) | Fix |
|---|-----|---------|-----|
| 1 | **Testing checklist: stale K8s Ollama references** — 8 sections still referenced `ai-assistant` namespace, `kubectl exec deployment/ollama`, K8s PVC checks. Ollama is now a Windows host service. | `testing-checklist.md` | Updated sections 1.1, 1.2, 3-I, 4.2, 5.3, 5.5, Step 3 to use Windows service commands (`Get-Service K2sOllama`, `ollama list`, `Restart-Service`). |
| 2 | **README: missing prerequisites** — No mention of ingress addon requirement, Ollama installation, `k2s.cluster.local` DNS, disk space, or GPU recommendation. | `README.md` | Added comprehensive prerequisites for all providers, with specific requirements per provider. |
| 3 | **README: no troubleshooting** — New user with a broken install had no guidance. | `README.md` | Added troubleshooting table with 7 common problems, checks, and fixes. |
| 4 | **README: no status/update section** — User had to discover `k2s addons status` on their own. | `README.md` | Added "Checking Status" and "Update" sections. |
| 5 | **Smoke test: stale Headlamp Phase 9** — Phase 9 titled "Headlamp Integration" testing Headlamp dashboard URL. Headlamp was removed in Phase 1. | `test/Invoke-SmokeTest.ps1` | Replaced with "Kagent UI Integration" testing the Kagent UI ingress route. |
| 6 | **Smoke test: stale architecture comment** — Referenced `Headlamp ->` in the validated architecture chain. | `test/Invoke-SmokeTest.ps1` | Updated to `Kagent UI ->`. |
| 7 | **Unit tests: testing removed functions** — Tests for `New-OllamaDataDirectory`, `New-ZscalerCaConfigMap`, `Set-KagentProxyService` which no longer exist in the module. `Invoke-OllamaModelPull` tests used old kubectl-based implementation. | `ai-assistant.module.unit.tests.ps1` | Removed stale test blocks. Updated `Invoke-OllamaModelPull` tests. Replaced stale export tests with current exports (`Install-OllamaWindowsService`, `Wait-ForOllamaReady`, `Set-OllamaKeepAlive`). |
| 8 | **Testing checklist: status property names wrong** — Listed `IsKagentRunning` but actual property is `IsKagentControllerRunning`. Missing `IsKagentIngressReady`. | `testing-checklist.md` | Fixed property names to match `Get-Status.ps1` output. |

### 2.2 Remaining Gaps (Recommendations Only)

| # | Gap | Severity | Recommendation |
|---|-----|----------|----------------|
| R1 | **No docs/ site entry** — The AI Assistant addon has zero mention in `docs/user-guide/addons.md` or any MkDocs page. A new user browsing docs would not know this addon exists. | HIGH | Add an "AI Assistant" section to `docs/user-guide/addons.md` with quick start, provider options, and link to README. |
| R2 | **Ingress prerequisite not validated at enable time** — `Enable.ps1` checks cluster availability and setup type but does not verify the ingress addon is enabled. A user who runs `k2s addons enable ai-assistant` without ingress gets a working backend but no way to access the UI via the documented URL. | HIGH | Add a check in `Enable.ps1` for ingress addon presence. Either error with guidance or warn clearly. |
| R3 | **Ollama not-installed error is not user-friendly** — `Get-OllamaExePath` throws a raw exception `'[AI-Assistant] Ollama is not installed...'` which surfaces as a PowerShell stack trace. | MEDIUM | Catch the error in `Enable.ps1` and produce a structured user-facing error with download URL. |
| R4 | **`--gpu` flag accepted but unused** — `Enable.ps1` accepts `$Gpu` parameter and it's documented in the manifest, but the Phase B Windows Ollama migration doesn't use it (Ollama auto-detects GPU). | LOW | Either remove the flag or document that GPU is auto-detected and the flag is a no-op. |
| R5 | **`--keep-model-data` semantics changed** — Previously preserved K8s PVC. Now the flag controls whether the nssm service is removed vs kept. The model data on disk (`~/.ollama/models`) is never deleted by the addon. | MEDIUM | Clarify in manifest description and README what exactly `--keep-model-data` preserves in the current architecture. |
| R6 | **Hardcoded Ollama IP `172.19.1.1`** — In `ollama-agent.yaml` ModelConfig, `Set-OllamaKeepAlive`, and smoke test. Will break on non-standard K2s network configurations. | MEDIUM | Extract to a configurable value (flag or ConfigMap). Already noted in `PRODUCTION-HARDENING-ROADMAP.md`. |
| R7 | **Smoke test checks for `devstral` model** — Line 364 validates model name matches `devstral` but the default model is `qwen2.5:7b`. | LOW | Change to check for the configured model dynamically or match any model. |
| R8 | **No automated integration test in CI** — The smoke test exists but is not wired into any GitHub Actions workflow. | MEDIUM | Add a CI workflow that enables the addon in a test cluster and runs `Invoke-SmokeTest.ps1`. |
| R9 | **`manifests/ollama/ollama.yaml` listed in README/status but directory only contains `kagent/`** — The manifest file path is documented but the file doesn't exist in the manifests directory. | LOW | Remove from the README Files table or create a placeholder note that it's legacy (no longer used). |

---

## 3. Validation Results

### A. Fresh Install

| Step | Result | Notes |
|------|--------|-------|
| User reads README | ✅ PASS (after fix) | Prerequisites now documented |
| `k2s install` | N/A | Outside addon scope |
| `k2s addons enable ingress nginx` | ⚠️ GAP | Not validated by Enable.ps1 (R2) |
| `k2s addons enable ai-assistant --provider ollama` | ✅ PASS | Clear flow, good error messages |
| Ollama not installed | ⚠️ GAP | Stack trace instead of friendly error (R3) |
| Enable completes | ✅ PASS | Usage notes printed with URL |

### B. First Query

| Step | Result | Notes |
|------|--------|-------|
| User finds Kagent UI URL | ✅ PASS | Printed in enable output + README |
| `https://k2s.cluster.local/agents/...` loads | ✅ PASS | Ingress + redirect configured |
| Port-forward alternative documented | ✅ PASS | In README |
| Agent visible in UI | ✅ PASS | `k2s-assistant` or `copilot-cli` |
| First query works | ✅ PASS | Deterministic shortcuts respond in <200ms |

### C. Operational Workflows (Deterministic)

| Workflow | Validated | Latency |
|----------|-----------|---------|
| health | ✅ | ~100ms |
| status | ✅ | ~100ms |
| nodes | ✅ | ~100ms |
| pods | ✅ | ~110ms |
| errors | ✅ | ~87ms |
| restarts | ✅ | ~106ms |
| help | ✅ | ~65ms |
| logs (existing) | ✅ | ~100ms |
| diagnose (existing) | ✅ | ~200ms |
| deploy (existing) | ✅ | ~100ms |

### D. Conversational Workflows

| Workflow | Validated | Latency |
|----------|-----------|---------|
| Summarize cluster | ✅ | ~7s warm, ~37s cold |
| List nodes | ✅ | ~7s |
| Tool calling (auto-confirm) | ✅ | Auto-confirmed |
| Multi-turn context | ✅ (checklist scenario J) | N/A |

### E. Failure Scenarios

| Scenario | Validated | Behavior |
|----------|-----------|----------|
| Ollama unavailable | ✅ | Graceful degradation, deterministic shortcuts still work |
| Invalid pod name | ✅ | Graceful error, no crash |
| Invalid deployment | ✅ | Graceful error, no crash |
| Non-existent namespace | ✅ (via diagnose test) | Error message returned |
| Missing model | ✅ | Clear error during enable |
| RBAC denied (write ops) | ✅ | k2s-tools ClusterRole only has get/list/watch |

### F. Documentation

| Document | State | Notes |
|----------|-------|-------|
| `README.md` | ✅ Fixed | Added prerequisites, troubleshooting, status, update |
| `ai-assistant-status.md` | ✅ Current | Accurate architecture, test results, service details |
| `testing-checklist.md` | ✅ Fixed | 8 stale sections updated for Windows Ollama |
| `addon.manifest.yaml` | ✅ Current | CLI flags, examples, parameter mappings |
| `docs/user-guide/addons.md` | ❌ Missing | No entry for ai-assistant (R1) |
| `PRODUCTION-HARDENING-ROADMAP.md` | ✅ Current | Accurate risk assessment |
| Unit tests | ✅ Fixed | Removed 3 stale test blocks, updated 1 |
| Smoke test | ✅ Fixed | Removed Headlamp references |

---

## 4. Highest-Priority Fixes (Recommended Next Steps)

1. **[HIGH] Add ai-assistant to `docs/user-guide/addons.md`** — Without this, the addon is invisible to anyone reading the official docs.
2. **[HIGH] Validate ingress prerequisite in `Enable.ps1`** — Prevents a common "it enabled but I can't access it" support case.
3. **[MEDIUM] Improve Ollama-not-installed error** — Catch the exception and produce a structured error with download URL.
4. **[MEDIUM] Clarify `--keep-model-data` semantics** — Document that Windows host model data at `~/.ollama/models` is never auto-deleted.

## 5. Nice-to-Have Improvements

- Add `/kagent-ui` convenience redirect mention to README (it exists in the ingress YAML but isn't documented)
- Add smoke test to CI pipeline
- Parameterize the Ollama host IP instead of hardcoding `172.19.1.1`
- Remove or deprecate the `--gpu` flag (Ollama auto-detects GPU on Windows)
- Fix smoke test Phase 4 model check from `devstral` to configurable
- Remove `manifests/ollama/ollama.yaml` from README Files table (legacy reference)

---

## 6. Release Recommendation

**CONDITIONAL GO** — The addon is functionally production-ready. All workflows pass, error handling is robust, and the architecture is clean. The documentation fixes applied in this review address the most critical first-time user blockers.

**Before GA release:**
- Add the addon to the docs site (R1)
- Add ingress prerequisite validation (R2)

**Can ship as-is for internal/beta users** who have access to the addon README and testing checklist.

