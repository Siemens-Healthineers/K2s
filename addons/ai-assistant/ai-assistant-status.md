<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant Addon — Final Configuration & Status

> **Last updated:** April 14, 2026 — MODEL_PLACEHOLDER regression fixed.

---

## 1. Architecture

```
Browser (Headlamp plugin)
        │  POST /api/agui/chat  (SSE)
        ▼
  ingress-nginx  (holmesgpt-sse-ingress.yaml)
  proxy-buffering: off, direct route to ai-assistant namespace
        │
        ▼
  holmesgpt-proxy  (python:3.11-alpine, default namespace)
  ┌────────────────────────────────────────────────────────┐
  │  REQUEST  — injects strict system prompt via           │
  │            ag_ui context[] field of RunAgentInput.     │
  │            Keeps ask field clean; no planning calls.   │
  │                                                        │
  │  RESPONSE — per-event SSE delta filter:                │
  │    Each TEXT_MESSAGE_CONTENT event is processed:       │
  │    1. Parse JSON envelope (never emit raw text).        │
  │    2. Strip tool_call_metadata={} prefix from delta.   │
  │    3. Tool markers (wrench emoji / "result:") → pass.  │
  │    4. kubectl multi-column rows + k8s identifiers → keep│
  │    5. Prose commentary → drop.                         │
  │    6. Empty delta="" → suppress (pydantic guard).      │
  │    JSON structure is ALWAYS preserved.                 │
  └────────────────────────────────────────────────────────┘
        │
        ▼
  holmesgpt-holmes  (robustadev/holmes:0.19.1, ai-assistant namespace)
  ┌────────────────────────────────────────────────────────┐
  │  Jinja2 prompt templates overridden via ConfigMap      │
  │  holmesgpt-prompt-overrides (subPath mounts):          │
  │    generic_ask_conversation.jinja2 → strict rules      │
  │    _general_instructions.jinja2    → no TodoWrite      │
  └────────────────────────────────────────────────────────┘
        │
        ▼
  Ollama (qwen2.5:7b, ai-assistant namespace)
```

---

## 2. Final Configuration

### Holmes env vars (`holmesgpt.yaml`)

| Variable | Value | Purpose |
|----------|-------|---------|
| `HOLMES_PORT` | `80` | AG-UI server bind port |
| `HOLMES_HOST` | `0.0.0.0` | AG-UI server bind address |
| `MODEL` | `openai/MODEL_PLACEHOLDER` | LiteLLM model. Substituted by `Set-HolmesModelConfig` at deploy time. Default: `qwen2.5:7b`. Minimum: 7B. |
| `API_BASE` | `http://172.19.1.1:11434/v1` | Ollama OpenAI-compatible endpoint via node bridge IP |
| `API_KEY` | `ollama` | Placeholder key (required by LiteLLM, not validated by Ollama) |
| `HOLMES_ALLOW_INSECURE_LLM` | `true` | Allows plain HTTP LLM endpoint |
| `LLM_REQUEST_TIMEOUT` | `600` | 10-min timeout for GPU inference latency |
| `OVERRIDE_MAX_CONTENT_SIZE` | `131072` | Context window (128k, matches qwen2.5:7b) |
| `OVERRIDE_MAX_OUTPUT_TOKEN` | `4096` | Max output tokens |
| `REQUEST_STRUCTURED_OUTPUT_FROM_LLM` | `false` | Use standard function-calling (tools array). Structured output causes small models to return JSON in content instead of tool_calls. |
| `MAX_STEPS` | `3` | Step 1: tool call. Step 2: process result. Step 3: safety. MIN=2 (below breaks tool execution). |

### Prompt override ConfigMap (`holmesgpt-prompt-overrides`, `ai-assistant` namespace)

Two Jinja2 files mounted over Holmes built-ins at `/app/holmes/plugins/prompts/`:

| File | Replaces | Effect |
|------|---------|--------|
| `generic_ask_conversation.jinja2` | Holmes base system prompt | Strict single-tool-call rules: call one tool, return raw output, stop |
| `_general_instructions.jinja2` | ~300 lines of TodoWrite + investigation rules | "Use EXACTLY ONE tool call. No TodoWrite." |

**Why this is needed:** Holmes's built-in `investigation_procedure.jinja2` mandates
TodoWrite, multi-phase investigation, and "five whys" root cause analysis. These are
injected via `add_or_update_system_prompt()` at every request and completely override
any context-level instructions. The subPath mount is the only way to suppress them.

