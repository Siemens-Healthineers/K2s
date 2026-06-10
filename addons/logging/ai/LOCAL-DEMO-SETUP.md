<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# OpenSearch Semantic Search — Local Demo Setup Guide

**Target audience:** Developers and operators who want to run the AI log analysis demo locally.  
**Time to set up:** ~10 minutes  
**Prerequisites:** K2s cluster running, `ai-assistant` addon enabled with Ollama provider.

---

## Architecture Overview

```
Browser (demo.html)
    │
    │  http://localhost:9090
    ▼
kubectl port-forward svc/logging-ai-api 9090:9090
    │
    ▼
logging-ai-api pod (Python, stdlib only)
    │
    ├──► OpenSearch (logs-vector index, k-NN HNSW)
    │         ▲
    │         └── embedding pipeline (CronJob, hourly)
    │                   │
    │                   ▼
    └──► Ollama on Windows host (172.19.1.1:11434)
              └── nomic-embed-text model (768-dim)

Fluent Bit DaemonSet ──► OpenSearch (k2s index, raw logs)
```

---

## Step 1 — Verify Prerequisites

### 1a. K2s cluster is running

```console
k2s status
```

Expected: `SUCCESS  The system is running`

### 1b. ai-assistant addon is enabled (provides Windows-host Ollama)

```console
k2s addons status ai-assistant
```

Expected:
```
SUCCESS  Active provider: Ollama (offline/local mode)
SUCCESS  Ollama LLM runtime is running (Windows host, GPU-accelerated)
```

If not enabled:

```console
k2s addons enable ai-assistant --provider ollama
```

### 1c. Ollama is reachable from Windows host

```powershell
curl.exe -s http://localhost:11434/api/tags
```

Expected: JSON with `"models":[...]`

---

## Step 2 — Pull the Embedding Model

The semantic search pipeline uses `nomic-embed-text` (274 MB, CPU-capable).

```powershell
ollama pull nomic-embed-text
```

Verify:

```powershell
ollama list
```

Expected: `nomic-embed-text:latest` in the list.

---

## Step 3 — Enable the Logging Addon with AI

```console
k2s addons enable logging --enableAI
```

This single command:

| Step | What happens |
|------|-------------|
| 1 | Creates `logging` namespace and sets `vm.max_map_count=262144` |
| 2 | Deploys OpenSearch StatefulSet + PersistentVolume (5Gi) |
| 3 | Deploys OpenSearch Dashboards |
| 4 | Deploys Fluent Bit DaemonSet (Linux + Windows) |
| 5 | Imports saved index pattern into Dashboards |
| 6 | Verifies `nomic-embed-text` on Windows-host Ollama |
| 7 | Creates `logging-ai-src-root` + `logging-ai-src-app` ConfigMaps (Python source) |
| 8 | Deploys `logging-ai-api` Deployment (query API) |
| 9 | Deploys `logging-ai-pipeline` CronJob (hourly embedding) |
| 10 | Deploys `order-service` demo pod (generates realistic error logs) |
| 11 | Runs initial embedding pipeline job (populates `logs-vector` index immediately) |

> **Total time:** ~3–5 minutes depending on image pull speed.

---

## Step 4 — Verify All Pods Are Running

```powershell
kubectl get pods -n logging
kubectl get pods -n demo-app
```

Expected:

```
NAME                                     READY   STATUS      
fluent-bit-xxxxx                         1/1     Running
fluent-bit-win-xxxxx                     1/1     Running
logging-ai-api-xxxxx                     1/1     Running
opensearch-cluster-master-0              1/1     Running
opensearch-dashboards-xxxxx              1/1     Running
pipeline-initial-xxxx                    0/1     Completed   ← OK, job ran and finished

NAME              READY   STATUS
order-service     0/1     Error   ← OK, intentionally broken for demo
```

---

## Step 5 — Verify the Vector Index Has Documents

```powershell
kubectl exec -n logging statefulset/opensearch-cluster-master -- `
  curl -s http://localhost:9200/logs-vector/_count
