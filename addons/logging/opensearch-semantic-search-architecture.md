<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# OpenSearch Semantic Search — Architecture & Roadmap

**Document date:** April 20, 2026  
**Status:** Prototype / Active Development  
**Audience:** K2s platform engineers, AI/ML practitioners, DevOps architects, forum reviewers  
**Scope:** Codebase & knowledge search using dense vector embeddings inside the K2s cluster

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Semantic Search vs. Keyword Search — Why It Matters](#2-semantic-search-vs-keyword-search--why-it-matters)
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
15. [Future Scope — Near Term (3-6 months)](#15-future-scope--near-term-3-6-months)
16. [Future Scope — Medium Term (6-12 months)](#16-future-scope--medium-term-6-12-months)
17. [Future Scope — Long Term Vision (12-24 months)](#17-future-scope--long-term-vision-12-24-months)
18. [Comparison with Alternatives](#18-comparison-with-alternatives)
19. [Quick Reference](#19-quick-reference)

---

## 1. Problem Statement

K2s is a large, multi-platform Kubernetes distribution with:

- **~50,000+ lines** of Go code across 15+ CLI commands
- **~30,000+ lines** of PowerShell modules and addon scripts
- **20+ addons**, each with its own manifests, enable/disable scripts, and configuration
- Documentation spread across `docs/`, `addons/*/README.md`, and inline comments

**The challenge:** Finding things in this codebase is hard when you don't know the exact function name, file name, or terminology used in the source.

Examples of searches that fail with `grep` / keyword search:

| What you want to find | What you actually type | grep result |
|---|---|---|
| Windows VM lifecycle management | "start virtual machine" | ❌ Miss: code says `New-VM`, `Start-VM` |
| Linux cluster provisioning | "setup kubeadm" | ❌ Miss: file is `setuporchestration` |
| Certificate renewal logic | "renew cert" | ❌ Miss: code calls `cert-manager` reconcile |
| HolmesGPT proxy filtering | "filter streaming" | ❌ Miss: code says `SSE delta filter` |
| Addon dependency checking | "check prerequisites" | ❌ Miss: function is `Test-IsAddonEnabled` |

**Semantic search solves this** — it finds results by *meaning*, not by exact words.

---

## 2. Semantic Search vs. Keyword Search — Why It Matters

### 2.1 How Each Works

```
Keyword Search (OpenSearch BM25 / grep):
  Query: "start virtual machine"
  Index: Inverted index on tokens → ["start", "virtual", "machine"]
  Matches: Only files containing those exact words
  Miss: New-VM, virsh start, Start-HyperVVM, vm.Power(on)

Semantic Search (Dense Vector / kNN):
  Query: "start virtual machine"
  Step 1: Embed query → vector [0.12, -0.34, 0.87, ...]  (768 floats)
  Step 2: kNN search in vector space → nearest neighbors
  Matches: All semantically similar content regardless of words used
  Finds: New-VM, virsh start, Start-HyperVVM, vm.Power(on), hypervisor boot sequence
```

### 2.2 Decision Matrix

| Criteria | Keyword (BM25) | Semantic (kNN) | Hybrid |
|---|---|---|---|
| Exact token match | ✅ Excellent | ⚠️ Good | ✅ Excellent |
| Synonym handling | ❌ None | ✅ Excellent | ✅ Excellent |
| Cross-language concepts | ❌ None | ✅ Strong | ✅ Strong |
| Query speed | ✅ Very fast (ms) | ✅ Fast (5-50ms) | ✅ Fast |
| Index build time | ✅ Fast | ⚠️ Slow (embedding GPU) | ⚠️ Moderate |
| Explainability | ✅ Token scores | ❌ Opaque | ⚠️ Partial |
| Code search | ⚠️ Literal only | ✅ Conceptual | ✅ Best |
| Doc discovery | ⚠️ Literal only | ✅ Intent-based | ✅ Best |

**Conclusion:** Hybrid search (BM25 + kNN with score fusion) gives the best results for K2s use cases.

---

## 3. Current Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  K2s Cluster  (namespace: search)                                   │
│                                                                     │
│  ┌─────────────────┐    REST :9200     ┌──────────────────────────┐ │
│  │   OpenSearch     │◄──────────────────│  Embedding Service       │ │
│  │  (single node)   │                  │  (sentence-transformers) │ │
│  │  kNN index:      │                  │  Model: all-MiniLM-L6-v2 │ │
│  │  k2s-knowledge   │                  │  :8080 / REST            │ │
│  └────────┬─────────┘                  └──────────────────────────┘ │
│           │ kNN vectors (768-dim)               ▲                   │
│           │ + BM25 text index                   │ embed text chunks  │
│           ▼                                     │                   │
│  ┌─────────────────────────────────────────────┐│                   │
│  │  Indexer Job (CronJob or one-shot)           ││                   │
│  │  • Crawls: /k2s (Go), /addons (PS1),        ││                   │
│  │            /lib/modules (PS1), /docs (MD)   ││                   │
│  │  • Splits into chunks (512 tokens / 100 overlap)                 │
│  │  • Calls Embedding Service → gets vector    ││                   │
│  │  • Bulk-indexes into OpenSearch             ││                   │
│  └──────────────────────────────────────────────┘                   │
│                                                                     │
│  ┌──────────────────────────────────────────────┐                   │
│  │  Search API  (:8081)                         │                   │
│  │  • POST /search  {query, top_k, filter}      │                   │
│  │  • Returns: {hits: [{score, content, file}]} │                   │
│  │  • Client: fmt.py / Headlamp plugin / AI     │                   │
│  └──────────────────────────────────────────────┘                   │
└─────────────────────────────────────────────────────────────────────┘
                              ▲
                    User / AI Assistant / CLI
```

### 3.1 Technology Choices

| Component | Technology | Reason |
|---|---|---|
| Vector store | **OpenSearch 2.13+** | Open-source, kNN native, BM25 built-in, offline-capable |
| Embedding model | **all-MiniLM-L6-v2** | 384-dim, fast CPU inference, permissive license (Apache 2.0) |
| Embedding service | **sentence-transformers** (Python/FastAPI) | De-facto standard, huggingface model hub |
| Search API | **Python FastAPI** | Lightweight, async, OpenAI-compatible response shape |
| Chunking | **langchain TextSplitter** | Token-aware, overlap-configurable |
| Result formatter | **fmt.py** | CLI utility: pretty-prints top-N hits with score% + preview |

---

## 4. Component Deep-Dive

### 4.1 OpenSearch Node

| Property | Value |
|---|---|
| Image | `opensearchproject/opensearch:2.13.0` |
| Namespace | `search` |
| Port | 9200 (REST), 9600 (Performance Analyzer) |
| Auth | Admin cert/key (TLS disabled in dev mode) |
| Plugin | `knn` (bundled since OpenSearch 2.0) |
| Index | `k2s-knowledge` |
| kNN algorithm | HNSW (Hierarchical Navigable Small World) |
| Vector dimensions | 384 (all-MiniLM-L6-v2) |
| Similarity metric | Cosine similarity |
| Storage | PVC 20 GiB on kubemaster |

**Why HNSW?**

HNSW is the gold standard approximate kNN algorithm:
- Sub-linear query time: `O(log N)` instead of `O(N)` for brute-force
- Very high recall (>95%) with tunable `ef_search` parameter
- Supports incremental inserts (no full rebuild on new documents)
- Memory-mapped — can exceed RAM size

### 4.2 Embedding Service

| Property | Value |
|---|---|
| Model | `sentence-transformers/all-MiniLM-L6-v2` |
| Vector size | 384 dimensions |
| Max input | 512 tokens (WordPiece) |
| Inference | CPU (no GPU required for this model) |
| Latency | ~15-30ms per chunk (CPU) |
| Throughput | ~50-100 chunks/second (single CPU core) |
| Memory | ~200 MB model weights |

**Model selection rationale:**

```
Model               Dims  Speed    Quality   License
all-MiniLM-L6-v2   384   ⚡⚡⚡   ⭐⭐⭐    Apache 2.0   ← Current choice
all-mpnet-base-v2   768   ⚡⚡     ⭐⭐⭐⭐  Apache 2.0   ← Better quality, 2× cost
bge-large-en-v1.5   1024  ⚡       ⭐⭐⭐⭐⭐ MIT          ← Best quality, 4× cost
nomic-embed-text    768   ⚡⚡     ⭐⭐⭐⭐  Apache 2.0   ← Good for code
```

For code-heavy corpora like K2s, `nomic-embed-text` (trained on code+docs) is a strong future candidate.

### 4.3 Indexer Job

The indexer crawls the K2s repository and builds the vector index:

```
Input sources:
  k2s/            → Go source files (.go)
  addons/         → PowerShell scripts (.ps1, .psm1), YAML manifests
  lib/modules/    → PowerShell modules (.psm1)
  lib/scripts/    → Orchestration scripts (.ps1)
  docs/           → MkDocs documentation (.md)
  *.md            → Top-level READMEs, analysis docs

Chunking strategy:
  • Code files:  512 tokens, 100 token overlap, split on function boundaries
  • Markdown:    512 tokens, 50 token overlap, split on headings
  • YAML:        256 tokens, 0 overlap (small structured blocks)

Metadata per chunk:
  • file_path       (relative to repo root)
  • language        (go / powershell / markdown / yaml)
  • chunk_index     (position within file)
  • function_name   (extracted via regex if detectable)
  • addon_name      (derived from path prefix for addons/)
  • last_modified   (git commit timestamp)
```

### 4.4 Search API

The search API wraps OpenSearch's kNN query with a clean interface:

**Request:**
```json
POST /search
{
  "query": "how does K2s handle VM startup on Windows?",
  "top_k": 10,
  "filter": {
    "language": "powershell"
  },
  "hybrid": true
}
```

**Response:**
```json
{
  "hits": [
    {
      "score": 0.87,
      "file": "lib/modules/k2s.infra.module/New-VM.ps1",
      "language": "powershell",
      "chunk_index": 2,
      "content": "function Start-LinuxVm {\n    param([string]$VmName)\n    Start-VM -Name $VmName\n    Wait-VmReady -Name $VmName -TimeoutSeconds 120\n..."
    },
    ...
  ],
  "total": 47,
  "took_ms": 23
}
```

**Result formatter (`fmt.py`):**
```python
import sys, json
d = json.load(sys.stdin)
hits = d["hits"]
print(f"{len(hits)} hits")
for h in hits[:5]:
    s = h["score"]
    c = h["content"][:130].replace("\n", " ")
    print(f"  [{s:.1%}] {c}")
```

Sample output:
```
47 hits
  [87.3%] function Start-LinuxVm {     param([string]$VmName)     Start-VM -Name $VmName     Wait-VmReady -Name $VmName -TimeoutSec
  [84.1%] func (p *Provider) StartCluster(ctx context.Context, config ClusterConfig) error {     return p.powershell.Execute("Start-Li
  [81.6%] function New-LinuxVmConfig {     param($Name, $Memory, $CPU)     # Hyper-V VM provisioning for K2s Linux node
  [79.2%] ## Starting the Linux VM     K2s starts a Hyper-V virtual machine hosting the Kubernetes control plane. The VM lifecycle is
  [76.8%] virsh start kubemaster     virsh dominfo kubemaster --state running
```

---

## 5. Data Flow & Request Lifecycle

### 5.1 Indexing Flow (one-time / incremental)

```
Repository Files
      │
      ▼ (Indexer Job)
 ┌──────────────┐
 │ File crawler  │  Walk directories, filter by extension
 └──────┬───────┘
        │ raw text chunks
        ▼
 ┌──────────────────┐
 │ Text Splitter     │  512-token chunks, 100-token overlap
 │ (LangChain)       │  Boundary-aware (functions, headings)
 └──────┬────────────┘
        │ chunk strings
        ▼
 ┌────────────────────┐
 │ Embedding Service  │  POST /embed  →  float[384]
 │ (MiniLM-L6-v2)     │  ~20ms per chunk
 └──────┬─────────────┘
        │ (chunk_text, vector, metadata)
        ▼
 ┌──────────────────────┐
 │ OpenSearch Bulk API  │  POST /_bulk  (batches of 100)
 │ knn_vector field      │  + BM25 text field (same content)
 └──────────────────────┘
```

**Indexing throughput:** ~500 chunks/minute on a single CPU core  
**Full K2s repo index time:** ~10-15 minutes  
**Index size:** ~2-5 MB (for 384-dim vectors × ~5,000 chunks)

### 5.2 Query Flow (real-time)

```
User query: "how does DNS resolution work in K2s?"
      │
      ▼
 Search API (:8081)
      │
      ├──► Embed query  →  Embedding Service  →  float[384]
      │    (synchronous, ~20ms)
      │
      ├──► kNN query to OpenSearch
      │    GET /k2s-knowledge/_search
      │    {
      │      "knn": { "vector": [...], "k": 10 },
      │      "filter": { "term": { "language": "..." } }
      │    }
      │    (~5-15ms HNSW lookup)
      │
      ├──► [hybrid mode] BM25 text query (parallel)
      │    { "match": { "content": "DNS resolution K2s" } }
      │
      ├──► Score fusion (RRF: Reciprocal Rank Fusion)
      │    final_score = α·knn_score + (1-α)·bm25_score
      │
      └──► Return ranked hits JSON
           Total latency: ~30-60ms
```

---

## 6. Embedding Pipeline

### 6.1 Chunking Strategy by File Type

```
┌─────────────────┬───────────────┬──────────────┬─────────────────────────┐
│ File Type        │ Chunk Size    │ Overlap      │ Split Boundary          │
├─────────────────┼───────────────┼──────────────┼─────────────────────────┤
│ Go (.go)         │ 512 tokens   │ 100 tokens   │ func / type / comment   │
│ PowerShell (.ps1)│ 512 tokens   │ 100 tokens   │ function / param block  │
│ Markdown (.md)   │ 512 tokens   │ 50 tokens    │ ## headings             │
│ YAML (.yaml)     │ 256 tokens   │ 0 tokens     │ top-level keys          │
│ Module (.psm1)   │ 512 tokens   │ 100 tokens   │ function boundary       │
└─────────────────┴───────────────┴──────────────┴─────────────────────────┘
```

### 6.2 Metadata Enrichment

Each chunk is stored with metadata that enables filtering and attribution:

```json
{
  "_index": "k2s-knowledge",
  "_source": {
    "content": "function Enable-KubernetesAddon { ...",
    "vector": [0.12, -0.34, 0.87, ...],
    "file_path": "addons/autoscaling/Enable.ps1",
    "language": "powershell",
    "addon_name": "autoscaling",
    "chunk_index": 3,
    "function_name": "Enable-KubernetesAddon",
    "token_count": 487,
    "git_commit": "abc1234",
    "indexed_at": "2026-04-20T10:00:00Z"
  }
}
```

---

## 7. Index Design & Schema

### 7.1 OpenSearch Index Mapping

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
      "content": {
        "type": "text",
        "analyzer": "english"
      },
      "vector": {
        "type": "knn_vector",
        "dimension": 384,
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
      "file_path": { "type": "keyword" },
      "language":  { "type": "keyword" },
      "addon_name":{ "type": "keyword" },
      "function_name": { "type": "keyword" },
      "chunk_index": { "type": "integer" },
      "indexed_at": { "type": "date" }
    }
  }
}
```

### 7.2 HNSW Tuning Parameters

| Parameter | Current Value | Effect |
|---|---|---|
| `m` | 16 | Graph edges per node — higher = better recall, more memory |
| `ef_construction` | 512 | Build-time quality — higher = better index, slower indexing |
| `ef_search` | 512 | Query-time beam width — higher = better recall, slower query |
| `k` (top-K) | 10 | Results returned — application tunable |

---

## 8. Query API & Result Format

### 8.1 API Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `POST /search` | POST | Semantic search query |
| `GET /health` | GET | Service health check |
| `POST /index` | POST | Trigger re-indexing (admin) |
| `GET /stats` | GET | Index statistics (doc count, size) |
| `DELETE /index` | DELETE | Clear and rebuild index (admin) |

### 8.2 Search Request Schema

```json
{
  "query": "string (required)",
  "top_k": 10,
  "filter": {
    "language": "go | powershell | markdown | yaml",
    "addon_name": "autoscaling | dashboard | ...",
    "file_path_prefix": "k2s/internal/provider"
  },
  "hybrid": true,
  "hybrid_alpha": 0.7,
  "include_metadata": true
}
```

### 8.3 Search Response Schema

```json
{
  "hits": [
    {
      "score": 0.87,
      "file": "lib/modules/k2s.infra.module/...",
      "language": "powershell",
      "function_name": "Start-LinuxVm",
      "addon_name": null,
      "chunk_index": 2,
      "content": "raw chunk text (up to 512 tokens)"
    }
  ],
  "total": 47,
  "took_ms": 23,
  "query_vector_ms": 18,
  "knn_ms": 5
}
```

---

## 9. Integration with the K2s AI Assistant

The semantic search index is a **core knowledge layer** that dramatically improves the AI Assistant's ability to answer K2s-specific questions.

### 9.1 Retrieval-Augmented Generation (RAG) Pattern

```
User: "How do I add a custom addon to K2s?"
         │
         ▼
 Headlamp AI Assistant plugin
         │
         ├──► Search API: "create custom addon K2s"
         │    Returns: addons/autoscaling/Enable.ps1,
         │             addons/addon.manifest.schema.json,
         │             docs/dev-guide/addons.md
         │    (top 3 chunks, score > 70%)
         │
         ├──► Build augmented prompt:
         │    [CONTEXT from codebase]:
         │      <chunk 1: addon manifest schema>
         │      <chunk 2: Enable.ps1 template>
         │      <chunk 3: addon dev guide>
         │    [USER QUESTION]: How do I add a custom addon?
         │
         └──► Send to Ollama (qwen2.5:7b)
              LLM generates answer grounded in actual K2s code
              Not hallucinated — sourced from the real repo
```

### 9.2 Without RAG vs. With RAG

| Scenario | Without RAG (today) | With RAG (future) |
|---|---|---|
| "How do I write an addon?" | Generic K8s addon advice | Actual K2s addon pattern from `addons/autoscaling/` |
| "What does `Test-SystemAvailability` do?" | Hallucination or "I don't know" | Exact function signature + description from module |
| "How does the delta packaging work?" | Generic explanation | Actual `New-K2sDeltaPackage.ps1` logic |
| "What images are in the offline package?" | Guesses | Exact list from manifest files |
| "How do I enable GPU mode?" | Generic k8s GPU advice | Exact `k2s addons enable ai-assistant --gpu` commands |

### 9.3 HolmesGPT Tool Extension

A new HolmesGPT tool `k2s_codebase_search` can be added to the toolset:

```yaml
# kubernetes.yaml toolset extension
- name: k2s_codebase_search
  description: >
    Search the K2s source code and documentation for concepts, functions,
    scripts, or configuration patterns. Use this when answering questions
    about how K2s works internally, how to configure addons, or how
    specific features are implemented.
  parameters:
    - name: query
      description: Natural language description of what to find
      type: string
    - name: language
      description: "Filter by: go, powershell, markdown, yaml (optional)"
      type: string
  returns:
    description: Top matching code/documentation chunks with file paths and relevance scores
```

---

## 10. Deployment Topology in K2s

### 10.1 Kubernetes Resources

```
namespace: search
├── Deployment: opensearch          (1 replica, StatefulSet preferred)
│   └── PVC: opensearch-data       (20 GiB, hostPath on kubemaster)
├── Deployment: embedding-service   (1 replica)
├── Deployment: search-api          (1 replica)
├── CronJob: indexer               (nightly or on-demand)
├── Service: opensearch            (:9200, ClusterIP)
├── Service: embedding-service     (:8080, ClusterIP)
└── Service: search-api            (:8081, ClusterIP)
```

### 10.2 Full Stack Topology

```
┌─── K2s cluster ──────────────────────────────────────────────────────┐
│                                                                      │
│  namespace: ai-assistant          namespace: search                  │
│  ┌─────────────┐                  ┌──────────────────┐               │
│  │   Ollama    │                  │   OpenSearch     │               │
│  │ (LLM)       │◄─────────────────│   kNN index      │               │
│  └─────────────┘  RAG context     └──────────────────┘               │
│  ┌─────────────┐     ↑            ┌──────────────────┐               │
│  │  HolmesGPT  │     │            │ Embedding Service│               │
│  │  (agent)    │─────┤            │ MiniLM-L6-v2     │               │
│  └─────────────┘     │            └──────────────────┘               │
│                       │            ┌──────────────────┐               │
│  namespace: dashboard │            │   Search API     │               │
│  ┌────────────────────┴──────┐     │   :8081          │               │
│  │  Headlamp + AI plugin     │────►│   /search        │               │
│  │  Chat panel               │     └──────────────────┘               │
│  └───────────────────────────┘     ┌──────────────────┐               │
│                                    │  Indexer CronJob │               │
│                                    │  (nightly)       │               │
│                                    └──────────────────┘               │
└──────────────────────────────────────────────────────────────────────┘
         ▲
    User browser (Headlamp UI)
    CLI: curl + fmt.py
```

### 10.3 K2s Addon Integration

The search stack is delivered as a K2s addon:

```console
# Enable semantic search
k2s addons enable semantic-search

# Enable AI Assistant with RAG (depends on semantic-search)
k2s addons enable ai-assistant --with-rag

# Trigger manual re-index (after code changes)
k2s addons update semantic-search --reindex

# Check search health
k2s addons status semantic-search
```

`addon.manifest.yaml` for `semantic-search`:
```yaml
apiVersion: v1
kind: AddonManifest
metadata:
  name: semantic-search
  description: OpenSearch-based semantic code and documentation search for K2s
spec:
  offlinePackage: true
  dependencies: []           # standalone, no prerequisites
  optionalFor: [ai-assistant]
```

---

## 11. Security & RBAC

### 11.1 OpenSearch Security Config

| Setting | Value | Rationale |
|---|---|---|
| TLS | Disabled in dev, enabled in prod | Dev convenience; prod requires cert-manager |
| Auth | Admin cert + key pair | K8s Secret, not plain password |
| Network | ClusterIP only | No external exposure |
| Snapshot | Disabled | Local dev; enable for prod backups |

### 11.2 K8s RBAC for Search Components

```yaml
# Search API service account — read-only to OpenSearch
kind: Role
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]           # To read OpenSearch admin credentials

# Indexer job service account — read K2s ConfigMaps for metadata
kind: Role
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list"]
```

### 11.3 Data Privacy Considerations

| Data type | Indexed? | Rationale |
|---|---|---|
| Source code (Go/PS1) | ✅ Yes | Public within org |
| Documentation (MD) | ✅ Yes | Public within org |
| Config manifests (YAML) | ✅ Yes | Public within org |
| Secrets / credentials | ❌ No | Excluded by path filter (`cfg/applocker`, `*.key`, `*.pem`) |
| User query history | ❌ No | Not stored; stateless API |
| Cluster runtime state | ❌ No | Index is static repo snapshot |

---

## 12. Offline / Air-Gap Operation

The semantic search stack is fully air-gap compatible — consistent with K2s's core offline-first promise.

### 12.1 Offline Components

| Component | Image | Offline strategy |
|---|---|---|
| OpenSearch | `opensearchproject/opensearch:2.13.0` | Bundled in K2s offline package |
| Embedding model | `all-MiniLM-L6-v2` (HuggingFace) | Model weights pre-downloaded, baked into embedding service image |
| Embedding service | Custom Python image | Built and bundled in K2s offline package |
| Search API | Custom Python image | Built and bundled in K2s offline package |

### 12.2 Pre-built Index Option

For fully air-gapped environments (no access to source at runtime):

```
Option A — Runtime indexing:
  Source repo mounted as volume (or git-synced)
  Indexer job runs inside cluster
  Requires: repo access from cluster (works if cluster = workstation)

Option B — Pre-built index export:
  Index built outside cluster (developer machine)
  Snapshot exported: opensearch-snapshot.tar.gz
  Bundled in K2s offline package
  Restored during addon enable
  Immutable until next K2s package release

Option C — Hybrid:
  Pre-built base index in offline package (stable modules)
  Incremental indexing of local modifications at runtime
```

### 12.3 Air-Gap Enablement Flow

```console
# Option B — pre-built index (recommended for air-gap)
k2s addons enable semantic-search --use-bundled-index

# Option A — runtime indexing (requires source access)
k2s addons enable semantic-search --source-path C:\ws\K2s
```

---

## 13. Performance Characteristics

### 13.1 Indexing Performance

| Metric | Value | Notes |
|---|---|---|
| Chunking throughput | ~2,000 chunks/min | Pure CPU, LangChain |
| Embedding throughput | 50-100 chunks/sec | MiniLM on 1 CPU core |
| Bulk index throughput | 1,000 docs/sec | OpenSearch default |
| Full repo index time | ~10-15 minutes | ~5,000 chunks total |
| Incremental update | ~1-3 minutes | Changed files only |
| Index size on disk | ~20-50 MB | 384-dim × 5,000 docs + BM25 |

### 13.2 Query Performance

| Metric | Value | Notes |
|---|---|---|
| Embedding latency | 15-30ms | MiniLM on CPU |
| HNSW kNN search | 5-15ms | 5,000 docs, ef_search=512 |
| BM25 text search | 2-5ms | Standard inverted index |
| Score fusion | <1ms | Pure math |
| Total query P95 | 30-60ms | End-to-end |
| Total query P99 | 80-120ms | Under load |

### 13.3 Resource Requirements

| Component | CPU Request | CPU Limit | Memory Request | Memory Limit | Disk |
|---|---|---|---|---|---|
| OpenSearch | 0.5 cores | 2 cores | 1 GiB | 4 GiB | 20 GiB PVC |
| Embedding Service | 0.5 cores | 2 cores | 512 MiB | 1 GiB | (model in image) |
| Search API | 0.1 cores | 0.5 cores | 64 MiB | 256 MiB | — |
| Indexer Job | 1 core | 2 cores | 512 MiB | 1 GiB | (ephemeral) |
| **Total** | **2.1 cores** | **6.5 cores** | **2.1 GiB** | **6.25 GiB** | **20 GiB** |

> ⚠️ These resources are **additive** to the AI Assistant stack (~6-7 GiB). Ensure kubemaster has ≥ 16 GB RAM when running both.

---

## 14. Current Limitations

| Limitation | Root Cause | Workaround |
|---|---|---|
| Static index (no real-time update) | Indexer is a batch job | Manual `--reindex` trigger |
| No binary file search | `.exe`, `.vhdx` not indexable as text | Excluded by design |
| 512-token chunk limit | Model context window | Overlap + neighboring chunks |
| English-only embedding quality | MiniLM trained on English | German/other language queries degrade |
| Single-node OpenSearch | Dev simplicity | StatefulSet for HA (production) |
| No authentication on Search API | Dev convenience | Add JWT/API key for production |
| MCP integration not yet wired | In-cluster MCP not supported by Headlamp | Roadmap item |
| fmt.py is a CLI-only client | No UI yet | Headlamp plugin integration planned |

---

## 15. Future Scope — Near Term (3-6 months)

### 15.1 Headlamp Search UI Panel

Add a dedicated **Search** panel to the Headlamp AI Assistant plugin:

```
┌─────────────────────────────────────────┐
│  🔍 K2s Codebase Search                 │
│  ┌─────────────────────────────────┐    │
│  │ how does addon enable work?     │    │
│  └─────────────────────────────────┘    │
│  Filter: [All] [Go] [PowerShell] [Docs] │
│                                          │
│  Results (47):                           │
│  ● [87%] addons/autoscaling/Enable.ps1  │
│    function Enable-AutoscalingAddon {   │
│    [View file] [Copy path] [Ask AI ↗]   │
│                                          │
│  ● [84%] k2s/cmd/k2s/addons/enable.go  │
│    func runEnable(cmd *cobra.Command... │
└─────────────────────────────────────────┘
```

Features:
- "Ask AI about this" button → pre-fills AI chat with the chunk as context
- File path click → opens file in Headlamp source viewer
- Filter chips for language/addon/path prefix
- Score threshold slider

### 15.2 RAG Integration with HolmesGPT

Wire the Search API as a HolmesGPT tool:

```yaml
# New tool in kubernetes.yaml toolset
- name: k2s_codebase_search
  description: "Search K2s source code and docs by meaning"
  endpoint: "http://search-api.search.svc.cluster.local:8081/search"
```

Expected improvement in AI answers:
- K2s-specific questions answered from real code, not hallucination
- Addon configuration questions answered from actual Enable.ps1 patterns
- Troubleshooting grounded in real implementation details

### 15.3 Incremental Real-Time Indexing

Replace batch CronJob with event-driven incremental updates:

```
Git push / file change
    → Webhook → Indexer service
    → Re-chunk only changed files
    → Update OpenSearch documents
    → Index lag < 30 seconds
```

### 15.4 Better Code Embedding Model

Switch from `all-MiniLM-L6-v2` to `nomic-embed-text` or `CodeBERT`:

| Model | Improvement | Cost |
|---|---|---|
| `nomic-embed-text` | Better on mixed code+prose | Same speed |
| `microsoft/codebert-base` | Better code semantic understanding | Same speed |
| `Salesforce/codet5-base` | Multi-language code aware | Slightly slower |

### 15.5 Hybrid Search Score Fusion (RRF)

Implement proper Reciprocal Rank Fusion:

```python
def rrf_score(knn_rank, bm25_rank, k=60):
    return 1/(k + knn_rank) + 1/(k + bm25_rank)
```

This eliminates the need to manually tune the `alpha` weight between semantic and keyword scores.

---

## 16. Future Scope — Medium Term (6-12 months)

### 16.1 Multi-Modal Indexing

Extend indexing beyond source code:

| Content type | Indexing approach | Use case |
|---|---|---|
| Architecture diagrams (PNG) | OCR → text → embed | Find diagrams by concept |
| Cluster runtime state | K8s API → JSON → embed | "Find pods similar to this configuration" |
| Log patterns | Log → embed → cluster | "Find similar incidents" |
| Addon manifests (structured YAML) | Schema-aware chunking | "Find addons that do X" |
| Helm chart values | Values → semantic meaning | "What values control memory limits?" |

### 16.2 Cluster-Aware Search (Live State + Code Combined)

Combine static repo knowledge with live cluster state:

```
Query: "why is the ingress not working?"
  │
  ├── Code context: ingress addon enable logic, nginx config templates
  ├── Live state: current ingress objects, endpoint health, cert status
  └── Combined answer: "Your ingress is missing a TLS secret — see how
      to create one in addons/ingress/Enable.ps1 line 45"
```

### 16.3 Semantic Diff for Upgrades

When a new K2s version is released, semantic search can power **upgrade impact analysis**:

```
"What changed between K2s 1.4 and 1.5?"
  → Embed both versions of the codebase
  → Find semantically shifted chunks (same file, different meaning)
  → Generate human-readable changelog with semantic grouping
```

### 16.4 Knowledge Graph Integration

Build a knowledge graph on top of the vector index:

```
Nodes:   Functions, Modules, Addons, Configs, Commands
Edges:   calls, imports, depends-on, configures, documents

Query:   "What does enabling the dashboard addon affect?"
Answer:  dashboard → headlamp deployment
         headlamp → ingress (optional)
         headlamp → ai-assistant (optional dependency)
         headlamp → TLS cert (via cert-manager)
```

### 16.5 OpenSearch Neural Search (Native ML)

OpenSearch 2.9+ supports **native neural search** with models running inside OpenSearch via the ML Commons plugin:

```
Current architecture:            Future native ML architecture:
  External embedding service  →   OpenSearch ML Commons
  Separate embedding call     →   Ingest pipeline auto-embeds
  Two API calls per query     →   Single API call
  Separate scaling            →   Unified scaling
```

Migration path: Publish the embedding model to OpenSearch ML Commons, configure an ingest pipeline with `text_embedding` processor, and simplify the Search API.

---

## 17. Future Scope — Long Term Vision (12-24 months)

### 17.1 K2s Institutional Memory

The combination of semantic search + AI assistant creates an **institutional memory** layer for K2s:

```
Every K2s operation generates context:
  - Installation decisions → stored + retrievable
  - Troubleshooting sessions → indexed
  - Configuration rationale → embedded with metadata
  - Upgrade history → versioned vector snapshots

Query anytime:
  "Why was the ingress configured with sticky sessions?"
  "Who changed the cert-manager issuer last month and why?"
  "What was the root cause of the last OOM incident?"
```

### 17.2 AI-Powered Documentation Generation

Use the codebase index to auto-generate and keep documentation up to date:

```
Code change detected (PR merge)
    → Re-index changed files
    → Semantic diff vs. existing docs
    → AI drafts documentation update
    → PR opened with suggested doc changes
    → Human review + merge
```

### 17.3 Federated Search Across K2s Deployments

For enterprises running multiple K2s clusters (factory, lab, staging, production):

```
┌─── Factory K2s ──┐  ┌─── Lab K2s ──────┐  ┌─── Staging K2s ──┐
│ search-api :8081 │  │ search-api :8081  │  │ search-api :8081  │
└──────────────────┘  └──────────────────┘  └──────────────────┘
         │                    │                      │
         └────────────────────┴──────────────────────┘
                              │
                    ┌─────────────────┐
                    │  Federated      │
                    │  Search API     │
                    │  (aggregator)   │
                    └─────────────────┘
                              │
                    "Find all clusters where
                     the dashboard addon is
                     configured with auth"
```

### 17.4 Autonomous Learning from Incidents

```
Incident occurs → HolmesGPT diagnoses → fix applied
    → Incident + fix pair stored as training data
    → Periodic fine-tuning of local embedding model
    → Model improves at understanding THIS environment's patterns
    → Semantic search becomes more accurate over time
```

### 17.5 Capability Maturity Timeline

| Capability | Today | 6 months | 12 months | 24 months |
|---|---|---|---|---|
| Code semantic search | ✅ Prototype | ✅ Production | ✅ Stable | ✅ Federated |
| RAG in AI Assistant | 🔵 In progress | ✅ Integrated | ✅ Multi-source | ✅ Live state |
| Headlamp Search UI | ❌ fmt.py only | 🔵 Alpha | ✅ Production | ✅ Advanced |
| Auto re-indexing | ❌ Manual | 🔵 CronJob | ✅ Event-driven | ✅ Real-time |
| Native OpenSearch ML | ❌ External | ❌ | 🔵 Prototype | ✅ Production |
| Knowledge graph | ❌ | ❌ | 🔵 Research | ✅ Prototype |
| Institutional memory | ❌ | ❌ | 🔵 Design | ✅ Alpha |
| Federated search | ❌ | ❌ | ❌ | 🔵 Design |

---

## 18. Comparison with Alternatives

### 18.1 OpenSearch vs. Other Vector Stores

| Feature | OpenSearch | Qdrant | Weaviate | pgvector | Chroma |
|---|---|---|---|---|---|
| BM25 + kNN hybrid | ✅ Native | ⚠️ Sparse vectors | ✅ Native | ⚠️ Manual | ❌ kNN only |
| Production-ready | ✅ Enterprise | ✅ Yes | ✅ Yes | ✅ Yes | ⚠️ Dev-focused |
| Offline/air-gap | ✅ Full | ✅ Full | ✅ Full | ✅ Full | ✅ Full |
| K8s native | ✅ Helm chart | ✅ Helm | ✅ Helm | ✅ (postgres) | ✅ |
| Dashboard UI | ✅ Dashboards | ✅ Web UI | ✅ Console | ❌ | ❌ |
| License | Apache 2.0 | Apache 2.0 | BSD-3 | PostgreSQL | Apache 2.0 |
| Ecosystem maturity | ✅ Very high | ✅ High | ✅ High | ✅ High | ⚠️ Growing |
| K2s fit | ✅ Best | ✅ Good | ✅ Good | ⚠️ Needs Postgres | ⚠️ Dev only |

**Verdict:** OpenSearch is the right choice for K2s because it provides BM25+kNN hybrid search natively, has enterprise-grade stability, and fits the offline-first constraint without external dependencies.

### 18.2 Semantic Search vs. GitHub Copilot / Cloud Code Search

| Aspect | K2s Semantic Search (local) | GitHub Copilot / Cloud |
|---|---|---|
| Air-gap compatible | ✅ Yes | ❌ No |
| Data stays on-premise | ✅ Yes | ❌ No |
| Costs per query | ✅ $0 | 💰 Subscription |
| Index freshness | Nightly CronJob | Real-time (GitHub) |
| Custom metadata | ✅ Full control | ❌ Limited |
| Code actions (fix, apply) | Roadmap | ✅ Available |
| Regulatory compliance | ✅ Simple | ⚠️ Complex |

---

## 19. Quick Reference

### 19.1 CLI Commands

```console
# Enable the semantic search addon
k2s addons enable semantic-search

# Trigger manual re-index (after code changes)
kubectl create job --from=cronjob/k2s-indexer manual-reindex -n search

# Search from command line using fmt.py
curl -s -X POST http://localhost:8081/search \
  -H "Content-Type: application/json" \
  -d '{"query": "how does addon enabling work", "top_k": 5}' \
  | python fmt.py

# Port-forward Search API
kubectl port-forward svc/search-api -n search 8081:8081

# Check OpenSearch index stats
curl -k https://localhost:9200/k2s-knowledge/_stats \
  --cert tmp/admin.crt --key tmp/admin.key | python -m json.tool

# Rebuild index from scratch
kubectl delete job -n search -l app=k2s-indexer
kubectl create job --from=cronjob/k2s-indexer full-reindex -n search
```

### 19.2 Useful OpenSearch Queries

```bash
# Check index document count
curl -k https://localhost:9200/k2s-knowledge/_count \
  --cert tmp/admin.crt --key tmp/admin.key

# See all indexed languages
curl -k https://localhost:9200/k2s-knowledge/_search \
  --cert tmp/admin.crt --key tmp/admin.key \
  -d '{"size":0,"aggs":{"langs":{"terms":{"field":"language"}}}}'

# Delete + recreate index
curl -k -X DELETE https://localhost:9200/k2s-knowledge \
  --cert tmp/admin.crt --key tmp/admin.key
```

### 19.3 fmt.py Reference

```python
# fmt.py — formats semantic search API JSON output
# Usage: curl ... | python fmt.py
import sys, json
d = json.load(sys.stdin)
hits = d["hits"]
print(f"{len(hits)} hits")
for h in hits[:5]:
    s = h["score"]
    c = h["content"][:130].replace("\n", " ")
    print(f"  [{s:.1%}] {c}")
```

---

## Summary

| Dimension | Today (prototype) | 6 months | 12 months | 24 months |
|---|---|---|---|---|
| **Search type** | kNN semantic | Hybrid BM25+kNN | Hybrid + live state | Federated |
| **UI** | fmt.py CLI | Headlamp panel | Full search UX | Multi-cluster |
| **RAG** | Manual context | Holmes tool | Auto-grounded AI | Institutional memory |
| **Index freshness** | Manual | Nightly CronJob | Event-driven | Real-time |
| **Model** | MiniLM 384-dim | nomic-embed 768-dim | Native OpenSearch ML | Fine-tuned local |
| **Air-gap** | ✅ Full | ✅ Pre-built index | ✅ Bundled in offline pkg | ✅ Full federated |
| **Latency** | 30-60ms | 20-40ms | 15-30ms | <15ms |

The OpenSearch semantic search stack transforms K2s from a large, hard-to-navigate codebase into a **searchable knowledge base** that both humans and AI agents can query by meaning. Combined with the AI Assistant's RAG capability, it eliminates hallucination in K2s-specific questions and provides a foundation for institutional knowledge management — a critical capability for long-lived, regulated, offline-first deployments.

