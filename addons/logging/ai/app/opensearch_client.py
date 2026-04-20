# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
"""Thin wrapper around the OpenSearch REST API – stdlib only (no requests)."""
from __future__ import annotations
import json
import logging
import urllib.request
import urllib.error
from typing import Any, Dict, Generator, List

from app.config import Config

logger = logging.getLogger(__name__)


def _base_url() -> str:
    return f"http://{Config.OPENSEARCH_HOST}:{Config.OPENSEARCH_PORT}"


def _request(method: str, path: str, body: Any = None, content_type: str = "application/json", timeout: int = 30) -> Any:
    """Perform an HTTP request and return parsed JSON response, or raise on error."""
    url = f"{_base_url()}{path}"
    data = None
    if body is not None:
        if isinstance(body, (dict, list)):
            data = json.dumps(body).encode()
            content_type = "application/json"
        elif isinstance(body, str):
            data = body.encode()
        else:
            data = body
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        raise exc


def index_exists(index: str) -> bool:
    req = urllib.request.Request(f"{_base_url()}/{index}", method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=10):
            return True
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return False
        raise


def create_index(index: str, body: Dict[str, Any]) -> None:
    _request("PUT", f"/{index}", body)
    logger.info("[AI][OS] Index created: %s", index)


def bulk_index(index: str, docs: List[Dict[str, Any]]) -> int:
    """Index *docs* using the OpenSearch bulk API. Returns the number of successful docs."""
    lines: List[str] = []
    for doc in docs:
        lines.append('{"index":{"_index":"' + index + '"}}')
        lines.append(json.dumps(doc))
    payload = "\n".join(lines) + "\n"
    result = _request("POST", "/_bulk", body=payload, content_type="application/x-ndjson", timeout=60)
    errors = [item for item in result.get("items", []) if "error" in item.get("index", {})]
    if errors:
        logger.warning("[AI][OS] %d bulk index errors (first: %s)", len(errors), errors[0])
    return len(docs) - len(errors)


def search(index: str, body: Dict[str, Any], size: int = 10) -> List[Dict[str, Any]]:
    result = _request("POST", f"/{index}/_search", {**body, "size": size})
    return result.get("hits", {}).get("hits", [])


def scroll_source_logs(index: str, query: Dict[str, Any], batch_size: int = 50) -> Generator:
    """Generator that yields batches of _source dicts from a scroll query."""
    data = _request("POST", f"/{index}/_search?scroll=2m", {**query, "size": batch_size})
    scroll_id = data.get("_scroll_id")
    hits = data.get("hits", {}).get("hits", [])
    while hits:
        yield [h["_source"] for h in hits]
        data = _request("POST", "/_search/scroll", {"scroll": "2m", "scroll_id": scroll_id})
        scroll_id = data.get("_scroll_id")
        hits = data.get("hits", {}).get("hits", [])
    # Clear scroll context
    try:
        _request("DELETE", "/_search/scroll", {"scroll_id": scroll_id})
    except Exception:
        pass