```

Expected: `{"count":N,...}` where N > 0.

If count is 0, run the pipeline manually:

```powershell
kubectl create job --from=cronjob/logging-ai-pipeline pipeline-now -n logging
kubectl logs -n logging job/pipeline-now -f
```

Expected output:
```
[AI][Pipeline] Starting run – lookback=60m batch=50 min_level=warn
[AI][Pipeline] Run complete – processed=N stored=M
```

Clean up:

```powershell
kubectl delete job pipeline-now -n logging
```

---

## Step 6 — Start the API Port-Forward

Open a **dedicated terminal** and keep it running during the demo:

```powershell
kubectl -n logging port-forward svc/logging-ai-api 9090:9090
```

Expected:
```
Forwarding from 127.0.0.1:9090 -> 9090
Forwarding from [::1]:9090 -> 9090
```

> **Note:** Keep this terminal open. Close it only after the demo.

---

## Step 7 — Open the Demo UI

```powershell
Start-Process "C:\ws\K2s\addons\logging\ai\demo.html"
```

Or open directly in your browser:

```
file:///C:/ws/K2s/addons/logging/ai/demo.html
```

The status bar at the top should show:

| Indicator | Expected status |
|-----------|----------------|
| 🟢 API    | `API: OK` |
| 🟢 Index  | `Index: ready` |
| 🟢 Model  | `Model: nomic-embed-text` |

---

## Step 8 — Verify with a Test Search

In the demo UI, type:

```
database connection pool exhausted
```

Click **Search**. You should see results like:

```
demo-app / order-service
[DB] connection pool exhausted: 50/50 connections in use...
Score: 167.4%
```

> The score above 100% is a hybrid score combining vector similarity + keyword boost. Relative ranking between results is what matters.

---

## Demo Script (5 minutes)

### 1. Show the Problem (1 min)

Open OpenSearch Dashboards in a second tab:

```powershell
kubectl -n logging port-forward svc/opensearch-dashboards 5601:5601
```

URL: `http://localhost:5601/logging` → Discover

Show raw log lines. Try keyword search for `"out of memory"` → few or no results.  
*"Traditional search requires exact keywords — if a log says OOMKilled, searching 'out of memory' won't find it."*

### 2. Show Semantic Search (2 min)

Switch to `demo.html`.

**Query 1** — Memory issues (semantic, no exact keyword):
```
container ran out of memory and was killed
```
Expected: finds `OOMKilled` logs from real cluster history.

**Query 2** — Database problems:
```
database connection pool exhausted
```
Expected: finds `order-service` errors with scores ~1.6+.

**Query 3** — With namespace filter:
- Namespace: `demo-app`
- Query: `service degraded, requests failing`

*"We found relevant logs across namespaces — no need to know exact error strings."*

### 3. Show Filtered Search (1 min)

Use the **Pod** filter: `order-service`  
Query: `high load order processing failing`

*"Scoped to a single pod. Works the same with namespace or time range filters."*

### 4. Show the Pipeline (1 min)

In a terminal:

```powershell
kubectl logs -n logging job/pipeline-initial-xxxx --tail=4
```

Output:
```
[AI][Pipeline] Starting run – lookback=60m batch=50 min_level=warn
[AI][Pipeline] Run complete – processed=2050 stored=71
```

*"The pipeline ran at enable time to index existing logs. It runs hourly going forward — only warn/error logs are embedded, ~3.5% of total volume."*

### Key Talking Points

| Point | Detail |
|-------|--------|
| **No new infrastructure** | Reuses the existing OpenSearch k-NN plugin |
| **Runs offline** | Ollama on the Windows host — no cloud API |
| **Non-invasive** | Existing Fluent Bit → k2s index is untouched |
| **Python stdlib only** | No pip install — source mounted as ConfigMap |
| **GPU-accelerated embeddings** | Uses Windows-host RTX A2000 via Ollama |

---

## Day-Two Operations

### Manually trigger pipeline

```powershell
$jobName = "pipeline-run-$(Get-Date -Format 'yyyyMMddHHmmss')"
kubectl create job --from=cronjob/logging-ai-pipeline $jobName -n logging
kubectl wait --for=condition=complete job/$jobName -n logging --timeout=120s
kubectl logs -n logging job/$jobName
kubectl delete job $jobName -n logging
```

### Enable RAG answer generation (optional)

Requires a chat model (e.g. `qwen2.5:7b`, which is already loaded):

```powershell
kubectl patch configmap logging-ai-config -n logging `
  --type merge --patch '{"data":{"LLM_ENABLED":"true","OLLAMA_LLM_MODEL":"qwen2.5:7b"}}'
kubectl rollout restart deployment/logging-ai-api -n logging
```

With this enabled, search responses include an **AI Answer** box with a natural-language summary.

Disable again:

```powershell
kubectl patch configmap logging-ai-config -n logging `
  --type merge --patch '{"data":{"LLM_ENABLED":"false"}}'
kubectl rollout restart deployment/logging-ai-api -n logging
```

### Update source code after changes

If you modify Python files under `addons/logging/ai/`:

