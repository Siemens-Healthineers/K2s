<!--
SPDX-FileCopyrightText: Â© 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Log Analysis â€“ Testing Checklist & Demo Guide

---

## Current Status (verified 2026-04-19)

| Component | Status | Notes |
|---|---|---|
| `logging-ai-api` | âœ… `1/1 Running` | stdlib HTTP server, no pip install needed |
| `ollama` | âœ… `1/1 Running` | `nomic-embed-text` model loaded (274 MB, copied from Windows host) |
| `logging-ai-pipeline` CronJob | âœ… Registered, runs hourly | |
| `logs-vector` index | âœ… **38 embedded documents** | Real semantic vectors from Ollama |
| Unit tests | âœ… **16/16 passing** | No external packages needed |

### Embedding mode: `ollama` (fully active)

The `nomic-embed-text` model is loaded in Ollama and producing real 768-dim semantic vectors.
The pipeline ran successfully: `processed=400, stored=38`.
Semantic search verified working: queries return hits with cosine similarity scores ~0.92â€“0.93.

> **Note on model loading**: `registry.ollama.ai` is not reachable from inside containers in this cluster.
> The model was loaded by pulling it on the Windows host and copying the blobs to the Ollama PVC.
> See Â§6 for the full procedure.

---

## 1. Unit Tests (no cluster required)

### Setup â€“ no pip install needed

The app uses **Python stdlib only**. Only `pytest` is required:

```console
cd addons/logging/ai
pip install pytest
```

### Run

```console
python -m pytest tests/ -v
```

### Expected result: **16 passed**

| # | Test | What it verifies |
|---|---|---|
| 1 | `TestNoopEmbeddingService::test_embed_returns_zero_vector` | NoopService returns a zero vector of the configured dimension |
| 2 | `TestNoopEmbeddingService::test_embed_batch_skips_on_error` | A failing item yields `[]`; remaining items are still processed |
| 3 | `TestOllamaEmbeddingService::test_embed_returns_vector_on_success` | Ollama HTTP success path returns the embedding vector |
| 4 | `TestOllamaEmbeddingService::test_embed_raises_on_dimension_mismatch` | Raises `ValueError` when model returns wrong dimension |
| 5 | `TestOllamaEmbeddingService::test_embed_raises_on_http_error` | Raises exception on HTTP failure |
| 6 | `TestBuildEmbeddingService::test_noop_provider` | Factory returns `NoopEmbeddingService` for `EMBEDDING_PROVIDER=noop` |
| 7 | `TestBuildEmbeddingService::test_unknown_provider_raises` | Factory raises `ValueError` for unknown provider |
| 8 | `TestPipelineFilter::test_error_level_is_important` | Logs with level `error` pass the importance filter |
| 9 | `TestPipelineFilter::test_debug_below_warn_is_not_important` | Logs with level `debug` are dropped at `warn` threshold |
| 10 | `TestPipelineFilter::test_error_keyword_in_content_is_always_important` | Logs containing "exception" are kept regardless of level field |
| 11 | `TestPipelineFilter::test_warn_is_important_when_min_warn` | `warn` level passes at `warn` threshold (boundary check) |
| 12 | `TestPipelineFilter::test_info_below_warn_is_not_important` | `info` level is dropped at `warn` threshold |
| 13 | `TestQueryBuilding::test_knn_query_no_filters` | k-NN clause is generated correctly with no filters |
| 14 | `TestQueryBuilding::test_knn_query_with_namespace_filter` | Namespace filter clause is injected into the `bool.filter` array |
| 15 | `TestQueryBuilding::test_hybrid_query_includes_both_knn_and_match` | Both `knn` and `match` clauses are present in `bool.should` |
| 16 | `TestEmbeddingPipelineRun::test_run_calls_bulk_index_with_important_logs` | End-to-end: only the error log is bulk-indexed; debug log is dropped |

---

## 2. Cluster Pre-flight Checklist

| âœ… | Check | Command |
|---|---|---|
| â˜ | k2s cluster is running | `k2s status` |
| â˜ | All AI pods are Ready | `kubectl get pods -n logging` |
| â˜ | OpenSearch responds | `kubectl exec -n logging statefulset/opensearch-cluster-master -- curl -s http://localhost:9200` |
| â˜ | Source logs exist | `kubectl exec -n logging statefulset/opensearch-cluster-master -- curl -s http://localhost:9200/k2s/_count` |
| â˜ | Vector index has knn_vector mapping | `kubectl exec -n logging statefulset/opensearch-cluster-master -- curl -s http://localhost:9200/logs-vector/_mapping` |
| â˜ | CronJob registered | `kubectl get cronjob logging-ai-pipeline -n logging` |

---

## 3. API Tests (can run from command line now)

### 3a. Start port-forward

```console
kubectl -n logging port-forward svc/logging-ai-api 9090:9090
```

Keep this running in a separate terminal, then run the checks below.

