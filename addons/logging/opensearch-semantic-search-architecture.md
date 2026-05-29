<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# OpenSearch Semantic Search - Architecture & Roadmap

**Document date:** April 21, 2026
**Status:** Prototype / Active Development
**Audience:** K2s platform engineers, AI/ML practitioners, DevOps architects, forum reviewers
**Scope:** Log & codebase search using dense vector embeddings inside the K2s cluster

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Semantic Search vs. Keyword Search - Why It Matters](#2-semantic-search-vs-keyword-search--why-it-matters)
3. [Current Architecture Overview](#3-current-architecture-overview)
4. [Component Deep-Dive](#4-component-deep-dive)
5. [Data Flow & Request Lifecycle](#5-data-flow--request-lifecycle)
6. [Embedding Pipeline](#6-embedding-pipeline)
7. [Index Design & Schema](#7-index-design--schema)
8. [Query API & Result Format](#8-query-api--result-format)
9. [Integration with the K2s AI Assistant](#9-integration-with-the-k2s-ai-assistant)
10. [Deployment Topology in K2s](#10-deployment-topology-in-k2s)
11. [Security & RBAC](#11-security--rbac)
12. [Offline / Air-Gap Operation](#12-offline--air-gap-operation)
13. [Performance Characteristics](#13-performance-characteristics)
14. [Current Limitations](#14-current-limitations)
15. [Future Scope - Near Term (3-6 months)](#15-future-scope--near-term-3-6-months)
16. [Future Scope - Medium Term (6-12 months)](#16-future-scope--medium-term-6-12-months)
17. [Future Scope - Long Term Vision (12-24 months)](#17-future-scope--long-term-vision-12-24-months)
18. [Comparison with Alternatives](#18-comparison-with-alternatives)
19. [Quick Reference](#19-quick-reference)

---

## 1. Problem Statement

K2s is a large, multi-platform Kubernetes distribution with:

- **~50,000+ lines** of Go code across 15+ CLI commands
- **~30,000+ lines** of PowerShell modules and addon scripts
- **20+ addons**, each with its own manifests, enable/disable scripts, and configuration
- Thousands of log lines per hour from pods across all namespaces

**The challenge:** Finding things - whether in source code or in logs - is hard when you do not
know the exact function name, file name, error text, or terminology used.

Examples of searches that fail with keyword search:

| What you want to find | What you actually type | Keyword result |
|---|---|---|
| Windows VM lifecycle management | "start virtual machine" | MISS: code says `New-VM`, `Start-VM` |
| Linux cluster provisioning | "setup kubeadm" | MISS: file is `setuporchestration` |
| Certificate renewal logic | "renew cert" | MISS: code calls `cert-manager` reconcile |
| DB pool exhausted | "database not responding" | MISS: log says `pq: too many clients` |
| Payment gateway down | "payment service error" | MISS: log says `x509: certificate has expired` |

**Semantic search solves this** - it finds results by *meaning*, not by exact words.

---

## 2. Semantic Search vs. Keyword Search - Why It Matters

### 2.1 How Each Works

```
Keyword Search (OpenSearch BM25 / grep):
  Query:   "database not responding"
  Index:   Inverted index on tokens -> ["database", "not", "responding"]
  Matches: Only logs/files containing those exact words
  Miss:    "pq: too many clients", "connection pool exhausted", "circuit breaker OPEN"

Semantic Search (Dense Vector / kNN):
  Query:   "database not responding"
  Step 1:  Embed query -> vector [0.12, -0.34, 0.87, ...]  (768 floats)
  Step 2:  kNN search in vector space -> nearest neighbors by cosine similarity
  Matches: All semantically similar content regardless of words used
  Finds:   "pq: too many clients", "connection pool exhausted",
           "circuit breaker OPEN", "Redis NOAUTH", "Kafka broker unavailable"
```

### 2.2 Live Demo - Log Search Comparison

The `order-service` demo pod (deployed by `k2s addons enable logging --enableAI`) generates
realistic error logs. Here is what each search mode finds:

| Query | Keyword search | Semantic search |
|---|---|---|
| "TLS issue" | Only logs with word "TLS" | TLS errors AND "connection pool exhausted" AND "circuit breaker" (all = service unreachable) |
| "database not responding" | Only logs with "database" | "pq: too many clients", "connection refused :5432", circuit breaker logs |
| "application is overloaded" | Nothing (phrase not in logs) | "GC pause 1.8s", "heap 487MB/512MB", "connection pool exhausted" |
| "payment processing failed" | Nothing | "x509 certificate expired", "Post https://payment-gateway", charge failed |
| "service cannot reach dependencies" | Nothing | Redis unavailable + DB refused + Kafka broker down |

### 2.3 Decision Matrix

| Criteria | Keyword (BM25) | Semantic (kNN) | Hybrid |
|---|---|---|---|
| Exact token match | Excellent | Good | Excellent |
| Synonym handling | None | Excellent | Excellent |
| Cross-language concepts | None | Strong | Strong |
| Query speed | Very fast (ms) | Fast (5-50ms) | Fast |
| Index build time | Fast | Moderate (embedding) | Moderate |
| Explainability | Token scores | Opaque (vector math) | Partial |
| Code/log search | Literal only | Conceptual | Best |
| Doc discovery | Literal only | Intent-based | Best |

**Conclusion:** Hybrid search (BM25 + kNN with score fusion) gives the best results for K2s
use cases.

---

## 3. Current Architecture Overview

```
+---------------------------------------------------------------------+
|  K2s Cluster  (logging addon with --enableAI)                       |
|                                                                     |
|  +-----------------+  REST :9200   +---------------------------+   |
|  |   OpenSearch    |<--------------| Embedding Service          |   |
|  |  (single node)  |               | Ollama (ai-assistant ns)   |   |
|  |  kNN index:     |               | Model: nomic-embed-text    |   |
|  |  logs-vector    |               | :11434 / REST              |   |
|  +--------+--------+               +---------------------------+   |
|           |  kNN vectors (768-dim)            ^                    |
|           |  + BM25 text index                | embed log chunks   |
|           v                                   |                    |
|  +------------------------------------------++                    |
|  |  Embedding Pipeline (CronJob, hourly)     |                     |
|  |  * Reads logs from OpenSearch k2s index   |                     |
|  |  * Filters: warn + error level logs only  |                     |
|  |  * Calls Ollama -> gets 768-dim vector    |                     |
|  |  * Bulk-indexes into logs-vector index    |                     |
|  +------------------------------------------+                     |
|                                                                     |
|  +------------------------------------------+                     |
|  |  Logging AI Query API  (:8080 / :9090)    |                     |
|  |  * POST /ai/logs/search {query, top_k}    |                     |
|  |  * Returns: {hits: [{score, log, pod}]}   |                     |
|  |  * Normal search:   OpenSearch BM25       |                     |
|  |  * Semantic search: kNN on logs-vector    |                     |
|  +------------------------------------------+                     |
|                                                                     |
|  +---------------------+   Fluent-bit collects all pod logs         |
|  |  demo-app/          |   and ships to OpenSearch k2s index        |
|  |  order-service (Err)|                                            |
|  |  (generates rich    |                                            |
|  |   error logs)       |                                            |
|  +---------------------+                                            |
+---------------------------------------------------------------------+
                              ^
         User browser (demo.html via port-forward :9090)
```

### 3.1 Technology Choices

| Component | Technology | Reason |
|---|---|---|
| Vector store | **OpenSearch 3.6.0** | Open-source, kNN native, BM25 built-in, offline-capable |
| Embedding model | **nomic-embed-text** (768-dim) | Strong on code+prose, Apache 2.0, already in Ollama |
| Embedding runtime | **Ollama** (shared from ai-assistant namespace) | No separate deployment, no extra image pull |
| Log collector | **Fluent-bit** (DaemonSet) | Lightweight, ships logs to OpenSearch automatically |
| Query API | **Python / stdlib only** | No external deps, runs on `python:3.11-alpine` |
| Demo UI | **demo.html** (plain HTML+JS) | Zero dependencies, opens in any browser |

---

## 4. Component Deep-Dive

### 4.1 OpenSearch Node

| Property | Value |
|---|---|
| Image | `docker.io/opensearchproject/opensearch:3.6.0` |
| Namespace | `logging` |
| Port | 9200 (REST) |
| Auth | Disabled (dev mode, security plugin off) |
| Plugin | `knn` (bundled since OpenSearch 2.0) |
| Indices | `k2s` (raw Fluent-bit logs), `logs-vector` (semantic vectors) |
| kNN algorithm | HNSW (Hierarchical Navigable Small World) |
| Vector dimensions | **768** (nomic-embed-text) |
| Similarity metric | Cosine similarity |
| Storage | hostPath `/logging` on kubemaster |

**Why HNSW?**

HNSW is the gold standard approximate kNN algorithm:
- Sub-linear query time: `O(log N)` instead of `O(N)` for brute-force
- Very high recall (>95%) with tunable `ef_search` parameter
- Supports incremental inserts (no full rebuild on new documents)
- Memory-mapped - can exceed RAM size

### 4.2 Embedding Service (Ollama)

| Property | Value |
|---|---|
| Model | `nomic-embed-text` |
| Vector size | **768 dimensions** |
| API endpoint | `http://ollama.ai-assistant.svc.cluster.local:11434/api/embed` |
| Inference | CPU (no GPU required) |
| Latency | ~15-30ms per log chunk |
| Throughput | ~50-100 chunks/second |
| Shared with | `ai-assistant` addon (qwen2.5:7b LLM in same Ollama instance) |

**Model selection rationale:**

```
Model                  Dims  Speed   Quality  License   Notes
-----------------------------------------------------------------
nomic-embed-text        768   **      ****    Apache2   <- CURRENT (deployed)
                                                         Strong on code + prose
                                                         Already cached in Ollama

all-mpnet-base-v2       768   **      ****    Apache2   Similar quality,
                                                         needs separate service

bge-large-en-v1.5      1024    *      *****   MIT       Best quality, 4x cost,
                                                         needs separate service

Custom fine-tuned       768   **      *****   internal  Future: tuned on K2s
                                                         log patterns
```

`nomic-embed-text` was chosen because:
1. Already loaded in the ai-assistant Ollama instance (zero extra image pull)
2. Trained on both natural language AND code - ideal for K2s mixed log workloads
3. 768-dim vectors give good quality without excessive storage cost
4. Works fully offline (model cached in `/ollama` hostPath on first ai-assistant enable)

### 4.3 Embedding Pipeline (CronJob)

The pipeline runs hourly and indexes recent logs into the vector index:

```
OpenSearch k2s index (raw Fluent-bit logs)
      |
      v  filter: warn + error only, last 60 minutes
 +-----------------------+
 | Log Fetcher           |  GET /_search with range + level filter
 +-----------+-----------+
             | raw log entries (up to BATCH_SIZE per run)
             v
 +-----------------------+
 | Text Normalizer       |  Extract: timestamp, level, message, pod, namespace
 +-----------+-----------+
             | normalized log strings
             v
 +-----------------------+
 | Ollama Embed Call     |  POST /api/embed -> float[768]
 | nomic-embed-text      |  ~20ms per log entry
 +-----------+-----------+
             | (log_text, vector, metadata)
             v
 +-----------------------+
 | OpenSearch Bulk Index |  POST /_bulk into logs-vector index
 | knn_vector field       |  + BM25 text field (same log text)
 +-----------------------+
```

**Pipeline configuration** (via ConfigMap):

| Setting | Default | Description |
|---|---|---|
| `PIPELINE_LOOKBACK_MINUTES` | 60 | How far back to fetch logs each run |
| `MIN_LOG_LEVEL` | `warn` | Minimum level to embed (warn, error, info, *) |
| `BATCH_SIZE` | 50 | Max log entries per pipeline run |
| `EMBEDDING_DIMENSION` | 768 | Must match nomic-embed-text output |

### 4.4 Logging AI Query API

The query API exposes two search modes on the same endpoint:

**Request:**
```json
POST /ai/logs/search
{
  "query": "database connection pool exhausted",
  "top_k": 10,
  "namespace": "demo-app",
  "search_type": "semantic"
}
```

**Response:**
```json
{
  "hits": [
    {
      "score": 0.89,
      "log": "ERROR: pq: too many clients - cannot acquire connection within 3s",
      "pod": "order-service",
      "namespace": "demo-app",
      "timestamp": "2026-04-21T12:46:56Z",
      "level": "error"
    }
  ],
  "total": 7,
  "search_type": "semantic",
  "took_ms": 34
}
```

---

## 5. Data Flow & Request Lifecycle

### 5.1 Log Ingestion Flow

```
Pod (any namespace)
      |
      | stdout/stderr
      v
 +--------------+
 | Fluent-bit   |  DaemonSet on every node
 | (DaemonSet)  |  Tails /var/log/containers/*.log
 +------+-------+
        |  JSON log records
        v
 +------------------+
 | OpenSearch       |  Index: k2s
 | Raw log index    |  Fields: @timestamp, log, kubernetes.pod_name,
 |                  |          kubernetes.namespace_name, level
 +------------------+
        |
        v (every hour, CronJob)
 +------------------+
 | Embedding        |  Filters warn+error logs
 | Pipeline         |  Calls Ollama -> 768-dim vector
 |                  |  Stores in logs-vector index
 +------------------+
```

### 5.2 Semantic Query Flow (real-time)

```
User query: "payment service cannot connect to gateway"
      |
      v
 Logging AI API (:8080)
      |
      +---> Embed query via Ollama nomic-embed-text  (~20ms)
      |     POST http://ollama.ai-assistant.svc:11434/api/embed
      |     -> float[768]
      |
      +---> kNN query to OpenSearch logs-vector index  (~10ms)
      |     GET /logs-vector/_search
      |     { "knn": { "vector": [...], "k": 10 } }
      |     HNSW approximate nearest neighbor lookup
      |
      +---> [normal mode] BM25 text query on k2s index  (~5ms)
      |     { "match": { "log": "payment service cannot connect..." } }
      |
      +---> Return ranked hits JSON
            Total latency: ~30-60ms
```

### 5.3 Normal vs. Semantic Search - Side by Side

```
Same query sent to both modes:
  "service cannot reach its dependencies"

Normal (BM25) result:
  0 hits   <- exact phrase not in any log

Semantic (kNN) results:
  7 hits
  [0.89] "Redis NOAUTH Authentication required"
  [0.87] "pq: too many clients - connection pool exhausted"
  [0.85] "circuit breaker OPEN after 5 consecutive failures"
  [0.83] "Kafka broker unavailable at :9092"
  [0.81] "goroutine panic: nil pointer dereference"
  [0.79] "x509: certificate has expired or is not yet valid"
  [0.76] "GC pause 1.8s - heap pressure at 487MB/512MB"
```

---

## 6. Embedding Pipeline

### 6.1 Log Level Filter

Only warn and error logs are embedded by default. This keeps the vector index focused on
actionable signals and reduces noise from routine info logs.

```
Fluent-bit log levels in k2s index:
  trace  -> skipped  (too verbose)
  debug  -> skipped  (too verbose)
  info   -> skipped  (unless MIN_LOG_LEVEL=info or *)
  warn   -> EMBEDDED into logs-vector
  error  -> EMBEDDED into logs-vector
  fatal  -> EMBEDDED into logs-vector
```

### 6.2 Metadata per Vector Document

Each vector document in `logs-vector` includes:

```json
{
  "_index": "logs-vector",
  "_source": {
    "log":        "ERROR: pq: too many clients already...",
    "vector":     [0.12, -0.34, 0.87, "...768 floats total..."],
    "pod":        "order-service",
    "namespace":  "demo-app",
    "node":       "kubemaster",
    "level":      "error",
    "timestamp":  "2026-04-21T12:46:56Z",
    "indexed_at": "2026-04-21T13:00:00Z"
  }
}
```

### 6.3 Initial Pipeline Run on Enable

When `k2s addons enable logging --enableAI` completes, Enable.ps1 immediately triggers
a one-shot pipeline job so the vector index is populated before the user opens demo.html:

```powershell
# From Enable.ps1 - runs automatically after AI components deploy
$jobName = "pipeline-initial-$(Get-Date -Format 'yyyyMMddHHmmss')"
kubectl create job --from=cronjob/logging-ai-pipeline $jobName -n logging
kubectl wait --for=condition=complete job/$jobName -n logging --timeout=120s
# Vector index is ready when this completes
```

No manual steps required - the index is ready when enable completes.

---

## 7. Index Design & Schema

### 7.1 OpenSearch Index Mapping (logs-vector)

```json
{
  "settings": {
    "index": {
      "knn": true,
      "knn.algo_param.ef_search": 512,
      "number_of_shards": 1,
      "number_of_replicas": 0
    }
  },
  "mappings": {
    "properties": {
      "log": {
        "type": "text",
        "analyzer": "english"
      },
      "vector": {
        "type": "knn_vector",
        "dimension": 768,
        "method": {
          "name": "hnsw",
          "space_type": "cosinesimil",
          "engine": "nmslib",
          "parameters": {
            "ef_construction": 512,
            "m": 16
          }
        }
      },
      "pod":        { "type": "keyword" },
      "namespace":  { "type": "keyword" },
      "node":       { "type": "keyword" },
      "level":      { "type": "keyword" },
      "timestamp":  { "type": "date" },
      "indexed_at": { "type": "date" }
    }
  }
}
```

### 7.2 HNSW Tuning Parameters

| Parameter | Current Value | Effect |
|---|---|---|
| `m` | 16 | Graph edges per node - higher = better recall, more memory |
| `ef_construction` | 512 | Build-time quality - higher = better index, slower indexing |
| `ef_search` | 512 | Query-time beam width - higher = better recall, slower query |
| `k` (top-K) | 10 | Results returned - application tunable |

---

## 8. Query API & Result Format

### 8.1 API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `POST /ai/logs/search` | POST | Semantic or normal log search |
| `GET /health` | GET | Service health check |
| `GET /ai/logs/stats` | GET | Index statistics (doc count, last pipeline run) |

### 8.2 Search Request Schema

```json
{
  "query":       "string (required)",
  "top_k":       10,
  "namespace":   "demo-app (optional filter)",
  "pod":         "order-service (optional filter)",
  "level":       "error (optional filter)",
  "search_type": "semantic | normal",
  "from_time":   "2026-04-21T00:00:00Z (optional)"
}
```

### 8.3 Search Response Schema

```json
{
  "hits": [
    {
      "score":     0.89,
      "log":       "raw log message text",
      "pod":       "order-service",
      "namespace": "demo-app",
      "node":      "kubemaster",
      "level":     "error",
      "timestamp": "2026-04-21T12:46:56Z"
    }
  ],
  "total":       7,
  "search_type": "semantic",
  "took_ms":     34
}
```

---

## 9. Integration with the K2s AI Assistant

The semantic log search complements the existing AI Assistant (Kagent + Ollama).

### 9.1 Current Integration

```
User opens demo.html (port-forward :9090)
         |
         +---> POST /ai/logs/search  { search_type: "semantic" }
         |     Logging AI API embeds query via Ollama nomic-embed-text
         |     OpenSearch kNN returns top matching log entries
         |
         +---> POST /ai/logs/search  { search_type: "normal" }
               OpenSearch BM25 returns keyword matches
               (shown side-by-side for comparison)
```

### 9.2 Future RAG Integration with Kagent

Wire the log search as a Kagent tool for incident analysis:

```yaml
# kubernetes.yaml toolset extension
- name: k2s_log_search
  description: >
    Search cluster logs semantically. Use this to find error patterns,
    understand why a pod is failing, or find similar past incidents.
    Returns logs ranked by conceptual similarity, not just keyword match.
  parameters:
    - name: query
      description: Natural language description of the issue to investigate
      type: string
    - name: namespace
      description: Filter by namespace (optional)
      type: string
```

### 9.3 Without vs. With Semantic Log Search

| Scenario | Without semantic search | With semantic search |
|---|---|---|
| "Why is order-service failing?" | Read recent pod logs literally | Find conceptually related errors across time |
| "Is this a known issue?" | No history search | Finds similar past error patterns in vector index |
| "What else is broken?" | Lists current pod states | Finds pods with semantically similar error patterns |
| "DB connection problem?" | grep for "database" | Finds pool exhaustion + circuit breaker + timeout |

---

## 10. Deployment Topology in K2s

### 10.1 Kubernetes Resources (logging --enableAI)

```
namespace: logging
+-- StatefulSet: opensearch-cluster-master   (OpenSearch 3.6.0)
+-- Deployment:  opensearch-dashboards        (OpenSearch Dashboards 3.6.0)
+-- DaemonSet:   fluent-bit                   (log collector, Linux nodes)
+-- DaemonSet:   fluent-bit-win               (log collector, Windows nodes)
+-- Deployment:  logging-ai-api               (Python query API :8080/:9090)
+-- CronJob:     logging-ai-pipeline          (hourly embedding job)
+-- Service:     opensearch-cluster-master    (:9200, ClusterIP)
+-- Service:     opensearch-dashboards        (:5601, ClusterIP)
+-- Service:     logging-ai-api               (:9090, ClusterIP)

namespace: demo-app
+-- Pod: order-service  (Status: Error - generates realistic error logs)

namespace: ai-assistant  (shared Ollama - pre-existing prerequisite)
+-- Deployment: ollama   (serves nomic-embed-text + qwen2.5:7b)
+-- Service:    ollama   (:11434, ClusterIP)
```

### 10.2 Full Stack Topology

```
+--- K2s cluster -------------------------------------------------------+
|                                                                       |
|  namespace: ai-assistant          namespace: logging                  |
|  +------------------+             +---------------------+            |
|  |      Ollama      |             |     OpenSearch      |            |
|  | nomic-embed-text |<------------| logs-vector (768-d) |            |
|  | qwen2.5:7b       |  embed API  | k2s (raw logs)      |            |
|  +------------------+             +---------------------+            |
|           ^                       |   logging-ai-api    |            |
|           |                       |   :9090             |            |
|           |                       +---------------------+            |
|           |                       |  pipeline CronJob   |            |
|           |  (embed calls)        |  (hourly indexing)  |            |
|           +----------------------------+----------------+            |
|                                                                       |
|  namespace: demo-app              namespace: logging                  |
|  +--------------------+           +--------------------+             |
|  |   order-service    |--logs-->  |    fluent-bit      |             |
|  |   (Status: Error)  | fluent-   |   (DaemonSet)      |             |
|  |   Generates:       |   bit     +--------------------+             |
|  |   - DB errors      |                                              |
|  |   - TLS errors     |                                              |
|  |   - Redis errors   |                                              |
|  |   - Kafka errors   |                                              |
|  +--------------------+                                              |
|                                                                       |
|  namespace: dashboard                                                 |
|  +----------------------------+                                       |
|  |  Headlamp + AI plugin      |                                       |
|  |  Chat: Kagent (k8s AI)    |                                       |
|  +----------------------------+                                       |
+-----------------------------------------------------------------------+
         ^                    ^
    User browser         User browser
    demo.html            Headlamp dashboard
    (port :9090)         (port :4654 or ingress)
```

### 10.3 K2s Addon Integration

```console
# Prerequisites
k2s addons enable ai-assistant     # provides Ollama with nomic-embed-text

# Enable logging with AI semantic search
k2s addons enable logging --enableAI

# Access semantic search demo (opens in browser)
kubectl -n logging port-forward svc/logging-ai-api 9090:9090
# Then open: addons/logging/ai/demo.html

# Disable (removes all AI components + demo-app namespace)
k2s addons disable logging
```

---

## 11. Security & RBAC

### 11.1 OpenSearch Security Config

| Setting | Value | Rationale |
|---|---|---|
| TLS | Disabled (dev mode) | Dev convenience; security plugin off |
| Auth | None | Cluster-internal access only via ClusterIP |
| Network | ClusterIP only | No external exposure |
| Snapshot | Disabled | Local dev; enable for prod backups |

### 11.2 Data Privacy Considerations

| Data type | Indexed into vectors? | Rationale |
|---|---|---|
| Pod logs (warn/error level) | Yes | Operational data, stays in cluster |
| Pod logs (info/debug/trace) | No | Too noisy; skipped by MIN_LOG_LEVEL |
| User query text | No | Stateless API; queries not stored |
| Source code / manifests | No (logging addon) | Separate future semantic-search addon |
| Secrets / credentials | No | Fluent-bit excludes secret volumes by default |

---

## 12. Offline / Air-Gap Operation

The semantic search stack is fully air-gap compatible - consistent with K2s's core
offline-first promise.

### 12.1 Offline Components

| Component | Image | Offline strategy |
|---|---|---|
| OpenSearch | `opensearchproject/opensearch:3.6.0` | Pre-loaded in K2s image cache |
| OpenSearch Dashboards | `opensearchproject/opensearch-dashboards:3.6.0` | Pre-loaded in K2s image cache |
| Fluent-bit | `cr.fluentbit.io/fluent/fluent-bit:5.0.2` | Pre-loaded in K2s image cache |
| Python API | `python:3.11-alpine` | Pre-loaded; source code via ConfigMap |
| nomic-embed-text model | Ollama (ai-assistant namespace) | Model cached in `/ollama` hostPath |

### 12.2 Model Caching

The `nomic-embed-text` model is downloaded once when `ai-assistant` is first enabled:

```
k2s addons enable ai-assistant
  -> Ollama init container: ollama pull nomic-embed-text
  -> Model stored in /ollama hostPath on kubemaster
  -> Survives cluster restarts (persistent hostPath)
  -> No internet access needed after this point

k2s addons enable logging --enableAI
  -> logging-ai-api connects to ai-assistant Ollama
  -> nomic-embed-text already available - no download
  -> Works fully offline from this point
```

---

## 13. Performance Characteristics

### 13.1 Indexing Performance

| Metric | Value | Notes |
|---|---|---|
| Pipeline frequency | Every 60 minutes | CronJob schedule (`0 * * * *`) |
| Logs per run | Up to 50 (BATCH_SIZE) | Warn+error only, last 60 min |
| Embedding latency | ~20ms per log entry | nomic-embed-text via Ollama CPU |
| Bulk index throughput | ~1,000 docs/sec | OpenSearch default |
| Initial pipeline time | ~30-60 seconds | Depends on log volume |
| Vector index size | ~5-10 MB per 1000 logs | 768-dim x 1000 docs |

### 13.2 Query Performance

| Metric | Value | Notes |
|---|---|---|
| Embed query latency | 15-30ms | nomic-embed-text via Ollama |
| HNSW kNN search | 5-15ms | ef_search=512 |
| BM25 text search | 2-5ms | Standard inverted index |
| Score fusion | less than 1ms | Pure math |
| Total query P95 | 30-60ms | End-to-end |
| Total query P99 | 80-120ms | Under load |

### 13.3 Resource Requirements

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Disk |
|---|---|---|---|---|---|
| OpenSearch | 500m | 2 cores | 1 GiB | 2 GiB | /logging hostPath |
| OpenSearch Dashboards | 100m | 500m | 512 MiB | 1 GiB | - |
| Logging AI API | 100m | 500m | 64 MiB | 256 MiB | - |
| Pipeline Job | 200m | 500m | 128 MiB | 256 MiB | ephemeral |
| Ollama (shared) | 200m | 4 cores | 512 MiB | 2 GiB | /ollama hostPath |

> Note: Ollama resources are shared with ai-assistant addon. No additional cost when both are enabled.

---

## 14. Current Limitations

| Limitation | Root Cause | Workaround |
|---|---|---|
| Only warn+error logs indexed | MIN_LOG_LEVEL=warn | Set `MIN_LOG_LEVEL=*` in ConfigMap to index all levels |
| 50 logs per pipeline run | BATCH_SIZE=50 | Increase `BATCH_SIZE` in ConfigMap |
| No real-time index update | CronJob is hourly | Trigger manually: `kubectl create job --from=cronjob/logging-ai-pipeline` |
| Single-node OpenSearch | Dev simplicity | StatefulSet HA for production |
| No auth on Query API | Dev convenience | Add JWT/API key for production |
| demo.html needs port-forward | No ingress configured | Add ingress rule for logging-ai-api |
| No LLM summarization yet | LLM_ENABLED=false | Enable + set `OLLAMA_LLM_MODEL=qwen2.5:7b` for RAG |
| Requires ai-assistant addon | Shared Ollama | Could be made standalone with own Ollama |

---

## 15. Future Scope - Near Term (3-6 months)

### 15.1 LLM-Powered Log Summarization (RAG)

Enable `LLM_ENABLED=true` to add natural language answers on top of semantic search:

```
Query: "why is the order service failing?"

Semantic search finds: 7 related error logs (scored 0.76 to 0.89)

LLM (qwen2.5:7b via Ollama) synthesizes answer:

  "The order-service is failing due to three cascading issues:
   1. The PostgreSQL connection pool is exhausted (too many clients)
   2. This triggered the circuit breaker (OPEN after 5 failures)
   3. Redis is also unavailable (NOAUTH error)

   Recommended action: Check DB max_connections setting and Redis
   authentication config. The circuit breaker will reset automatically
   after the DB issue is resolved."
```

### 15.2 Headlamp Log Search UI Panel

Add a dedicated Log Search panel to the Headlamp AI Assistant plugin:

```
+------------------------------------------+
|  Log Search                              |
|  +------------------------------------+  |
|  | payment service cannot connect     |  |
|  +------------------------------------+  |
|  [Semantic]  [Normal]  [Side-by-side]    |
|  Filter: namespace [demo-app v]          |
|                                          |
|  Semantic results (7):                   |
|  [0.89] order-service  error             |
|         pq: too many clients already...  |
|                                          |
|  [0.87] order-service  error             |
|         circuit breaker OPEN after 5...  |
|                                          |
|  [Ask AI to diagnose these logs ->]      |
+------------------------------------------+
```

### 15.3 Incremental Real-Time Indexing

Replace hourly CronJob with event-driven pipeline:

```
New log arrives in OpenSearch
    -> Fluent-bit webhook / OpenSearch change feed
    -> Embedding service notified immediately
    -> Log embedded and indexed within seconds
    -> Index lag: < 5 seconds (vs. up to 60 minutes today)
```

### 15.4 Better Embedding Model Options

Currently using `nomic-embed-text` (768-dim). Future upgrade candidates:

| Model | Dims | Improvement | Notes |
|---|---|---|---|
| `nomic-embed-text` | 768 | Current choice | Already deployed - no change needed |
| `bge-large-en-v1.5` | 1024 | Higher recall quality | Higher memory cost, needs own service |
| `microsoft/codebert-base` | 768 | Better code semantic understanding | Good for source code indexing |
| Custom fine-tuned | 768 | Tuned on K2s log patterns | Requires training data collection |

### 15.5 Hybrid Search Score Fusion (RRF)

Implement proper Reciprocal Rank Fusion to combine BM25 + kNN results:

```python
def rrf_score(knn_rank, bm25_rank, k=60):
    return 1/(k + knn_rank) + 1/(k + bm25_rank)
```

This eliminates manual alpha weight tuning and generally outperforms both pure modes.

---

## 16. Future Scope - Medium Term (6-12 months)

### 16.1 Multi-Source Indexing

Extend the vector index beyond pod logs:

| Content type | Indexing approach | Use case |
|---|---|---|
| K8s events | Events API -> embed | "Find scheduling failures similar to this" |
| Metrics anomalies | Time-series -> embed | "Find historical CPU spikes like current" |
| Audit logs | K8s audit -> embed | "Who changed this resource recently?" |
| Source code | Repo crawler -> embed | "Find code that handles this error pattern" |
| Documentation | MkDocs -> embed | "How do I configure this addon?" |

### 16.2 Cluster-Aware Incident Analysis

Combine semantic log search with live cluster state:

```
Query: "why is the ingress not working?"
  |
  +-- Semantic log search: TLS errors, 502 logs, cert errors
  +-- Live state:          current ingress objects, endpoint health, cert expiry
  +-- Combined answer:     "Your ingress TLS cert expired 2 days ago.
                            See: kubectl describe certificate -n ingress-nginx"
```

### 16.3 Anomaly Detection via Embedding Distance

```
Baseline: embed all "normal" info logs -> compute cluster centroids
New log arrives -> embed -> compute distance from nearest centroid
If distance > threshold -> flag as anomaly -> create K8s event / alert
```

### 16.4 OpenSearch Neural Search (Native ML)

OpenSearch 2.9+ supports native neural search with models running inside OpenSearch
via the ML Commons plugin:

```
Current architecture:               Future native ML architecture:
  External Ollama embed call  ->     OpenSearch ML Commons
  Separate embedding step     ->     Ingest pipeline auto-embeds on index
  Two API calls per query     ->     Single API call
  Separate Ollama scaling     ->     Unified OpenSearch scaling
```

---

## 17. Future Scope - Long Term Vision (12-24 months)

### 17.1 K2s Operational Memory

Semantic search over logs creates persistent operational memory:

```
Every incident generates indexed evidence:
  - Error logs -> embedded -> retrievable by concept forever
  - Fix actions -> stored with incident context
  - Resolution notes -> indexed alongside log vectors

Query anytime (even months later):
  "Have we seen this DB exhaustion before?"
  "What fixed the Redis connection issue last time?"
  "Is this payment error pattern new or recurring?"
```

### 17.2 Autonomous Incident Correlation

```
Alert fires: pod CrashLoopBackOff
    -> Kagent called (existing today)
    -> ALSO: semantic log search for similar past incidents
    -> ALSO: search K2s docs for known issue patterns
    -> Combined: root cause + historical context + fix recommendation
    -> One-click remediation suggestion
```

### 17.3 Federated Search Across K2s Deployments

For enterprises running multiple K2s clusters:

```
+--- Factory K2s ----+  +--- Lab K2s -------+  +--- Staging K2s ---+
| logging-ai-api     |  | logging-ai-api    |  | logging-ai-api    |
| :8080              |  | :8080             |  | :8080             |
+--------------------+  +-------------------+  +-------------------+
         |                       |                       |
         +-----------------------+-----------------------+
                                 |
                    +------------+------------+
                    |  Federated Log Search   |
                    |  (aggregator service)   |
                    +-------------------------+
                                 |
              "Find all clusters with similar payment errors"
              "Has this DB exhaustion pattern appeared in prod?"
```

### 17.4 Capability Maturity Timeline

| Capability | Today | 6 months | 12 months | 24 months |
|---|---|---|---|---|
| Semantic log search | Prototype (demo.html) | Production | Stable | Federated |
| Normal vs. semantic comparison | demo.html | Headlamp panel | Full UX | Advanced |
| RAG log summarization | Disabled | Alpha | Production | Multi-source |
| Real-time indexing | Hourly CronJob | Event-driven | Real-time | Real-time |
| Native OpenSearch ML | External Ollama | External | Prototype | Production |
| Anomaly detection | No | Research | Prototype | Production |
| Federated search | No | No | Design | Prototype |

---

## 18. Comparison with Alternatives

### 18.1 OpenSearch vs. Other Vector Stores

| Feature | OpenSearch | Qdrant | Weaviate | pgvector | Chroma |
|---|---|---|---|---|---|
| BM25 + kNN hybrid | Native | Sparse vectors | Native | Manual | kNN only |
| Production-ready | Enterprise | Yes | Yes | Yes | Dev-focused |
| Offline/air-gap | Full | Full | Full | Full | Full |
| K8s native | Helm chart | Helm | Helm | (postgres) | Yes |
| Dashboard UI | OpenSearch Dashboards | Web UI | Console | No | No |
| License | Apache 2.0 | Apache 2.0 | BSD-3 | PostgreSQL | Apache 2.0 |
| Already in K2s logging | Yes | No | No | No | No |
| K2s fit | Best (already deployed) | Good | Good | Needs Postgres | Dev only |

**Verdict:** OpenSearch is the right choice for K2s because it provides BM25+kNN hybrid search
natively, is already deployed as the logging backend, and fits the offline-first constraint
without additional dependencies.

### 18.2 K2s Semantic Search vs. Cloud Code Search

| Aspect | K2s Semantic Search (local) | GitHub Copilot / Cloud |
|---|---|---|
| Air-gap compatible | Yes | No |
| Data stays on-premise | Yes | No |
| Costs per query | $0 | Subscription |
| Index freshness | Hourly CronJob | Real-time |
| Custom metadata | Full control | Limited |
| Proprietary/regulated logs | Yes (never leaves cluster) | No |
| Regulatory compliance | Simple | Complex |

---

## 19. Quick Reference

### 19.1 Enable & Access

```console
# Step 1: Enable ai-assistant (provides Ollama + nomic-embed-text)
k2s addons enable ai-assistant

# Step 2: Enable logging with AI semantic search
k2s addons enable logging --enableAI

# Step 3: Port-forward the query API
kubectl -n logging port-forward svc/logging-ai-api 9090:9090

# Step 4: Open the demo UI in your browser
# File: addons/logging/ai/demo.html

# Access OpenSearch Dashboards (raw log exploration)
kubectl -n logging port-forward svc/opensearch-dashboards 5601:5601
# Open: http://localhost:5601/logging
```

### 19.2 Manual Pipeline Operations

```console
# Trigger embedding pipeline immediately (do not wait for hourly CronJob)
kubectl create job --from=cronjob/logging-ai-pipeline manual-$(Get-Date -Format yyyyMMddHHmmss) -n logging

# Check pipeline job logs
kubectl logs -n logging job/manual-<timestamp>

# Check how many vectors are indexed
curl -s http://localhost:9200/logs-vector/_count

# Check OpenSearch index stats
curl -s http://localhost:9200/_cat/indices?v

# Delete vector index and re-run pipeline from scratch
curl -X DELETE http://localhost:9200/logs-vector
kubectl create job --from=cronjob/logging-ai-pipeline rebuild-$(Get-Date -Format yyyyMMddHHmmss) -n logging
```

### 19.3 Demo Search Queries for Presentation

Use these in demo.html to demonstrate semantic search power vs. keyword search:

| Search query (type this) | Semantic finds (different words, same meaning) |
|---|---|
| `database is not responding` | `pq: too many clients`, circuit breaker OPEN, connection pool exhausted |
| `TLS issue` | `x509: certificate has expired`, payment gateway TLS handshake failed |
| `application is overloaded` | `GC pause 1.8s`, `heap 487MB/512MB`, connection pool full |
| `payment processing failed` | cert expired + `Post https://payment-gateway` charge failed logs |
| `service cannot reach dependencies` | Redis NOAUTH + DB refused + Kafka broker unavailable |
| `application crashed` | goroutine panic + nil pointer dereference + stack trace |
| `memory pressure` | heap 487MB/512MB + GC pause + OOM risk |

**Demo script:** Run each query in "Normal" mode first (shows 0 results), then switch
to "Semantic" mode (shows 5-9 results). This clearly demonstrates the value of semantic
search over keyword matching.

### 19.4 Configuration Reference

| Environment Variable | Default | Description |
|---|---|---|
| `OPENSEARCH_HOST` | `opensearch-cluster-master.logging.svc.cluster.local` | OpenSearch address |
| `OPENSEARCH_PORT` | `9200` | OpenSearch REST port |
| `OLLAMA_HOST` | `http://ollama.ai-assistant.svc.cluster.local:11434` | Ollama address |
| `OLLAMA_MODEL` | `nomic-embed-text` | Embedding model name |
| `EMBEDDING_DIMENSION` | `768` | Vector dimensions (must match model output) |
| `MIN_LOG_LEVEL` | `warn` | Minimum log level to embed (warn, error, info, *) |
| `BATCH_SIZE` | `50` | Max logs per pipeline run |
| `PIPELINE_LOOKBACK_MINUTES` | `60` | How far back pipeline fetches logs |
| `LLM_ENABLED` | `false` | Enable LLM summarization (RAG) |
| `OLLAMA_LLM_MODEL` | `llama3` | LLM model for RAG answers |
| `TOP_K` | `10` | Number of results returned per search |
| `API_PORT` | `8080` | Query API internal listen port |

---

## Summary

| Dimension | Today (demo) | 6 months | 12 months | 24 months |
|---|---|---|---|---|
| **Search type** | kNN semantic + BM25 normal | Hybrid fused (RRF) | Hybrid + anomaly | Federated |
| **UI** | demo.html (browser) | Headlamp panel | Full log UX | Multi-cluster |
| **RAG** | Disabled (LLM_ENABLED=false) | LLM alpha | Production RAG | Institutional memory |
| **Index freshness** | Hourly CronJob | Event-driven | Real-time | Real-time |
| **Embedding model** | nomic-embed-text 768-dim | nomic-embed-text | Native OpenSearch ML | Fine-tuned |
| **Log sources** | Pod logs (warn+error) | All log levels | Logs + events + metrics | Federated multi-cluster |
| **Air-gap** | Full | Full | Full | Full |
| **Query latency** | 30-60ms | 20-40ms | 15-30ms | less than 15ms |

The OpenSearch semantic search stack transforms K2s log exploration from simple keyword grep
into **meaning-based discovery** - letting engineers find related errors, understand cascading
failures, and investigate incidents by describing *what happened*, not by remembering *exact
log text*. Combined with the existing AI Assistant (Kagent + Ollama), it forms the
foundation for fully AI-driven incident response in the K2s platform.

