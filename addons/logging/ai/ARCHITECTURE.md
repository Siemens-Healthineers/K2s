<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI-Powered Log Analysis — Architecture & Demo Guide

## Executive Summary

The K2s logging addon now includes an **optional AI layer** that transforms raw Kubernetes logs into a **semantically searchable knowledge base**. Instead of grep-style keyword matching, operators can ask natural-language questions like *"which pods had memory issues?"* and get ranked results by meaning — even when the exact words don't match.

**Key design decisions:**
- Zero new infrastructure — reuses the existing OpenSearch instance
- Zero external dependencies at runtime — Python stdlib only, no pip install
- Ollama runs in-cluster for embeddings — no cloud API keys needed
- Existing Fluent Bit → OpenSearch pipeline is untouched
- Everything is optional — enabled via `--enableAI` flag

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        K2s Cluster (logging namespace)              │
│                                                                     │
│  ┌──────────┐    ┌──────────────────┐    ┌──────────────────────┐  │
│  │Fluent Bit│───▶│  OpenSearch       │    │  OpenSearch           │  │
│  │DaemonSet │    │  Index: k2s       │    │  Dashboards           │  │
│  │          │    │  (all raw logs)   │    │  localhost:5601       │  │
│  └──────────┘    └────────┬─────────┘    └──────────────────────┘  │
│                           │                                         │
│                    ┌──────▼──────────┐                              │
│                    │ Embedding        │   ┌────────────────┐        │
│                    │ Pipeline         │──▶│  Ollama         │        │
│                    │ (CronJob hourly) │◀──│  nomic-embed-   │        │
│                    │                  │   │  text (768-dim) │        │
│                    │ • scroll k2s idx │   └────────────────┘        │
│                    │ • filter warn/err│          ▲                   │
│                    │ • embed → vector │          │                   │
│                    │ • bulk store     │          │                   │
│                    └──────┬──────────┘          │                   │
│                           │                      │                   │
│                    ┌──────▼──────────┐          │                   │
│                    │  OpenSearch      │          │                   │
│                    │  Index:          │          │                   │
│                    │  logs-vector     │          │                   │
│                    │  (k-NN HNSW,    │          │                   │
│                    │   cosine, 768d)  │          │                   │
│                    └──────▲──────────┘          │                   │
│                           │                      │                   │
│                    ┌──────┴──────────┐          │                   │
│                    │ Query API        │──────────┘                   │
│                    │ (Deployment)     │  embed query                 │
│                    │                  │                              │
│                    │ POST /ai/logs/   │  ◀── Browser / curl         │
│                    │      search      │      localhost:9090          │
│                    │ GET  /healthz    │                              │
│                    └─────────────────┘                              │
└─────────────────────────────────────────────────────────────────────┘
```

### Data Flow

| Step | Component | What happens |
|------|-----------|-------------|
| 1 | **Fluent Bit** | Collects stdout/stderr from every pod. Ships to OpenSearch index `k2s` with fields: `log`, `@timestamp`, `k2s.pod.name`, `k2s.namespace.name`, `k2s.host.name` |
| 2 | **Embedding Pipeline** (CronJob, hourly) | Scrolls `k2s` index for logs from the last 60 minutes. Filters to only **warn/error** severity (or logs containing keywords like `exception`, `fatal`, `traceback`). Sends each log text to Ollama for embedding. Bulk-indexes the resulting `{content, embedding[768], metadata}` documents into `logs-vector` |
| 3 | **Query API** (Deployment, always-on) | Receives a natural-language query. Embeds it via Ollama. Runs a **hybrid search** on `logs-vector`: k-NN cosine similarity + BM25 keyword match. Returns ranked hits with similarity scores. Optionally generates an AI summary (RAG) via Ollama LLM |

### What makes it "semantic"?

Traditional log search requires exact keyword matches. With embeddings:

| Traditional search | Semantic search |
|---|---|
| `grep "OOMKilled"` → finds only logs with that exact word | Query: *"container ran out of memory"* → finds `OOMKilled` logs even without the keyword |
| Must know the exact error string | Understands meaning — synonyms, paraphrases, related concepts |
| No ranking by relevance | Results ranked by cosine similarity (0.0–1.0) |

---

## Components in Detail

### 1. Embedding Model: Ollama + nomic-embed-text

| Property | Value |
|---|---|
| Model | `nomic-embed-text` |
| Dimensions | 768 |
| Size | 274 MB |
| Runs on | CPU (no GPU required) |
| Deployed as | Kubernetes Deployment + Service in `logging` namespace |
| Storage | PersistentVolumeClaim (`ollama-models-pvc`, 5Gi) |

**Why this model?** It's small enough to run on CPU, produces high-quality embeddings for English text, and is open-source with a permissive license.

### 2. Vector Index: OpenSearch k-NN

| Property | Value |
|---|---|
| Index name | `logs-vector` |
| Engine | Lucene (via OpenSearch k-NN plugin) |
| Algorithm | HNSW (Hierarchical Navigable Small World) |
| Space type | Cosine similarity |
| Dimension | 768 |

**Schema:**
```json
{
  "content":   { "type": "text" },
  "embedding": { "type": "knn_vector", "dimension": 768 },
  "metadata": {
    "pod":       { "type": "keyword" },
    "namespace": { "type": "keyword" },
    "host":      { "type": "keyword" },
    "log_level": { "type": "keyword" },
    "timestamp": { "type": "date" }
  }
}
```

**Why reuse OpenSearch?** The existing OpenSearch instance already has the k-NN plugin enabled. No need for a separate vector database (Qdrant, Milvus, Weaviate) — fewer components to manage, same backup/restore, same security boundary.

### 3. Hybrid Search Strategy

The query API combines two search techniques:

```
bool.should:
  ├── knn: { embedding: <query_vector>, k: top_k }     ← semantic (weight 1.0)
  └── match: { content: <query_text>, boost: 0.3 }     ← keyword (weight 0.3)