### 3b. Health check âœ… (automated â€“ verified working)

```console
curl http://localhost:9090/healthz
```

**Expected:** `{"status": "ok"}`

### 3c. Semantic search âœ… (automated â€“ verified working with real embeddings)

```console
curl -s -X POST http://localhost:9090/ai/logs/search \
  -H "Content-Type: application/json" \
  -d '{"query": "container ran out of memory", "top_k": 3}'
```

**Expected:** `hits` array with 1â€“10 results, each with a `score` ~0.90+ (cosine similarity).
The query does not need to contain exact keywords â€” Ollama provides true semantic matching.

### 3d. Namespace-filtered search âœ… (automated â€“ verified working)

```console
curl -s -X POST http://localhost:9090/ai/logs/search \
  -H "Content-Type: application/json" \
  -d '{"query": "warn", "filters": {"namespace": "kube-system"}, "top_k": 3}'
```

### 3e. Time-range filter

```console
curl -s -X POST http://localhost:9090/ai/logs/search \
  -H "Content-Type: application/json" \
  -d '{"query": "connection refused", "filters": {"time_range": {"gte": "2026-04-19T00:00:00Z"}}, "top_k": 5}'
```

---

## 4. Pipeline Test âœ… (automated â€“ verified working)

Trigger the pipeline manually:

```console
kubectl create job --from=cronjob/logging-ai-pipeline pipeline-test -n logging
kubectl logs -n logging job/pipeline-test -f
```

**Expected output (with Ollama):**
```
[AI][Index] Vector index already exists: logs-vector
[AI][Embed] Using OllamaEmbeddingService model=nomic-embed-text
[AI][Pipeline] Starting run â€“ lookback=60m batch=50 min_level=warn
[AI][Pipeline] Run complete â€“ processed=N stored=M
```

`stored > 0` confirms real embeddings are being created and indexed.
`stored=0` means either no warn/error logs in the lookback window, or Ollama is not yet ready.

Clean up:
```console
kubectl delete job pipeline-test -n logging
```

---

## 5. Full Demo Scenario (requires Ollama model)

> âš ï¸ **Steps 2â€“4 below require the Ollama embedding model to be loaded.** See Â§6 for how to enable it.
> In noop mode, the pipeline runs but stores no vectors â€” search returns empty hits.

### Step 1 â€” Produce sample warn/error logs

```console
kubectl run log-demo --image=busybox --restart=Never -- \
  sh -c 'for i in $(seq 1 20); do
    echo "OOMKilled: container exceeded memory limit";
    echo "disk usage above 90 percent threshold warning";
    echo "routine heartbeat tick";
    sleep 1;
  done'
```

Confirm Fluent Bit picked them up:
```console
kubectl exec -n logging statefulset/opensearch-cluster-master -- \
  curl -s "http://localhost:9200/k2s/_count"
```

### Step 2 â€” Trigger the embedding pipeline

```console
kubectl create job --from=cronjob/logging-ai-pipeline pipeline-demo -n logging
kubectl get job pipeline-demo -n logging -w
kubectl logs -n logging job/pipeline-demo
```

**Expected (with Ollama):** `stored=M` where M > 0.

Confirm vectors indexed:
```console
kubectl exec -n logging statefulset/opensearch-cluster-master -- \
  curl -s "http://localhost:9200/logs-vector/_count"
```

### Step 3 â€” Semantic search

```console
# Requires port-forward active: kubectl -n logging port-forward svc/logging-ai-api 9090:9090

curl -s -X POST http://localhost:9090/ai/logs/search \
  -H "Content-Type: application/json" \
  -d '{"query": "container ran out of memory and was killed", "top_k": 3}'
```

**Expected (with Ollama):** hits containing `OOMKilled` with high similarity scores.

### Step 4 â€” Optional RAG answer generation

> Requires Ollama running with a chat model (e.g. `llama3`).

```console
kubectl patch configmap logging-ai-config -n logging \
  --type merge --patch '{"data":{"LLM_ENABLED":"true"}}'
kubectl rollout restart deployment/logging-ai-api -n logging
```

Re-run Query 3 â€” response will include an `"answer"` field with a natural-language summary.

### Step 5 â€” Clean up

```console
kubectl delete pod log-demo --ignore-not-found
kubectl delete job pipeline-demo -n logging --ignore-not-found
```

---

## 6. Loading the Ollama Model (air-gapped environment)

`registry.ollama.ai` is not reachable from inside containers in this cluster. The model must be loaded from the Windows host. This has already been done â€” see current status above.

### Procedure used (for reference / re-install)

**Step 1** â€” Pull the model on Windows (registry reachable from Windows host):
```console
ollama pull nomic-embed-text
```

**Step 2** â€” Scale down Ollama to release the PVC:
```console
kubectl scale deployment ollama -n logging --replicas=0
```

