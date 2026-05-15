<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant Addon

The AI Assistant addon deploys [Kagent](https://kagent.dev) (a CNCF Kubernetes-native AI agent framework) with a configurable backend provider, and injects an AI chat panel into the Headlamp dashboard.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Headlamp UI  (plugin: ai-assistant 0.2.0-alpha)    │
│  Chat panel · Model selector · Agent status         │
└─────────────────────────┬───────────────────────────┘
                          │  A2A / SSE
                          ▼
┌─────────────────────────────────────────────────────┐
│  Kagent Controller  (kagent.dev v0.9.0)             │
│  K8s-native AI agent orchestration · A2A protocol   │
│  UI · PostgreSQL · Tool Server · MCP                │
└─────────────┬───────────────────┬───────────────────┘
              │                   │
    ┌─────────▼─────────┐  ┌─────▼──────────────────┐
    │  Copilot CLI Agent │  │  Ollama Local Agent    │
    │  (BYO, connected)  │  │  (offline/air-gapped)  │
    │  GitHub Copilot    │  │  qwen2.5:7b / etc.     │
    └────────────────────┘  └────────────────────────┘
```

## Providers

| Provider | Flag | Connectivity | Description |
|----------|------|-------------|-------------|
| `copilot` (default) | `--provider copilot` | Connected | Kagent + Copilot CLI BYO agent. Requires GitHub PAT. |
| `ollama` | `--provider ollama` | Offline | Kagent + Ollama local LLM. Fully air-gapped. |

## Quick Start

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

1. **Dashboard addon** must be enabled: `k2s addons enable dashboard`
2. For `copilot` provider: GitHub PAT with "Copilot Requests" permission
3. For `copilot` provider: Container registry secret for `shsk2s.azurecr.io` (the Copilot CLI wrapper image)

## Kagent UI

The Kagent UI is available via port-forward:

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
| `manifests/kagent/copilot-cli-agent.yaml` | Copilot CLI BYO Agent CR + RBAC |
| `manifests/kagent/ollama-agent.yaml` | Ollama-backed Agent CR + ModelConfig |
| `manifests/kagent/kagent-ingress.yaml` | Ingress for A2A API + SSE streaming |
| `manifests/ollama/ollama.yaml` | Ollama deployment (offline provider only) |
