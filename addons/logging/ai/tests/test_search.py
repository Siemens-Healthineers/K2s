# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
"""Unit tests for the search service (API query building and pipeline filtering)."""
import os
import sys
import unittest
from unittest.mock import MagicMock, patch
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ.setdefault("EMBEDDING_DIMENSION", "3")
os.environ.setdefault("EMBEDDING_PROVIDER", "noop")
os.environ.setdefault("VECTOR_INDEX", "logs-vector")
os.environ.setdefault("SOURCE_INDEX", "k2s")
os.environ.setdefault("TOP_K", "5")
class TestPipelineFilter(unittest.TestCase):
    def setUp(self):
        import importlib, app.config, app.pipeline
        importlib.reload(app.config)
        importlib.reload(app.pipeline)
        from app.pipeline import _is_important
        self._is_important = _is_important
    def test_error_level_is_important(self):
        record = {"level": "error", "log": "something crashed"}
        self.assertTrue(self._is_important(record, "warn"))
    def test_debug_below_warn_is_not_important(self):
        record = {"level": "debug", "log": "verbose detail"}
        self.assertFalse(self._is_important(record, "warn"))
    def test_error_keyword_in_content_is_always_important(self):
        record = {"level": "debug", "log": "NullPointerException in service"}
        self.assertTrue(self._is_important(record, "warn"))
    def test_warn_is_important_when_min_warn(self):
        record = {"level": "warn", "log": "disk usage high"}
        self.assertTrue(self._is_important(record, "warn"))
    def test_info_below_warn_is_not_important(self):
        record = {"level": "info", "log": "request received"}
        self.assertFalse(self._is_important(record, "warn"))
class TestQueryBuilding(unittest.TestCase):
    def setUp(self):
        import importlib, app.config, app.api
        importlib.reload(app.config)
        importlib.reload(app.api)
        from app.api import _build_knn_query, _build_hybrid_query
        self._build_knn = _build_knn_query
        self._build_hybrid = _build_hybrid_query

    def test_knn_query_no_filters(self):
        vector = [0.1, 0.2, 0.3]
        query = self._build_knn(vector, 5, None)
        self.assertIn("knn", query)

    def test_knn_query_with_namespace_filter(self):
        vector = [0.1, 0.2, 0.3]
        filters = {"namespace": "default"}
        query = self._build_knn(vector, 5, filters)
        self.assertIn("bool", query)
        filter_clauses = query["bool"]["filter"]
        namespaces = [c.get("term", {}).get("metadata.namespace") for c in filter_clauses]
        self.assertIn("default", namespaces)

    def test_knn_query_with_pod_filter(self):
        vector = [0.1, 0.2, 0.3]
        filters = {"pod": "order-service"}
        query = self._build_knn(vector, 5, filters)
        self.assertIn("bool", query)
        filter_clauses = query["bool"]["filter"]
        pods = [c.get("term", {}).get("metadata.pod") for c in filter_clauses]
        self.assertIn("order-service", pods)

    def test_hybrid_query_includes_both_knn_and_match(self):
        vector = [0.1, 0.2, 0.3]
        query = self._build_hybrid("crash in pod", vector, 5, None)
        self.assertIn("bool", query)
        should = query["bool"]["should"]
        types = [list(c.keys())[0] for c in should]
        self.assertIn("knn", types)
        self.assertIn("match", types)
class TestEmbeddingPipelineRun(unittest.TestCase):
    def test_run_calls_bulk_index_with_important_logs(self):
        import importlib, app.config
        importlib.reload(app.config)
        import app.pipeline
        importlib.reload(app.pipeline)
        from app.pipeline import EmbeddingPipeline
        from app.embedding import NoopEmbeddingService
        sample_batch = [
            {"log": "OOMKilled", "level": "error", "@timestamp": "2026-01-01T00:00:00Z",
             "k2s.pod.name": "p1", "k2s.namespace.name": "ns1", "k2s.host.name": "h1"},
            {"log": "routine heartbeat", "level": "debug", "@timestamp": "2026-01-01T00:00:01Z",
             "k2s.pod.name": "p2", "k2s.namespace.name": "ns1", "k2s.host.name": "h1"},
        ]
        svc = EmbeddingPipeline(NoopEmbeddingService())

        # Patch embed_batch to return non-zero vectors so they pass the zero-vector filter
        non_zero_vectors = [[0.1, 0.2, 0.3]]  # one vector for the one important log
        with patch("app.pipeline.os_client.index_exists", return_value=True):
            with patch("app.pipeline.os_client.scroll_source_logs", return_value=iter([sample_batch])):
                with patch("app.pipeline.os_client.bulk_index", return_value=1) as mock_bulk:
                    with patch.object(svc._svc, "embed_batch", return_value=non_zero_vectors):
                        svc.run()
        mock_bulk.assert_called_once()
        docs = mock_bulk.call_args[0][1]
        # Only the error log should be indexed
        self.assertEqual(len(docs), 1)
        self.assertIn("OOMKilled", docs[0]["content"])
if __name__ == "__main__":
    unittest.main()
