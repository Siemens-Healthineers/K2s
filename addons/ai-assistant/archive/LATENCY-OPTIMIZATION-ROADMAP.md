<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Post-Production Latency Optimization Roadmap

**Date:** May 30, 2026
**Status:** Analysis only — no changes implemented.
**Current state:** 23/23 acceptance tests passing, production-ready.

---

## 1. Current End-to-End Latency Breakdown (Conversational Workflow)

A typical conversational query (e.g., "show me all pods") traverses:

```
User Browser → Kagent UI (Next.js) → nginx (in-pod) → Ingress Controller
  → a2a-proxy → kagent-controller → Ollama (172.19.1.1:11434) → Model Inference
  → kagent-controller → MCP tool call → mcp-preprocessor → k2s-tools
  → Kubernetes API → k2s-tools → mcp-preprocessor → kagent-controller
  → Ollama (response generation) → kagent-controller → a2a-proxy → User
```

### Measured/Estimated Latency per Component

| Component | Estimated Latency | Notes |
|-----------|------------------|-------|
| **Kagent UI** (browser → nginx → Next.js) | ~50-100ms | SSR hydration, WebSocket setup |
| **Ingress Controller** (nginx-ingress) | ~5-10ms | TLS termination, proxy pass |
| **a2a-proxy** (routing + auto-confirm) | ~5-15ms | JSON parse + forward (no LLM) |
| **kagent-controller** (orchestration) | ~100-200ms | Agent dispatch, prompt assembly, DB write |
| **Ollama — prompt processing** (input) | ~500-1500ms | Tokenize + process system prompt + context |
| **Ollama — tool call decision** | ~300-800ms | Model decides which tool to call |
| **kagent-controller → tool dispatch** | ~50-100ms | MCP protocol overhead |
| **mcp-preprocessor** | ~5-10ms | Forward + truncation (if needed) |
| **k2s-tools** (kubectl execution) | ~200-800ms | kubectl API call |
| **Kubernetes API** | ~50-200ms | etcd query, response serialization |
| **mcp-preprocessor (response)** | ~5-20ms | Truncation + token limiting |
| **kagent-controller (tool result)** | ~50ms | Store result, prepare for model |
| **Ollama — process tool output** | ~500-1000ms | Tokenize tool result into context |
| **Ollama — response generation** | ~1000-2500ms | Generate ~100-200 tokens @ 41 tok/s |
| **Auto-confirm round-trip** (if needed) | ~3000-5000ms | Full second LLM pass for confirmation |
| **a2a-proxy → ingress → browser** | ~10-20ms | Response delivery |

### **Total: ~6000-7500ms (6-7 seconds)**

---

## 2. Why 6-7 Seconds Despite 41 tok/s Inference

The 41 tok/s figure is **output generation speed only**. The full latency includes:

1. **Prompt processing (prefill):** ~1-2s. The system prompt (78 lines) + builtin prompts (skills-usage, tool-usage, safety, kubernetes-context, a2a-communication = ~200+ lines from ConfigMap) + conversation history must be tokenized and processed before any output token is generated. At ~8K context tokens, prefill alone costs 1-2s on qwen2.5:7b.

2. **Two LLM passes per tool-using query:**
   - Pass 1: User input → Model decides tool call (~1s prefill + ~0.5s for tool decision tokens)
   - Tool execution: ~0.5-1s
   - Pass 2: Tool result injected → Model generates final response (~0.5s prefill + ~2s for ~80 tokens of response)

3. **Auto-confirmation overhead:** When kagent-controller returns `input-required` for tool confirmation, a2a-proxy sends "yes" back, triggering a **third full LLM pass** (confirmation → tool execution → response generation). This adds 3-5s when it occurs.

4. **Kagent orchestration overhead:** The kagent-controller framework (AutoGen-based) adds ~200ms per step for agent dispatch, state management, and PostgreSQL conversation logging.

5. **Network hops compound:** 12+ HTTP hops in the full path, each adding 5-50ms of serialization/deserialization.

---