### Proxy ConfigMap (`holmesgpt-proxy-config`, `default` namespace)

| Key | Content |
|-----|---------|
| `proxy.py` | Python 3.11 proxy script with `_inject_prompt` + `_process_sse_line` + `_filter_delta` |
| `strict_system_prompt.txt` | ~1730-char strict rules injected via ag_ui context[] |

---

## 3. Proxy Filter Logic

```
_process_sse_line(raw_line: bytes) -> bytes | None
```

Called for every SSE line on `/api/agui/chat` responses.

1. If not `data:` prefix → pass through.
2. If not `TEXT_MESSAGE_CONTENT` type → pass through (preserves START, END, RUN_*, TOOL_CALL_*).
3. If `delta == ""` → return `None` (suppress — pydantic guard).
4. Call `_filter_delta(delta)`:
   - Strip `tool_call_metadata={...}` prefix.
   - If result contains tool marker (wrench emoji / `result:\n`) → return original delta.
   - Otherwise keep lines that are:
     - kubectl multi-column rows (2+ consecutive spaces between tokens)
     - k8s identifiers (single token: `[A-Za-z0-9][A-Za-z0-9\-\./\_]*`)
   - Drop lines matching `_NOISE_RE`: `it looks like`, `next steps`, `you can`, markdown headings, code fences, numbered list items, etc.
5. If filtered == original → return original bytes (no re-serialisation).
6. If filtered is empty → return `None` (suppress event).
7. Otherwise → reconstruct same JSON with `delta` replaced, return as `data: {...}` bytes.

**JSON is never broken.** Only the string value of the `delta` field changes.

---

## 4. What Has Been Fixed

| # | Fix | File(s) |
|---|-----|---------|
| 2.1 | nginx → Python proxy | `ai-assistant.module.psm1` |
| 2.2 | Empty SSE delta (pydantic crash) | `proxy.py` |
| 2.3 | `kubectl wait --ignore-not-found` | `Get-Status.ps1` |
| 2.4 | `Update.ps1` missing params | `Update.ps1` |
| 2.5 | Duplicate `MAX_STEPS` | `holmesgpt.yaml` |
| 2.6 | Wrong prompt injection field | `proxy.py` |
| 2.7 | Holmes built-in TodoWrite rules | `holmesgpt.yaml` (ConfigMap + subPath mounts) |
| 2.8 | MODEL_PLACEHOLDER reset by direct apply | Patched via `kubectl set env` |
| 2.9 | SSE output filter — JSON corruption | `proxy.py` rewritten (per-event, not buffered) |
| 2.10 | **Stabilization** — orphaned old proxy code, stale comments, encoding artifacts, `LITELLM_CONFIG_PATH` | `ai-assistant.module.psm1`, `holmesgpt.yaml` |
| 2.11 | **Nodes list broken** — `qwen2.5:7b` hallucinated `.status?option` for nodes STATUS column; root cause: the `kubernetes_tabular_query` tool always uses `--all-namespaces -o custom-columns='{{ columns }}'` and the small LLM corrupts complex JSONPath strings. Fix: changed nodes columns to simple direct paths (`NAME:.metadata.name,OS:.status.nodeInfo.operatingSystem,VERSION:.status.nodeInfo.kubeletVersion`) with no array indexing. Added `_is_header_only_text` guard in proxy to suppress echo of column headers without data. | `holmesgpt.yaml`, `ai-assistant.module.psm1` |
| 2.12 | **MODEL_PLACEHOLDER regression** — `Update.ps1` change added `kubectl apply -f holmesgpt.yaml` which reset `MODEL=openai/MODEL_PLACEHOLDER` in the Deployment (the YAML still has the literal placeholder). Fix: `Update.ps1` now snapshots the live MODEL before applying and restores it immediately after via `kubectl set env`. | `Update.ps1` |

---

## 5. Current State

### Files

| File | State |
|------|-------|
| `ai-assistant.module.psm1` | ✅ Clean — 872 lines, 2 here-string closers, no stale code |
| `manifests/holmesgpt/holmesgpt.yaml` | ✅ Clean — no `LITELLM_CONFIG_PATH`, no encoding artifacts |
| `Get-Status.ps1` | ✅ Fixed — two-step get+wait |
| `Update.ps1` | ✅ Fixed — `-EncodeStructuredOutput`, `-MessageType` |
| `manifests/holmesgpt/holmesgpt-sse-ingress.yaml` | ✅ Verified — regex `(/|$)(.*)` |

