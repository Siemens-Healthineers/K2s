<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant Addon

The AI Assistant addon deploys [Kagent](https://kagent.dev) (a CNCF Kubernetes-native AI agent framework) with a configurable backend provider. The **Kagent UI** is the sole AI interface.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Kagent UI  (Next.js · https://k2s.cluster.local/   │
│             agents/kagent/k2s-assistant/chat)        │
│  Chat panel · Agent management · Tool execution     │
└─────────────────────────┬───────────────────────────┘
                          │  A2A protocol
                          ▼
┌─────────────────────────────────────────────────────┐
│  a2a-proxy  (kagent namespace, port 8082)           │
│  Deterministic workflows (shortcut fast-path)       │
│  Conversational workflows (A2A → kagent-controller) │
│  Auto-confirms approved read-only tool calls        │
└─────────────┬───────────────────┬───────────────────┘
              │                   │
    ┌─────────▼─────────┐  ┌─────▼──────────────────┐
    │  Copilot CLI Agent │  │  Ollama Local Agent    │
    │  (BYO, connected)  │  │  (offline/air-gapped)  │
    │  GitHub Copilot    │  │  qwen2.5:7b / etc.     │
    └────────────────────┘  └────────────────────────┘
```

### Key Components (preserved)

| Component | Namespace | Description |
|-----------|-----------|-------------|
| `kagent-controller` | `kagent` | Agent orchestration framework (A2A server) |
| `kagent-ui` | `kagent` | Primary AI interface (Next.js web UI) |
| `a2a-proxy` | `kagent` | Deterministic + conversational workflow router |
| `mcp-preprocessor` | `kagent` | Tool output preprocessing proxy |
| `k2s-tools` RBAC | `kagent` | Read-only cluster access for tools |

## Providers

| Provider | Flag | Connectivity | Description |
|----------|------|-------------|-------------|
| `copilot` (default) | `--provider copilot` | Connected | Kagent + Copilot CLI BYO agent. Requires GitHub PAT. |
| `ollama` | `--provider ollama` | Offline | Kagent + Ollama local LLM. Fully air-gapped. |

## Quick Start

For a step-by-step local setup guide, see [`LOCAL-SETUP.md`](LOCAL-SETUP.md).

```console
# Connected mode (default) — uses GitHub Copilot CLI
k2s addons enable ai-assistant --github-token ghp_xxx

# Offline mode — uses local Ollama LLM
k2s addons enable ai-assistant --provider ollama

# Offline with specific model and GPU
k2s addons enable ai-assistant --provider ollama --model mistral --gpu

# Check status
k2s addons status ai-assistant

# Disable (removes everything)
k2s addons disable ai-assistant

# Disable but keep downloaded models
k2s addons disable ai-assistant --keep-model-data
```

## Prerequisites

### All providers

1. **K2s cluster installed and running** — `k2s install` must have completed successfully
2. **Ingress addon enabled** — required for external access to Kagent UI:
   ```console
   k2s addons enable ingress nginx
   ```
3. **DNS resolution for `k2s.cluster.local`** — ensure your hosts file maps `k2s.cluster.local` to the ingress IP (typically `172.19.1.100`). K2s usually configures this during install.

### Copilot provider (connected mode)

4. GitHub PAT with **"Copilot Requests"** permission
5. Container registry secret for `shsk2s.azurecr.io` (the Copilot CLI wrapper image)

### Ollama provider (offline mode)

6. **Ollama installed on the Windows host** — download from <https://ollama.com/download/windows>
7. **GPU (optional but recommended)** — NVIDIA GPU with CUDA support for accelerated inference. Without a GPU, inference runs on CPU (significantly slower).
8. Sufficient disk space for model storage (~5GB for `qwen2.5:7b`)

## Accessing the AI Interface

The Kagent UI is the sole AI interface, accessible via:

**Ingress (recommended):**
```
https://k2s.cluster.local/agents/kagent/k2s-assistant/chat
```

**Port-forward (alternative):**
```console
kubectl port-forward svc/kagent-ui -n kagent 8080:8080
# Then open http://localhost:8080
```

## Files

| File | Description |
|------|-------------|
| `manifests/kagent/namespace.yaml` | Kagent namespace |
| `manifests/kagent/kagent-crds.yaml` | Kagent CRDs (pre-rendered) |
| `manifests/kagent/kagent.yaml` | Kagent core (controller, UI, PostgreSQL, tools) |
| `manifests/kagent/local-path-provisioner.yaml` | StorageClass for PVCs |
| `manifests/kagent/a2a-proxy.yaml` | A2A proxy (deterministic + conversational routing) |
| `manifests/kagent/mcp-preprocessor.yaml` | Tool output preprocessing |
| `manifests/kagent/k2s-tools-rbac.yaml` | Read-only cluster RBAC |
| `manifests/kagent/copilot-cli-agent.yaml` | Copilot CLI BYO Agent CR + RBAC |
| `manifests/kagent/ollama-agent.yaml` | Ollama-backed Agent CR + ModelConfig |
| `manifests/kagent/kagent-ingress.yaml` | Ingress for A2A API + Kagent UI |

## Checking Status

```console
k2s addons status ai-assistant
```

All components should report as healthy. For detailed checks:

```console
# Kagent pods
kubectl get pods -n kagent

# Registered agents
kubectl get agents -n kagent

# Ollama service (ollama provider only)
Get-Service K2sOllama
curl.exe -s http://localhost:11434/api/tags
```

## Troubleshooting

| Problem | Check | Fix |
|---------|-------|-----|
| Kagent UI not loading | `kubectl get pods -n kagent -l app.kubernetes.io/component=ui` | `k2s addons update ai-assistant` |
| Agent not listed in UI | `kubectl get agents -n kagent` | Check agent CR: `kubectl describe agent k2s-assistant -n kagent` |
| Ollama not responding | `Get-Service K2sOllama` and `curl.exe -s http://localhost:11434/` | `Restart-Service K2sOllama` |
| Slow first response | Expected — model loads into memory on first query (~10-30s cold start) | Subsequent queries will be fast (~6-7s) |
| Ingress returns 404 | `kubectl get ingress -n kagent` | Ensure ingress addon is enabled: `k2s addons enable ingress nginx` |
| `k2s.cluster.local` unreachable | Check hosts file: `type C:\Windows\System32\drivers\etc\hosts` | Add `172.19.1.100 k2s.cluster.local` |
| Model pull fails | Check disk space and Ollama logs: `Get-Content "$env:LOCALAPPDATA\K2s\logs\ollama-stderr.log"` | Free disk space or choose a smaller model |

## Update

To re-apply manifests after changes or after a cluster reinstall:

```console
k2s addons update ai-assistant
```

