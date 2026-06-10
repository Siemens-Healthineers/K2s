# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
"""EmbeddingService interface and provider implementations – stdlib only."""
from __future__ import annotations
import json
import logging
import urllib.request
import urllib.error
from abc import ABC, abstractmethod
from typing import List

from app.config import Config

logger = logging.getLogger(__name__)


class EmbeddingService(ABC):
    """Interface for generating vector embeddings from text."""

    @abstractmethod
    def embed(self, text: str) -> List[float]:
        """Return a float vector for *text*. Raises on unrecoverable error."""

    def embed_batch(self, texts: List[str]) -> List[List[float]]:
        """Embed a list of texts. Skips items that fail and logs the error."""
        results: List[List[float]] = []
        for text in texts:
            try:
                results.append(self.embed(text))
            except Exception as exc:
                logger.error("[AI][Embed] Failed to embed snippet - skipping. error=%s", exc)
                results.append([])
        return results


class OllamaEmbeddingService(EmbeddingService):
    """Embedding via a locally accessible Ollama instance.

    Supports both Ollama ≥0.9 (/api/embed, input, embeddings[0])
    and legacy Ollama <0.9 (/api/embeddings, prompt, embedding).
    """

    def __init__(self, host=None, model=None):
        self._host = (host or Config.OLLAMA_HOST).rstrip("/")
        self._model = model or Config.OLLAMA_MODEL
        # Prefer the modern endpoint; fall back to legacy on 404
        self._url_new = f"{self._host}/api/embed"
        self._url_legacy = f"{self._host}/api/embeddings"

    def embed(self, text: str) -> List[float]:
        # Try modern Ollama ≥0.9 API first
        payload = json.dumps({"model": self._model, "input": text}).encode()
        req = urllib.request.Request(
            self._url_new, data=payload, method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode())
            # /api/embed returns {"embeddings": [[...vector...]]}
            # Some environments/proxies still return the legacy shape
            # {"embedding": [...vector...]} even on a successful 200.
            if "embeddings" in data:
                embedding = data["embeddings"][0]
            elif "embedding" in data:
                embedding = data["embedding"]
            else:
                raise KeyError("embeddings")
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
            # Fall back to legacy /api/embeddings
            payload_legacy = json.dumps({"model": self._model, "prompt": text}).encode()
            req_legacy = urllib.request.Request(
                self._url_legacy, data=payload_legacy, method="POST",
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req_legacy, timeout=30) as resp:
                data = json.loads(resp.read().decode())
            embedding = data["embedding"]

        if len(embedding) != Config.EMBEDDING_DIMENSION:
            raise ValueError(
                f"[AI][Embed] Dimension mismatch: expected {Config.EMBEDDING_DIMENSION}, "
                f"got {len(embedding)}"
            )
        return embedding


class NoopEmbeddingService(EmbeddingService):
    """Returns a zero vector - useful for testing without a running model."""

    def embed(self, text: str) -> List[float]:
        return [0.0] * Config.EMBEDDING_DIMENSION


def build_embedding_service() -> EmbeddingService:
    """Factory that returns the configured EmbeddingService implementation."""
    provider = Config.EMBEDDING_PROVIDER.lower()
    if provider == "ollama":
        logger.info("[AI][Embed] Using OllamaEmbeddingService model=%s", Config.OLLAMA_MODEL)
        return OllamaEmbeddingService()
    if provider == "noop":
        logger.warning("[AI][Embed] Using NoopEmbeddingService - embeddings are zero vectors")
        return NoopEmbeddingService()
    raise ValueError(f"Unknown EMBEDDING_PROVIDER: {provider!r}")