## 3. Largest Latency Contributors (Ranked)

| Rank | Contributor | Latency Cost | % of Total |
|------|-------------|-------------|------------|
| 1 | **LLM prefill (system prompt processing)** | 1000-2000ms | ~25% |
| 2 | **LLM response generation** | 1000-2500ms | ~20% |
| 3 | **LLM tool-call decision** | 500-1000ms | ~12% |
| 4 | **Auto-confirmation (extra LLM round-trip)** | 0-5000ms (when triggered) | ~0-40% |
| 5 | **kubectl/K8s API execution** | 200-800ms | ~10% |
| 6 | **Kagent controller orchestration** | 200-400ms | ~5% |
| 7 | **Network serialization (12+ hops)** | 100-200ms | ~3% |
| 8 | **Kagent UI rendering** | 50-100ms | ~2% |

**Key insight:** ~60% of latency is LLM-bound (prefill + generation + tool decision). The remaining ~40% is system overhead that could be reduced but is already modest.

---

## 4. Identified Inefficiencies

### 4.1 Unnecessary Hops

| Issue | Impact | Location |
|-------|--------|----------|
| Tool calls go: kagent-controller → k2s-tools (MCPServer managed) → k8s API, but ALSO separately through mcp-preprocessor for shortcuts | No double-cost for same query, but two tool server instances exist | `ollama-agent.yaml` uses MCPServer `k2s-tools`; `mcp-preprocessor.yaml` uses RemoteMCPServer pointing to the MCPServer-managed instance |
| Agent's `mcpServer.name: k2s-tools` routes through kmcp-managed pod, then mcp-preprocessor intercepts via `k2s-tools-processed` RemoteMCPServer | The agent uses `k2s-tools` (direct) not `k2s-tools-processed` — **mcp-preprocessor is NOT in the LLM tool-call path** | Agent yaml line 109-110 |

**Critical finding:** The `ollama-agent.yaml` Agent spec references `mcpServer: k2s-tools` directly — NOT the `k2s-tools-processed` RemoteMCPServer. This means:
- The mcp-preprocessor's truncation logic **does NOT apply** to LLM-initiated tool calls
- LLM receives **untruncated** tool output (potentially thousands of tokens)
- This inflates prefill time on the second LLM pass significantly
- The mcp-preprocessor only serves shortcuts (a2a-proxy calls it directly)

### 4.2 Duplicate Processing

| Issue | Impact |
|-------|--------|
| Builtin prompts ConfigMap injects ~5 large prompt sections (skills-usage, tool-usage-best-practices, safety-guardrails, kubernetes-context, a2a-communication) — all processed on EVERY request | ~2000+ tokens of static prompt, costs ~500ms prefill per request |
| The agent's system prompt (22 lines) duplicates parts of the builtin prompts (tool usage rules) | ~200 extra tokens per request |
| PostgreSQL conversation logging is synchronous in kagent-controller | ~20-50ms per step (minor but cumulative) |

### 4.3 Redundant Tool Calls

| Issue | Impact |
|-------|--------|
| Agent has `max 2 calls per request` in system prompt — but auto-confirm can trigger additional LLM passes | When confirmation triggers, effectively 3 LLM passes occur |
| For simple queries ("show pods"), the LLM still processes the full tool-usage and safety prompts before deciding on a single obvious tool call | ~1s of unnecessary prefill |

### 4.4 Unnecessary Context Injection

| Issue | Impact |
|-------|--------|
| `a2a-communication` prompt section (agent-to-agent communication) is loaded but there's only ONE agent deployed | ~400 tokens wasted per request |
| `safety-guardrails` prompt is appropriate but verbose — the agent never writes to the cluster (read-only tools only) | ~300 tokens that could be condensed |
| `kubernetes-context` prompt duplicates much of what the agent's own system prompt already says | ~500 tokens overlap |
| Full conversation history grows unbounded per session — no sliding window | After 5+ turns, prefill grows to 3-4s |

### 4.5 Prompt Inefficiencies