```powershell
$aiSourcePath = "C:\ws\K2s\addons\logging\ai"
$srcRootTmp = Join-Path $env:TEMP 'logging-ai-src-root.yaml'
$srcAppTmp  = Join-Path $env:TEMP 'logging-ai-src-app.yaml'

kubectl create configmap logging-ai-src-root `
  --from-file="main.py=$aiSourcePath\main.py" -n logging `
  --dry-run=client -o yaml | Set-Content $srcRootTmp -Encoding utf8
kubectl apply -f $srcRootTmp

$appArgs = @('create','configmap','logging-ai-src-app','-n','logging','--dry-run=client','-o','yaml')
Get-ChildItem "$aiSourcePath\app\*.py" | ForEach-Object { $appArgs += "--from-file=$($_.Name)=$($_.FullName)" }
& kubectl @appArgs | Set-Content $srcAppTmp -Encoding utf8
kubectl apply -f $srcAppTmp

kubectl rollout restart deployment/logging-ai-api -n logging
kubectl rollout status deployment/logging-ai-api -n logging --timeout=300s
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Status bar shows `API: unreachable` | Port-forward not running | `kubectl -n logging port-forward svc/logging-ai-api 9090:9090` |
| Port-forward drops after pod restart | API pod was restarted | Re-run the port-forward command |
| No search results | Vector index empty | Run pipeline manually (see Step 5) |
| Pipeline `stored=0` | Ollama unreachable from pod | Check: `kubectl exec -n logging deploy/logging-ai-api -- curl -s http://172.19.1.1:11434/api/tags` |
| Pipeline fails with `Name or service not known` | Wrong `OLLAMA_HOST` in ConfigMap | Check: `kubectl get configmap logging-ai-config -n logging -o yaml` — should show `172.19.1.1:11434` |
| `logging-ai-api` in `CrashLoopBackOff` | Source copy failed | `kubectl logs -n logging deploy/logging-ai-api -c copy-src` |
| OpenSearch not ready | Slow startup or memory | Wait; check `kubectl describe pod opensearch-cluster-master-0 -n logging` |
| `k2s addons enable logging --enableAI` fails with `AlreadyExists` | Previous partial deploy | Resources already exist — deploy AI layer manually: `kubectl apply -k addons/logging/manifests/logging/ai` then update source ConfigMaps as described above |
| `logs-vector` count stays at 0 | `nomic-embed-text` not loaded on host | `ollama pull nomic-embed-text` then re-run pipeline |

---

## Checking Status at Any Time

```powershell
# Overall addon status
k2s addons status logging

# All pods
kubectl get pods -n logging
kubectl get pods -n demo-app

# Vector index document count
kubectl exec -n logging statefulset/opensearch-cluster-master -- `
  curl -s http://localhost:9200/logs-vector/_count

# API health (requires port-forward)
curl.exe -s http://localhost:9090/healthz

# ConfigMap — active settings
kubectl get configmap logging-ai-config -n logging -o yaml

# Relay logs from most recent pipeline run
kubectl logs -n logging -l app.kubernetes.io/name=logging-ai-pipeline --tail=10
```

---

## Cleanup (after demo)

```console
k2s addons disable logging
```

This removes the entire `logging` namespace, all AI components, and the demo pod namespace.

> The `order-service` demo pod in `demo-app` namespace is removed as part of this cleanup.

---

## Configuration Reference

All settings live in the `logging-ai-config` ConfigMap:

| Key | Default | Description |
|-----|---------|-------------|
| `OLLAMA_HOST` | `http://172.19.1.1:11434` | Windows-host Ollama endpoint (bridge IP) |
| `OLLAMA_MODEL` | `nomic-embed-text` | Embedding model (768-dim) |
| `EMBEDDING_PROVIDER` | `ollama` | `ollama` or `noop` (zero vectors, no model) |
| `EMBEDDING_DIMENSION` | `768` | Must match model output |
| `SOURCE_INDEX` | `k2s` | Fluent Bit source index in OpenSearch |
| `VECTOR_INDEX` | `logs-vector` | k-NN vector index for semantic search |
| `BATCH_SIZE` | `50` | Documents per bulk-index batch |
| `PIPELINE_LOOKBACK_MINUTES` | `60` | How far back each CronJob run looks |
| `MIN_LOG_LEVEL` | `warn` | Minimum severity to embed |
| `TOP_K` | `10` | Default max results returned by API |
| `LLM_ENABLED` | `false` | Enable RAG answer generation |
| `OLLAMA_LLM_MODEL` | `llama3` | Chat model for RAG (use `qwen2.5:7b`) |

---

## Running Unit Tests

No external packages needed — only `pytest`:

```powershell
cd C:\ws\K2s\addons\logging\ai
python -m pytest tests/ -v
```

Expected: **17 passed**