**Step 3** â€” Start a helper pod that mounts the Ollama host path:
```yaml
# tmp/manifest-copy-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: manifest-copy
  namespace: logging
spec:
  nodeName: kubemaster
  restartPolicy: Never
  containers:
    - name: copier
      image: busybox
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: host-ollama
          mountPath: /hostollama
      securityContext:
        privileged: true
  volumes:
    - name: host-ollama
      hostPath:
        path: /ollama
```
```console
kubectl apply -f tmp/manifest-copy-pod.yaml
```

**Step 4** â€” Copy blobs and manifest (use `Set-Location` to avoid `C:` colon issue with `kubectl cp`):
```powershell
$base = "$env:USERPROFILE\.ollama\models"

# Copy blobs
Set-Location "$base\blobs"
@(
  "sha256-970aa74c0a90ef7482477cf803618e776e173c007bf957f635f1015bfcfef0e6",
  "sha256-c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
  "sha256-ce4a164fc04605703b485251fe9f1a181688ba0eb6badb80cc6335c0de17ca0d",
  "sha256-31df23ea7daa448f9ccdbbcecce6c14689c8552222b80defd3830707c0139d4f"
) | ForEach-Object {
  kubectl cp ".\$_" "logging/manifest-copy:/hostollama/models/blobs/$_"
}

# Copy manifest
Set-Location "$base\manifests\registry.ollama.ai\library\nomic-embed-text"
kubectl cp ".\latest" "logging/manifest-copy:/hostollama/models/manifests/registry.ollama.ai/library/nomic-embed-text/latest"
```

**Step 5** â€” Clean up and restart Ollama:
```console
kubectl delete pod manifest-copy -n logging
kubectl scale deployment ollama -n logging --replicas=1
kubectl exec -n logging deploy/ollama -- ollama list   # verify nomic-embed-text appears
```

**Step 6** â€” Switch embedding provider and restart API:
```console
kubectl apply -k addons/logging/manifests/logging/ai/
kubectl rollout restart deployment/logging-ai-api -n logging
```

**Step 7** â€” Trigger pipeline and verify:
```console
kubectl create job --from=cronjob/logging-ai-pipeline pipeline-verify -n logging
kubectl logs -n logging job/pipeline-verify   # expect stored > 0
```

---

## 7. Troubleshooting Quick Reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `k2s addons enable logging --enableAI` fails at OpenSearch | OpenSearch slow to start | Re-run â€” base stack is idempotent; it will proceed once OpenSearch is ready |
| Ollama init container stuck `Init:0/1` | Image still pulling (large ~1GB) | Wait; check `kubectl describe pod -n logging -l app.kubernetes.io/name=ollama` |
| `ollama list` shows empty model list | Model pull failed (no internet in container) | See Â§6 for options |
| Pipeline `stored=0` with `noop` provider | Expected â€” zero vectors are skipped | Switch to `ollama` once model is available |
| API returns `{"hits":[],"answer":null}` | `logs-vector` index has no documents | Run pipeline with Ollama provider first |
| API returns `{"detail":"Search backend unavailable"}` | OpenSearch not reachable | `kubectl get pods -n logging -l app.kubernetes.io/name=opensearch` |
| API pod `CrashLoopBackOff` | Config error or source copy failed | `kubectl logs -n logging deploy/logging-ai-api -c copy-src` then `-c api` |
| `logs-vector` index already exists warning | Harmless â€” index creation is idempotent | No action needed |
| Ollama pod `OOMKilled` | Node memory too tight | Current limits: 256Mi req / 2Gi limit. Reduce other workloads or increase limit |

---

## 8. Configuration Reference

All parameters live in the `logging-ai-config` ConfigMap.

```console
kubectl edit configmap logging-ai-config -n logging
kubectl rollout restart deployment/logging-ai-api -n logging   # apply changes
```

| Key | Current default | Description |
|---|---|---|
| `EMBEDDING_PROVIDER` | `noop` | `noop` = keyword-only fallback; `ollama` = semantic embeddings |
| `EMBEDDING_DIMENSION` | `768` | Must match model output (`nomic-embed-text` = 768) |
| `OLLAMA_HOST` | `http://ollama.logging.svc.cluster.local:11434` | Ollama service URL |
| `OLLAMA_MODEL` | `nomic-embed-text` | Embedding model name |
| `BATCH_SIZE` | `50` | Documents per bulk-index request |
| `PIPELINE_LOOKBACK_MINUTES` | `60` | How far back each CronJob run looks |
| `MIN_LOG_LEVEL` | `warn` | Minimum severity to embed (`error`, `warn`, `info`) |
| `TOP_K` | `10` | Default max results from API |
| `LLM_ENABLED` | `false` | Set `true` to enable RAG answer (requires Ollama chat model) |
| `OLLAMA_LLM_MODEL` | `llama3` | Chat model for RAG â€” ignored when `LLM_ENABLED=false` |

