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

    # Explicitly pin the MODEL env var after apply. kubectl client-side apply stores the
    # full manifest (with MODEL_PLACEHOLDER still in the annotation) so a subsequent apply
    # would silently revert the live value back to MODEL_PLACEHOLDER. Using 'kubectl set env'
    # here ensures the correct value wins regardless of annotation state.
    $envModel = "openai/$Model"
    $patchResult = Invoke-Kubectl -Params 'set', 'env', 'deployment/holmesgpt-holmes',
        '-n', 'ai-assistant', "MODEL=$envModel"
    $patchResult.Output | Write-Log
    if (-not $patchResult.Success) {
        Write-Log "[AI-Assistant] Warning: failed to pin MODEL env to '$envModel' after apply — manual check recommended." -Console
    }
    else {
        Write-Log "[AI-Assistant] MODEL env pinned to '$envModel'." -Console
    }
}

<#
.SYNOPSIS
Deploys a Python-based smart proxy pod + selector-based Service in the default
namespace that forwards to the real HolmesGPT service in ai-assistant.

BACKGROUND
The Headlamp AI Assistant plugin hardcodes HOLMES_SERVICE_NAMESPACE=default and uses
the K8s API server proxy path:
  /api/v1/namespaces/default/services/holmesgpt-holmes:80/proxy/...

K8s apiserver proxy validation requires:
  1. The Service must have a spec.selector (selectorless ClusterIP -> NotFound).
  2. Endpoint addresses must have a valid targetRef whose namespace matches the
     Endpoints namespace - cross-namespace pod refs are rejected.

The only correct cross-namespace approach is a real pod in default relaying to
ai-assistant. The Python proxy (python:3.11-alpine) adds two behaviours:
  1. REQUEST  - injects the strict system prompt into the ag_ui context[] field
               so Holmes operates in deterministic single-tool-call mode.
  2. RESPONSE - filters each TEXT_MESSAGE_CONTENT SSE event: modifies only the
               delta string (never the JSON envelope), stripping LLM commentary
               while preserving kubectl tabular output and identifier lists.
               Empty delta="" events are also dropped (pydantic guard).

Architecture:
  Headlamp plugin
    -> K8s apiserver proxy (/namespaces/default/services/holmesgpt-holmes:80/proxy/...)
    -> Python proxy pod in default (selector: app=holmesgpt-proxy)
    -> holmesgpt-holmes.ai-assistant.svc.cluster.local:80
    -> HolmesGPT pod in ai-assistant
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

ABSOLUTE RULE — NO EXCEPTIONS:
Every single user message requires a REAL tool call. No matter what.
NEVER answer from memory, conversation history, or prior tool results.
NEVER generate, guess, or invent resource names (node1, pod1, etc.).
Cluster state changes constantly — always fetch fresh data with a tool.

EXECUTION PROTOCOL (follow exactly):
1. Receive user request about Kubernetes resources.
2. Call the appropriate kubectl tool(s) to retrieve REAL live data.
   Maximum 2 tool calls per request. STOP after the second tool call.
3. After the final tool returns, write a text response with the REAL tool output.
4. STOP. Do not call additional tools beyond the 2-call maximum.

CRITICAL — ALWAYS WRITE A FINAL TEXT RESPONSE:
- After EVERY tool call sequence you MUST emit a final text message to the user.
- The final text MUST contain the actual tool result.
- NEVER stop after tool execution without sending a text response.
- If the tool returned data → write it out as your final response.
- If the tool returned empty → write exactly: No data found
- If the tool failed → write exactly: Unable to execute tool

════════════════════════════════════════════════════════
FAILED / CRASHED / ERROR PODS — EXACT PROTOCOL
════════════════════════════════════════════════════════
Triggers: "list failed pods", "show crashed pods", "any failing pods",
          "why is X failing", "what is wrong with X", "pod errors",
          "CrashLoopBackOff", "Error pods", "problem pods"

STEP 1 — List ALL pods WITH namespace column:
  Call kubernetes_tabular_query with:
    kind=pods
    columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase
  This gives you both NAMESPACE and NAME for every pod.
  Do NOT filter — retrieve all pods.

STEP 2 — Describe the first failed pod:
  From Step 1 output, find pods where STATUS is NOT "Running" AND NOT "Succeeded".
  Take the FIRST such pod. Note its exact NAME and NAMESPACE from the Step 1 output.
  Call kubectl_describe with:
    kind=pod
    name=<exact NAME from Step 1>
    namespace=<exact NAMESPACE from Step 1>
  CRITICAL: kubectl_describe is the ONLY allowed second tool for this query.
  DO NOT call kubernetes_tabular_query again.
  DO NOT call fetch_pod_logs.
  DO NOT call kubectl_events.

STEP 3 — Write final response:
  List ALL non-Running/non-Succeeded pods found in Step 1 (name + namespace + status).
  For the first failed pod, include from Step 2 describe output:
    - Container name
    - State / Last State → Reason, Exit Code
    - Started / Finished timestamps
    - Message (if present)
  If NO failed pods found in Step 1 → respond: "All pods are Running or Succeeded — no failures found."

════════════════════════════════════════════════════════
OTHER QUERY TYPES
════════════════════════════════════════════════════════
- List resources        → kubernetes_tabular_query (list ALL, pick matching item yourself)
- Count resources       → kubernetes_count
- Why is pod restarting → TWO steps:
    Step 1: kubernetes_tabular_query kind=pods
            columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase
            Scan ALL namespaces. Pick the matching pod name yourself.
    Step 2: kubectl_describe kind=pod name=<exact name> namespace=<exact namespace from Step 1>
    kubectl_describe shows Last State, Reason, Exit Code, Restart Count.
    Use describe, NOT events, NOT fetch_pod_logs.