| Issue | Impact |
|-------|--------|
| System prompt uses natural language where structured format would be more token-efficient | ~30% more tokens than necessary |
| Tool descriptions from MCP include verbose schemas that the model must process | ~500-800 tokens of tool metadata |
| No prompt caching — identical system prompt is re-tokenized on every request | Ollama caches KV internally if keep_alive is active, but prompt changes (history growth) invalidate the cache |

---

## 5. Configuration Review

### 5.1 keep_alive Configuration

**Current:** `keep_alive: "30m"` in `ollama-agent.yaml` ModelConfig, `OLLAMA_KEEP_ALIVE: "24h"` in ollama.yaml.

**Analysis:**
- Server-level: 24h (good — model stays loaded)
- Per-request: 30m (sent with each request via ModelConfig)
- The per-request value overrides server-level — 30m is reasonable
- **Issue:** If no queries for 30m, the model unloads. Cold reload of qwen2.5:7b takes ~10s. This is fine for interactive use but could cause surprise latency after idle periods.

**Recommendation:** Keep as-is. 30m is a good balance between memory usage and responsiveness.

### 5.2 Model Options

**Current:** `temperature: "0"`, `num_predict: "1024"`.

**Analysis:**
- `temperature: 0` — deterministic outputs, good for tool-calling reliability
- `num_predict: 1024` — max 1024 output tokens per response
- **Issue:** 1024 tokens is generous for typical responses (~50-200 tokens). The model generates until EOS naturally, so this mainly acts as a safety cap. However, Ollama pre-allocates KV cache space for num_predict, which may slightly increase memory pressure.
- **Missing:** `num_ctx` not set — defaults to model's training context (typically 32768 for qwen2.5:7b). This means the model allocates KV cache for 32K context even when typical usage is 4-8K tokens.

### 5.3 Token Limits

**Current limits in mcp-preprocessor:**
- `k8s_get_resources`: 60 lines / 2048 tokens
- `k8s_describe_resource`: 120 lines / 4096 tokens
- `k8s_get_pod_logs`: 100 lines / 3072 tokens
- `k8s_get_events`: 60 lines / 2048 tokens
- `k8s_get_resource_yaml`: 150 lines / 4096 tokens

**Issue:** These limits apply to shortcuts only (see §4.1). LLM-path tool calls through `k2s-tools` MCPServer bypass the preprocessor entirely and return full untruncated output.

### 5.4 Context Window Settings

**Current:** Not explicitly set (`num_ctx` absent from ModelConfig options).

**Impact:** Ollama defaults to the model's max (32K for qwen2.5:7b). KV cache is allocated for the full context window. With 8GB VRAM and qwen2.5:7b (~4.7GB weights), only ~3.3GB remains for KV cache — sufficient for 32K at q4 quantization but tight.

### 5.5 Streaming Behavior

**Current:** `STREAMING_TIMEOUT: "600s"`, `STREAMING_INITIAL_BUF_SIZE: "4Ki"`, `STREAMING_MAX_BUF_SIZE: "1Mi"` in kagent-controller ConfigMap.

**Issue:** The ingress and a2a-proxy both set `proxy-buffering: off` and have streaming-compatible configurations. However, the A2A protocol as implemented uses **synchronous request/response** (not SSE streaming) for the `tasks/send` method. This means:
- The user sees NO output until the ENTIRE response (including all tool calls) completes
- 6-7s of complete silence followed by the full answer appearing at once
- Streaming would allow showing partial responses (thinking indicators, tool call progress)

---

## 6. Optimization Opportunities

### Quick Wins (< 1 day effort)

