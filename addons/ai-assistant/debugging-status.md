<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# AI Assistant — Debugging Status & Known Issues

## Strict Controlled Mode (implemented)

**Problem observed:**
- HolmesGPT was calling `TodoWrite` autonomously to create investigation plans.
- Holmes chained multiple tool calls per user request (e.g., listing pods twice).
- Empty SSE delta chunks caused pydantic validation errors:  
  `1 validation error for TextMessageContentEvent delta String should have at least 1 character`
- "List all nodes" returned `(no data found)` despite nodes being present.
- `BodyStreamBuffer was aborted` errors on short responses.

**Root cause:**
HolmesGPT's default behaviour is autonomous agent mode — it uses `TodoWrite`, chains
multiple `kubernetes_tabular_query` calls, and generates verbose reasoning text.  
Small models (7B) sometimes produce empty text chunks in SSE streams, triggering
pydantic validation errors in the Headlamp plugin.

**Fix implemented (`ai-assistant.module.psm1` + `holmesgpt-sse-ingress.yaml`):**

1. **Python smart proxy** (replaces `nginx:alpine` in `holmesgpt-proxy` Deployment):
   - Intercepts every `POST /api/agui/chat` request.
   - Injects a strict system prompt into `additional_system_prompt` JSON field before
     forwarding to HolmesGPT — constraining it to single-tool-call deterministic mode.
   - Filters empty SSE `delta` chunks (`"delta": ""`) before streaming to the browser.

2. **SSE bridge service** (`holmesgpt-proxy-bridge` ExternalName in `ai-assistant`):
   - Routes the SSE direct-ingress path through the Python proxy so the strict prompt
     is also injected for streamed responses (not just apiserver-proxy path).

3. **`MAX_STEPS=5`** in HolmesGPT Deployment:
   - Hard ceiling on tool-call iterations per request, preventing runaway loops.

**Strict mode rules injected:**
- Execute at most ONE tool call per request.
- Never use `TodoWrite`.
- Never create investigation plans or suggest next steps.
- Return only the tool result — no extra commentary.
- If tool result is empty → return `No data found`.
- Never send empty text chunks.

**To apply to a running cluster:**
```console
k2s addons update ai-assistant
```

This re-runs `Set-HolmesProxyEndpoints` which deploys the Python proxy with the
updated strict system prompt ConfigMap and `python:3.11-alpine` image.

**Images used:**
- Proxy: `python:3.11-alpine` (~50MB, standard Python without extra deps)
- HolmesGPT: `robustadev/holmes:0.19.1` (unchanged)
- Ollama: unchanged

