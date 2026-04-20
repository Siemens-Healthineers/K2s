# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

"""Central configuration loaded from environment variables."""

import os


class Config:
    # OpenSearch connection
    OPENSEARCH_HOST: str = os.environ.get("OPENSEARCH_HOST", "opensearch-cluster-master.logging.svc.cluster.local")
    OPENSEARCH_PORT: int = int(os.environ.get("OPENSEARCH_PORT", "9200"))

    # Source index (Fluent Bit writes here)
    SOURCE_INDEX: str = os.environ.get("SOURCE_INDEX", "k2s")

    # Vector index
    VECTOR_INDEX: str = os.environ.get("VECTOR_INDEX", "logs-vector")
    EMBEDDING_DIMENSION: int = int(os.environ.get("EMBEDDING_DIMENSION", "768"))

    # Embedding provider
    EMBEDDING_PROVIDER: str = os.environ.get("EMBEDDING_PROVIDER", "ollama")  # ollama | noop
    OLLAMA_HOST: str = os.environ.get("OLLAMA_HOST", "http://ollama.logging.svc.cluster.local:11434")
    OLLAMA_MODEL: str = os.environ.get("OLLAMA_MODEL", "nomic-embed-text")

    # Pipeline
    BATCH_SIZE: int = int(os.environ.get("BATCH_SIZE", "50"))
    PIPELINE_LOOKBACK_MINUTES: int = int(os.environ.get("PIPELINE_LOOKBACK_MINUTES", "60"))
    # Filter: only embed logs at or above this level (error, warn, info, *)
    MIN_LOG_LEVEL: str = os.environ.get("MIN_LOG_LEVEL", "warn")

    # Query API
    API_HOST: str = os.environ.get("API_HOST", "0.0.0.0")
    API_PORT: int = int(os.environ.get("API_PORT", "8080"))
    TOP_K: int = int(os.environ.get("TOP_K", "10"))

    # LLM (optional RAG)
    LLM_ENABLED: bool = os.environ.get("LLM_ENABLED", "false").lower() == "true"
    OLLAMA_LLM_MODEL: str = os.environ.get("OLLAMA_LLM_MODEL", "llama3")

