<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Headlamp AI Assistant — Complete Analysis & Future Roadmap

**Document date:** April 14, 2026  
**Status:** Live on K2s cluster (kubemaster · Kubernetes v1.35.3)  
**Plugin version:** 0.2.0-alpha  
**Audience:** K2s developers, platform engineers, DevOps practitioners

---

## Table of Contents

1. [What Is It?](#1-what-is-it)
2. [Live Cluster Snapshot](#2-live-cluster-snapshot)
3. [Architecture Deep-Dive](#3-architecture-deep-dive)
4. [Component Reference](#4-component-reference)
5. [What It Can Do Today](#5-what-it-can-do-today)
6. [Known Constraints & Limitations](#6-known-constraints--limitations)
7. [Resource Requirements](#7-resource-requirements)
8. [GPU Acceleration](#8-gpu-acceleration)
9. [Offline / Air-Gap Operation](#9-offline--air-gap-operation)
10. [Why It Matters for K2s Users](#10-why-it-matters-for-k2s-users)
11. [Future Roadmap — Near Term](#11-future-roadmap--near-term)
12. [Future Roadmap — Flux GitOps Integration](#12-future-roadmap--flux-gitops-integration)
13. [Future Roadmap — MCP Server Ecosystem](#13-future-roadmap--mcp-server-ecosystem)
14. [Future Roadmap — Autonomous DevOps Agent](#14-future-roadmap--autonomous-devops-agent)
15. [Integration with K2s Security Addon](#15-integration-with-k2s-security-addon)
16. [Quick Reference & Commands](#16-quick-reference--commands)

---

## 1. What Is It?

The **Headlamp AI Assistant** is a Kubernetes-native AI chat panel embedded directly inside the Headlamp dashboard. It brings natural-language cluster interaction to K2s — no separate tool, no cloud account, no internet required.

The addon is a three-layer stack:

```
┌─────────────────────────────────────────────────────┐
│  Headlamp UI  (plugin: ai-assistant 0.2.0-alpha)    │
│  Chat panel · Model selector · MCP settings         │
└─────────────────────────┬───────────────────────────┘
                          │  AG-UI / SSE
                          ▼
┌─────────────────────────────────────────────────────┐
│  HolmesGPT  (robustadev/holmes:0.19.1)              │
│  Kubernetes-aware AI agent · 26+ kubectl tools      │
│  Strict single-tool-call mode (custom prompt)       │
└─────────────────────────┬───────────────────────────┘
                          │  OpenAI-compatible REST
                          ▼
┌─────────────────────────────────────────────────────┐
│  Ollama  (ollama/ollama:0.9.1)                      │
│  Local LLM runtime · qwen2.5:7b (default)           │
│  20 GiB PVC on kubemaster · CPU or GPU              │
└─────────────────────────────────────────────────────┘
```

Everything runs inside the K2s cluster. No data ever leaves your environment.

---

## 2. Live Cluster Snapshot

Observed on the running system as of April 14, 2026.

### Running Pods

| Namespace     | Pod                                  | Status      | Uptime   |
|---------------|--------------------------------------|-------------|----------|
| ai-assistant  | ollama-685984fb9d-zzw56              | ✅ Running  | 2d 17h   |
| ai-assistant  | holmesgpt-holmes-66876864f-ghgmt     | ✅ Running  | 178 min  |
| default       | holmesgpt-proxy-765c65dd68-hqvj5    | ✅ Running  | 3h 43m   |
| dashboard     | headlamp-56fb6659bc-th8jz            | ✅ Running  | 2d 16h   |

### Active Images on kubemaster

| Image                                                        | Size      | Role             |
|--------------------------------------------------------------|-----------|------------------|
| docker.io/ollama/ollama:0.9.1                                | 3.46 GB   | LLM runtime      |
| docker.io/robustadev/holmes:0.19.1                           | 1.34 GB   | AI agent         |
| ghcr.io/headlamp-k8s/headlamp:v0.40.1                       | 249 MB    | Dashboard host   |
| shsk2s.azurecr.io/headlamp-plugin-ai-assistant:0.2.0-alpha  | 12.5 MB   | Plugin injector  |
| docker.io/library/python:3.11-alpine                         | 57.1 MB   | SSE proxy        |

> **Total footprint of AI stack:** ~5.1 GB of images (dominated by Ollama + model weights ~4.5 GB)

### Co-running Addons (same cluster)

| Addon              | Version  | Notes                       |
|--------------------|----------|-----------------------------|
| autoscaling (KEDA) | 2.19.0   | KEDA operator + metrics API |
| cert-manager       | v1.20.0  | TLS certificate automation  |
| dashboard (Headlamp)| v0.40.1 | Required prerequisite       |
| ingress-nginx      | v1.15.1  | Ingress controller          |
| metrics            | v0.8.1   | Resource metrics            |
| external-dns       | v0.19.0  | DNS automation              |

---

## 3. Architecture Deep-Dive

### 3.1 Full Request Flow

```
User types in Headlamp chat
        │
        ▼
Headlamp plugin (React/TypeScript)
  – Builds RunAgentInput JSON with user message
  – POSTs to: /api/v1/namespaces/default/services/holmesgpt-holmes:80/proxy/api/agui/chat
  – Streams SSE response back
        │
        ▼ (via K8s API Server proxy)
holmesgpt-proxy Pod  [default namespace · python:3.11-alpine]
  ┌──────────────────────────────────────────────────────┐
  │  REQUEST interceptor:                                │
  │   • Injects strict system prompt via ag_ui context[] │
  │   • Forces single-tool-call deterministic mode       │
  │                                                      │
  │  RESPONSE SSE filter (per-event, not buffered):      │
  │   • Parses JSON envelope of every SSE event          │
  │   • TEXT_MESSAGE_CONTENT: filters delta string       │
  │     – Keeps kubectl tabular rows + k8s identifiers   │
  │     – Drops LLM prose commentary                     │
  │     – Suppresses empty delta="" (pydantic guard)     │
  │   • All other event types: pass through unchanged    │
  │   • JSON envelope is NEVER broken                    │
  └──────────────────────────────────────────────────────┘
        │
        ▼
holmesgpt-holmes Pod  [ai-assistant namespace · holmes:0.19.1]
  ┌──────────────────────────────────────────────────────┐
  │  AG-UI server (uvicorn/FastAPI)                      │
  │  Custom Jinja2 prompt overrides (ConfigMap subPath): │
  │   • generic_ask_conversation.jinja2 → strict rules   │
  │   • _general_instructions.jinja2   → no TodoWrite    │
  │  Toolset override: kubernetes.yaml (nodes fix)       │
  │  MAX_STEPS=3 · LLM_REQUEST_TIMEOUT=600s              │
  └──────────────────────────────────────────────────────┘
        │  LiteLLM → OpenAI-compatible REST
        │  http://172.19.1.1:11434/v1 (host bridge IP)
        ▼
Ollama Pod  [ai-assistant namespace · ollama:0.9.1]
  ┌──────────────────────────────────────────────────────┐
  │  Model: qwen2.5:7b (default) or user-selected        │
  │  PVC: ollama-models (20 GiB, local path /data/ollama)│
  │  CPU: up to 4 cores · Memory: up to 8 GiB            │
  │  GPU: optional (requires node label gpu=true)        │
  └──────────────────────────────────────────────────────┘
```

### 3.2 Cross-Namespace Proxy Design

A key engineering challenge: the Headlamp plugin hardcodes `HOLMES_SERVICE_NAMESPACE=default` and uses the K8s API Server proxy path. Kubernetes 1.35 rejects selectorless ClusterIP services via the proxy handler. The solution is a real Python proxy pod in `default` that:

1. Has a proper `spec.selector` → K8s API server accepts the proxy request.
2. Injects the strict system prompt into every request before forwarding to `ai-assistant` namespace.
3. Filters verbose SSE output so the UI only receives clean, structured data.

This avoids direct ingress exposure of HolmesGPT and keeps all traffic through the K8s API server's built-in auth/authz.

### 3.3 RBAC Model

HolmesGPT runs with a read-only `ClusterRole` (`holmesgpt-reader`):

- **Allowed verbs:** `get`, `list`, `watch`
- **Resources:** `pods`, `pods/log`, `events`, `nodes`, `namespaces`, `services`, `endpoints`,
  `persistentvolumes`, `persistentvolumeclaims`, `configmaps`,
  `deployments`, `replicasets`, `statefulsets`, `daemonsets`,
  `jobs`, `cronjobs`, `ingresses`, `storageclasses`

> **No write access.** The AI cannot modify, create, or delete any cluster resource via HolmesGPT tools. Any changes suggested must be executed manually by the user.

---

## 4. Component Reference

### 4.1 Ollama (Local LLM Runtime)

| Property       | Value                                                   |
|----------------|---------------------------------------------------------|
| Image          | `ollama/ollama:0.9.1` (3.46 GB)                        |
| Namespace      | `ai-assistant`                                          |
| API port       | 11434 (ClusterIP service)                               |
| Model storage  | PVC `ollama-models` · 20 GiB · `/data/ollama` on kubemaster |
| Default model  | `qwen2.5:7b`                                            |
| Keep-alive     | 24 hours (model stays loaded in RAM)                    |
| CPU limit      | 4 cores                                                 |
| Memory limit   | 8 GiB                                                   |
| GPU support    | Optional via `--gpu` flag (patches node selector + resource limits) |
| Protocol       | OpenAI-compatible REST (`/v1/chat/completions`)         |

**Supported models (pull on-demand):**

| Model         | Size on disk | Quality | Use case                                    |
|---------------|-------------|---------|---------------------------------------------|
| qwen2.5:7b    | ~4.5 GB     | ⭐⭐⭐  | Default — best balance for K8s tooling      |
| llama3.1      | ~4.7 GB     | ⭐⭐⭐  | Strong general reasoning                    |
| mistral       | ~4.1 GB     | ⭐⭐    | Fast responses                              |
| phi3          | ~2.3 GB     | ⭐⭐    | Low-memory nodes                            |
| llama3.2:3b   | ~2.0 GB     | ⭐      | ❌ Fails with 26 tools — too small          |

> **Minimum model size for HolmesGPT tools: 7B parameters.**  
> Small models (3B) cannot reliably handle the 26-tool function-calling payload.

### 4.2 HolmesGPT (Kubernetes AI Agent)

| Property       | Value                                          |
|----------------|------------------------------------------------|
| Image          | `robustadev/holmes:0.19.1` (1.34 GB)          |
| Namespace      | `ai-assistant`                                 |
| API port       | 80 (AG-UI SSE server)                          |
| Protocol       | AG-UI (Agent UI) over Server-Sent Events       |
| Tool count     | 26 kubectl-based tools                         |
| Max steps      | 3 (tool call → process result → safety margin) |
| Context window | 128k tokens (qwen2.5:7b)                       |
| Max output     | 4096 tokens                                    |

**Key tools available:**

| Tool                       | What it does                                                      |
|----------------------------|-------------------------------------------------------------------|
| `kubernetes_tabular_query` | `kubectl get <kind> --all-namespaces -o custom-columns`           |
| `kubernetes_count`         | Counts resources, supports jq expressions for complex queries     |
| `kubernetes_pod_logs`      | Fetches real pod logs                                             |
| `kubernetes_describe`      | `kubectl describe` on any resource                               |
| `kubernetes_events`        | Cluster event stream                                              |

### 4.3 Headlamp Plugin (UI)

| Property         | Value                                                          |
|------------------|----------------------------------------------------------------|
| Image            | `shsk2s.azurecr.io/headlamp-plugin-ai-assistant:0.2.0-alpha` (12.5 MB) |
| Injection method | initContainer in the Headlamp deployment                       |
| Plugin path      | `/tmp/headlamp/plugins/ai-assistant/`                          |
| Framework        | React + TypeScript + MUI                                       |
| Protocol         | AG-UI over SSE via K8s API server proxy                        |

**Supported AI providers (plugin configuration):**

| Provider       | Models                                    | Needs API Key | Offline  |
|----------------|-------------------------------------------|---------------|----------|
| Local Models (Ollama) | Any pulled model                  | ❌ No         | ✅ Yes   |
| OpenAI         | GPT-4o, o3-mini, o4-mini, GPT-4.1        | ✅ Yes        | ❌ No    |
| Azure OpenAI   | GPT-4o, GPT-4, GPT-35-turbo              | ✅ Yes        | ❌ No    |
| Anthropic      | Claude Opus 4, Sonnet 4, Haiku            | ✅ Yes        | ❌ No    |
| Mistral AI     | mistral-large, mistral-medium             | ✅ Yes        | ❌ No    |
| Google Gemini  | Gemini 2.5 Pro/Flash, 2.0 Flash          | ✅ Yes        | ❌ No    |
| DeepSeek       | deepseek-chat, deepseek-reasoner          | ✅ Yes        | ❌ No    |

> For K2s offline/air-gap deployments, **Local Models (Ollama)** is the only supported provider.

---

## 5. What It Can Do Today

These capabilities are verified working on the live cluster as of April 14, 2026.

### ✅ Supported Queries (via HolmesGPT tools)

| Query type               | Example                                          | Tool used                                        |
|--------------------------|--------------------------------------------------|--------------------------------------------------|
| List all namespaces      | "What namespaces exist?"                         | `kubernetes_tabular_query`                       |
| List pods (all/specific NS) | "What pods are running in ai-assistant?"      | `kubernetes_tabular_query`                       |
| List nodes               | "Show me the nodes"                              | `kubernetes_count` + jq                          |
| List deployments         | "What deployments are running?"                  | `kubernetes_tabular_query`                       |
| List services            | "What services exist in kube-system?"            | `kubernetes_tabular_query`                       |
| Pod diagnosis            | "Why is pod X crashing?"                         | `kubernetes_pod_logs` + `kubernetes_events`      |
| Pod log retrieval        | "Show logs of pod X"                             | `kubernetes_pod_logs`                            |
| Resource description     | "Describe the nginx deployment"                  | `kubernetes_describe`                            |
| Stuck pod diagnosis      | "Pod Y is Pending, why?"                         | `kubernetes_events` + `kubernetes_describe`      |
| ImagePullBackOff         | "Pod Z won't start"                              | `kubernetes_events`                              |
| Resource pressure        | "Why is pod stuck in Pending?"                   | `kubernetes_describe` + events                   |
| Namespace inventory      | "What's running in autoscaling namespace?"       | `kubernetes_tabular_query`                       |
| Cluster health summary   | "How is the cluster doing?"                      | Multiple tools                                   |

### ✅ YAML Generation (via direct LLM)

The plugin (not HolmesGPT) can generate Kubernetes YAML directly from the conversation:

- Deployment YAML with specific replicas, image, namespace
- Service YAML (ClusterIP, NodePort, LoadBalancer)
- ConfigMap and Secret templates
- PersistentVolumeClaim templates
- HorizontalPodAutoscaler (KEDA-compatible)
- Ingress rules

Generated YAML displays with syntax highlighting and an **Apply** button that opens an editor dialog for review before applying.

### ✅ Conversational Context

The chat maintains session history — you can ask follow-up questions like:

- "Now scale that deployment to 3 replicas"
- "What are the logs of the failing pod you just mentioned?"

### ❌ Current Limitations

| Limitation                          | Root cause                                                   |
|-------------------------------------|--------------------------------------------------------------|
| Read-only — cannot apply fixes      | HolmesGPT RBAC is `get`/`list`/`watch` only                 |
| No write to cluster via Holmes      | By design for safety                                         |
| Non-kubectl questions return empty  | SSE filter drops prose responses (by design)                 |
| `qwen2.5:7b` complex JSONPath fails | Small model corrupts advanced JSONPath expressions           |
| No GitOps awareness                 | No Flux/ArgoCD integration yet                               |
| No metrics/alerting context         | Prometheus data not fed to agent                             |
| MCP servers: desktop only           | K2s cluster deployment not yet supported                     |
| Single model active at a time       | Ollama serves one model concurrently                         |

---

## 6. Known Constraints & Limitations

### 6.1 Engineering Challenges Solved

The current 0.2.0-alpha represents significant engineering effort to tame HolmesGPT's default behavior in a small-model environment:

| Problem                                         | Fix Applied                                                             |
|-------------------------------------------------|-------------------------------------------------------------------------|
| TodoWrite autonomous investigation chains       | Custom Jinja2 prompt override via ConfigMap subPath mount               |
| Empty SSE delta chunks → pydantic crash         | Python proxy filters `delta=""` events                                  |
| MODEL_PLACEHOLDER reset on `kubectl apply`      | `Update.ps1` snapshots live MODEL, restores after apply                 |
| Nodes query returning `<none>` STATUS           | Custom `kubernetes.yaml` toolset using simple direct JSONPath           |
| Multi-tool-call loops                           | `MAX_STEPS=3` + strict system prompt                                    |
| K8s 1.35 API server rejects selectorless proxy  | Python proxy pod with real selector in `default` namespace              |
| Verbose LLM commentary in responses             | SSE delta filter keeps only kubectl rows + k8s identifiers              |

### 6.2 Model Quality vs. Size Trade-off

| Model Size    | Capability           | Memory Needed | K8s Tooling                  |
|---------------|----------------------|---------------|------------------------------|
| 3B (phi3)     | Basic text only      | ~2 GB         | ❌ Fails tool calls          |
| 7B (qwen2.5)  | Good reasoning       | ~5-6 GB       | ✅ Works with guard rails    |
| 13B (llama2)  | Better reasoning     | ~9-10 GB      | ✅ Better tool reliability   |
| 70B (llama3)  | Near-GPT4 quality    | ~45 GB        | ✅ Excellent (GPU required)  |

---

## 7. Resource Requirements

### 7.1 Minimum Requirements (CPU-only, current setup)

| Resource                  | Minimum | Recommended | Notes                                                                     |
|---------------------------|---------|-------------|---------------------------------------------------------------------------|
| RAM (kubemaster Linux VM) | 8 GB    | 16 GB       | Ollama qwen2.5:7b needs ~5-6 GB; OS + K8s need ~4 GB                     |
| Disk (kubemaster)         | 30 GB   | 50 GB       | Ollama image: 3.46 GB · Model: ~4.5 GB · PVC: 20 GB reserved             |
| CPU (kubemaster)          | 4 cores | 8 cores     | LLM inference is CPU-bound without GPU; 4 cores = ~30-60s/response       |
| Windows Host RAM          | 16 GB   | 32 GB       | K2s Linux VM + Windows processes                                          |
| Windows Host Disk         | 80 GB   | 150 GB      | Base K2s install + AI images + model weights                              |

### 7.2 Image Disk Footprint Breakdown

```
AI Assistant Stack:
  ollama/ollama:0.9.1                         3.46 GB  (runtime)
  robustadev/holmes:0.19.1                    1.34 GB  (agent)
  headlamp-plugin-ai-assistant:0.2.0-alpha    0.01 GB  (plugin)
  python:3.11-alpine                          0.06 GB  (proxy)
  ─────────────────────────────────────────────────────
  Subtotal (images):                         ~4.87 GB

Ollama model weights (qwen2.5:7b on PVC):    ~4.50 GB
─────────────────────────────────────────────────────
TOTAL AI STACK DISK:                         ~9.37 GB
```

### 7.3 Runtime Memory per Component

| Component            | Memory Request | Memory Limit | Typical Usage               |
|----------------------|----------------|--------------|-----------------------------|
| Ollama               | 512 MB         | 8 GiB        | ~5-6 GB with qwen2.5:7b loaded |
| HolmesGPT            | 256 MB         | 1 GiB        | ~300-400 MB                 |
| Headlamp plugin proxy| 64 MB          | 256 MB       | ~80 MB                      |
| Python SSE proxy     | 32 MB          | 128 MB       | ~50 MB                      |
| **Total**            | ~864 MB        | ~9.4 GiB     | ~6-7 GB typical             |

> ⚠️ **Most important constraint:** Ollama loads the entire model into RAM. A 7B model requires approximately 5-6 GB of free RAM on kubemaster. If your Linux VM has less than 8 GB RAM total, the Ollama pod will OOMKill.

### 7.4 Per-Request Latency (CPU-only, qwen2.5:7b)

| Query type                          | Typical latency | Notes                                              |
|-------------------------------------|-----------------|----------------------------------------------------|
| Simple list (pods, namespaces)      | 15-45 seconds   | Tool call + LLM processing                         |
| Pod diagnosis                       | 30-90 seconds   | Multiple tool calls in sequence                    |
| YAML generation                     | 20-60 seconds   | Pure LLM generation, no tools                      |
| Nodes query                         | 20-50 seconds   | Uses jq-based tool                                 |

> `LLM_REQUEST_TIMEOUT` is set to 600 seconds (10 minutes) to handle worst-case GPU inference latency and large outputs.

---

## 8. GPU Acceleration

### 8.1 Current State

GPU support is implemented and available via the `--gpu` flag:

```console
k2s addons enable ai-assistant --model qwen2.5:7b --gpu
```

This patches the Ollama deployment to:

- Add `nodeSelector: gpu: "true"`
- Add resource limit: `nvidia.com/gpu: "1"`

### 8.2 Requirements for GPU Mode

| Requirement          | Detail                                            |
|----------------------|---------------------------------------------------|
| Node label           | `kubectl label node <nodename> gpu=true`          |
| NVIDIA device plugin | Must be running in `kube-system` namespace        |
| NVIDIA driver        | Installed on the node OS                          |
| CUDA                 | Compatible with the driver version                |
| VRAM                 | Minimum 8 GB for 7B model · 24 GB for 13B · 80 GB for 70B |

### 8.3 Performance Gain with GPU

| Model        | CPU latency     | GPU latency  | Speedup       |
|--------------|-----------------|--------------|---------------|
| qwen2.5:7b   | 30-60 sec       | 2-5 sec      | ~10-15×       |
| llama3.1:8b  | 45-90 sec       | 3-8 sec      | ~10-12×       |
| llama3:13b   | 90-180 sec      | 5-15 sec     | ~12-15×       |
| llama3:70b   | ❌ OOM (CPU)    | 15-45 sec    | Only on GPU   |

### 8.4 K2s GPU Node Setup

K2s already has the `gpu-node` addon for Windows GPU nodes. For the AI assistant, the Linux kubemaster node needs GPU. In the current K2s architecture (Hyper-V VM for Linux):

- Hyper-V GPU-P (GPU Partitioning) is supported on Windows 11 / Server 2022+
- The `gpu-node` addon (`k2s addons enable gpu-node`) handles driver and device plugin deployment
- After enabling `gpu-node`, label the kubemaster node, then enable AI assistant with `--gpu`

```console
k2s addons enable gpu-node
kubectl label node kubemaster gpu=true
k2s addons enable ai-assistant --model qwen2.5:7b --gpu
```

### 8.5 GPU Recommendations by Use Case

| Use Case                        | Recommended GPU                    | Model                          |
|---------------------------------|------------------------------------|--------------------------------|
| Developer workstation (offline) | NVIDIA RTX 3080 (10 GB VRAM)       | qwen2.5:7b or llama3.1:8b     |
| Lab server                      | NVIDIA RTX 4090 (24 GB VRAM)       | llama3:13b                     |
| Production / enterprise         | NVIDIA A100 (80 GB VRAM)           | llama3:70b or mixtral:8x7b    |
| Edge / industrial               | NVIDIA Jetson Orin (16 GB)         | phi3:mini or qwen2.5:7b       |

---

## 9. Offline / Air-Gap Operation

### 9.1 Full Air-Gap Support Today

The AI Assistant is one of the most air-gap-friendly AI stacks available. All components ship in the K2s offline package:

| Component          | Image                                                     | Included in offline package |
|--------------------|-----------------------------------------------------------|-----------------------------|
| Ollama runtime     | `ollama/ollama:0.9.1`                                    | ✅ Yes                      |
| HolmesGPT agent    | `shsk2s.azurecr.io/holmesgpt:0.19.1`                    | ✅ Yes                      |
| Headlamp plugin    | `shsk2s.azurecr.io/headlamp-plugin-ai-assistant:0.2.0-alpha` | ✅ Yes                  |
| Python proxy       | `python:3.11-alpine`                                     | ✅ Yes (standard image)     |

```console
# Full offline enable — zero internet required
k2s addons enable ai-assistant
```

### 9.2 Model Weight Handling in Air-Gap

The only component requiring internet is model download (Ollama pulls model weights from ollama.com). For true air-gap:

**Option A — Pre-pull before air-gap:**

```console
# While internet is still available, pull the model
k2s addons enable ai-assistant --model qwen2.5:7b

# Disable without deleting model data
k2s addons disable ai-assistant --keep-model-data

# Transport the system to air-gap environment
# Re-enable (model already on PVC, no download needed)
k2s addons enable ai-assistant
```

**Option B — Manual model import:**

```console
# On internet-connected machine, export model
ollama pull qwen2.5:7b
# Copy ~/.ollama/models/ to USB/NFS

# In air-gap environment, mount into PVC
kubectl cp ./models/. ai-assistant/$(kubectl get pod -n ai-assistant -l app=ollama -o jsonpath='{.items[0].metadata.name}'):/root/.ollama/models/
```

**Option C — Include in K2s offline package:**

Add model weights to the K2s offline ZIP as part of the packaging pipeline. The model directory structure (`~/.ollama/models/blobs/`) can be pre-seeded into the PVC path (`/data/ollama`) on kubemaster during `k2s install`.

### 9.3 Air-Gap Advantages Over Cloud AI

| Aspect                    | Cloud AI (OpenAI/Azure)  | K2s Local AI                      |
|---------------------------|--------------------------|-----------------------------------|
| Internet required         | ✅ Always               | ❌ Never (after model pull)       |
| Data leaves cluster       | ✅ Always               | ❌ Never                          |
| GDPR / data sovereignty   | ⚠️ Complex              | ✅ Simple (data stays local)      |
| Cost per query            | 💰 ~$0.06/query         | 💰 $0 (electricity only)         |
| Latency                   | 0.5-3 sec (network)      | 5-60 sec (CPU) / 2-5 sec (GPU)   |
| Model updates             | Automatic (vendor)       | Manual (controlled)               |
| Regulatory compliance     | Complex                  | Simple                            |

### 9.4 Corporate Proxy / ZScaler Support

The current implementation already handles corporate proxy environments:

- `HTTPS_PROXY` / `HTTP_PROXY` env vars set on Ollama pod (for model pulls)
- ZScaler CA certificate injection via `install-ca` initContainer
- `NO_PROXY` configured for cluster-internal CIDRs
- `SSL_CERT_FILE` points to the bundle that includes the ZScaler CA

This means the addon works transparently behind enterprise MITM proxies — no manual certificate configuration required.

---

## 10. Why It Matters for K2s Users

### 10.1 Democratizing Kubernetes Operations

K2s targets both experienced DevOps engineers and domain experts who are not Kubernetes specialists (e.g., medical device engineers, imaging system operators). The AI Assistant bridges this gap:

| Without AI Assistant                        | With AI Assistant                    |
|---------------------------------------------|--------------------------------------|
| "Why is my pod crashing?"                   | "Why is my pod crashing?"            |
| ↓ Learn kubectl syntax                      | ↓ AI fetches real logs               |
| `kubectl get pods -A`                       | AI explains root cause               |
| `kubectl describe pod X`                    | AI suggests the fix                  |
| `kubectl logs X --previous`                 | User applies it manually             |
| Interpret error messages                    | Done in 30 seconds                   |
| *(15-30 minutes for new users)*             |                                      |

### 10.2 Specific K2s Scenarios Where AI Adds Value

| Scenario                        | Without AI                                            | With AI                                                          |
|---------------------------------|-------------------------------------------------------|------------------------------------------------------------------|
| Ingress not routing             | Manual inspection of ingress rules, DNS, certs        | "Why isn't my ingress working?" → AI checks rules, endpoints, cert status |
| Pod OOMKilled repeatedly        | Check limits, metrics, logs manually                  | "Pod X keeps dying" → AI reads events, identifies memory limit hit |
| KEDA not scaling                | Read KEDA docs, check ScaledObject spec               | "Why isn't autoscaling working?" → AI checks ScaledObject, metrics API |
| cert-manager cert not issuing   | Check ClusterIssuer, Challenge, Order resources       | "TLS cert won't issue" → AI inspects cert-manager resources      |
| Windows node not ready          | SSH to Windows node, check kubelet logs               | "Windows node imw1030228c is unhealthy" → AI reads node events  |
| Headlamp plugin not loading     | Check initContainer logs, plugin path                 | "AI icon missing" → AI verifies deployment spec                  |

### 10.3 Offline-First Value Proposition

For K2s's primary use cases — factory floors, medical devices, defense systems, industrial edge — cloud AI is simply not an option. K2s AI Assistant is unique in delivering:

- Full LLM capability with zero cloud dependency
- Cluster diagnostics without exposing cluster data externally
- Compliance-safe operation in ISO 13485 / IEC 62443 regulated environments
- Reproducible deployments from the K2s offline package (same images, same model)

---

## 11. Future Roadmap — Near Term

### 11.1 Write Capabilities (Guarded)

The single most requested improvement: allow the AI to apply fixes, not just diagnose.

**Proposed design:**

```
User: "Fix the broken pod"
  → AI diagnoses root cause (read-only, as today)
  → AI generates fix YAML / kubectl command
  → UI shows "Apply Fix" button with diff preview
  → User clicks Approve
  → AI executes the fix
  → AI verifies the fix worked (reads back state)
```

This requires:

- Extended HolmesGPT RBAC: add `create`, `update`, `patch` for specific resource types
- "Sandbox" mode: changes go to a staging namespace first
- Audit log of every AI-applied change
- Two-person-integrity option for regulated environments

### 11.2 Prometheus / Metrics Integration

Connect the AI to the metrics addon (already running: `metrics-server-5c554cbd59-9zl5q`):

```
# Future: AI can answer
"Is kubemaster CPU-bound right now?"
"Which pod is using the most memory?"
"Show me CPU trends over the last hour"
```

Implementation: Mount Prometheus query capabilities into HolmesGPT as a new toolset (`prometheus_query`, `prometheus_range_query`).

### 11.3 Larger Model Support

With 16 GB RAM on kubemaster:

```console
k2s addons enable ai-assistant --model llama3.1:13b
```

- Better tool-call reliability
- More nuanced diagnosis
- Longer context handling

### 11.4 Model Switching Without Restart

Currently, changing the model requires `k2s addons disable` + `k2s addons enable`. A future enhancement would expose a model-swap API that:

- Loads the new model while the old one serves requests
- Atomic cutover once the new model is ready
- No downtime

---

## 12. Future Roadmap — Flux GitOps Integration

### 12.1 Flux Plugin (Already in Repo)

The `headlamp-k8s-plugins` repository already contains a mature Flux plugin (`headlamp-k8s-plugins/flux/`, version 0.6.0) for Headlamp. This plugin adds:

- Flux CRD visualization (HelmRelease, GitRepository, Kustomization, ImageRepository)
- Reconciliation status overview
- Suspend/resume operations
- Source health monitoring

### 12.2 AI + Flux = GitOps Intelligence

By combining the AI Assistant with the Flux plugin, K2s users could get:

| Capability                  | Example interaction                                                   |
|-----------------------------|-----------------------------------------------------------------------|
| GitOps drift detection      | "Why is my HelmRelease failing to reconcile?"                         |
| Source health diagnosis     | "My GitRepository shows NotReady — what's wrong?"                    |
| Rollback guidance           | "The last Flux reconciliation broke my app — how do I roll back?"    |
| Kustomization debugging     | "Which Kustomizations have failed in the last 24 hours?"              |
| Image policy analysis       | "What image tags are being tracked by ImagePolicy X?"                 |

### 12.3 Flux MCP Server

The Flux project provides an official MCP server (`flux-operator-mcp`) that exposes Flux operations as AI tools:

```json
{
  "name": "flux-operator-mcp",
  "command": "flux-operator-mcp",
  "args": ["serve", "--kube-context", "HEADLAMP_CURRENT_CLUSTER"],
  "env": {
    "KUBECONFIG": "/path/to/kubeconfig"
  }
}
```

When configured as an MCP server in the AI Assistant settings, this gives the AI:

| Tool                          | Description                                    |
|-------------------------------|------------------------------------------------|
| `flux_get_helmrelease`        | Query HelmRelease status                       |
| `flux_suspend_kustomization`  | Pause reconciliation                           |
| `flux_resume_kustomization`   | Resume reconciliation                          |
| `flux_reconcile_source`       | Force sync from git                            |
| `flux_diff`                   | Show drift between git and cluster state       |

K2s integration path: Add Flux as a K2s addon (`k2s addons enable flux`), then configure the Flux MCP server in the AI Assistant settings panel. Both plugins are already in the same `headlamp-k8s-plugins` repository.

### 12.4 Example Workflow: AI-Assisted GitOps Incident Response

```
1. Developer pushes a broken Helm values change to git
2. Flux reconciles → HelmRelease fails
3. AI Assistant detects the failure:
   "HelmRelease myapp in namespace production failed to reconcile.
    Error: values.yaml validation failed: field 'replicas' must be > 0.
    Last successful reconciliation: 2h ago (commit abc123)."
4. AI suggests: "Revert commit abc123 or fix the values.yaml"
5. [Future write mode] AI can: git revert + push + trigger reconciliation
```

---

## 13. Future Roadmap — MCP Server Ecosystem

### 13.1 What is MCP?

**Model Context Protocol (MCP)** is an open standard (Anthropic, 2024) that lets AI assistants connect to external tools and data sources via a unified protocol. Think of it as "USB for AI tools" — any MCP server can plug into any MCP-compatible AI client.

The Headlamp AI Assistant already supports MCP servers (currently desktop-app only). The plugin settings panel has a full MCP server management UI:

- Add/remove servers
- Enable/disable individual tools
- View tool schemas
- Track usage statistics

### 13.2 MCP Servers Relevant to K2s

| MCP Server         | What it adds                    | K2s relevance                           |
|--------------------|---------------------------------|-----------------------------------------|
| flux-operator-mcp  | Flux GitOps operations          | GitOps-managed K2s clusters             |
| kubernetes-mcp     | Extended kubectl operations     | Broader K8s resource coverage           |
| prometheus-mcp     | Metrics queries + alerting      | Works with K2s monitoring addon         |
| helm-mcp           | Helm chart operations           | Addon management via Helm               |
| github-mcp         | GitHub repo access              | Pull manifests, open issues             |
| jira-mcp           | Issue tracking integration      | Auto-create incidents from alerts       |
| pagerduty-mcp      | On-call alerting                | Escalate cluster issues                 |
| datadog-mcp        | Observability platform          | Enterprise monitoring integration       |
| vault-mcp          | HashiCorp Vault secrets         | Secrets management in K2s               |
| argocd-mcp         | ArgoCD GitOps                   | Alternative to Flux                     |

### 13.3 MCP in K2s Air-Gap Environments

For air-gap compatibility, MCP servers must be:

- Pre-packaged as container images in the K2s offline package
- Exposed as in-cluster services (not external processes)
- Accessible via the K8s API server proxy (same pattern as HolmesGPT)

**Proposed K2s MCP addon structure:**

```
addons/
  mcp-servers/
    addon.manifest.yaml
    Enable.ps1
    manifests/
      prometheus-mcp.yaml
      flux-mcp.yaml
      vault-mcp.yaml
```

### 13.4 Enabling MCP for K2s Cluster Deployment

Currently MCP only works in Headlamp Desktop. To support K2s (cluster-deployed Headlamp):

1. MCP server process → containerized → deployed as K8s pod
2. AI Assistant plugin discovers MCP servers via K8s ConfigMap (instead of local process spawn)
3. Communication via in-cluster TCP (not stdio)

This is an upstream Headlamp project item. K2s can prototype this with a sidecar approach: run the MCP server as a sidecar in the HolmesGPT pod.

---

## 14. Future Roadmap — Autonomous DevOps Agent

### 14.1 Vision: The AI as an On-Call Engineer

The ultimate direction is transforming the AI Assistant from a read-only advisor into a first-responder autonomous agent that can:

```
Alert fires: "Pod crashlooping in production"
    ↓
AI agent wakes up (via alertmanager webhook)
    ↓
AI reads pod logs, events, metrics
    ↓
AI identifies root cause (OOM, bad config, broken image)
    ↓
AI drafts a fix (scale down, rollback, config patch)
    ↓
AI applies fix to staging/sandbox first
    ↓
AI validates fix worked (pod running, metrics healthy)
    ↓
[Human approval gate] for production apply
    ↓
AI applies to production
    ↓
AI writes incident summary to ticketing system
```

### 14.2 Capability Levels

| Level | Description                                                      | Status                   |
|-------|------------------------------------------------------------------|--------------------------|
| L0 — Observer             | Reads cluster state, answers questions          | ✅ Implemented today     |
| L1 — Advisor              | Diagnoses issues, suggests fixes                | ✅ Implemented today     |
| L2 — Executor             | Applies approved fixes with human confirmation  | 🔵 Near-term roadmap    |
| L3 — Autonomous responder | Acts on alerts without human input (low-risk)   | 🟡 Future (12-18 months)|
| L4 — Predictive           | Detects anomalies before they become incidents  | 🟡 Future (18-24 months)|

### 14.3 Required Capabilities for L2/L3

**Write RBAC expansion:**

```yaml
# Additional rules needed for autonomous operations
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets"]
  verbs: ["patch", "update"]    # For scaling, rollout restart
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["delete"]             # For pod restart
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create", "update"]  # For config fixes
```

**Safety constraints for autonomous mode:**

- Never delete namespaces or PVCs
- Never modify `kube-system` resources
- Never change RBAC
- All changes logged to immutable audit trail
- Rollback plan generated before every change
- Maximum impact radius: one deployment at a time

### 14.4 Integration with K2s Security Addon

The security addon (currently enabled in parallel on the same cluster) provides the security infrastructure for safe autonomous operations:

| Security component        | Role in autonomous AI                             |
|---------------------------|---------------------------------------------------|
| cert-manager              | Mutual TLS between AI agent and K8s API          |
| Keycloak                  | Identity for AI agent service account            |
| OAuth2 proxy              | Audit trail of AI-initiated API calls            |
| Linkerd (enhanced mode)   | mTLS for all AI↔K8s API traffic                  |
| ServerAuthorization policies | Limit what AI can call                        |

The combination of the security addon + ai-assistant addon creates a trusted, auditable AI agent that can operate in regulated environments.

### 14.5 HolmesGPT Roadmap Alignment

HolmesGPT (the underlying agent, maintained by Robusta) has an official roadmap including:

- **Auto-remediation:** HolmesGPT can already suggest fixes via `AskHolmesResult.remediations`
- **Runbook execution:** Holmes can execute predefined playbooks
- **Alertmanager integration:** Holmes can receive Prometheus alerts and auto-investigate
- **Slack/Teams integration:** Holmes can post findings to chat channels

K2s can benefit from these upstream features with minimal integration work.

### 14.6 Proposed Architecture for Autonomous Agent Mode

```
┌─────────────────────────────────────────────────────────────┐
│  Event Sources                                              │
│  Prometheus AlertManager  ──────┐                           │
│  K8s Admission Webhook    ──────┤                           │
│  Custom CronJob (health)  ──────┘                           │
│                                 ↓                           │
│  AI Agent Coordinator (new component)                       │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  1. Receive event                                    │   │
│  │  2. Classify severity (critical / warning / info)   │   │
│  │  3. Route to appropriate response playbook          │   │
│  │  4. Call HolmesGPT tools for diagnosis              │   │
│  │  5. Generate fix proposal                           │   │
│  │  6. Apply to sandbox → validate                     │   │
│  │  7. Request human approval (if above threshold)     │   │
│  │  8. Apply to production                             │   │
│  │  9. Write to audit log + ticketing system           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                 ↓                           │
│  Human oversight: Headlamp UI shows "Pending approvals"     │
│  + Slack/Teams notification with one-click approve/reject   │
└─────────────────────────────────────────────────────────────┘
```

---

## 15. Integration with K2s Security Addon

The security addon and ai-assistant are running simultaneously on this cluster. Here's how they interact and complement each other.

### 15.1 Current Interaction

| Security component        | How AI assistant uses it                                          |
|---------------------------|-------------------------------------------------------------------|
| cert-manager (running)    | AI can diagnose certificate issuance failures                     |
| ingress-nginx (running)   | AI can diagnose routing and TLS issues                            |
| Keycloak (if enabled)     | AI can check pod status, but cannot access user data              |

### 15.2 Security Considerations for AI Operations

| Risk                                          | Mitigation in place                                                                       |
|-----------------------------------------------|-------------------------------------------------------------------------------------------|
| AI reads sensitive ConfigMaps                 | `holmesgpt-reader` ClusterRole allows ConfigMap read — review if secrets are in ConfigMaps |
| AI reads pod logs containing PII              | Read-only access; logs stay in cluster; no external transmission                          |
| Prompt injection via pod names               | Proxy filter + strict system prompt limits tool selection to explicit kubectl calls        |
| LLM hallucination producing wrong commands    | Read-only mode means wrong answers are informational only; user must apply                |
| Model weights contain sensitive info          | Model is general-purpose (Qwen/Llama); no cluster-specific fine-tuning                   |

### 15.3 Enhanced Security Mode Recommendation

If the security addon is enabled with `--type enhanced` (Linkerd service mesh):

```console
# Annotate AI assistant pods for mTLS
kubectl annotate deployment holmesgpt-holmes -n ai-assistant \
  linkerd.io/inject=enabled

kubectl annotate deployment ollama -n ai-assistant \
  linkerd.io/inject=enabled

kubectl annotate deployment holmesgpt-proxy -n default \
  linkerd.io/inject=enabled
```

This ensures:

- All traffic between AI components is mTLS-encrypted
- Linkerd metrics show AI traffic patterns (visible in Headlamp)
- ServerAuthorization policies can restrict which namespaces AI can query

---

## 16. Quick Reference & Commands

### 16.1 Lifecycle Commands

```console
# Enable (default model)
k2s addons enable ai-assistant

# Enable with specific model
k2s addons enable ai-assistant --model llama3.1

# Enable with GPU acceleration
k2s addons enable ai-assistant --model qwen2.5:7b --gpu

# Disable (removes all resources including model data)
k2s addons disable ai-assistant

# Disable but keep downloaded models
k2s addons disable ai-assistant --keep-model-data

# Re-wire proxy and sync plugin after cluster reinstall
k2s addons update ai-assistant

# Check addon status
k2s addons status ai-assistant
```

### 16.2 Operational Diagnostics

```console
# Check all AI assistant pods
kubectl get pods -n ai-assistant
kubectl get pods -n default -l app=holmesgpt-proxy

# Ollama model list
kubectl exec -n ai-assistant deployment/ollama -- ollama list

# Pull additional model
kubectl exec -n ai-assistant deployment/ollama -- ollama pull llama3.1

# Holmes logs (tool calls + reasoning)
kubectl logs -n ai-assistant deployment/holmesgpt-holmes --tail=50

# Proxy filter logs (shows suppressed/filtered deltas)
kubectl logs -n default deployment/holmesgpt-proxy --tail=20

# Verify prompt overrides active in pod
kubectl exec -n ai-assistant deployment/holmesgpt-holmes -- \
  head -5 /app/holmes/plugins/prompts/generic_ask_conversation.jinja2

# Check live MODEL and MAX_STEPS
kubectl get deployment holmesgpt-holmes -n ai-assistant \
  -o jsonpath="{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{'\n'}{end}" \
  | Select-String -Pattern "MODEL|MAX_STEPS|API_BASE"

# Verify RBAC is read-only
kubectl get clusterrole holmesgpt-reader \
  -o jsonpath='{range .rules[*]}{.verbs}{"\n"}{end}'
```

### 16.3 Browser Access

```console
# Port-forward Headlamp
kubectl port-forward svc/headlamp -n dashboard 4466:4466

# Generate login token (8-hour session)
kubectl -n dashboard create token headlamp --duration 8h
```

Open: [http://localhost:4466/dashboard/](http://localhost:4466/dashboard/)

> **AI Assistant location:** Robot/AI icon in the top-right app bar of Headlamp.

### 16.4 Plugin Settings

Navigate to **Settings → Plugins → AI Assistant** in Headlamp:

| Setting           | Value for K2s offline                                    |
|-------------------|----------------------------------------------------------|
| Provider          | Local Models                                             |
| Base URL          | `http://ollama.ai-assistant.svc.cluster.local:11434`    |
| Model             | `qwen2.5:7b` (or whichever you enabled)                 |
| Holmes namespace  | `ai-assistant`                                           |

---

## Summary

| Dimension        | Today (v0.2.0-alpha)                  | 6 months                          | 12 months                        |
|------------------|---------------------------------------|-----------------------------------|----------------------------------|
| Queries          | kubectl list/describe/logs            | + Prometheus metrics              | + Flux/ArgoCD GitOps             |
| Actions          | Read-only advisory                    | Guarded write (human approval)    | Autonomous low-risk fixes        |
| Integrations     | Ollama + Holmes + Headlamp            | + Flux MCP + Prometheus MCP       | + Full MCP ecosystem             |
| Model quality    | 7B CPU (30-60s latency)               | 7B GPU (2-5s) or 13B CPU          | 70B GPU cluster                  |
| Security         | Read-only RBAC                        | mTLS + audit log                  | Full zero-trust agent identity   |
| Air-gap          | ✅ Full support                       | ✅ Extended offline models        | ✅ Packaged MCP servers          |

The Headlamp AI Assistant in K2s is already **production-ready** for read-only cluster intelligence in offline/air-gap regulated environments. The foundation is solid — the path to autonomous DevOps operations is an incremental engineering investment on top of a working, deployed system.