- Events for a known resource → kubectl_events (resource_type, resource_name, namespace)
- Describe a known resource   → kubectl_describe kind=<kind> name=<name> namespace=<ns>

════════════════════════════════════════════════════════
OUTPUT RULES
════════════════════════════════════════════════════════
- Return ONLY the real tool output. No explanations, no commentary, no next steps.
- NEVER generate or invent pod names, node names, or namespace names.
- Output MUST be non-empty (never send empty text).
- For describe output: include Name, Namespace, Status, Container name,
  State→Reason, Exit Code, Started, Finished, Message. These are DIAGNOSTIC DATA.

════════════════════════════════════════════════════════
ABSOLUTELY FORBIDDEN — ZERO TOLERANCE
════════════════════════════════════════════════════════
- Calling kubernetes_tabular_query MORE THAN ONCE per request.
- Calling fetch_pod_logs for crash/failure diagnosis (use kubectl_describe instead).
- Answering without calling a tool.
- Generating fake cluster data (node1, pod1, example-pod-1, etc.).
- Stopping after tool execution without writing a final text response.
- More than 2 tool calls per request.
- Using kubectl_events for restart/crash diagnosis.
- Suggesting follow-up actions or next steps.
'@

    # ── Python proxy script ───────────────────────────────────────────────────
    # Reads HOLMES_BACKEND_URL from env (set in the Deployment).
    #
    # REQUEST  — POST /api/agui/chat: injects the strict system prompt via the
    #            ag_ui context[] field (server-agui.py inserts it as a system
    #            message).  Keeps the ask field clean; no broken planning calls.
    #
    # RESPONSE — Each TEXT_MESSAGE_CONTENT SSE event is processed individually:
    #            the "delta" string is filtered in-place (JSON envelope untouched).
    #            tool_call_metadata={} prefix is stripped; tool markers pass through;
    #            kubectl multi-column rows and single k8s identifiers are kept;
    #            prose commentary is dropped.  Empty delta="" events are suppressed.
    #
    # All other HTTP paths and SSE event types: transparent proxy.
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
       - If delta is a tool-result block (starts with wrench emoji AND contains
         "result:") -> extract the table, format it, return header + formatted.
       - If delta is a tool-announcement line -> pass through unchanged.
       - Otherwise strip commentary lines while keeping kubectl output lines
         and plain k8s identifier lists.
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

# When RAW_OUTPUT=true the formatter is bypassed and raw kubectl text is returned.
RAW_OUTPUT = os.environ.get("RAW_OUTPUT", "false").strip().lower() == "true"

# ── Regex helpers ──────────────────────────────────────────────────────────────

# Lines that are clearly kubectl tabular output: 2+ consecutive spaces between tokens.
_KUBECTL_MULTI_COL_RE = re.compile(r"\S  +\S")

# Prose lines to always drop (case-insensitive prefix match).
# NOTE: patterns here must NOT match kubectl events/describe output — those
# contain diagnostic data and must reach the user.
_NOISE_RE = re.compile(
    r"(?i)^("
    r"here (are|is)|the (pods?|nodes?|services?|namespaces?|deployments?) "
    r"(in|for|of|are|is)|pods? in |nodes? in |services? in |namespaces? in |"
    r"(pods?|nodes?|services?|namespaces?|deployments?):\s*$|"
    r"this (means|indicates|suggests)|the (above|following|output|result)|"
    r"to (fix|resolve|investigate|check)|additionally|furthermore|note:|tip:|"
    r"next steps?|follow[- ]up|investigation|analysis|root cause|"
    r"i (found|see|notice|recommend|suggest)|you (can|should|may|might)|"
    r"please |running |#+ |\* |\d+\. "
    r")"
)

# kubectl events output lines — always pass through the filter.
# Format: "LAST SEEN   TYPE     REASON     OBJECT    MESSAGE"
# or data rows like: "2m   Warning  OOMKilled  pod/x-abc  container exceeded memory"
_EVENTS_HEADER_RE = re.compile(
    r"^(LAST[\s_]?SEEN|LAST SEEN)\s+(TYPE|REASON|OBJECT|MESSAGE)",
    re.IGNORECASE
)
_EVENTS_ROW_RE = re.compile(
    r"^(\d+[smhd]|\d+[smhd]\s+\d+[smhd]|<unknown>)\s+(Normal|Warning)\s+\S",
    re.IGNORECASE
)

# kubectl describe output lines — key: value pairs always pass through.
# kubectl describe uses 0–16 spaces of indentation at various levels:
#   "Name:             cert-manager-..."   (0 spaces)
#   "  Reason:         OOMKilled"          (2 spaces)
#   "    Last State:   Terminated"         (4 spaces)
#   "      Exit Code:  1"                  (6 spaces)
#   "        Message:  ..."                (8 spaces)
_DESCRIBE_KV_RE = re.compile(
    r"^\s{0,16}[A-Z][A-Za-z0-9\s\-/]+:\s+\S",
)