| # | Optimization | Expected Improvement | Implementation |
|---|-------------|---------------------|----------------|
| Q1 | **Route agent tools through mcp-preprocessor** — change `ollama-agent.yaml` to use `k2s-tools-processed` RemoteMCPServer instead of `k2s-tools` MCPServer | -500ms to -1500ms (reduced prefill on tool results) | Change `tools[0].mcpServer.name` from `k2s-tools` to reference `k2s-tools-processed` RemoteMCPServer |
| Q2 | **Remove `a2a-communication` builtin prompt** — no multi-agent scenario exists | -100ms (400 fewer tokens in prefill) | Remove from `kagent-builtin-prompts` ConfigMap or override in agent system message |
| Q3 | **Set `num_ctx: 8192`** in ModelConfig options | -200ms prefill (smaller KV cache allocation, faster attention) | Add `num_ctx: "8192"` to `ollama-agent.yaml` ModelConfig `options` |
| Q4 | **Reduce `num_predict: 512`** — responses rarely exceed 200 tokens | Marginal (helps Ollama memory planning) | Change in `ollama-agent.yaml` |
| Q5 | **Condense system prompt** — remove redundancies with builtin prompts | -100-200ms (fewer tokens) | Rewrite system prompt to be more concise, remove duplicated tool-usage rules |

**Total Quick Wins: -900ms to -2500ms → Target: 4-5.5s conversational**

### Medium Improvements (1-3 days)

| # | Optimization | Expected Improvement | Implementation |
|---|-------------|---------------------|----------------|
| M1 | **Eliminate auto-confirmation entirely** — modify kagent Agent spec to disable tool confirmation for read-only tools | -3000-5000ms (removes entire extra LLM round-trip when triggered) | Investigate kagent `confirmBeforeExec` or similar Agent spec field; if not available, the a2a-proxy already handles it but the kagent-controller still generates the confirmation request first |
| M2 | **Implement context window sliding** — limit conversation history to last N turns (e.g., 3-5) | -500-2000ms after 5+ turns (prevents prefill growth) | Modify agent configuration or implement history pruning in a2a-proxy before forwarding |
| M3 | **Add shortcut detection in a2a-proxy for LLM-path queries** — intercept obvious tool-call queries before they reach kagent-controller | -4000-5000ms for shortcuttable queries sent via chat | Extend `handleA2A` to pattern-match the user message against shortcut patterns before forwarding to upstream |
| M4 | **Optimize builtin prompts** — merge/condense kubernetes-context + safety + tool-usage into one compact prompt block | -300-500ms (reduce ~1500 tokens to ~600) | Rewrite ConfigMap content |
| M5 | **Pre-warm MCP session** — the mcp-preprocessor already does this, but k2s-tools MCPServer may cold-start | -200-500ms on first query after idle | Add keepalive ping from kagent-controller to tool servers |

**Total Medium: -4000-8000ms (for applicable scenarios) → Target: 2-4s for simple queries**

### Major Improvements (> 3 days)

| # | Optimization | Expected Improvement | Implementation |
|---|-------------|---------------------|----------------|
| J1 | **Implement SSE streaming** — stream tokens from Ollama through kagent-controller to browser | Perceived: -4000ms (tokens appear after ~1s instead of 6-7s silence) | Requires: kagent A2A streaming support, a2a-proxy streaming passthrough, Kagent UI streaming rendering. Major framework change. |
| J2 | **Switch to a smaller/faster model** — e.g., qwen2.5:3b or qwen2.5:1.5b for tool-calling workloads | -2000-3000ms (faster prefill + generation) | Trade-off: reduced quality for complex queries. Could use routing: fast model for simple tool calls, current model for complex analysis. |
| J3 | **Implement prompt caching** — detect unchanged prompt prefix and skip re-tokenization | -500-1500ms per request (Ollama partially does this via KV cache, but history changes invalidate) | Requires Ollama-level changes or a caching proxy that manages prompt IDs. Out of scope for addon layer. |
| J4 | **Move from A2A synchronous to direct Ollama streaming** — bypass kagent framework for simple queries | -2000-3000ms + streaming UX | Significant architecture departure. Would require a lightweight direct-to-Ollama path for basic queries while keeping kagent for agent-framework features. |
| J5 | **Implement speculative tool routing** — while LLM generates, speculatively pre-fetch likely tool results | -500-1000ms for common patterns | Complex: predict which tool the LLM will call based on user query keywords, pre-fetch results |

---

## 7. Priority Recommendations

