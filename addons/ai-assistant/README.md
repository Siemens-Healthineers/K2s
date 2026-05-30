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

1. For `copilot` provider: GitHub PAT with "Copilot Requests" permission
2. For `copilot` provider: Container registry secret for `shsk2s.azurecr.io` (the Copilot CLI wrapper image)

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
| `manifests/ollama/ollama.yaml` | Ollama deployment (offline provider only) |