# Section headers and diagnostic keywords that must always pass through.
# e.g. "Last State:", "Conditions:", "Containers:", "Restart Count:"
_DESCRIBE_SECTION_RE = re.compile(
    r"^\s{0,16}(Last State|Restart Count|Exit Code|Reason|Message|"
    r"Ready|State|Conditions|Containers|Volumes|Events|Liveness|"
    r"Readiness|QoS Class|Node-Selectors|Tolerations|Controlled By|"
    r"Name|Namespace|Status|Phase|Node|Image|Started|Finished|Signal|"
    r"Labels|Annotations|IP|IPs|Container ID|Host IP|Pod IP|"
    r"Init Containers|Ephemeral Containers|Priority|"
    r"Termination Message|Environment|Mounts)[\s:]+",
    re.IGNORECASE
)

# Indented continuation lines for multi-line describe values (e.g. Message: body text)
# These appear as lines with leading whitespace but no colon (not a new key).
# Example: "      Error from server: ..."  after "  Message:" line
_DESCRIBE_CONTINUATION_RE = re.compile(
    r"^\s{4,16}\S"  # 4–16 spaces indent, then non-whitespace (continuation body)
)

# ── Table helpers ──────────────────────────────────────────────────────────────

# Column headers that indicate the resource type when present.
# Both NAME+STATUS+ROLES+AGE+VERSION (nodes) and NAME+READY+STATUS+RESTARTS+AGE (pods)
# before READY — both variants must be listed so _detect_resource_type() can match.
_TYPE_HINTS = {
    frozenset(["NAME", "STATUS", "ROLES", "AGE", "VERSION"]): "Nodes",
    frozenset(["NAME", "OS", "VERSION"]): "Nodes",            # simplified node columns (no array JSONPath)
    frozenset(["NAME", "READY", "STATUS", "RESTARTS", "AGE"]): "Pods",
    frozenset(["NAME", "NAMESPACE", "READY", "STATUS", "RESTARTS", "AGE"]): "Pods",  # wide/all-ns
    frozenset(["NAME", "TYPE", "CLUSTER-IP", "EXTERNAL-IP", "PORT(S)", "AGE"]): "Services",
    frozenset(["NAME", "READY", "UP-TO-DATE", "AVAILABLE", "AGE"]): "Deployments",
    frozenset(["NAME", "COMPLETIONS", "DURATION", "AGE"]): "Jobs",
}

# Which column (by header name) holds the primary status/state value.
_STATUS_COLS = {"STATUS", "READY", "PHASE"}
# Which column is the "name" column.
_NAME_COL = "NAME"

# Known kubectl column-header tokens — used to detect "header-only" output
# that carries no real data (e.g. LLM echoing "NAME  STATUS" without rows).
_KNOWN_HEADER_TOKENS = frozenset([
    "NAME", "NAMESPACE", "STATUS", "READY", "RESTARTS", "AGE", "VERSION",
    "ROLES", "TYPE", "CLUSTER-IP", "EXTERNAL-IP", "PORT", "PORT(S)",
    "OS", "COMPLETIONS", "DURATION", "UP-TO-DATE", "AVAILABLE", "PHASE",
    "SELECTOR", "CAPACITY", "ACCESS", "MODES", "RECLAIM", "POLICY",
    "STORAGECLASS", "REASON", "MESSAGE", "HOST", "NODE", "NOMINATED",
    "READINESS", "GATES", "IP", "CONTAINERS", "IMAGES", "LABELS",
])


def _is_header_only_text(lines: list) -> bool:
    """
    Return True when every non-empty token in the given lines is a known kubectl
    column-header word (all-caps).  This detects "NAME  STATUS" echoed by the LLM
    with no actual data rows — output that is not useful to show.
    """
    tokens = []
    for line in lines:
        tokens.extend(line.strip().split())
    if not tokens:
        return False
    # All tokens must be known header words (uppercase)
    return all(t.upper() in _KNOWN_HEADER_TOKENS for t in tokens)


def _is_valid_table_header(headers: list) -> bool:
    """
    Return True only when the header looks like a genuine kubectl table:
      - Must contain "NAME"
      - Must contain at least one of STATUS / READY / PHASE / ROLES / TYPE / VERSION / OS
      - Must have >= 2 columns
    This prevents treating a partial chunk (e.g. just "NAME") as a full table.
    """
    if len(headers) < 2:
        return False
    hu = {h.upper() for h in headers}
    return "NAME" in hu and bool(hu & {"STATUS", "READY", "PHASE", "ROLES", "TYPE", "VERSION", "OS"})


def _detect_resource_type(headers: list) -> str:
    """Detect the Kubernetes resource type label from table headers."""
    try:
        hset = frozenset(h.upper() for h in headers)
        for key, label in _TYPE_HINTS.items():
            if key.issubset(hset):
                return label
        # Fallback: use first column name to guess
        first = headers[0].upper() if headers else ""
        if first == "NAMESPACE":
            return "Namespaces"
        return "Resources"
    except Exception:
        return "Resources"


def _split_table(lines: list) -> tuple:
    """
    Split kubectl tabular output into (headers, data_rows).
    Returns ([], []) on any error.
    """
    try:
        if not lines:
            return [], []
        headers = lines[0].split()
        if not headers:
            return [], []
        data_rows = []
        for line in lines[1:]:
            stripped = line.strip()
            if not stripped:
                continue
            parts = stripped.split()
            if parts:
                data_rows.append(parts)
        return headers, data_rows
    except Exception as exc:
        logging.warning("Formatter: _split_table error: %s", exc)
        return [], []


