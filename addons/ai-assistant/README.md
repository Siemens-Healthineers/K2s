<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant Addon

The **AI Assistant** addon brings natural-language Kubernetes assistance directly into K2s by combining:

| Component | Role |
|---|---|
| **Ollama** | Offline-capable local LLM runtime (runs in the cluster) |
| **HolmesGPT** | Kubernetes-aware AI agent (reads cluster state, streams reasoning via AG-UI) |
| **Headlamp plugin** | Chat UI injected into the Headlamp dashboard |

> **Prerequisites**: The `dashboard` addon must be enabled before enabling `ai-assistant`.

---

## Quick Start

```console
# 1. Enable the dashboard first (if not already done)
k2s addons enable dashboard

# 2. Enable AI Assistant with the default model (qwen2.5:7b)
k2s addons enable ai-assistant

# 3. Open Headlamp, click the AI icon, configure Local Models provider
#    Base URL: http://ollama.ai-assistant.svc.cluster.local:11434
#    Model:    qwen2.5:7b
```

---

## CLI Options

### Enable

| Flag | Default | Description |
|---|---|---|
| `--model` | `qwen2.5:7b` | Ollama model to pull on first enable |
| `--gpu` | `false` | Enable GPU acceleration (requires a node labelled `gpu=true`) |

```console
k2s addons enable ai-assistant --model mistral
k2s addons enable ai-assistant --model phi3 --gpu
```

### Disable

| Flag | Default | Description |
|---|---|---|
| `--keep-model-data` | `false` | Preserve the Ollama PVC so models survive a re-enable |

```console
k2s addons disable ai-assistant
k2s addons disable ai-assistant --keep-model-data
```

---

## Architecture

```
┌─ K2s cluster ──────────────────────────────────────────────┐
│                                                            │
│  namespace: ai-assistant                                   │
│  ┌────────────┐    REST /v1    ┌──────────────────────┐   │
│  │   Ollama   │◄──────────────│    HolmesGPT (holmes) │   │
│  │ :11434     │               │    AG-UI :5050        │   │
│  └────────────┘               └──────────┬───────────┘   │
│       │ PVC: ollama-models               │ SSE /api/agui/chat
│                                          │               │
│  namespace: dashboard                    │               │
│  ┌───────────────────────────────────────┘               │
│  │  Headlamp pod                                          │
│  │  initContainer: ai-assistant-plugin                    │
│  │  → /tmp/headlamp/plugins/ai-assistant/                │
│  └────────────────────────────────────────────────────────│
└────────────────────────────────────────────────────────────┘
        ▲
        │  K8s service proxy
   User Browser (Headlamp UI → AI chat panel)
```

The Headlamp plugin communicates with HolmesGPT through the Kubernetes API server's service proxy (`/api/v1/namespaces/ai-assistant/services/holmesgpt-holmes:80/proxy/api/agui/chat`). No direct ingress or port-forwarding is needed for the agent.

---

## Headlamp Plugin Configuration

After enabling the addon, open Headlamp → **Settings → AI Assistant**:

- **Provider**: `Local Models`
- **Base URL**: `http://ollama.ai-assistant.svc.cluster.local:11434`  
  *(or port-forward: `kubectl port-forward svc/ollama -n ai-assistant 11434:11434` → `http://localhost:11434`)*
- **Model**: The model name you supplied with `--model` (default: `qwen2.5:7b`)

The plugin auto-detects HolmesGPT via the K8s service proxy. When the Holmes indicator in the UI shows **Connected**, the agent is reachable and will enhance responses with live cluster diagnostics.

> **Note**: The HolmesGPT service namespace in this addon is `ai-assistant`. If the plugin shows "disconnected", navigate to plugin settings and set the Holmes namespace to `ai-assistant`.

---

## Pulling Additional Models

```console
kubectl exec -n ai-assistant deployment/ollama -- ollama pull llama3.1
kubectl exec -n ai-assistant deployment/ollama -- ollama list
```

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Ollama not starting | `kubectl describe pod -n ai-assistant -l app=ollama` — check PVC binding and resource limits |
| Model pull timeout | Large models (7B+) take several minutes. Watch: `kubectl logs -n ai-assistant deployment/ollama -f` |
| Holmes "disconnected" | Verify pod: `kubectl get pods -n ai-assistant -l app=holmesgpt` — check it is Running and ready |
| Plugin icon not in Headlamp | `kubectl get deploy headlamp -n dashboard -o jsonpath='{.spec.template.spec.initContainers[*].name}'` should include `ai-assistant-plugin` |
| Holmes uses wrong namespace | Go to Headlamp → Settings → AI Assistant → Holmes tab → set namespace to `ai-assistant` |

---

## Offline Usage

All images referenced by this addon are included in the K2s offline package:

- `ollama/ollama:0.9.1`
- `shsk2s.azurecr.io/holmesgpt:0.19.1` (retagged from `robustadev/holmes:0.19.1`)
- `shsk2s.azurecr.io/headlamp-plugin-ai-assistant:0.2.0-alpha`

No internet access is required after the initial installation, except for pulling new Ollama models (use `--keep-model-data` to avoid re-downloading).

