# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule    = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule  = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$nodeModule     = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$addonsModule   = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $nodeModule, $addonsModule

function Get-AiAssistantManifestsDir {
    return "$PSScriptRoot\manifests"
}

function Get-OllamaManifestPath {
    return "$PSScriptRoot\manifests\ollama\ollama.yaml"
}

function Get-HolmesManifestPath {
    return "$PSScriptRoot\manifests\holmesgpt\holmesgpt.yaml"
}

function Get-HolmesSseIngressPath {
    return "$PSScriptRoot\manifests\holmesgpt\holmesgpt-sse-ingress.yaml"
}

<#
.SYNOPSIS
Patches the HolmesGPT model ConfigMap with the chosen Ollama model name then re-applies it.
#>
function Set-HolmesModelConfig {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Model
    )

    $manifestPath = Get-HolmesManifestPath
    $content      = Get-Content -Path $manifestPath -Raw
    $patched      = $content -replace 'MODEL_PLACEHOLDER', $Model

    $tmpFile = [System.IO.Path]::GetTempFileName() + '.yaml'
    Set-Content -Path $tmpFile -Value $patched -Encoding UTF8

    $result = Invoke-Kubectl -Params 'apply', '-f', $tmpFile
    $result.Output | Write-Log
    Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue

    if (-not $result.Success) {
        throw "[AI-Assistant] Failed to apply HolmesGPT manifests with model '$Model'"
    }
}

<#
.SYNOPSIS
Deploys a Python-based smart proxy pod + selector-based Service in the 'default'
namespace that forwards to the real HolmesGPT service in 'ai-assistant'.

BACKGROUND
The Headlamp AI Assistant plugin hardcodes HOLMES_SERVICE_NAMESPACE='default' and uses
the K8s API server proxy path:
  /api/v1/namespaces/default/services/holmesgpt-holmes:80/proxy/...

K8s 1.35 apiserver proxy validation requires:
  1. The Service must have a spec.selector (selectorless ClusterIP → NotFound).
  2. Endpoint addresses must have a valid targetRef whose namespace matches the
     Endpoints namespace — cross-namespace pod refs are rejected.

The only correct cross-namespace proxy approach is therefore a real pod running in
'default' that relays traffic to 'ai-assistant'.

The proxy is implemented in Python (python:alpine image) so it can:
  1. Intercept POST /api/agui/chat requests and inject the strict system prompt
     into the 'additional_system_prompt' field of the JSON body — controlling
     Holmes behaviour without modifying the Headlamp plugin or the Holmes image.
  2. Filter empty SSE delta chunks that cause pydantic validation errors in the
     plugin (TextMessageContentEvent: 'delta' must have at least 1 character).

Architecture:
  Headlamp plugin
    → K8s apiserver proxy (/namespaces/default/services/holmesgpt-holmes:80/proxy/...)
    → Python proxy pod in 'default' (selector: app=holmesgpt-proxy)
    → holmesgpt-holmes.ai-assistant.svc.cluster.local:80
    → HolmesGPT pod in 'ai-assistant'
