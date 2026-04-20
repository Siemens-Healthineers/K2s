# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
"""Batch embedding pipeline: reads logs from OpenSearch, embeds, stores in vector index."""
from __future__ import annotations
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional
from app import opensearch_client as os_client
from app.config import Config
from app.embedding import EmbeddingService
logger = logging.getLogger(__name__)
# Log levels considered worth embedding (lower = less verbose)
_LEVEL_ORDER = {"error": 0, "err": 0, "warn": 1, "warning": 1, "info": 2, "debug": 3, "trace": 4}
def _is_important(log_record: Dict[str, Any], min_level: str) -> bool:
    """Return True when the log record meets the minimum severity threshold."""
    min_rank = _LEVEL_ORDER.get(min_level.lower(), 1)
    raw_level = (
        log_record.get("level")
        or log_record.get("log.level")
        or log_record.get("severity")
        or ""
    ).lower()
    record_rank = _LEVEL_ORDER.get(raw_level, 999)  # unknown = treat as very verbose
    # Always include explicit error / exception mentions regardless of level field
    content = log_record.get("log", "") or log_record.get("message", "")
    has_error_keywords = any(
        kw in content.lower() for kw in ("error", "exception", "traceback", "critical", "fatal")
    )
    return record_rank <= min_rank or has_error_keywords
def _build_source_query(lookback_minutes: int) -> Dict[str, Any]:
    since = (datetime.now(timezone.utc) - timedelta(minutes=lookback_minutes)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    return {
        "query": {
            "range": {"@timestamp": {"gte": since}}
        },
        "_source": ["log", "message", "level", "severity", "@timestamp", "k2s.pod.name", "k2s.namespace.name", "k2s.host.name"],
        "sort": [{"@timestamp": "asc"}],
    }
def _record_to_content(record: Dict[str, Any]) -> str:
    return (record.get("log") or record.get("message") or "").strip()
def _record_to_metadata(record: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "pod": record.get("k2s.pod.name", ""),
        "namespace": record.get("k2s.namespace.name", ""),
        "host": record.get("k2s.host.name", ""),
        "log_level": (record.get("level") or record.get("severity") or "unknown").lower(),
        "timestamp": record.get("@timestamp", ""),
    }
class EmbeddingPipeline:
    """Orchestrates batch-reading, filtering, embedding, and storing log vectors."""
    def __init__(self, embedding_svc: EmbeddingService) -> None:
        self._svc = embedding_svc
    def run(self) -> None:
        logger.info(
            "[AI][Pipeline] Starting run – lookback=%dm batch=%d min_level=%s",
            Config.PIPELINE_LOOKBACK_MINUTES,
            Config.BATCH_SIZE,
            Config.MIN_LOG_LEVEL,
        )
        query = _build_source_query(Config.PIPELINE_LOOKBACK_MINUTES)
        total_processed = 0
        total_stored = 0
        if not os_client.index_exists(Config.SOURCE_INDEX):
            logger.warning("[AI][Pipeline] Source index '%s' does not exist yet – no logs to embed. Fluent Bit may not have started writing.", Config.SOURCE_INDEX)
            return
        for batch in os_client.scroll_source_logs(
            Config.SOURCE_INDEX, query, batch_size=Config.BATCH_SIZE
        ):
            important = [r for r in batch if _is_important(r, Config.MIN_LOG_LEVEL)]
            if not important:
                continue
            texts = [_record_to_content(r) for r in important]
            vectors = self._svc.embed_batch(texts)
            docs: List[Dict[str, Any]] = []
            for record, text, vector in zip(important, texts, vectors):
                if not vector or not text:
                    continue
                # Skip zero vectors (noop provider) – cosine similarity rejects them
                if all(v == 0.0 for v in vector):
                    continue
                docs.append(
                    {
                        "content": text,
                        "embedding": vector,
                        "metadata": _record_to_metadata(record),
                    }
                )
            if docs:
                stored = os_client.bulk_index(Config.VECTOR_INDEX, docs)
                total_stored += stored
            total_processed += len(batch)
        logger.info(
            "[AI][Pipeline] Run complete – processed=%d stored=%d",
            total_processed,
            total_stored,
        )