### Immediate Actions (This Week)

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| **P0** | Q1: Route agent through mcp-preprocessor | 30 min | HIGH — unbounded tool output is likely the #1 hidden latency source |
| **P1** | Q3: Set num_ctx: 8192 | 5 min | MEDIUM — reduces KV allocation overhead |
| **P2** | Q5: Condense system prompt | 2 hours | MEDIUM — fewer tokens in every request |
| **P3** | Q2: Remove a2a-communication prompt | 15 min | LOW — small token savings |

### Next Sprint

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| **P4** | M1: Eliminate auto-confirmation round-trip | 1-2 days | HIGH — removes 3-5s when triggered |
| **P5** | M3: Shortcut detection in A2A path | 1-2 days | HIGH — eliminates LLM for obvious queries |
| **P6** | M4: Optimize builtin prompts | 1 day | MEDIUM — broad improvement |
| **P7** | M2: Context window sliding | 1-2 days | MEDIUM — prevents degradation over session |

### Future Consideration

| Priority | Item | Effort | Impact |
|----------|------|--------|--------|
| **P8** | J1: SSE streaming | 1-2 weeks | HIGH perceived improvement (time-to-first-token) |
| **P9** | J2: Smaller model for tool calls | 3-5 days | HIGH raw speed improvement, quality trade-off |

---

## 8. Expected Outcomes

### After Quick Wins (Q1-Q5)

| Metric | Current | Expected | Improvement |
|--------|---------|----------|-------------|
| Simple tool query (e.g., "show pods") | 6-7s | 4-5.5s | -1.5-2s |
| First-turn latency | 6-7s | 5-6s | -1s |
| Multi-turn (turn 5+) | 8-12s | 6-8s | -2-4s |

### After Medium Improvements (M1-M5)

| Metric | Current | Expected | Improvement |
|--------|---------|----------|-------------|
| Simple tool query (shortcut-eligible) | 6-7s | 0.5-1s | -5.5-6s (bypasses LLM) |
| Simple tool query (LLM path) | 6-7s | 3-4.5s | -2.5-3.5s |
| Queries triggering auto-confirm | 9-12s | 3-4.5s | -6-8s |
| Multi-turn (turn 5+) | 8-12s | 4-6s | -4-6s |

### After Major Improvements (J1)

| Metric | Current | Expected | Improvement |
|--------|---------|----------|-------------|
| Time-to-first-token | 6-7s | 1-2s | -5s perceived |
| Full response complete | 6-7s | 4-5s | -2s actual |

---

## 9. Critical Finding: mcp-preprocessor Not in LLM Path

The most impactful discovery is that **tool output truncation does NOT apply to LLM-initiated tool calls**. The agent YAML references `k2s-tools` (MCPServer CRD, line 109-110 of `ollama-agent.yaml`), which creates a kmcp-managed deployment — completely separate from `k2s-tools-processed` (RemoteMCPServer pointing to mcp-preprocessor).

This means when the LLM calls `k8s_get_resources(resource_type="pod", all_namespaces="true")` on a cluster with 30+ pods, it receives the **full untruncated output** (potentially 3000+ tokens). This inflates the second LLM pass prefill by 1-2 seconds.

**Fix:** Change the agent's tool reference to use the preprocessed path. This is a one-line YAML change with high impact.

---

## 10. Summary

The 6-7s latency is dominated by:
1. **LLM compute** (prefill + generation + tool decision) — ~60%
2. **Auto-confirmation overhead** (when triggered) — ~0-40%
3. **System orchestration** (kagent, network) — ~15%
4. **Tool execution** (kubectl, K8s API) — ~10%

The most impactful optimizations are:
1. Route tool calls through mcp-preprocessor (reduces token count → faster prefill)
2. Eliminate auto-confirmation LLM passes (architectural fix in kagent config)
3. Extend shortcut detection to catch LLM-path queries (eliminates LLM entirely for simple queries)
4. Implement streaming (eliminates perceived wait time)

No architecture changes required. All recommendations work within the existing Windows Ollama + Kagent + a2a-proxy design.

