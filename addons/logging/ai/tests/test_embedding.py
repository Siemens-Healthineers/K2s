# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
"""Unit tests for the embedding service."""
import os
import sys
import unittest
from unittest.mock import MagicMock, patch
# Allow imports without installing the package
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("EMBEDDING_DIMENSION", "4")
os.environ.setdefault("EMBEDDING_PROVIDER", "noop")
from app.embedding import (
    EmbeddingService,
    NoopEmbeddingService,
    OllamaEmbeddingService,
    build_embedding_service,
)
class TestNoopEmbeddingService(unittest.TestCase):
    def setUp(self):
        os.environ["EMBEDDING_DIMENSION"] = "4"
        # Re-import Config to pick up env changes
        import importlib
        import app.config
        importlib.reload(app.config)
        import app.embedding
        importlib.reload(app.embedding)
        from app.embedding import NoopEmbeddingService as _Noop
        self._svc = _Noop()
    def test_embed_returns_zero_vector(self):
        result = self._svc.embed("hello world")
        self.assertEqual(result, [0.0, 0.0, 0.0, 0.0])
    def test_embed_batch_skips_on_error(self):
        svc = NoopEmbeddingService()
        # Monkey-patch embed to raise on second call
        calls = []
        original = svc.embed
        def patched(text):
            calls.append(text)
            if len(calls) == 2:
                raise RuntimeError("simulated failure")
            return original(text)
        svc.embed = patched
        results = svc.embed_batch(["a", "b", "c"])
        self.assertEqual(len(results), 3)
        self.assertEqual(results[1], [])  # failed item returns empty list
class TestOllamaEmbeddingService(unittest.TestCase):
    def _make_svc(self):
        os.environ["EMBEDDING_DIMENSION"] = "3"
        import importlib, app.config
        importlib.reload(app.config)
        import app.embedding
        importlib.reload(app.embedding)
        from app.embedding import OllamaEmbeddingService as _Ollama
        return _Ollama(host="http://localhost:11434", model="test-model")
    def _mock_urlopen(self, body_bytes):
        mock_read = MagicMock()
        mock_read.read.return_value = body_bytes
        mock_cm = MagicMock()
        mock_cm.__enter__ = MagicMock(return_value=mock_read)
        mock_cm.__exit__ = MagicMock(return_value=False)
        return mock_cm

    def test_embed_returns_vector_on_success(self):
        svc = self._make_svc()
        with patch("urllib.request.urlopen", return_value=self._mock_urlopen(b'{"embedding": [0.1, 0.2, 0.3]}')):
            result = svc.embed("test text")
        self.assertEqual(result, [0.1, 0.2, 0.3])
    def test_embed_raises_on_dimension_mismatch(self):
        svc = self._make_svc()
        with patch("urllib.request.urlopen", return_value=self._mock_urlopen(b'{"embedding": [0.1, 0.2]}')):
            with self.assertRaises(ValueError):
                svc.embed("test text")

    def test_embed_raises_on_http_error(self):
        svc = self._make_svc()
        import urllib.error
        with patch("urllib.request.urlopen", side_effect=urllib.error.HTTPError(
            url="http://x", code=500, msg="err", hdrs=None, fp=None
        )):
            with self.assertRaises(Exception):
                svc.embed("test text")
class TestBuildEmbeddingService(unittest.TestCase):
    def test_noop_provider(self):
        os.environ["EMBEDDING_PROVIDER"] = "noop"
        import importlib, app.config, app.embedding
        importlib.reload(app.config)
        importlib.reload(app.embedding)
        from app.embedding import build_embedding_service, NoopEmbeddingService
        svc = build_embedding_service()
        self.assertIsInstance(svc, NoopEmbeddingService)
    def test_unknown_provider_raises(self):
        os.environ["EMBEDDING_PROVIDER"] = "unknown"
        import importlib, app.config, app.embedding
        importlib.reload(app.config)
        importlib.reload(app.embedding)
        from app.embedding import build_embedding_service
        with self.assertRaises(ValueError):
            build_embedding_service()
if __name__ == "__main__":
    unittest.main()