def _format_kubectl_output(text: str) -> str:
    """
    Convert raw kubectl tabular text (or simple identifier list) into a
    readable ASCII list.

    Examples:
      Pods:
      - coredns-774b6dc6fc-t75h9  Running
      - kube-apiserver-kubemaster  Running

      Nodes:
      - imw1030228c  Ready  windows
      - kubemaster  Ready  linux

      Namespaces:
      - ai-assistant
      - cert-manager

    Safety rules:
    - If parsing fails OR produces empty output -> return ORIGINAL text unchanged.
    - Only attempts formatting when a header row exists AND >= 1 data row.
    - Uses only ASCII characters and plain newlines for broad terminal compatibility.
    - Uses "-" instead of special Unicode bullets to avoid rendering as "?".
    - Replaces "<none>" tokens with "-" to prevent ReactMarkdown treating them
      as unknown HTML tags (which renders as empty string in the UI).
    """
    try:
        original = text  # keep for fallback
        # Replace <none> with "-" everywhere to avoid Markdown HTML-tag rendering
        text = text.replace("<none>", "-")
        lines = [l.rstrip() for l in text.splitlines() if l.strip()]
        if not lines:
            logging.info("Formatter: skipped (empty input)")
            return original

        # Check whether there is at least one multi-column line (table format)
        has_table = any(_KUBECTL_MULTI_COL_RE.search(l) for l in lines)

        if not has_table:
            # ── Identifier list path ──────────────────────────────────────────
            # Simple identifier list — one item per line (e.g. namespace names)
            # Only format if every line looks like a k8s identifier (no spaces)
            valid_ids = all(
                re.match(r"^[A-Za-z0-9][A-Za-z0-9\-\./\_]*$", l.strip())
                for l in lines
            )
            if not valid_ids:
                logging.info("Formatter: skipped (no table, not pure identifiers)")
                return original

            # Guard: need at least 2 items; single token could be a partial chunk
            if len(lines) < 2:
                logging.info("Formatter: skipped (single-token input — possible partial chunk)")
                return original

            label = "Namespaces" if all(
                re.match(r"^[a-z][a-z0-9\-]*$", l.strip()) for l in lines
            ) else "Items"
            out = [label + ":"] + ["- " + l.strip() for l in lines]
            result = "\n".join(out)
            if not result.strip():
                logging.info("Formatter: skipped (fallback - empty identifier result)")
                return original
            return result

        # ── Table path ────────────────────────────────────────────────────────
        headers, rows = _split_table(lines)

        # STRICT: header must look like a real kubectl header (NAME + status col)
        if not _is_valid_table_header(headers):
            # ── Headerless data rows path (jq output: "name  Ready  linux") ──
            # When all lines look like "k8s-name  status  os" data rows with no
            # header row, format them as a Nodes list directly.
            all_data_rows = all(
                re.match(r"^[a-z0-9][a-z0-9\-\.]*\s", l.strip())
                for l in lines
            )
            if all_data_rows and len(lines) >= 1:
                out = ["Nodes:"]
                for line in lines:
                    parts = line.strip().split()
                    if parts:
                        out.append("- " + "  ".join(parts))
                result = "\n".join(out)
                if "- " in result:
                    logging.info("Formatter: headerless rows formatted as Nodes list (%d lines)", len(lines))
                    return result
            logging.info("Formatter: skipped (fallback - header failed validation: %s)", headers)
            return original

        resource_type = _detect_resource_type(headers)
        headers_upper = [h.upper() for h in headers]

        name_idx = next(
            (i for i, h in enumerate(headers_upper) if h == _NAME_COL), 0
        )
        status_idx = next(
            (i for i, h in enumerate(headers_upper) if h == "STATUS"), None
        )
        if status_idx is None:
            status_idx = next(
                (i for i, h in enumerate(headers_upper) if h in _STATUS_COLS), None
            )
        # For nodes with NAME+OS+VERSION (no STATUS col): show OS as primary info
        if status_idx is None:
            os_idx = next(
                (i for i, h in enumerate(headers_upper) if h == "OS"), None
            )
            version_idx = next(
                (i for i, h in enumerate(headers_upper) if h == "VERSION"), None
            )
        else:
            os_idx = None
            version_idx = None
        roles_idx = next(
            (i for i, h in enumerate(headers_upper) if h == "ROLES"), None
        )

        out = [resource_type + ":"]
        kept = 0
        for row in rows:
            # STRICT: skip rows with fewer than 2 tokens — partial chunk guard
            if not row or len(row) < 2:
                logging.info("Formatter: skipping row with <2 tokens: %s", row)
                continue
            name = row[name_idx] if name_idx < len(row) else ""
            if not name:
                logging.info("Formatter: skipping row — empty name cell")
                continue

            parts = [name]
            if status_idx is not None and status_idx < len(row):
                status = row[status_idx]
                if status and status not in ("<none>", "-"):
                    parts.append(status)
            elif os_idx is not None and os_idx < len(row):
                # No STATUS col: show OS (linux/windows) as primary info
                os_val = row[os_idx]
                if os_val and os_val != "-":
                    parts.append("(" + os_val + ")")
                if version_idx is not None and version_idx < len(row):
                    ver = row[version_idx]
                    if ver and ver != "-":
                        parts.append(ver)
            if roles_idx is not None and roles_idx < len(row):
                role = row[roles_idx]
                if role and role not in ("<none>", "-"):
                    parts.append("(" + role + ")")

            if not parts or len(parts) == 1:
                # Only name found — append all remaining non-empty, non-dash values
                extras = [
                    v for v in row[name_idx + 1:]
                    if v and v not in ("-", "<none>")
                ]
                if extras:
                    out.append("- " + name + "  " + "  ".join(extras))
                else:
                    out.append("- " + name)
            else:
                out.append("- " + "  ".join(parts))
            kept += 1

        if kept == 0 or len(out) <= 1:
            logging.info("Formatter: skipped (fallback - no valid rows produced)")
            return original

        # SANITY: if we lost more than 20% of rows -> fallback (data loss guard)
        if kept < len(rows) * 0.8:
            logging.warning(
                "Formatter: fallback triggered — kept %d/%d rows (>20%% loss)", kept, len(rows)
            )
            return original

        return "\n".join(out)

    except Exception as exc:
        logging.warning("Formatter: exception — returning original: %s", exc)
        return text