#>
function Set-HolmesProxyEndpoints {
    [CmdletBinding()]
    Param()

    Write-Log '[AI-Assistant] Deploying HolmesGPT smart proxy in default namespace...' -Console

    # Clean up legacy resources from older versions
    (Invoke-Kubectl -Params 'delete', 'endpointslice', 'holmesgpt-holmes-k2s', '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'endpoints',     'holmesgpt-holmes',     '-n', 'default', '--ignore-not-found').Output | Write-Log
    # Remove old nginx ConfigMap from previous versions
    (Invoke-Kubectl -Params 'delete', 'configmap', 'holmesgpt-nginx-conf', '-n', 'default', '--ignore-not-found').Output | Write-Log

    # ── Strict system prompt injected into every Holmes chat request ──────────
    # This constrains Holmes to use real tool calls for all data queries and
    # prevents hallucination, multi-step loops, and empty delta chunks.
    $strictSystemPrompt = @'
KUBERNETES ASSISTANT — STRICT EXECUTION MODE

CRITICAL RULE — MANDATORY TOOL USE:
You MUST call a kubectl tool for ANY question about cluster state (pods, nodes, namespaces, services, deployments, etc.).
NEVER answer from memory or generate example data. ALL answers MUST come from real tool output.
If you answer without calling a tool, you are violating this rule.

EXECUTION PROTOCOL (follow exactly):
1. Receive user request about Kubernetes resources.
2. Call EXACTLY ONE appropriate kubectl tool to retrieve real data.
3. Return the tool result directly — no modification, no commentary.
4. STOP. Do not call additional tools.

TOOL SELECTION (use the SIMPLEST tool for the job):
- List resources → kubernetes_tabular_query with appropriate kubectl get command
- Count resources → kubernetes_count
- Describe a resource → kubernetes_tabular_query with kubectl describe

OUTPUT RULES:
- Return ONLY the raw tool output as a clean table or list.
- If tool result is empty → return exactly: No data found
- If tool execution fails → return exactly: Unable to execute tool
- NEVER add explanations, next steps, or commentary after the result.
- NEVER generate example pod names, node names, or namespace names.
- NEVER output "(Call tool ...)" — actually EXECUTE the tool.
- NEVER duplicate the response.
- Output MUST be non-empty (never send empty text).

FORBIDDEN BEHAVIORS:
- Answering without calling a tool first.
- Generating fake/example cluster data (e.g., "example-pod-1", "node1").
- Multi-step tool chains (more than 1 tool per request).
- Appending "No data found" after real tool output.
- Suggesting follow-up actions or next steps.
- Autonomous investigation or root cause analysis unless explicitly requested.
'@

    # ── Python proxy script ───────────────────────────────────────────────────
    # Reads HOLMES_BACKEND_URL from env (set in the Deployment).
    # For POST /api/agui/chat:
    #   REQUEST side: injects the strict system prompt via the ag_ui context field.
    #   RESPONSE side: _SseOutputFilter buffers TEXT_MESSAGE groups and at END:
    #     - Tool-result messages (delta starts with wrench emoji / " result:\n"):
    #       forwarded unchanged — these contain the raw kubectl output.
    #     - LLM-commentary messages: _filter_commentary() extracts only lines that
    #       match kubectl tabular output patterns; everything else (analysis,
    #       recommendations, "Next steps:", markdown) is silently dropped.
    #     - If nothing survives the filter: entire message is suppressed.
    # For SSE responses: also drops empty delta="" chunks (pydantic guard).
    # All other paths: transparent proxy.
    $proxyScript = @'
#!/usr/bin/env python3
"""
HolmesGPT strict-mode proxy.

REQUEST side:
  Injects strict system prompt via the ag_ui context field so Holmes
  operates in deterministic single-tool-call mode.

RESPONSE side (SSE delta filter):
  For every TEXT_MESSAGE_CONTENT SSE event on /api/agui/chat responses:
    1. Parse the JSON envelope (never emit raw text).
    2. Extract the "delta" string.
    3. If delta is empty -> skip event (pydantic guard).
    4. Apply _filter_delta() to the delta string:
       - Detects whether this delta is a tool-result line (starts with wrench
         emoji or contains "result:" near the start) -> pass through unchanged.
       - Otherwise strips commentary lines (analysis, "Next steps:", markdown,
         etc.) while KEEPING all lines that look like kubectl output OR simple
         plain-text list entries (one identifier per line, no prose).
    5. If filtered delta is non-empty -> re-emit the original JSON with only
       the delta field replaced. ALL other fields (type, messageId, ...) are
       preserved exactly.
    6. If filtered delta is empty -> skip the event entirely.
  TEXT_MESSAGE_START / TEXT_MESSAGE_END and all other event types are always
  forwarded unchanged.

JSON envelope is NEVER broken. Only the delta string value is modified.
"""
import json
import logging
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import URLError
from urllib.request import Request, urlopen

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s proxy %(levelname)s %(message)s",
    stream=sys.stdout,
)

BACKEND = os.environ.get(
    "HOLMES_BACKEND_URL",
    "http://holmesgpt-holmes.ai-assistant.svc.cluster.local:80",
).rstrip("/")

SYSTEM_PROMPT_FILE = os.environ.get(
    "HOLMES_STRICT_PROMPT_FILE", "/etc/holmes-proxy/strict_system_prompt.txt"
)

try:
    with open(SYSTEM_PROMPT_FILE, "r", encoding="utf-8") as _f:
        STRICT_PROMPT = _f.read().strip()
    logging.info("Loaded strict system prompt (%d chars)", len(STRICT_PROMPT))
except OSError as _e:
    logging.warning("Could not load strict system prompt from %s: %s", SYSTEM_PROMPT_FILE, _e)
    STRICT_PROMPT = ""

CHAT_PATH_RE = re.compile(r"^/api/agui/chat(/.*)?$")

# ── Delta filtering ────────────────────────────────────────────────────────────

# Prose lines to always drop (case-insensitive prefix match)
_NOISE_RE = re.compile(
    r"(?i)^(it looks like|next steps?|let'?s |you can|you may|you should|"
    r"to (fix|resolve|investigate|check)|additionally|furthermore|note:|tip:|"
    r"warning:|#+\s|```|---+|\*\s|\d+\.\s+[A-Za-z]|>\s|"
    r"this (means|indicates|suggests)|the (above|following|output|result))"
)

# Lines that are clearly kubectl tabular output:
#   header: "NAME   STATUS   AGE" (all-caps tokens separated by 2+ spaces)
#   data:   any line with 2+ consecutive spaces (kubectl column padding)
_KUBECTL_MULTI_COL_RE = re.compile(r"\s{2,}")

# Lines that are clearly a tool_call_metadata prefix (strip entirely)
_TOOL_META_RE = re.compile(r"^tool_call_metadata=\{.*?\}")


def _strip_tool_meta(text: str) -> str:
    """Remove leading tool_call_metadata={...} prefix if present."""
    return _TOOL_META_RE.sub("", text, count=1).lstrip()


def _is_tool_marker(text: str) -> bool:
    """
    Returns True if this delta is a Holmes tool-announcement or tool-result
    prefix emitted by server-agui.py. These are forwarded unchanged.
    """
    # Tool announcement: "🔧 Using Agent tool: `...`..."
    # Tool result:       "🔧 tool_name result:\n..."
    t = text.strip()
    return (
        t.startswith("\U0001f527")  # 🔧 wrench
        or t.startswith("\u2261")   # ≡ triple-bar
        or " result:\n" in text[:120]
        or " result:\r\n" in text[:120]
        or "Using Agent tool:" in text[:80]
    )


def _filter_delta(delta: str) -> str:
    """
    Filter the delta string of a TEXT_MESSAGE_CONTENT event.

    Returns the filtered delta (may be empty string to signal suppression).
    The JSON envelope is handled by the caller — this function only
    works on the plain text content of the delta field.

    Rules:
    - tool_call_metadata={...} prefix is stripped silently.
    - If the result after stripping contains a tool-result marker -> pass through.
    - Otherwise keep lines that are:
        a) kubectl multi-column rows (contain 2+ consecutive spaces)
        b) plain identifiers / names (word chars + common k8s chars: -./_ no spaces)
           These represent kubectl list output: one namespace/pod/node per line.
    - Drop lines that match _NOISE_RE (prose analysis, commentary).
    - If nothing remains -> return "".
    """
    cleaned = _strip_tool_meta(delta)

    if _is_tool_marker(cleaned):
        return delta  # forward tool markers unchanged (don't strip metadata prefix though)

    kept = []
    for raw_line in cleaned.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()

        if not stripped:
            continue  # skip blank lines

        if _NOISE_RE.match(stripped):
            continue  # drop commentary

        if _KUBECTL_MULTI_COL_RE.search(stripped):
            # Has 2+ spaces between tokens -> kubectl tabular row or header
            kept.append(line)
            continue

        # Single-token lines: keep if they look like a k8s identifier
        # (letters, digits, hyphens, dots, slashes, underscores — NO spaces)
        if re.match(r"^[A-Za-z0-9][A-Za-z0-9\-\./\_]*$", stripped):
            kept.append(stripped)
            continue

        # Anything else (prose sentences, multi-word lines without column spacing) -> drop

    result = "\n".join(kept)
    return result


def _is_chat_endpoint(path: str) -> bool:
    return bool(CHAT_PATH_RE.match(path.split("?")[0]))


def _inject_prompt(body_bytes: bytes) -> bytes:
    """Inject STRICT_PROMPT via the context field of RunAgentInput."""
    if not STRICT_PROMPT:
        return body_bytes
    try:
        data = json.loads(body_bytes.decode("utf-8"))
        rules_ctx = {"description": "assistant_behavioral_rules", "value": STRICT_PROMPT}
        existing = data.get("context")
        if isinstance(existing, list):
            data["context"] = [rules_ctx] + existing
        else:
            data["context"] = [rules_ctx]
        logging.info("Injected strict rules via context field (%d chars)", len(STRICT_PROMPT))
        return json.dumps(data).encode("utf-8")
    except Exception as exc:
        logging.warning("Could not inject system prompt: %s", exc)
        return body_bytes


def _process_sse_line(raw_line: bytes) -> bytes | None:
    """
    Process one SSE line (stripped of trailing CR/LF).

    Returns:
      - The original raw_line bytes unchanged (pass-through).
      - A new bytes line with a modified delta (same JSON envelope, delta replaced).
      - None to suppress the line entirely.

    JSON structure is ALWAYS preserved. Only the "delta" string value is changed.
    """
    if not raw_line.startswith(b"data:"):
        return raw_line

    payload = raw_line[5:].strip()
    if not payload or payload == b"[DONE]":
        return raw_line

    try:
        obj = json.loads(payload)
    except Exception:
        return raw_line  # not valid JSON -> pass through unchanged

    ev_type = obj.get("type", "")
    if ev_type not in ("TEXT_MESSAGE_CONTENT", "text_message_content"):
        return raw_line  # non-content events pass through unchanged

    delta = obj.get("delta", "")
    if not isinstance(delta, str):
        return raw_line

    # Drop empty deltas (pydantic guard)
    if len(delta) == 0:
        return None

    # Apply delta filter
    filtered = _filter_delta(delta)

    if filtered == delta:
        return raw_line  # nothing changed -> return original bytes (no re-serialisation)

    if not filtered:
        logging.info("OutputFilter: suppressed delta (%d chars): %r", len(delta), delta[:80])
        return None  # suppress this event entirely

    # Reconstruct the same JSON object with only delta replaced
    obj["delta"] = filtered
    new_payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    logging.info(
        "OutputFilter: filtered delta %d->%d chars",
        len(delta), len(filtered),
    )
    return b"data: " + new_payload


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "HolmesProxy/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: N802
        logging.info("%-4s %s", self.command, self.path)

    def _write_chunk(self, data: bytes) -> None:
        hex_len = format(len(data), "x").encode() + b"\r\n"
        self.wfile.write(hex_len + data + b"\r\n")

    def _forward(self, body: bytes | None = None, filter_output: bool = False):
        target = BACKEND + self.path
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "content-length", "transfer-encoding")
        }
        if body is not None:
            headers["Content-Length"] = str(len(body))

        req = Request(target, data=body, headers=headers, method=self.command)
        try:
            resp = urlopen(req, timeout=620)
        except URLError as exc:
            logging.error("Backend error: %s", exc)
            self.send_response(502)
            self.end_headers()
            return

        self.send_response(resp.status)
        is_sse = False
        for k, v in resp.headers.items():
            if k.lower() == "transfer-encoding":
                continue
            if k.lower() == "content-type" and "text/event-stream" in v:
                is_sse = True
            self.send_header(k, v)

        if is_sse:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for raw_line in resp:
                    line_stripped = raw_line.rstrip(b"\r\n")
                    if filter_output:
                        out = _process_sse_line(line_stripped)
                    else:
                        out = line_stripped
                    if out is not None:
                        self._write_chunk(out + b"\n")
                        self.wfile.flush()
                self._write_chunk(b"")  # terminal chunk
                self.wfile.flush()
            except Exception as exc:
                logging.warning("SSE stream interrupted: %s", exc)
        else:
            resp_body = resp.read()
            self.send_header("Content-Length", str(len(resp_body)))
            self.end_headers()
            self.wfile.write(resp_body)

    def do_GET(self):  # noqa: N802
        self._forward()

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        is_chat = _is_chat_endpoint(self.path)
        if is_chat:
            body = _inject_prompt(body)
        self._forward(body, filter_output=is_chat)

    def do_DELETE(self):  # noqa: N802
        self._forward()

    def do_PUT(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        self._forward(body)

    def do_PATCH(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        self._forward(body)


class ThreadingHTTPServer(HTTPServer):
    def process_request(self, request, client_address):
        t = threading.Thread(target=self._handle, args=(request, client_address))
        t.daemon = True
        t.start()

    def _handle(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


if __name__ == "__main__":
    port = int(os.environ.get("PROXY_PORT", 80))
    logging.info("HolmesGPT proxy listening on :%d -> %s", port, BACKEND)
    srv = ThreadingHTTPServer(("0.0.0.0", port), ProxyHandler)
    srv.serve_forever()
'@
    - If accumulated text starts with the tool-result prefix => FORWARD as-is
      (these carry the actual kubectl output)
    - Otherwise strip LLM commentary:
      * Keep lines that look like kubectl tabular output (NAME/STATUS/AGE columns,
        or list items)
      * Drop everything else (analysis, recommendations, markdown headings, etc.)
      * If the stripped result is non-empty => send it as a single new message
      * If nothing survives the filter => suppress the whole message silently

  Non-TEXT_MESSAGE events (RUN_STARTED, RUN_FINISHED, RUN_ERROR, TOOL_CALL_*)
  are always forwarded unchanged.

Also strips empty SSE delta="" chunks that cause pydantic validation errors
(TextMessageContentEvent: delta must have >= 1 character).
"""
import json
import logging
import os
import re
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import URLError
from urllib.request import Request, urlopen

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s proxy %(levelname)s %(message)s",
    stream=sys.stdout,
)

BACKEND = os.environ.get(
    "HOLMES_BACKEND_URL",
    "http://holmesgpt-holmes.ai-assistant.svc.cluster.local:80",
).rstrip("/")

SYSTEM_PROMPT_FILE = os.environ.get(
    "HOLMES_STRICT_PROMPT_FILE", "/etc/holmes-proxy/strict_system_prompt.txt"
)

try:
    with open(SYSTEM_PROMPT_FILE, "r", encoding="utf-8") as _f:
        STRICT_PROMPT = _f.read().strip()
    logging.info("Loaded strict system prompt (%d chars)", len(STRICT_PROMPT))
except OSError as _e:
    logging.warning("Could not load strict system prompt from %s: %s", SYSTEM_PROMPT_FILE, _e)
    STRICT_PROMPT = ""

CHAT_PATH_RE = re.compile(r"^/api/agui/chat(/.*)?$")

# Lines that look like raw kubectl output:
#   - table header/data rows: at least two whitespace-separated tokens, first is
#     an identifier (upper or mixed case, may include / - _)
#   - namespace lines, event lines, etc.
# We accept a line if it contains a tab or 2+ consecutive spaces between tokens
# (kubectl always uses multi-space column alignment) OR if it is a header row
# (all-caps first word: NAME, NAMESPACE, STATUS, NODE, etc.).
_KUBECTL_HEADER_RE = re.compile(
    r"^[A-Z][A-Z0-9_\-/]*(\s{2,}[A-Z][A-Z0-9_\-/]*)+$"
)
_KUBECTL_DATA_ROW_RE = re.compile(
    r"^\S.*(\s{2,}|\t)\S"
)
# Lines we always drop regardless of anything else
_NOISE_LINE_RE = re.compile(
    r"(?i)^(it looks like|next steps?|you can|check|ensure|note:|tip:|"
    r"warning:|error:|#+\s|```|---|\* |> |\d+\.\s+[A-Z])"
)


def _is_chat_endpoint(path: str) -> bool:
    return bool(CHAT_PATH_RE.match(path.split("?")[0]))


def _inject_prompt(body_bytes: bytes) -> bytes:
    """Inject STRICT_PROMPT via the context field of RunAgentInput."""
    if not STRICT_PROMPT:
        return body_bytes
    try:
        data = json.loads(body_bytes.decode("utf-8"))
        rules_ctx = {"description": "assistant_behavioral_rules", "value": STRICT_PROMPT}
        existing = data.get("context")
        if isinstance(existing, list):
            data["context"] = [rules_ctx] + existing
        else:
            data["context"] = [rules_ctx]
        logging.info("Injected strict rules via context field (%d chars)", len(STRICT_PROMPT))
        return json.dumps(data).encode("utf-8")
    except Exception as exc:
        logging.warning("Could not inject system prompt: %s", exc)
        return body_bytes


def _filter_commentary(text: str) -> str:
    """
    Given the accumulated delta text of a single TEXT_MESSAGE group,
    return only the lines that look like raw kubectl output.
    Returns empty string if nothing survives.
    """
    kept = []
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            # Preserve blank lines between table sections
            if kept and kept[-1] != "":
                kept.append("")
            continue
        if _NOISE_LINE_RE.match(stripped):
            continue
        if _KUBECTL_HEADER_RE.match(stripped) or _KUBECTL_DATA_ROW_RE.match(stripped):
            kept.append(line)
        # Everything else (prose sentences, short words, etc.) is dropped
    # Trim trailing blank lines
    while kept and kept[-1] == "":
        kept.pop()
    return "\n".join(kept)


def _is_tool_result_message(text: str) -> bool:
    """
    Tool-result messages emitted by server-agui.py always start with the
    rocket/wrench emoji prefix: "=F tool_name result:\n..."
    We detect these and forward them unchanged (the kubectl output is already
    inside the text after the first line).
    """
    return bool(text) and (
        text.startswith("\U0001f527")   # wrench emoji
        or text.startswith("\u2261")    # triple-bar (fallback rendering)
        or text.startswith("=F")        # ASCII fallback in some terminals
        or " result:\n" in text[:120]   # content-based fallback
        or " result:\r\n" in text[:120]
    )


def _sse_event(obj: dict) -> bytes:
    return b"data: " + json.dumps(obj, ensure_ascii=False).encode("utf-8") + b"\n"


def _build_text_message_events(mid: str, text: str) -> list[bytes]:
    """Emit a complete START / CONTENT / END triplet for the given text."""
    return [
        _sse_event({"type": "TEXT_MESSAGE_START", "messageId": mid, "role": "assistant"}),
        _sse_event({"type": "TEXT_MESSAGE_CONTENT", "messageId": mid, "delta": text}),
        _sse_event({"type": "TEXT_MESSAGE_END", "messageId": mid}),
    ]


class _SseOutputFilter:
    """
    Stateful per-request SSE output filter.

    Buffers TEXT_MESSAGE groups (START → N×CONTENT → END).
    At END decides whether to forward the raw buffered events, replace them
    with a filtered version, or suppress them entirely.
    All other event types pass through immediately.
    """

    def __init__(self):
        self._pending_id: str | None = None        # messageId currently buffering
        self._pending_raw: list[bytes] = []        # raw SSE lines for current group
        self._pending_text: str = ""               # accumulated delta text

    def feed(self, raw_line: bytes) -> list[bytes]:
        """
        Feed one raw SSE line (already stripped of trailing newline).
        Returns a list of SSE line bytes to emit (may be empty).
        """
        if not raw_line.startswith(b"data:"):
            return [raw_line]

        payload = raw_line[5:].strip()
        if not payload or payload == b"[DONE]":
            return [raw_line]

        try:
            obj = json.loads(payload)
        except Exception:
            return [raw_line]

        ev_type = obj.get("type", "")

        # ── TEXT_MESSAGE_START ────────────────────────────────────────────────
        if ev_type in ("TEXT_MESSAGE_START", "text_message_start"):
            self._pending_id = obj.get("messageId")
            self._pending_raw = [raw_line]
            self._pending_text = ""
            return []   # hold until END

        # ── TEXT_MESSAGE_CONTENT ──────────────────────────────────────────────
        if ev_type in ("TEXT_MESSAGE_CONTENT", "text_message_content"):
            delta = obj.get("delta", "")
            if not isinstance(delta, str) or len(delta) == 0:
                return []   # drop empty deltas (pydantic guard)
            self._pending_raw.append(raw_line)
            self._pending_text += delta
            return []   # hold until END

        # ── TEXT_MESSAGE_END ──────────────────────────────────────────────────
        if ev_type in ("TEXT_MESSAGE_END", "text_message_end"):
            self._pending_raw.append(raw_line)
            text = self._pending_text
            mid = self._pending_id or str(uuid.uuid4())
            raw_events = list(self._pending_raw)
            self._pending_id = None
            self._pending_raw = []
            self._pending_text = ""

            # Tool-announcement messages ("=F Using Agent tool: `...`...")
            # and tool-result messages: forward as-is
            if _is_tool_result_message(text):
                logging.debug("OutputFilter: forwarding tool-result message (%d chars)", len(text))
                return raw_events

            # Everything else: try to extract kubectl table lines
            filtered = _filter_commentary(text)
            if filtered:
                logging.info(
                    "OutputFilter: replaced LLM commentary (%d chars) with kubectl output (%d chars)",
                    len(text), len(filtered),
                )
                return _build_text_message_events(mid, filtered)
            else:
                logging.info(
                    "OutputFilter: suppressed LLM commentary (%d chars): %r",
                    len(text), text[:120],
                )
                return []   # suppress entirely

        # ── All other events (RUN_STARTED, RUN_FINISHED, RUN_ERROR, TOOL_CALL_*) ──
        return [raw_line]


class ProxyHandler(BaseHTTPRequestHandler):
    server_version = "HolmesProxy/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: N802
        logging.info("%-4s %s", self.command, self.path)

    def _write_chunk(self, data: bytes) -> None:
        hex_len = format(len(data), "x").encode() + b"\r\n"
        self.wfile.write(hex_len + data + b"\r\n")

    def _forward(self, body: bytes | None = None, filter_output: bool = False):
        target = BACKEND + self.path
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "content-length", "transfer-encoding")
        }
        if body is not None:
            headers["Content-Length"] = str(len(body))

        req = Request(target, data=body, headers=headers, method=self.command)
        try:
            resp = urlopen(req, timeout=620)
        except URLError as exc:
            logging.error("Backend error: %s", exc)
            self.send_response(502)
            self.end_headers()
            return

        self.send_response(resp.status)
        is_sse = False
        for k, v in resp.headers.items():
            if k.lower() == "transfer-encoding":
                continue
            if k.lower() == "content-type" and "text/event-stream" in v:
                is_sse = True
            self.send_header(k, v)

        if is_sse:
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            output_filter = _SseOutputFilter() if filter_output else None
            try:
                for raw_line in resp:
                    line_stripped = raw_line.rstrip(b"\r\n")
                    if output_filter is not None:
                        out_lines = output_filter.feed(line_stripped)
                    else:
                        out_lines = [line_stripped]
                    for out in out_lines:
                        chunk = out + b"\n"
                        self._write_chunk(chunk)
                        self.wfile.flush()
                self._write_chunk(b"")   # terminal chunk
                self.wfile.flush()
            except Exception as exc:
                logging.warning("SSE stream interrupted: %s", exc)
        else:
            resp_body = resp.read()
            self.send_header("Content-Length", str(len(resp_body)))
            self.end_headers()
            self.wfile.write(resp_body)

    def do_GET(self):  # noqa: N802
        self._forward()

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        is_chat = _is_chat_endpoint(self.path)
        if is_chat:
            body = _inject_prompt(body)
        self._forward(body, filter_output=is_chat)

    def do_DELETE(self):  # noqa: N802
        self._forward()

    def do_PUT(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        self._forward(body)

    def do_PATCH(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        self._forward(body)


class ThreadingHTTPServer(HTTPServer):
    def process_request(self, request, client_address):
        t = threading.Thread(target=self._handle, args=(request, client_address))
        t.daemon = True
        t.start()

    def _handle(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


if __name__ == "__main__":
    port = int(os.environ.get("PROXY_PORT", 80))
    logging.info("HolmesGPT proxy listening on :%d -> %s", port, BACKEND)
    srv = ThreadingHTTPServer(("0.0.0.0", port), ProxyHandler)
    srv.serve_forever()
'@

    # Write the strict system prompt to a temp file, then create a ConfigMap
    $tmpPrompt = [System.IO.Path]::GetTempFileName() + '.txt'
    [System.IO.File]::WriteAllText($tmpPrompt, $strictSystemPrompt, [System.Text.Encoding]::UTF8)
    $tmpScript = [System.IO.Path]::GetTempFileName() + '.py'
    [System.IO.File]::WriteAllText($tmpScript, $proxyScript, [System.Text.Encoding]::ASCII)

    $cmResult = Invoke-Kubectl -Params 'create', 'configmap', 'holmesgpt-proxy-config',
        '-n', 'default',
        "--from-file=strict_system_prompt.txt=$tmpPrompt",
        "--from-file=proxy.py=$tmpScript",
        '--dry-run=client', '-o', 'yaml'
    $tmpYaml = [System.IO.Path]::GetTempFileName() + '.yaml'
    $cmResult.Output | Set-Content $tmpYaml -Encoding UTF8
    (Invoke-Kubectl -Params 'apply', '-f', $tmpYaml).Output | Write-Log
    Remove-Item $tmpYaml, $tmpPrompt, $tmpScript -Force -ErrorAction SilentlyContinue

    # Deployment + Service manifests
    $manifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: holmesgpt-proxy
  namespace: default
  labels:
    app: holmesgpt-proxy
    app.kubernetes.io/part-of: ai-assistant
    app.kubernetes.io/managed-by: k2s
spec:
  replicas: 1
  selector:
    matchLabels:
      app: holmesgpt-proxy
  template:
    metadata:
      labels:
        app: holmesgpt-proxy
        app.kubernetes.io/part-of: ai-assistant
    spec:
      nodeSelector:
        kubernetes.io/os: linux
      containers:
        - name: proxy
          image: python:3.11-alpine
          imagePullPolicy: IfNotPresent
          command: ["python3", "/etc/holmes-proxy/proxy.py"]
          ports:
            - containerPort: 80
          env:
            - name: HOLMES_BACKEND_URL
              value: "http://holmesgpt-holmes.ai-assistant.svc.cluster.local:80"
            - name: HOLMES_STRICT_PROMPT_FILE
              value: "/etc/holmes-proxy/strict_system_prompt.txt"
            - name: PROXY_PORT
              value: "80"
          volumeMounts:
            - name: proxy-config
              mountPath: /etc/holmes-proxy
              readOnly: true
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 128Mi
      volumes:
        - name: proxy-config
          configMap:
            name: holmesgpt-proxy-config
            defaultMode: 0755
---
apiVersion: v1
kind: Service
metadata:
  name: holmesgpt-holmes
  namespace: default
  labels:
    app.kubernetes.io/name: holmesgpt
    app.kubernetes.io/part-of: ai-assistant
    app.kubernetes.io/managed-by: k2s
  annotations:
    k2s.ai-assistant/proxy-target: "holmesgpt-holmes.ai-assistant.svc.cluster.local"
spec:
  type: ClusterIP
  selector:
    app: holmesgpt-proxy
  ports:
    - name: agui
      port: 80
      targetPort: 80
      protocol: TCP
"@

    $tmpFile = [System.IO.Path]::GetTempFileName() + '.yaml'
    Set-Content -Path $tmpFile -Value $manifest -Encoding UTF8
    $result = Invoke-Kubectl -Params 'apply', '-f', $tmpFile
    $result.Output | Write-Log
    Remove-Item -Path $tmpFile -Force -ErrorAction SilentlyContinue

    if (-not $result.Success) {
        throw '[AI-Assistant] Failed to apply HolmesGPT proxy deployment/service in default namespace'
    }

    Write-Log '[AI-Assistant] Waiting for HolmesGPT proxy pod to be ready...' -Console
    $ready = Wait-ForPodCondition -Condition Ready -Label 'app=holmesgpt-proxy' -Namespace 'default' -TimeoutSeconds 90
    if (-not $ready) {
        Write-Log '[AI-Assistant] Warning: HolmesGPT proxy pod did not become ready within 90s. Check: kubectl get pods -n default -l app=holmesgpt-proxy' -Console
    } else {
        Write-Log '[AI-Assistant] HolmesGPT smart proxy is ready.' -Console
    }

    # ── SSE Direct-Route Ingress ───────────────────────────────────────────────
    # Bypasses the K8s apiserver service proxy (which buffers SSE streams) by
    # routing the HolmesGPT path directly from ingress-nginx to holmesgpt-holmes
    # in ai-assistant namespace with proxy-buffering off.
    Write-Log '[AI-Assistant] Applying SSE direct-route ingress...' -Console
    $sseResult = Invoke-Kubectl -Params 'apply', '-f', (Get-HolmesSseIngressPath)
    $sseResult.Output | Write-Log
    if (-not $sseResult.Success) {
        # Non-fatal: the nginx proxy still works; SSE streaming may be impaired
        Write-Log '[AI-Assistant] Warning: Failed to apply SSE ingress. SSE streaming may buffer. Check: kubectl get ingress -n ai-assistant' -Console
    } else {
        Write-Log '[AI-Assistant] SSE direct-route ingress applied.' -Console
    }
}

<#
.SYNOPSIS
Removes the Python smart proxy pod/Service for HolmesGPT from the 'default' namespace.
#>
function Remove-HolmesProxyEndpoints {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Removing HolmesGPT proxy resources from default namespace...' -Console
    (Invoke-Kubectl -Params 'delete', 'deployment',  'holmesgpt-proxy',       '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'configmap',   'holmesgpt-proxy-config','-n', 'default', '--ignore-not-found').Output | Write-Log
    # Also remove legacy nginx ConfigMap from older versions
    (Invoke-Kubectl -Params 'delete', 'configmap',   'holmesgpt-nginx-conf',  '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service',     'holmesgpt-holmes',      '-n', 'default', '--ignore-not-found').Output | Write-Log
    # Remove the SSE direct-route ingress and the bridge service
    (Invoke-Kubectl -Params 'delete', 'ingress', 'holmesgpt-sse-direct',    '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service', 'holmesgpt-proxy-bridge',  '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    # Also clean up legacy resources from older versions
    (Invoke-Kubectl -Params 'delete', 'endpointslice', 'holmesgpt-holmes-k2s', '-n', 'default', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'endpoints',     'holmesgpt-holmes',     '-n', 'default', '--ignore-not-found').Output | Write-Log
}

<#
.SYNOPSIS
Creates the /data/ollama directory on the kubemaster Linux node via SSH.
This directory backs the static PV used by the Ollama models PVC.
Idempotent - safe to call when the directory already exists.
#>
function New-OllamaDataDirectory {
    [CmdletBinding()]
    Param()
    Write-Log '[AI-Assistant] Creating /data/ollama on kubemaster...' -Console
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 10 -CmdToExecute 'sudo mkdir -m 777 -p /data/ollama').Output | Write-Log
    Write-Log '[AI-Assistant] /data/ollama directory ready.' -Console
}

<#
.SYNOPSIS
Creates (or updates) the 'zscaler-ca' ConfigMap in the ai-assistant namespace
using the ZScaler root CA certificate that is already committed to the K2s repo.
The Ollama init-container mounts this ConfigMap to trust the corporate proxy.
Idempotent - safe to call when the ConfigMap already exists.
#>
function New-ZscalerCaConfigMap {
    [CmdletBinding()]
    Param()

    Write-Log '[AI-Assistant] Creating ZScaler CA ConfigMap for Ollama proxy trust...' -Console

    # Use the cert committed to the K2s repo - no SSH needed
    $certPath = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/linuxnode/setup/certificate/ZScalerRootCA.crt"
    $certPath = [System.IO.Path]::GetFullPath($certPath)

    if (-not (Test-Path $certPath)) {
        Write-Log "[AI-Assistant] Warning: ZScaler CA cert not found at '$certPath' - skipping ConfigMap." -Console
        return
    }

    # Strip SPDX header lines (lines starting with #) - keep only the PEM block
    $lines = Get-Content $certPath
    $pemLines = $lines | Where-Object { $_ -notmatch '^\s*#' }
    $tmpPem = [System.IO.Path]::GetTempFileName() + '.pem'
    $pemLines | Set-Content $tmpPem -Encoding ASCII

    $r = Invoke-Kubectl -Params 'create', 'configmap', 'zscaler-ca',
        '-n', 'ai-assistant',
        "--from-file=ZScalerRootCA.pem=$tmpPem",
        '--dry-run=client', '-o', 'yaml'
    $tmpYaml = [System.IO.Path]::GetTempFileName() + '.yaml'
    $r.Output | Set-Content $tmpYaml -Encoding UTF8
    (Invoke-Kubectl -Params 'apply', '-f', $tmpYaml).Output | Write-Log
    Remove-Item $tmpYaml -Force -ErrorAction SilentlyContinue

    Remove-Item $tmpPem -Force -ErrorAction SilentlyContinue
    Write-Log '[AI-Assistant] ZScaler CA ConfigMap ready.' -Console
}



function Invoke-OllamaModelPull {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true)]
        [string] $Model
    )

    Write-Log "[AI-Assistant] Waiting for Ollama pod to be ready..." -Console
    $ollamaReady = Wait-ForPodCondition -Condition Ready -Label 'app=ollama' -Namespace 'ai-assistant' -TimeoutSeconds 180
    if (-not $ollamaReady) {
        throw '[AI-Assistant] Ollama pod did not become ready within 180s'
    }

    # Get the Ollama ClusterIP so we can POST to /api/pull directly from kubemaster.
    # This bypasses the proxy issue: the Ollama *server* correctly uses the system
    # proxy (HTTPS_PROXY in the container) to reach registry.ollama.ai, while our
    # Python client talks to the ClusterIP (cluster-internal, NO_PROXY range).
    $clusterIP = (Invoke-Kubectl -Params 'get', 'svc', 'ollama', '-n', 'ai-assistant',
        '-o', 'jsonpath={.spec.clusterIP}').Output
    if ([string]::IsNullOrWhiteSpace($clusterIP)) {
        throw '[AI-Assistant] Could not resolve ClusterIP for Ollama service'
    }

    Write-Log "[AI-Assistant] Pulling Ollama model '$Model' via REST API at $clusterIP:11434 ..." -Console
    Write-Log "[AI-Assistant] (This may take several minutes - model is ~2 GB)" -Console

    # Write a small Python script to /tmp on kubemaster and run it via SSH.
    # Python is always present on the Debian kubemaster node.
    $pyScript = @"
import urllib.request, json, sys
url = 'http://${clusterIP}:11434/api/pull'
payload = json.dumps({'model': '${Model}', 'stream': True}).encode()
req = urllib.request.Request(url, data=payload,
    headers={'Content-Type': 'application/json'}, method='POST')
try:
    with urllib.request.urlopen(req, timeout=600) as resp:
        for line in resp:
            try:
                d = json.loads(line.decode())
                status = d.get('status', '')
                if 'total' in d and 'completed' in d and d['total']:
                    pct = int(100 * d['completed'] / d['total'])
                    print(f'  {status}: {pct}%', flush=True)
                elif status:
                    print(f'  {status}', flush=True)
            except Exception:
                pass
    print('success', flush=True)
except Exception as e:
    print(f'error: {e}', file=sys.stderr, flush=True)
    sys.exit(1)
"@

    $tmpPy = [System.IO.Path]::GetTempFileName() + '.py'
    $pyScript | Set-Content $tmpPy -Encoding ASCII
    Copy-ToControlPlaneViaSSHKey -Source $tmpPy -Target '/tmp/ollama_pull.py'
    Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue

    $pullResult = Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'python3 /tmp/ollama_pull.py' -Timeout 620
    $pullResult.Output | Write-Log
    Remove-Item $tmpPy -Force -ErrorAction SilentlyContinue

    if (-not $pullResult.Success -or ($pullResult.Output -notmatch 'success')) {
        throw "[AI-Assistant] 'ollama pull $Model' failed. See log for details."
    }
    Write-Log "[AI-Assistant] Model '$Model' pulled successfully." -Console
}

<#
.SYNOPSIS
Waits for the HolmesGPT deployment to become available.
#>
function Wait-ForHolmesAvailable {
    return (Wait-ForPodCondition -Condition Ready -Label 'app=holmesgpt' -Namespace 'ai-assistant' -TimeoutSeconds 120)
}

<#
.SYNOPSIS
Removes all ai-assistant addon resources. Optionally keeps the Ollama model PVC.
#>
function Remove-AiAssistantResources {
    [CmdletBinding()]
    Param(
        [switch] $KeepModelData = $false
    )

    # ── HolmesGPT ─────────────────────────────────────────────────────────────
    # Delete the cross-namespace proxy resources first (explicitly, since
    # 'kubectl delete -f' only deletes resources listed in the file - the
    # Endpoints object is created dynamically by Set-HolmesProxyEndpoints).
    Remove-HolmesProxyEndpoints

    Write-Log '[AI-Assistant] Removing HolmesGPT workload resources...' -Console
    (Invoke-Kubectl -Params 'delete', 'deployment',  'holmesgpt-holmes',        '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service',     'holmesgpt-holmes',        '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'configmap',   'holmesgpt-model-config',  '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'serviceaccount', 'holmesgpt',            '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log

    # Cluster-scoped RBAC must be deleted explicitly (namespace deletion won't remove them)
    (Invoke-Kubectl -Params 'delete', 'clusterrolebinding', 'holmesgpt-reader', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'clusterrole',        'holmesgpt-reader', '--ignore-not-found').Output | Write-Log

    # ── Ollama ─────────────────────────────────────────────────────────────────
    Write-Log '[AI-Assistant] Removing Ollama resources...' -Console
    (Invoke-Kubectl -Params 'delete', 'deployment',     'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'service',        'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    (Invoke-Kubectl -Params 'delete', 'serviceaccount', 'ollama', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log

    if ($KeepModelData) {
        # Keep PVC and PV (and namespace so the PVC can live in it)
        Write-Log '[AI-Assistant] Ollama PVC/PV preserved - namespace kept for PVC residency.' -Console
    }
    else {
        # Delete PVC then the static PV, then the namespace
        (Invoke-Kubectl -Params 'delete', 'pvc', 'ollama-models', '-n', 'ai-assistant', '--ignore-not-found').Output | Write-Log
        (Invoke-Kubectl -Params 'delete', 'pv', 'ollama-models-pv', '--ignore-not-found').Output | Write-Log
        Write-Log '[AI-Assistant] Deleting ai-assistant namespace...' -Console
        (Invoke-Kubectl -Params 'delete', 'namespace', 'ai-assistant', '--ignore-not-found').Output | Write-Log
    }
}

<#
.SYNOPSIS
Writes post-installation usage notes for the AI Assistant addon.
#>
function Write-AiAssistantUsageForUser {
    [CmdletBinding()]
    Param(
        [string] $Model = 'llama3.2'
    )
    @"

                AI ASSISTANT ADDON - USAGE NOTES

 The AI Assistant addon has deployed:
   - Ollama  (local LLM runtime, namespace: ai-assistant)
   - HolmesGPT (Kubernetes AI agent,  namespace: ai-assistant)
   - AI Assistant Headlamp plugin     (injected into dashboard)

 To use the AI Assistant:
   1. Open the Headlamp dashboard:
      k2s addons status dashboard   (shows the URL / port-forward command)

   2. Click the AI icon in the top-right app bar of Headlamp.

   3. On first use, go to Settings → AI Assistant and configure:
        Provider  : Local Models
        Base URL  : http://ollama.ai-assistant.svc.cluster.local:11434
                    (or use port-forward: kubectl port-forward svc/ollama -n ai-assistant 11434:11434)
        Model     : $Model

   4. Holmes agent:
      The plugin auto-detects HolmesGPT via the K8s service proxy.
      If it shows "disconnected", verify the pod is running:
        kubectl get pods -n ai-assistant -l app=holmesgpt

 To pull an additional Ollama model later:
   kubectl exec -n ai-assistant deployment/ollama -- ollama pull <model-name>

 NOTE: Model files are stored in a PersistentVolumeClaim (ollama-models).
 Disabling the addon with '--keep-model-data' preserves downloaded models.

"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

Export-ModuleMember -Function `
    Get-AiAssistantManifestsDir, Get-OllamaManifestPath, Get-HolmesManifestPath, Get-HolmesSseIngressPath, `
    Set-HolmesModelConfig, Set-HolmesProxyEndpoints, Remove-HolmesProxyEndpoints, `
    New-OllamaDataDirectory, New-ZscalerCaConfigMap, Invoke-OllamaModelPull, `
    Wait-ForHolmesAvailable, Remove-AiAssistantResources, Write-AiAssistantUsageForUser