### Live cluster

| Resource | Value |
|----------|-------|
| `holmesgpt-holmes` model | `openai/qwen2.5:7b` |
| `holmesgpt-holmes` `MAX_STEPS` | `3` |
| `holmesgpt-prompt-overrides` ConfigMap | Present, mounted via subPath |
| `generic_ask_conversation.jinja2` in pod | Overridden (strict rules) |
| `_general_instructions.jinja2` in pod | Overridden (no TodoWrite) |
| `holmesgpt-proxy-config` ConfigMap | Present (`proxy.py` + `strict_system_prompt.txt`) |
| `holmesgpt-proxy` deployment | Running, per-event delta filter active |

### Live API test results

| Query | Tool called | Commentary | JSON errors |
|-------|-------------|------------|-------------|
| List all namespaces | `kubernetes_tabular_query` ✅ | None ✅ | None ✅ |
| List all pods | `kubernetes_tabular_query` ✅ | None ✅ | None ✅ |
| List all nodes | `kubernetes_tabular_query` ✅ | None ✅ | None ✅ |

---

## 6. Remaining

### 6.1 🔴 UI validation required
All fixes confirmed at API level. Manual test in Headlamp still needed.

### 6.2 🟡 Non-kubectl queries return empty
The delta filter suppresses responses with no kubectl output (e.g. "What is Kubernetes?").
Scoped to kubectl queries by design. Extend `_filter_delta` if general Q&A is needed later.

### 6.3 🟢 `debugging-status.md` outdated
Describes old `additional_system_prompt` approach. Low priority — can update separately.

---

## 7. Quick Reference

```console
# Verify prompt overrides active in pod
kubectl exec -n ai-assistant deployment/holmesgpt-holmes -- \
  head -3 /app/holmes/plugins/prompts/generic_ask_conversation.jinja2

# Check MODEL and MAX_STEPS live
kubectl get deployment holmesgpt-holmes -n ai-assistant \
  -o jsonpath="{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{'\n'}{end}" \
  | grep -E "MODEL|MAX_STEPS|API_BASE"

# Proxy filter log (shows suppressed/filtered deltas)
kubectl logs -n default deployment/holmesgpt-proxy --tail=20

# Holmes logs (shows tool calls)
kubectl logs -n ai-assistant deployment/holmesgpt-holmes --tail=30

# Full redeploy (regenerates proxy ConfigMap from psm1)
k2s addons update ai-assistant

# Restart proxy only (picks up ConfigMap changes)
kubectl rollout restart deployment/holmesgpt-proxy -n default
```

---

## 8. Key Technical Findings

| Finding | Detail |
|---------|--------|
| Holmes system prompt source | `add_or_update_system_prompt()` → `generic_ask_conversation.jinja2` → `_general_instructions.jinja2` → `investigation_procedure.jinja2` |
| TodoWrite source | `investigation_procedure.jinja2` included by `_general_instructions.jinja2` (300+ lines) |
| Template override mechanism | ConfigMap subPath mount at `/app/holmes/plugins/prompts/` |
| ag_ui `context[]` injection | Rendered as weak "user has the following information..." framing — insufficient alone |
| `additional_system_prompt` field | Exists on `ChatRequestBaseModel` but `server-agui.py` never sets it from AG-UI input |
| `get_tasks_management_system_reminder()` | Only in `build_initial_ask_messages()`, not in the agui chat path |
| SSE JSON corruption (old) | Buffered approach reconstructed SSE events from scratch; multi-line delta broke JSON |
| Per-event filter (current) | Modifies only `delta` string in-place; all other JSON fields preserved |
| `LITELLM_CONFIG_PATH` | No-op for the agui path — removed |
| `kubernetes_tabular_query` tool | Always runs `kubectl get {{ kind }} --all-namespaces -o custom-columns='{{ columns }}'`. Has `llm_summarize` transformer (fires if output >10,000 chars). `columns` param is required — the tool never falls back to default kubectl output. Not allowed chars in columns: `'` `/` `;` newline. |
| Nodes query root cause | `qwen2.5:7b` corrupts complex JSONPath like `.status.conditions[-1].type` → hallucinated `.status?option` → STATUS=`<none>` → LLM writes prose instead of echoing data → proxy safety guard passes prose through as displayed content. Fix: use only simple direct-field paths with no array indexing. |
