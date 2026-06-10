<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant Addon — Local Setup Guide

**Target audience:** Developers and operators who want to run the K2s AI Assistant locally.  
**Goal:** Get the Kagent UI running with either the default connected Copilot provider or the offline Ollama provider.

---

## Architecture Overview

```
Browser / Kagent UI
    │
    │  https://k2s.cluster.local/agents/kagent/k2s-assistant/chat
    ▼
a2a-proxy (kagent namespace)
    │
    ├──► kagent-controller
    ├──► mcp-preprocessor
    ├──► k2s-tools (read-only cluster tools)
    └──► active provider
            ├── copilot-cli agent (connected mode)
            └── ollama agent (offline/local mode)

Windows host Ollama (ollama provider only)
    └── http://localhost:11434 (host)
    └── http://172.19.1.1:11434 (reachable from the cluster)
```

---

## Step 1 — Verify Prerequisites

### 1a. K2s cluster is running

```console
k2s status
```

Expected: `SUCCESS  The system is running`

### 1b. Ingress addon is enabled

The AI Assistant UI is exposed through the K2s ingress.

```console
k2s addons enable ingress nginx
```

If you prefer a different ingress implementation, use the one that matches your environment.

### 1c. DNS / hosts entry exists for `k2s.cluster.local`

The Kagent UI is accessed through:

```text
https://k2s.cluster.local/agents/kagent/k2s-assistant/chat
```

Make sure `k2s.cluster.local` resolves to the ingress IP on your machine.

---

## Step 2 — Choose a Provider

The addon supports two provider modes:

| Provider | Mode | When to use |
|----------|------|-------------|
| `copilot` | Connected | GitHub Copilot CLI BYO agent |
| `ollama` | Offline/local | Windows-host Ollama with a local model |

### Option A — Connected mode (default)

Use this if you have a GitHub PAT with Copilot permissions:

```console
k2s addons enable ai-assistant --provider copilot --github-token ghp_xxx
```

### Option B — Offline/local mode

Use this if you want the AI Assistant to run fully locally:

```console
k2s addons enable ai-assistant --provider ollama
```

Recommended for demos when you want no cloud dependency.

---

## Step 3 — Prepare Windows-host Ollama for Offline Mode

This step is only needed for `--provider ollama`.

### 3a. Install Ollama on Windows

Download and install Ollama for Windows:

```text
https://ollama.com/download/windows
```

### 3b. Verify the Ollama service is running

```powershell
Get-Service K2sOllama
curl.exe -s http://localhost:11434/api/tags
```

Expected:
- `K2sOllama` service is running
- JSON output contains a `models` array

### 3c. Pull the model used by the addon

The addon defaults to `qwen2.5:7b` for chat.

```powershell
ollama pull qwen2.5:7b
```

If you want a different model, choose one that fits your hardware and update the enable command:

```console
k2s addons enable ai-assistant --provider ollama --model mistral
```

### 3d. Optional GPU acceleration

If your Windows host has a supported GPU and Ollama is configured to use it, you can enable the addon with GPU support:

```console
k2s addons enable ai-assistant --provider ollama --gpu
```

---

## Step 4 — Enable the Addon

After prerequisites are ready, enable the addon with your chosen provider:

```console
k2s addons enable ai-assistant --provider ollama
```

or:

```console
k2s addons enable ai-assistant --provider copilot --github-token ghp_xxx
```

This deploys the Kagent stack in the `kagent` namespace, including:
- `kagent-controller`
- `kagent-ui`
- `a2a-proxy`
- `mcp-preprocessor`
- read-only `k2s-tools` RBAC
- provider-specific agent resources

---

## Step 5 — Check Status

```console
k2s addons status ai-assistant
```

Expected healthy status messages include:

- `Kagent controller is running`
- `A2A proxy is running in kagent namespace`
- `Kagent ingress is active`
- `Kagent UI is running`
- For Ollama mode: `Ollama LLM runtime is running (Windows host, GPU-accelerated)`

Useful detail checks:

```powershell
kubectl get pods -n kagent
kubectl get agents -n kagent
Get-Service K2sOllama
curl.exe -s http://localhost:11434/api/tags
```

---

## Step 6 — Open the UI

### Recommended access path

```text
https://k2s.cluster.local/agents/kagent/k2s-assistant/chat
```

### Alternative: port-forward

If you do not want to use ingress, port-forward the UI service:

```powershell
kubectl port-forward svc/kagent-ui -n kagent 8080:8080
```

Then open:

```text
http://localhost:8080
```

---

## Step 7 — Validate the Setup

A quick sanity check in the UI:

1. Open the Kagent UI
2. Start a new chat with `k2s-assistant`
3. Ask a read-only question such as:

```text
Show me the running pods in the cluster.
```

In Ollama mode, the assistant should answer locally and the model should be served by Windows-host Ollama.

---

## Day-Two Operations

### Re-apply the addon after changes

```console
k2s addons update ai-assistant
```

### Check addon health

```console
k2s addons status ai-assistant
```

### Disable the addon

```console
k2s addons disable ai-assistant
```

### Disable but keep downloaded Ollama models

```console
k2s addons disable ai-assistant --keep-model-data
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| UI not loading | Ingress not enabled or DNS not set | Enable ingress and verify `k2s.cluster.local` resolves |
| `Ollama is not running on Windows host` | `K2sOllama` service is stopped | `Restart-Service K2sOllama` |
| Ollama query returns no models | Model not pulled yet | `ollama pull qwen2.5:7b` |
| Agent not visible in UI | Deployment not finished or wrong provider | Re-run `k2s addons status ai-assistant` and inspect `kubectl get agents -n kagent` |
| Slow first response | Cold model load | Wait for the first request to warm up the model |

---

## Configuration Summary

| Item | Value |
|------|-------|
| Addon name | `ai-assistant` |
| Primary UI | Kagent UI |
| Connected provider | `copilot` |
| Offline provider | `ollama` |
| Default Ollama model | `qwen2.5:7b` |
| Windows Ollama host | `http://localhost:11434` |
| Cluster-reachable Ollama endpoint | `http://172.19.1.1:11434` |
| Chat URL | `https://k2s.cluster.local/agents/kagent/k2s-assistant/chat` |

---

## Quick Reference

```console
k2s addons enable ai-assistant --provider ollama
k2s addons status ai-assistant
k2s addons update ai-assistant
k2s addons disable ai-assistant
```

