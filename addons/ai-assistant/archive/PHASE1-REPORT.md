<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Phase 1 Report — Headlamp AI Plugin Removal

**Date:** May 30, 2026  
**Status:** ✅ Complete  
**Scope:** Remove all Headlamp AI plugin integration; make Kagent UI the sole AI interface.

---

## Summary of Changes

### 1. Removed: Headlamp AI Plugin Injection

| File | Change |
|------|--------|
| `addons/ai-assistant/Enable.ps1` | Removed `Sync-HeadlampPlugins` call, removed `dashboardModule` import |
| `addons/ai-assistant/Disable.ps1` | Removed `Sync-HeadlampPlugins` call, removed `dashboardModule` import |
| `addons/ai-assistant/Update.ps1` | Removed `Sync-HeadlampPlugins` call, removed `dashboardModule` import |
| `addons/dashboard/dashboard.module.psm1` | Removed AI-assistant plugin init-container and `ai-assistant-kagent-patch` sed logic from `Sync-HeadlampPlugins` |

### 2. Removed: AG-UI Compatibility Layer References

| File | Change |
|------|--------|
| `addons/ai-assistant/ai-assistant.module.psm1` | Removed `Set-KagentProxyService` function (was a no-op referencing AG-UI patch) |
| `addons/ai-assistant/ai-assistant-status.md` | Removed AG-UI protocol adapter description |
| `headlamp-ai-assistant.md` | Marked as SUPERSEDED |
| `docs/ai-assistant-complete-analysis.md` | Marked as SUPERSEDED |

### 3. Removed: Headlamp-Specific AI Routing (SSE Direct Ingress)

| File | Change |
|------|--------|
| `addons/ai-assistant/manifests/kagent/kagent-ingress.yaml` | Removed `kagent-sse-direct` Ingress resource (intercepted K8s apiserver proxy path for Headlamp) |
| `addons/ai-assistant/ai-assistant.module.psm1` | Added `kagent-sse-direct` to `Remove-LegacyAgentResources` for upgrade cleanup |

### 4. Removed: Dashboard Dependency

| File | Change |
|------|--------|
| `addons/ai-assistant/Enable.ps1` | Removed dashboard addon prerequisite check |
| `addons/ai-assistant/addon.manifest.yaml` | Updated description (no longer mentions Headlamp) |
| `addons/ai-assistant/README.md` | Removed "Dashboard addon must be enabled" from prerequisites |

### 5. Removed: Obsolete HolmesGPT Compatibility Logic

Already handled by `Remove-LegacyAgentResources` — no additional changes needed. The function continues to clean up legacy resources on enable/update for clusters upgrading from old versions.

### 6. Removed: Headlamp Plugin Offline Images

| File | Change |
|------|--------|
| `addons/ai-assistant/addon.manifest.yaml` | Removed `headlamp-plugin-ai-assistant:0.2.0-alpha` and `busybox:1.37` (patch helper) from `additionalImages` |

---

## Preserved (unchanged)

| Component | Status |
|-----------|--------|
| Kagent UI | ✅ Preserved — sole AI interface via ingress (`/agents/...`) |
| kagent-controller | ✅ Preserved — A2A agent orchestration |
| a2a-proxy | ✅ Preserved — deterministic + conversational workflow router |
| mcp-preprocessor | ✅ Preserved — tool output preprocessing |
| k2s-tools RBAC | ✅ Preserved — read-only cluster access |
| Deterministic workflows | ✅ Preserved — shortcut fast-path in a2a-proxy |
| Conversational workflows | ✅ Preserved — A2A → kagent-controller → LLM |
| Ollama | ✅ NOT MOVED — stays in Linux VM as before |
| Models | ✅ NOT CHANGED — qwen2.5:7b default unchanged |

---

## Validation Checklist

### Kagent UI works
- [ ] `kubectl get deployment kagent-ui -n kagent` shows Available
- [ ] `https://k2s.cluster.local/agents/kagent/k2s-assistant/chat` loads
- [ ] Chat interface accepts input and returns responses

### Deterministic workflows work
- [ ] Shortcut queries (e.g. "list pods") return sub-second responses
- [ ] a2a-proxy routes shortcuts to mcp-preprocessor directly

### Conversational workflows work
- [ ] Free-form queries route through kagent-controller to LLM
- [ ] Tool calls are auto-confirmed for read-only tools
- [ ] Multi-turn conversations maintain context

---

## Files Modified

```
addons/ai-assistant/Enable.ps1
addons/ai-assistant/Disable.ps1
addons/ai-assistant/Update.ps1
addons/ai-assistant/Get-Status.ps1
addons/ai-assistant/ai-assistant.module.psm1
addons/ai-assistant/addon.manifest.yaml
addons/ai-assistant/README.md
addons/ai-assistant/ai-assistant-status.md
addons/ai-assistant/testing-checklist.md
addons/ai-assistant/manifests/kagent/kagent-ingress.yaml
addons/dashboard/dashboard.module.psm1
headlamp-ai-assistant.md
docs/ai-assistant-complete-analysis.md
```

---

## Not In Scope (future phases)

- Moving Ollama to Windows host
- Changing models or inference location
- Removing a2a-proxy (it still serves as the workflow router for Kagent UI)

