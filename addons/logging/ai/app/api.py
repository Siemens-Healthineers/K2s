# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
"""HTTP query API – POST /ai/logs/search – stdlib only (no fastapi/pydantic/uvicorn)."""
from __future__ import annotations
import json
import logging
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Optional

from app import opensearch_client as os_client
from app.config import Config
from app.embedding import build_embedding_service

logger = logging.getLogger(__name__)
_embedding_svc = None


def _get_embedding_svc():
    global _embedding_svc
    if _embedding_svc is None:
        _embedding_svc = build_embedding_service()
    return _embedding_svc


# ── Query builders ─────────────────────────────────────────────────────────────

def _build_knn_query(vector: List[float], top_k: int, filters: Optional[Dict]) -> Dict[str, Any]:
    knn_clause: Dict[str, Any] = {
        "knn": {
            "embedding": {
                "vector": vector,
                "k": top_k,
            }
        }
    }
    filter_clauses: List[Dict[str, Any]] = []
    if filters:
        pod_name = filters.get("pod") or filters.get("service")
        if pod_name:
            filter_clauses.append({"term": {"metadata.pod": pod_name}})
        if filters.get("namespace"):
            filter_clauses.append({"term": {"metadata.namespace": filters["namespace"]}})
        if filters.get("env"):
            filter_clauses.append({"term": {"metadata.env": filters["env"]}})
        tr = filters.get("time_range")
        if tr:
            range_body: Dict[str, Any] = {}
            if tr.get("gte"):
                range_body["gte"] = tr["gte"]
            if tr.get("lte"):
                range_body["lte"] = tr["lte"]
            if range_body:
                filter_clauses.append({"range": {"metadata.timestamp": range_body}})
    if not filter_clauses:
        return knn_clause
    return {"bool": {"must": [knn_clause], "filter": filter_clauses}}


def _build_hybrid_query(query_text: str, vector: List[float], top_k: int, filters: Optional[Dict]) -> Dict[str, Any]:
    """Combine k-NN vector search with a keyword match for hybrid retrieval.
    Falls back to keyword-only if the vector is zero (noop provider)."""
    keyword_clause = {"match": {"content": {"query": query_text, "boost": 0.3}}}

    # Skip kNN for zero vectors (noop provider) — OpenSearch rejects zero-vector queries
    if not vector or all(v == 0.0 for v in vector):
        return {"bool": {"should": [keyword_clause], "minimum_should_match": 1}}

    knn_query = _build_knn_query(vector, top_k, filters)
    return {
        "bool": {
            "should": [knn_query, keyword_clause],
            "minimum_should_match": 1,
        }
    }


def _generate_rag_answer(query: str, context_logs: List[str]) -> str:
    """Call Ollama LLM to summarize retrieved log context (optional)."""
    ctx = "\n".join(f"- {line}" for line in context_logs[:10])
    prompt = (
        f"You are a Kubernetes log analysis assistant.\n"
        f"The following log entries are relevant to the user's query:\n{ctx}\n\n"
        f"User query: {query}\n"
        f"Provide a concise summary of what these logs indicate."
    )
    try:
        payload = json.dumps({"model": Config.OLLAMA_LLM_MODEL, "prompt": prompt, "stream": False}).encode()
        req = urllib.request.Request(
            f"{Config.OLLAMA_HOST.rstrip('/')}/api/generate", data=payload,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode()).get("response", "")
    except Exception as exc:
        logger.error("[AI][RAG] LLM call failed: %s", exc)
        return ""


# ── HTTP Handler ───────────────────────────────────────────────────────────────

class _Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # silence default access log
        logger.debug("[AI][API] " + fmt, *args)

    def _send_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def _send_json(self, status: int, body: Any):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self._send_cors_headers()
        self.end_headers()
        self.wfile.write(data)

    def _read_json(self) -> Any:
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length).decode()) if length else {}

    def do_OPTIONS(self):
        self.send_response(204)
        self._send_cors_headers()
        self.end_headers()

    def do_GET(self):
        if self.path == "/healthz":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"detail": "not found"})

    def do_POST(self):
        if self.path == "/ai/logs/search":
            self._handle_search()
        else:
            self._send_json(404, {"detail": "not found"})

    def _handle_search(self):
        try:
            req = self._read_json()
        except Exception as exc:
            self._send_json(400, {"detail": f"Invalid JSON: {exc}"})
            return

        query_text = req.get("query", "")
        top_k = int(req.get("top_k", Config.TOP_K))
        filters = req.get("filters")

        logger.info("[AI][API] search query=%r top_k=%d", query_text, top_k)

        try:
            vector = _get_embedding_svc().embed(query_text)
        except Exception as exc:
            logger.error("[AI][API] Embedding failed: %s", exc)
            self._send_json(503, {"detail": "Embedding service unavailable"})
            return

        os_query = _build_hybrid_query(query_text, vector, top_k, filters)
        try:
            raw_hits = os_client.search(Config.VECTOR_INDEX, {"query": os_query}, size=top_k)
        except Exception as exc:
            logger.error("[AI][API] OpenSearch query failed: %s", exc)
            self._send_json(503, {"detail": "Search backend unavailable"})
            return

        hits = [
            {
                "content": h["_source"].get("content", ""),
                "score": h.get("_score", 0.0),
                "metadata": h["_source"].get("metadata", {}),
            }
            for h in raw_hits
        ]

        answer = None
        if Config.LLM_ENABLED and hits:
            answer = _generate_rag_answer(query_text, [h["content"] for h in hits])

        self._send_json(200, {"hits": hits, "answer": answer})


def run_server(host: str = "0.0.0.0", port: int = 9090):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    logger.info("[AI][API] Starting server on %s:%d", host, port)
    server = HTTPServer((host, port), _Handler)
    server.serve_forever()