minimum_should_match: 1
```

- **k-NN** finds logs that are semantically similar to the query (understands meaning)
- **BM25 match** catches exact keyword matches that k-NN might rank lower
- Combined scoring gives the best of both worlds

### 4. Log Filtering (Pipeline)

Not all logs are worth embedding. The pipeline filters by:

| Rule | Purpose |
|---|---|
| Level ≥ `warn` (configurable) | Skip debug/info noise |
| Contains `error`, `exception`, `traceback`, `critical`, `fatal` | Always keep regardless of level field |

This typically reduces the volume by **90%+**, keeping storage and embedding costs manageable.

### 5. Query API

| Endpoint | Method | Purpose |
|---|---|---|
| `/healthz` | GET | Liveness/readiness probe |
| `/ai/logs/search` | POST | Semantic log search |

**Request:**
```json
{
  "query": "container ran out of memory",
  "top_k": 5,
  "filters": {
    "namespace": "default",
    "time_range": { "gte": "2026-04-19T00:00:00Z" }
  }
}
```

**Response:**
```json
{
  "hits": [
    {
      "content": "OOMKilled: container exceeded memory limit",
      "score": 0.94,
      "metadata": {
        "pod": "myapp-xyz",
        "namespace": "default",
        "log_level": "error",
        "timestamp": "2026-04-19T08:30:00Z"
      }
    }
  ],
  "answer": null
}
```

### 6. Demo UI

A standalone HTML file (`addons/logging/ai/demo.html`) provides a browser-based search interface:
- Dark theme, responsive layout
- Real-time status indicators (API, index, model)
- Filters: namespace, pod, time range
- Color-coded similarity scores (green ≥90%, orange ≥80%, red <80%)
- Optional AI answer display (when RAG is enabled)

---

## Deployment Topology

```
k2s addons enable logging --enableAI
```

Creates these resources in the `logging` namespace:

| Resource | Kind | Image | Purpose |
|---|---|---|---|
| `fluent-bit` | DaemonSet | `fluent/fluent-bit` | Log collection (existing) |
| `opensearch-cluster-master-0` | StatefulSet | `opensearchproject/opensearch` | Search engine (existing) |
| `opensearch-dashboards` | Deployment | `opensearchproject/opensearch-dashboards` | Web UI (existing) |
| **`ollama`** | Deployment | `ollama/ollama:0.6.5` | Embedding model server |
| **`logging-ai-api`** | Deployment | `python:3.12-slim` | Query API |
| **`logging-ai-pipeline`** | CronJob | `python:3.12-slim` | Batch embedding pipeline |
| **`logging-ai-config`** | ConfigMap | — | All tunable parameters |
| **`logging-ai-src-root`** | ConfigMap | — | Python source (main.py) |
| **`logging-ai-src-app`** | ConfigMap | — | Python source (app/*.py) |
| **`ollama-models-pvc`** | PVC | — | Persistent model storage (5Gi) |

**No custom Docker image required** — source code is mounted via ConfigMaps.

---

## Comparison with Alternatives

| Approach | Pros | Cons |
|---|---|---|
| **This implementation** (OpenSearch k-NN + Ollama) | Reuses existing infra, no cloud dependency, runs offline, no API keys | Requires embedding model in cluster, CPU-only embedding is slower than GPU |
| Elasticsearch + external embedding API (OpenAI, Cohere) | Better embedding quality | Cloud dependency, API costs, data leaves cluster |
| Dedicated vector DB (Qdrant, Milvus) | Purpose-built for vector search | Additional infrastructure, operational overhead, separate backup/restore |
| LLM-only approach (send all logs to GPT-4) | Most flexible | Extremely expensive at scale, data privacy concerns, latency |

---

## Future Prospects

### Short-term (next release)

| Feature | Description | Effort |
|---|---|---|
| **OpenSearch Dashboards plugin** | Embed the AI search UI directly into the Dashboards sidebar — no separate port-forward needed | Medium |
| **Auto-trigger pipeline on high-severity logs** | Instead of hourly CronJob, use a Fluent Bit output plugin to trigger embedding immediately for error-level logs | Medium |
| **Ingress support** | Expose `/ai/logs/search` via the existing ingress (traefik/nginx) alongside Dashboards at `/logging/ai` | Low |

### Medium-term

| Feature | Description | Effort |
|---|---|---|
| **Anomaly detection** | Use embedding distance to detect log patterns that are unusual compared to the last 24h baseline. Alert when cosine distance from "normal" centroid exceeds threshold | High |
| **Multi-model support** | Allow swapping embedding models (e.g., `all-MiniLM-L6-v2` for lower memory, or GPU-optimized models) via ConfigMap | Low |
| **Cluster-wide RAG assistant** | A chat interface where operators ask questions about the entire cluster state, with context pulled from logs + metrics + events | High |
| **Streaming pipeline** | Replace hourly CronJob with a streaming Fluent Bit → embedding → vector index pipeline using OpenSearch's ingest pipeline with ML inference | Medium |
| **Cross-cluster search** | Federate vector search across multiple K2s clusters for centralized troubleshooting | High |

### Long-term vision

| Feature | Description |
|---|---|
| **Automated root cause analysis** | When an alert fires, automatically retrieve related logs across all namespaces, embed them, cluster by semantic similarity, and generate a root-cause report |
| **Log-to-runbook matching** | Embed existing runbooks/playbooks as vectors. When an error log appears, find the most relevant runbook and surface it to the operator |
| **Predictive alerting** | Use embedding time series to detect drift patterns that precede known failure modes, generating early warnings before actual errors |
| **Natural language monitoring queries** | Replace PromQL/OpenSearch DSL with natural language: *"Show me pods that restarted more than 3 times in the last hour due to configuration errors"* |

---

## Demo Script (5 minutes)

### Setup (before the meeting)
```powershell
# Ensure port-forwards are running
kubectl -n logging port-forward svc/opensearch-dashboards 5601:5601
kubectl -n logging port-forward svc/logging-ai-api 9090:9090
```

### Demo flow

**1. Show the problem (1 min)**
- Open OpenSearch Dashboards at `http://localhost:5601/logging`
- Navigate to Discover → show thousands of raw log lines
- Try searching for "memory pressure" — may not find `OOMKilled` logs
- *"Traditional log search requires knowing the exact keywords"*