def _extract_table_from_tool_result(text: str) -> tuple:
    """
    Given a tool-result block that starts with a '🔧 ... result:' line, split it
    into (header_line, table_body).

    The block looks like one of:
      🔧 kubernetes_tabular_query result:\n<table>
      🔧 kubernetes_tabular_query result:\n\n<table>   (blank separator)

    Strategy:
      1. Find the first newline — splits announcement from table body.
      2. Everything on that first line up to and including "result:" is
         the announcement header (kept as-is in the UI).
      3. Everything after the first newline is the table body.
         Leading blank lines are stripped (optional separator), but the
         table content is preserved verbatim.

    Returns ("", "") if the block cannot be parsed safely.
    If the block has no table body, table_body is "".
    header_line  — the '🔧 tool result:' announcement line (always kept as-is)
    table_body   — everything after the first blank line (the actual kubectl output)
    """
    # Locate first newline — splits announcement from table body
    nl_pos = text.find("\n")
    if nl_pos == -1:
        # No newline: entire delta is just the announcement line, no table yet
        return text.strip(), ""

    header_line = text[:nl_pos].rstrip()
    rest = text[nl_pos + 1:]  # everything after the first newline

    # Strip leading blank lines (optional separator between header and table)
    table_body = rest.lstrip("\r\n")

    # Final trim of trailing whitespace only — DO NOT strip content lines
    table_body = table_body.rstrip()

    return header_line, table_body


