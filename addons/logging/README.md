<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# logging

## Introduction

The `logging` addon provides an [OpenSearch Dashboards web-based UI](https://github.com/opensearch-project/OpenSearch-Dashboards) for Kubernetes logging. It enables users to analyze container logs from k2s cluster supporting full-text search.

## Getting started

The logging addon can be enabled using the k2s CLI by running the following command:
```console
k2s addons enable logging
```

### Integration with ingress nginx and ingress traefik addons

The logging addon can be integrated with ingress controllers (nginx, nginx-gw, or traefik) to expose the dashboard outside the cluster.

For example, the logging addon can be enabled along with traefik addon using the following command:
```console
k2s addons enable logging --ingress traefik
```

Or with nginx Gateway Fabric:
```console
k2s addons enable logging --ingress nginx-gw
```

_Note:_ The above command shall enable the specified ingress addon if it is not already enabled.

## Accessing the logging dashboard

The logging dashboard UI can be accessed via the following methods.

### Access using ingress

To access logging dashboard via ingress, one of the ingress addons (nginx, nginx-gw, or traefik) must be enabled.
Once the addons are enabled, the logging dashboard UI can be accessed at the following URL: <https://k2s.cluster.local/logging>

_Note:_ If a proxy server is configured in the Windows Proxy settings, please add the hosts **k2s.cluster.local** as a proxy override.

### Access using port-forwarding

To access logging dashboard via port-forwarding, the following command can be executed:
```console
kubectl -n logging port-forward svc/opensearch-dashboards 5601:5601
```
In this case, the logging dashboard UI can be accessed at the following URL: <http://localhost:5601/logging>

Once the `Home` section appears, navigate to `Menu -> Discover`. Now logs can be searched and analyzed.

## OpenTelemetry

The OpenTelemetry input plugin of the logging addon allows receiving data as per the OTLP specification. The following endpoint can be used to send logs to the logging addon:

```
http://otel.logging.svc.cluster.local:4318/v1/logs
```

Those logs are added to the same index like all other logs and are visible under the `Discover` section.

## Disable logging

The logging addon can be disabled using the k2s CLI by running the following command:
```console
k2s addons disable logging
```

_Note:_ The above command will only disable logging addon. If other addons were enabled while enabling the logging addon, they will not be disabled.

## Deploying without OpenSearch (Fluent-bit only mode)

The `--omitOpensearch` flag deploys only the Fluent-bit DaemonSet(s), skipping OpenSearch and OpenSearch Dashboards. This is useful for consuming logs from an external pipeline.

```console
k2s addons enable logging --omitOpensearch
```

### Viewing logs

```console
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit
```

**Important notes:**

- No OpenSearch dashboard is available in this mode
- Fluent-bit outputs logs to stdout in JSON format
- The `--ingress` flag is ignored when `--omitOpensearch` is set
- To forward to an external OTEL collector, replace the generated ConfigMap after enabling

### Disabling

```console
k2s addons disable logging
```

## Backup and restore

Create a backup zip (defaults to `C:\Temp\k2s\Addons` on Windows):
```console
k2s addons backup logging
```

Restore from a backup zip:
```console
k2s addons restore logging -f C:\Temp\k2s\Addons\logging_backup_YYYYMMDD_HHMMSS.zip
```

What is backed up:
- Selected ConfigMaps (best-effort) for OpenSearch and Fluent Bit.

Notes:
- Backup/restore does not include OpenSearch data (historical logs).
- Restore applies config and triggers best-effort rollout restarts.

## AI-Powered Log Analysis (optional)

The logging addon can be extended with an AI layer that adds **vector search**, an **embedding pipeline**, and a **RAG-ready query API** — all backed by the existing OpenSearch instance.

### Enabling the AI layer

```console
k2s addons enable logging --enableAI
```

This deploys three additional components into the `logging` namespace:

| Component | Kind | Purpose |
|---|---|---|
| `logging-ai-api` | Deployment | FastAPI query API (`POST /ai/logs/search`) |
| `logging-ai-pipeline` | CronJob | Batch embedding pipeline (runs every hour) |
| `logging-ai-config` | ConfigMap | All tunable parameters |

### Architecture

```
Fluent Bit → OpenSearch (k2s index)
                    ↓  [CronJob: every hour]
            EmbeddingPipeline
              – filter: warn/error logs only
              – embed via Ollama (nomic-embed-text)
                    ↓
            OpenSearch (logs-vector index, k-NN HNSW)
                    ↑
            Query API  POST /ai/logs/search
              – embed query → k-NN search + keyword hybrid
              – optional: RAG summarisation via Ollama LLM
```

### Vector index

A new index `logs-vector` is created automatically on first startup (idempotent). It uses the OpenSearch k-NN plugin with HNSW/Lucene and cosine similarity. The mapping is:

```json
{
  "content":   "text",
  "embedding": "knn_vector (dim=768)",
  "metadata":  { "pod", "namespace", "host", "log_level", "timestamp" }
}
```

The existing `k2s` index written by Fluent Bit is **not modified**.

### Query API

```console
# Port-forward the API locally
kubectl -n logging port-forward svc/logging-ai-api 8080:8080

# Semantic search
curl -X POST http://localhost:8080/ai/logs/search \
  -H 'Content-Type: application/json' \
  -d '{
    "query": "pod OOMKilled memory pressure",
    "filters": { "namespace": "default" },
    "top_k": 5
  }'
```

Response:
```json
{
  "hits": [
    {
      "content": "OOMKilled: container exceeded memory limit",
      "score": 0.94,
      "metadata": { "pod": "myapp-xyz", "namespace": "default", "log_level": "error" }
    }
  ],
  "answer": null
}
```

Set `LLM_ENABLED: "true"` in `logging-ai-config` ConfigMap to receive an LLM-generated `answer` field (requires Ollama with a chat model).

### Configuration

All settings are in the `logging-ai-config` ConfigMap. Key parameters:

| Key | Default | Description |
|---|---|---|
| `EMBEDDING_DIMENSION` | `768` | Must match the embedding model output |
| `EMBEDDING_PROVIDER` | `ollama` | `ollama` or `noop` (zero vectors, for testing) |
| `OLLAMA_MODEL` | `nomic-embed-text` | Embedding model served by Ollama |
| `BATCH_SIZE` | `50` | Logs per bulk-index request |
| `PIPELINE_LOOKBACK_MINUTES` | `60` | How far back the CronJob looks each run |
| `MIN_LOG_LEVEL` | `warn` | Minimum severity to embed (`error`, `warn`, `info`) |
| `LLM_ENABLED` | `false` | Enable RAG answer generation |
| `OLLAMA_LLM_MODEL` | `llama3` | Chat model for RAG |

### Running tests

```console
cd addons/logging/ai
python -m pytest tests/ -v
```

### Demo UI

A browser-based search interface is included:
```console
# Start port-forward
kubectl -n logging port-forward svc/logging-ai-api 9090:9090

# Open the demo page
start addons/logging/ai/demo.html
```

### Architecture deep-dive

See [ai/ARCHITECTURE.md](ai/ARCHITECTURE.md) for the full architecture diagram, component details, hybrid search strategy, demo script, and future prospects.

### Source layout

```
addons/logging/ai/
  app/
    config.py          – configuration from env vars
    embedding.py       – EmbeddingService interface + OllamaEmbeddingService / NoopEmbeddingService
    opensearch_client.py – REST wrapper (index, bulk, search, scroll)
    index_manager.py   – idempotent vector index creation
    pipeline.py        – EmbeddingPipeline (filter → embed → store)
    api.py             – FastAPI: POST /ai/logs/search, GET /healthz
  tests/
    test_embedding.py
    test_search.py
  main.py              – entry point (mode: api | pipeline)
  Dockerfile
  requirements.txt
addons/logging/manifests/logging/ai/
  configmap.yaml
  deployment-api.yaml
  service-api.yaml
  cronjob-pipeline.yaml
  kustomization.yaml
```

## Further Reading
- [fluentbit](https://github.com/fluent/fluent-bit)
- [opensearch](https://github.com/opensearch-project/OpenSearch)
- [OpenSearch k-NN plugin](https://opensearch.org/docs/latest/search-plugins/knn/)
