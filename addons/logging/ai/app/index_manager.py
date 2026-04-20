# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
"""Creates and manages the logs-vector k-NN index in OpenSearch."""
from __future__ import annotations
import logging
from app import opensearch_client as os_client
from app.config import Config
logger = logging.getLogger(__name__)
_INDEX_BODY = {
    "settings": {
        "index": {
            "knn": True,
            "knn.algo_param.ef_search": 100,
            "number_of_shards": 1,
            "number_of_replicas": 0,
        }
    },
    "mappings": {
        "properties": {
            "content": {"type": "text"},
            "embedding": {
                "type": "knn_vector",
                "dimension": Config.EMBEDDING_DIMENSION,
                "method": {
                    "name": "hnsw",
                    "space_type": "cosinesimil",
                    "engine": "lucene",
                },
            },
            "metadata": {
                "type": "object",
                "properties": {
                    "service": {"type": "keyword"},
                    "namespace": {"type": "keyword"},
                    "pod": {"type": "keyword"},
                    "host": {"type": "keyword"},
                    "env": {"type": "keyword"},
                    "log_level": {"type": "keyword"},
                    "timestamp": {"type": "date"},
                },
            },
        }
    },
}
def ensure_vector_index() -> None:
    """Idempotently create the vector index if it does not exist."""
    index = Config.VECTOR_INDEX
    if os_client.index_exists(index):
        logger.info("[AI][Index] Vector index already exists: %s", index)
        return
    logger.info("[AI][Index] Creating vector index: %s (dim=%d)", index, Config.EMBEDDING_DIMENSION)
    os_client.create_index(index, _INDEX_BODY)
    logger.info("[AI][Index] Vector index ready: %s", index)