**2. Show the solution (2 min)**
- Open `demo.html` in browser
- Type: **"container ran out of memory"**
- Click Search → results appear with 87%+ similarity scores
- *"The AI found OOMKilled logs even though we didn't use that keyword"*
- Show the metadata: pod, namespace, timestamp, severity

**3. Show filtered search (1 min)**
- Type namespace filter: `kube-system`
- Search: **"scheduler error"**
- *"We can scope semantic search to specific namespaces, pods, or time ranges"*

**4. Show the pipeline (1 min)**
- Terminal: `kubectl logs -n logging job/pipeline-now --tail=4`
- *"The pipeline runs hourly, filters to warn/error logs only, embeds them via Ollama, and stores vectors in OpenSearch"*
- Show: `processed=500, stored=13` — *"Only 2.6% of logs needed embedding — the rest was debug noise"*

### Key talking points
- **No new infrastructure** — reuses OpenSearch's built-in k-NN plugin
- **Runs offline** — Ollama serves the model locally, no cloud API
- **Incremental** — existing pipeline untouched, AI is an optional layer
- **Extensible** — swap models, add RAG, integrate with alerting

---

## Configuration Reference

| Key | Default | Description |
|---|---|---|
| `EMBEDDING_PROVIDER` | `ollama` | `ollama` or `noop` (zero vectors, for testing) |
| `EMBEDDING_DIMENSION` | `768` | Must match model output |
| `OLLAMA_HOST` | `http://ollama.logging.svc.cluster.local:11434` | Ollama service URL |
| `OLLAMA_MODEL` | `nomic-embed-text` | Embedding model |
| `BATCH_SIZE` | `50` | Documents per bulk-index request |
| `PIPELINE_LOOKBACK_MINUTES` | `60` | CronJob lookback window |
| `MIN_LOG_LEVEL` | `warn` | Minimum severity to embed |
| `TOP_K` | `10` | Default search results |
| `LLM_ENABLED` | `false` | Enable RAG answer generation |
| `OLLAMA_LLM_MODEL` | `llama3` | Chat model for RAG |