def _strip_tool_meta(text: str) -> str:
    """Remove leading tool_call_metadata={...} prefix if present."""
    if not text.startswith("tool_call_metadata="):
        return text
    brace = text.find("{")
    if brace == -1:
        return text
    depth = 0
    for i, ch in enumerate(text[brace:], brace):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[i + 1:].lstrip()
    return text


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
    - If the delta contains a tool-result block (🔧 ... result:\\n<table>):
        * Keep the '🔧 tool result:' header line.
        * Extract the embedded kubectl table and run it through _format_kubectl_output().
        * Return "header_line\\n" + formatted_table.
        * If the table body cannot be formatted, return the original block unchanged.
    - Tool-announcement lines (🔧 Using Agent tool: ...) pass through unchanged.
    - Otherwise keep lines that are:
        a) kubectl multi-column rows (contain 2+ consecutive spaces)
        b) plain identifiers / names (word chars + common k8s chars: -./_ no spaces)
    - Drop lines that match _NOISE_RE (prose analysis, commentary).
    - If nothing remains -> return "".
    - If RAW_OUTPUT=false (default) -> format kept lines with _format_kubectl_output().
    """
    cleaned = _strip_tool_meta(delta)

    # ── Tool-result block: contains embedded kubectl table ─────────────────────
    # Condition: delta starts with 🔧 AND contains "result:" near the start.
    # Pattern: "🔧 tool_name result:\n<kubectl output>"
    # We MUST format the table rather than pass the raw block through, otherwise
    # pods/services/deployments tables are shown as unstyled raw text.
    is_result_block = (
        cleaned.strip().startswith("\U0001f527")  # starts with 🔧
        and "result:" in cleaned[:200]
    )

    if is_result_block:
        header_line, table_body = _extract_table_from_tool_result(cleaned)
        if not table_body:
            # Only the announcement line arrived (partial SSE chunk) — pass through
            logging.info("OutputFilter: tool-result block has no table body yet — pass through")
            return cleaned
        if RAW_OUTPUT:
            return cleaned
        # Validate that the first line of the table body looks like a kubectl header.
        # kubectl describe output does NOT have a tabular header — pass it through as-is.
        first_table_line = table_body.splitlines()[0] if table_body else ""
        candidate_headers = first_table_line.split()
        if not _is_valid_table_header(candidate_headers):
            # Could be kubectl describe output — check for key: value pattern
            if _DESCRIBE_KV_RE.match(first_table_line) or _DESCRIBE_SECTION_RE.match(first_table_line):
                logging.info("OutputFilter: tool-result block is kubectl describe output — passing through as-is")
                return cleaned
            logging.info(
                "OutputFilter: table header failed validation (%s) — returning original block",
                candidate_headers,
            )
            return cleaned  # return full original block, data preserved
        # Attempt formatting — pass extracted table to _format_kubectl_output()
        formatted = _format_kubectl_output(table_body)
        # If formatting succeeds (non-empty and contains "- " list entries):
        # return: 🔧 tool_name result: <formatted output>
        # If formatting fails: return original delta (no change)
        if formatted and formatted.strip() and "- " in formatted:
            logging.info(
                "OutputFilter: formatted tool-result table (%d->%d chars)",
                len(table_body), len(formatted),
            )
            return header_line + "\n" + formatted
        # Fallback: return original cleaned block (data preserved, unformatted)
        logging.info(
            "OutputFilter: formatting skipped for tool-result — returning original block "
            "(formatted_len=%d, body_len=%d)",
            len(formatted) if formatted else 0, len(table_body),
        )
        return cleaned

    # ── Tool-announcement line only (no embedded table) ───────────────────────
    if _is_tool_marker(cleaned):
        return delta  # forward unchanged (tool start/end markers)

    # SAFETY: if the original delta contains tool markers (🔧) but was not caught
    # by is_result_block above (e.g. it's a multi-line chunk that mixes tool text
    # and prose), always pass it through rather than risk dropping real data.
    if "\U0001f527" in cleaned:
        logging.info("OutputFilter: delta contains tool marker but not result block — pass through")
        return delta

    # ── Detect kubectl describe block — pass through entirely ─────────────────
    # If the delta as a whole looks like kubectl describe output (starts with
    # "Name:" or contains multiple key: value pairs) pass it through unchanged.
    # This prevents stripping of failure details (Reason, Exit Code, Message).
    cleaned_lines_for_detect = cleaned.splitlines()
    describe_kv_count = sum(
        1 for ln in cleaned_lines_for_detect
        if _DESCRIBE_KV_RE.match(ln) or _DESCRIBE_SECTION_RE.match(ln)
    )
    if describe_kv_count >= 2:
        logging.info(
            "OutputFilter: delta looks like kubectl describe output (%d kv lines) — pass through",
            describe_kv_count,
        )
        return cleaned

    # ── Regular LLM text: filter line-by-line ─────────────────────────────────
    kept = []
    in_describe_block = False  # track whether we are inside a describe key-value section
    for raw_line in cleaned_lines_for_detect:
        line = raw_line.rstrip()
        stripped = line.strip()

        if not stripped:
            in_describe_block = False
            continue

        # ── kubectl events output — always pass through ────────────────────────
        # Events header: "LAST SEEN   TYPE   REASON   OBJECT   MESSAGE"
        # Events row:    "2m   Warning  OOMKilled  pod/x   container exceeded..."
        if _EVENTS_HEADER_RE.match(stripped) or _EVENTS_ROW_RE.match(stripped):
            kept.append(line)
            in_describe_block = False
            continue

        # ── kubectl describe key-value lines — always pass through ─────────────
        # e.g. "  Reason:    OOMKilled"  "  Message:   ..."  "  Node:  kubemaster"
        # "    Last State:   Terminated"  "      Exit Code:  1"
        if _DESCRIBE_KV_RE.match(line) or _DESCRIBE_SECTION_RE.match(line):
            kept.append(line)
            in_describe_block = True
            continue

        # ── Continuation lines following a describe key-value line ─────────────
        # Multi-line field values (e.g. Message body) appear as indented lines
        # with no colon. Pass them through while inside a describe section.
        if in_describe_block and _DESCRIBE_CONTINUATION_RE.match(line):
            kept.append(line)
            continue

        in_describe_block = False

        if _NOISE_RE.match(stripped):
            continue  # drop commentary

        if _KUBECTL_MULTI_COL_RE.search(stripped):
            # Has 2+ spaces between tokens -> kubectl tabular row or header
            kept.append(line)
            continue

        # Single-token: keep only if it looks like a k8s name/identifier
        # (letters, digits, hyphens, dots, slashes, underscores — NO spaces)
        if re.match(r"^[A-Za-z0-9][A-Za-z0-9\-\./\_]*$", stripped):
            kept.append(stripped)
            continue

        # jq output format: "name (info)" e.g. "imw1030228c (linux)" or "kubemaster (linux)"
        # Keep lines that start with a k8s identifier followed by a parenthesised annotation.
        if re.match(r"^[A-Za-z0-9][A-Za-z0-9\-\./\_]*\s+\([A-Za-z0-9][A-Za-z0-9\-\._]*\)$", stripped):
            kept.append(stripped)
            continue

        # Multi-word prose without column spacing -> drop

    if not kept:
        # SAFETY: if the original delta had substantial content (>20 chars) that we
        # are about to suppress entirely, return the original rather than an empty
        # string — data must never silently disappear from the UI.
        if len(cleaned.strip()) > 20:
            logging.info(
                "OutputFilter: all lines filtered from non-empty delta (%d chars) — "
                "returning original to prevent data loss",
                len(cleaned),
            )
            return delta
        return ""  # safe to suppress — was only prose/commentary

    # Guard: if every kept line is just known kubectl column-header tokens
    # (e.g. "NAME  STATUS" or "NAME  STATUS  ROLES  AGE  VERSION"), this is a
    # header-only chunk — the LLM echoed column headers without data rows.
    # Suppress it so the UI never shows "Resources:\n- NAME  STATUS" artifacts.
    if _is_header_only_text(kept):
        logging.info(
            "OutputFilter: suppressed header-only chunk (%d kept lines): %r",
            len(kept), kept[:3],
        )
        return ""

    raw_text = "\n".join(kept)

    if RAW_OUTPUT:
        return raw_text

    # Format into readable output
    formatted = _format_kubectl_output(raw_text)
    # SAFETY: if formatter returned empty or same-as-input, use the raw_text
    if not formatted or not formatted.strip():
        return raw_text
    return formatted


def _is_chat_endpoint(path: str) -> bool:
    return bool(CHAT_PATH_RE.match(path.split("?")[0]))


# ── Ask-field rewrite patterns ────────────────────────────────────────────────
# These detect the user's intent and prepend a hard one-line instruction
# directly into the `ask` field so Holmes's planner cannot ignore it.
# The context[] injection is still done as a secondary guard.

_FAILED_PODS_RE = re.compile(
    r"(?i)(list|show|get|find|any|are there)[\w\s]*(fail|crash|error|broken|problem|bad|not.?running|crashing)",
)
_WHY_FAILING_RE = re.compile(
    r"(?i)(why|what|reason|cause|issue|problem|how).{0,40}(fail|crash|error|broken|not.?running|crashing|restart|killed|exit)",
)
_DESCRIBE_POD_RE = re.compile(
    r"(?i)(describe|inspect|detail|info).{0,30}pod",
)
# Short affirmative replies the user sends after AI asks "do you want more details?"
_AFFIRMATIVE_RE = re.compile(
    r"(?i)^\s*(yes|yeah|yep|sure|ok|okay|please|go ahead|tell me|more|show me|why|what happened|details?|reason|cause)\s*[!?.]?\s*$",
)
# Extract pod names mentioned in text (e.g. "dummy-failed-pod (default)")
_POD_NAME_IN_TEXT_RE = re.compile(
    r"([a-z0-9][a-z0-9\-]+)\s+\(([a-z0-9][a-z0-9\-]*)\)",  # "pod-name (namespace)"
)
# Detect AI text that offered more details about a failed pod
_AI_OFFERED_DETAILS_RE = re.compile(
    r"(?i)(more detailed|more information|specific pod|issues with|failed pod|want.*detail|let me know)",
)


def _extract_failed_pod_from_history(messages: list) -> tuple:
    """
    Scan recent conversation messages for a failed pod name + namespace.
    Returns (pod_name, namespace) or ("", "") if not found.
    Looks for patterns like "dummy-failed-pod (default)" in AI messages.
    """
    # Look at last 6 messages (3 exchanges) in reverse order
    for msg in reversed(messages[-6:]):
        role = msg.get("role", "")
        content = msg.get("content", "")
        if not isinstance(content, str):
            continue
        # Only scan AI assistant messages for the pod name it mentioned
        if role in ("assistant", "ai"):
            m = _POD_NAME_IN_TEXT_RE.search(content)
            if m:
                pod_name = m.group(1)
                namespace = m.group(2)
                # Filter out obvious non-pod matches
                if len(pod_name) > 3 and pod_name not in ("running", "succeeded", "failed"):
                    logging.info(
                        "History scan: found failed pod %r in namespace %r",
                        pod_name, namespace,
                    )
                    return pod_name, namespace
    return "", ""


def _build_ask_prefix(ask: str, messages: list = None) -> str:
    """
    Return a short hard instruction prefix to prepend to the ask field.
    This directly shapes what Holmes's planner is told to do.

    For vague affirmatives (yes/ok/sure), scans conversation history to find
    the failed pod that was being discussed, then injects a direct describe call.
    Returns "" if no special handling needed.
    """
    ask_lower = ask.lower().strip()

    # ── Vague affirmative after AI offered more details ───────────────────────
    if _AFFIRMATIVE_RE.match(ask) and messages:
        pod_name, namespace = _extract_failed_pod_from_history(messages)
        if pod_name and namespace:
            logging.info(
                "Affirmative follow-up detected; injecting describe for %r/%r",
                namespace, pod_name,
            )
            return (
                f"[INSTRUCTION] Use exactly 1 tool call. "
                f"Call kubectl_describe kind=pod name={pod_name} namespace={namespace}. "
                f"DO NOT use fetch_pod_logs. DO NOT use TodoWrite. DO NOT use kubernetes_count. "
                f"DO NOT call kubernetes_tabular_query. "
                f"Write the describe output (State, Reason, Exit Code, Started, Finished, Message) as your final answer. "
                f"Original request: "
            )

    # ── Explicit failed/crash pod listing ────────────────────────────────────
    if _FAILED_PODS_RE.search(ask) or "failed" in ask_lower or "failing" in ask_lower:
        return (
            "[INSTRUCTION] Use exactly 2 tool calls. "
            "Tool call 1: kubernetes_tabular_query with columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase to list ALL pods. "
            "Tool call 2: kubectl_describe kind=pod name=<first non-Running non-Succeeded pod name> namespace=<its namespace from Tool call 1>. "
            "DO NOT use fetch_pod_logs. DO NOT use TodoWrite. DO NOT use kubernetes_count. "
            "After tool call 2, write the describe output (Name, Namespace, State, Reason, Exit Code, Started, Finished) as your final answer. "
            "Original request: "
        )

    # ── Why is X failing / describe a pod ────────────────────────────────────
    if _WHY_FAILING_RE.search(ask) or _DESCRIBE_POD_RE.search(ask):
        return (
            "[INSTRUCTION] Use exactly 2 tool calls. "
            "Tool call 1: kubernetes_tabular_query with columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase to find the pod name and namespace. "
            "Tool call 2: kubectl_describe kind=pod name=<exact pod name> namespace=<exact namespace from Tool call 1>. "
            "DO NOT use fetch_pod_logs. DO NOT use TodoWrite. DO NOT use kubernetes_count. "
            "After tool call 2, write the describe output (Name, Namespace, State, Reason, Exit Code, Started, Finished) as your final answer. "
            "Original request: "
        )
    return ""


def _inject_prompt(body_bytes: bytes) -> bytes:
    """
    Two-layer injection:
    1. context[] field — full strict system prompt (secondary guard).
    2. ask field prefix — short hard instruction prepended to user's question
       so Holmes's planner receives it as part of the task itself.
       For vague affirmatives, scans conversation history to find the pod.
    """
    if not STRICT_PROMPT:
        return body_bytes
    try:
        data = json.loads(body_bytes.decode("utf-8"))

        # Layer 1: context[] injection (full system prompt)
        rules_ctx = {"description": "assistant_behavioral_rules", "value": STRICT_PROMPT}
        existing = data.get("context")
        if isinstance(existing, list):
            data["context"] = [rules_ctx] + existing
        else:
            data["context"] = [rules_ctx]

        # Layer 2: ask field prefix injection (passes message history for affirmative detection)
        ask = data.get("ask", "")
        messages = data.get("messages", [])
        if isinstance(ask, str) and ask.strip():
            prefix = _build_ask_prefix(ask, messages)
            if prefix:
                data["ask"] = prefix + ask
                logging.info(
                    "Injected ask-prefix (%d chars) for ask: %r",
                    len(prefix), ask[:80],
                )

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


# When DISABLE_FILTER=true the SSE filter is bypassed — raw stream forwarded.
DISABLE_FILTER = os.environ.get("DISABLE_FILTER", "false").strip().lower() == "true"


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
            # Disable Nagle's algorithm so each chunk is sent immediately.
            try:
                import socket as _socket
                self.connection.setsockopt(_socket.IPPROTO_TCP, _socket.TCP_NODELAY, 1)
            except Exception:
                pass

            chunks_sent = 0
            chunks_suppressed = 0
            logging.info("SSE stream started: %s (filter=%s disable_filter=%s)",
                         self.path, filter_output, DISABLE_FILTER)
            try:
                # Read line-by-line preserving original \n endings.
                # readline(4MB) prevents splitting on very long data: lines.
                # We do NOT strip newlines — the original SSE framing is kept.
                #
                # SSE wire format from HolmesGPT (FastAPI/uvicorn):
                #   data: {...}\n        <- data line  (ends with \n)
                #   \n                   <- blank line  (event separator)
                #   data: {...}\n
                #   \n
                #   ...
                #
                # Strategy:
                #   - Blank lines (\n or \r\n): forward as-is — they are the SSE
                #     event separator and MUST NOT be doubled or dropped.
                #   - data: lines: strip trailing \n, filter/modify, re-add \n.
                #   - Other lines (event:, id:, :comment): forward as-is.
                #   - Suppressed data: lines: also suppress the following blank line
                #     so the client never sees an orphaned separator.
                suppress_next_blank = False

                while True:
                    raw_line = resp.readline(4 * 1024 * 1024)
                    if not raw_line:
                        # Backend closed connection — stream complete.
                        logging.info("SSE stream ended (backend closed): sent=%d suppressed=%d",
                                     chunks_sent, chunks_suppressed)
                        break

                    logging.debug("SSE line received: %d bytes", len(raw_line))

                    # Classify the line
                    stripped = raw_line.rstrip(b"\r\n")

                    # ── Blank line (SSE event separator) ──────────────────────
                    if not stripped:
                        if suppress_next_blank:
                            # The preceding data: line was suppressed — drop
                            # this separator too so client sees no orphan event.
                            suppress_next_blank = False
                            chunks_suppressed += 1
                            continue
                        suppress_next_blank = False
                        self._write_chunk(raw_line)
                        self.wfile.flush()
                        chunks_sent += 1
                        continue

                    # ── data: line — only these are filtered ──────────────────
                    if stripped.startswith(b"data:") and filter_output and not DISABLE_FILTER:
                        out = _process_sse_line(stripped)
                        if out is None:
                            # Suppressed — also suppress the following blank line.
                            suppress_next_blank = True
                            chunks_suppressed += 1
                            logging.debug("SSE line suppressed")
                            continue
                        # Re-emit with original line ending preserved.
                        ending = raw_line[len(stripped):]  # \n or \r\n
                        out_line = out + ending
                        self._write_chunk(out_line)
                        self.wfile.flush()
                        chunks_sent += 1
                        logging.debug("SSE line forwarded (filtered): %d bytes", len(out_line))
                        suppress_next_blank = False
                        continue

                    # ── All other lines: forward as-is ─────────────────────────
                    suppress_next_blank = False
                    self._write_chunk(raw_line)
                    self.wfile.flush()
                    chunks_sent += 1
                    logging.debug("SSE line forwarded (pass-through): %d bytes", len(raw_line))

                # Chunked transfer terminator
                self._write_chunk(b"")
                self.wfile.flush()
                logging.info("SSE stream completed: sent=%d suppressed=%d",
                             chunks_sent, chunks_suppressed)

            except Exception as exc:
                logging.warning("SSE stream interrupted after %d chunks: %s",
                                chunks_sent, exc)
                try:
                    self._write_chunk(b"")
                    self.wfile.flush()
                except Exception:
                    pass
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
            # RAW_OUTPUT=true returns unformatted kubectl table text instead of
            # the readable Markdown list. Set to "true" to disable formatting.
            - name: RAW_OUTPUT
              value: "false"
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
        [string] $Model = 'qwen2.5:7b'
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

