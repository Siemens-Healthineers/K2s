<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant Addon — Architecture & Status

> **Last updated:** May 27, 2026 — Migrated from legacy agent to Kagent framework.

---

## 1. Architecture

```
Browser (Headlamp plugin)
        │  POST /api/agui/chat  (SSE)
        ▼
  ingress-nginx  (kagent-ingress.yaml)
  proxy-buffering: off, direct route to kagent namespace
        │
        ▼
  a2a-proxy  (kagent namespace, port 8082)
  ┌────────────────────────────────────────────────────────┐
  │  A2A/AG-UI protocol adapter                            │
  │  Routes requests to Kagent controller via A2A protocol │
  │  Streams SSE events back to the browser                │
  └────────────────────────────────────────────────────────┘
        │
        ▼
  kagent-controller  (kagent namespace)
  ┌────────────────────────────────────────────────────────┐
  │  Agent orchestration framework                         │
  │  Manages agent lifecycle, tool execution, PostgreSQL   │
  │  Registered agents: copilot-cli or ollama-agent        │
  └────────────────────────────────────────────────────────┘
        │
        ▼
  LLM Backend (provider-dependent):
    - 'copilot'  → GitHub Copilot CLI (connected, requires PAT)
    - 'ollama'   → Ollama (ai-assistant namespace, local/offline)
```

---

## 2. Provider Configuration

### Copilot Provider (default)

| Component | Namespace | Description |
|-----------|-----------|-------------|
| `kagent-controller` | `kagent` | Agent orchestration framework |
| `kagent-ui` | `kagent` | Web UI for agent management |
| `a2a-proxy` | `kagent` | A2A/AG-UI protocol adapter for Headlamp |
| `mcp-preprocessor` | `kagent` | Tool output preprocessing proxy |
| `copilot-cli` agent | `kagent` | BYO agent using GitHub Copilot CLI |
| `copilot-github-token` secret | `kagent` | GitHub PAT for Copilot access |

### Ollama Provider (offline)

All Copilot components above, plus:

| Component | Namespace | Description |
|-----------|-----------|-------------|
| `ollama` deployment | `ai-assistant` | Local LLM runtime with persistent model storage |
| `ollama-models` PVC | `ai-assistant` | 20Gi persistent volume for downloaded models |
| `ollama-agent` | `kagent` | Kagent agent backed by local Ollama model |

---

## 3. Kagent Framework Components

| Manifest | Purpose |
|----------|---------|
| `manifests/kagent/namespace.yaml` | Kagent namespace |
| `manifests/kagent/kagent-crds.yaml` | Custom Resource Definitions (agents, tools, etc.) |
| `manifests/kagent/kagent.yaml` | Controller, UI, PostgreSQL, tools |
| `manifests/kagent/a2a-proxy.yaml` | A2A protocol adapter for Headlamp integration |
| `manifests/kagent/mcp-preprocessor.yaml` | Tool output preprocessing |
| `manifests/kagent/k2s-tools-rbac.yaml` | Read-only cluster access RBAC |
| `manifests/kagent/kagent-ingress.yaml` | Ingress for SSE streaming |
| `manifests/kagent/copilot-cli-agent.yaml` | Copilot CLI BYO agent definition |
| `manifests/kagent/ollama-agent.yaml` | Ollama-backed agent definition |
| `manifests/kagent/local-path-provisioner.yaml` | StorageClass for Kagent PVCs |
| `manifests/ollama/ollama.yaml` | Ollama deployment + PV/PVC |

---

## 4. Headlamp Plugin Integration

The Headlamp AI Assistant plugin is injected via init-container pattern
(see `dashboard.module.psm1` → `Sync-HeadlampPlugins`).

At deploy time, a `sed`-based init-container (`ai-assistant-kagent-patch`)
rewrites the plugin's `main.js` to:
- Point to `a2a-proxy:8082` in the `kagent` namespace (instead of legacy backend)
- Replace all legacy branding with K2s AI branding

---

## 5. Legacy Resource Cleanup

`Remove-LegacyAgentResources` (in `ai-assistant.module.psm1`) deletes resources
from the pre-Kagent era during enable/update. This ensures clean upgrades from
previous addon versions. The kubectl delete commands reference actual K8s resource
names that may exist in clusters being upgraded — these references are intentional.

---

## 6. Quick Reference

```console
# Check Kagent controller status
kubectl get pods -n kagent

# Check registered agents
kubectl get agents -n kagent

# Check a2a-proxy
kubectl get pods -n kagent -l app=a2a-proxy

# Check Ollama (ollama provider only)
kubectl get pods -n ai-assistant -l app=ollama
kubectl exec -n ai-assistant deployment/ollama -- ollama list

# Kagent UI (port-forward)
kubectl port-forward svc/kagent-ui -n kagent 8080:8080

# Full redeploy
k2s addons update ai-assistant

# Check Headlamp plugin injection
kubectl get deployment headlamp -n dashboard \
  -o jsonpath='{.spec.template.spec.initContainers[*].name}'
```

---

## 7. What Has Been Fixed

| # | Fix | File(s) |
|---|-----|---------|
| 3.0 | **Kagent migration** — Replaced legacy agent with Kagent framework. Dual-provider architecture (copilot/ollama). A2A protocol adapter for Headlamp. | `ai-assistant.module.psm1`, `Enable.ps1`, `Update.ps1`, `manifests/kagent/*` |
| 3.1 | **Legacy cleanup** — `Remove-LegacyAgentResources` removes all pre-Kagent resources on enable/update | `ai-assistant.module.psm1` |
| 3.2 | **Plugin branding** — `sed`-based init-container rewrites all legacy references in Headlamp plugin JS | `dashboard.module.psm1` |

---

## 8. Current State

### Files

| File | State |
|------|-------|
| `ai-assistant.module.psm1` | ✅ Clean — Kagent-based, dual-provider |
| `Enable.ps1` | ✅ Clean — Kagent framework + provider deployment |
| `Update.ps1` | ✅ Clean — Kagent update flow |
| `Disable.ps1` | ✅ Clean — full teardown with optional `--keep-model-data` |
| `Get-Status.ps1` | ✅ Clean — Kagent status checks |
| `manifests/kagent/*` | ✅ Kagent framework manifests |
| `manifests/ollama/ollama.yaml` | ✅ Ollama deployment manifest |

### Live cluster (after enable)

| Resource | Description |
|----------|-------------|
| `kagent` namespace | Kagent framework components |
| `kagent-controller` | Agent orchestration controller |
| `a2a-proxy` | A2A/AG-UI adapter (port 8082) |
| `mcp-preprocessor` | Tool output preprocessor |
| Agent CRs | `copilot-cli` or `ollama-agent` (provider-dependent) |
| `ai-assistant` namespace | Ollama + PVC (ollama provider only) |
