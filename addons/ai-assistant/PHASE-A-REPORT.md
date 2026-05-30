<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Phase A Report — Windows Ollama Parallel Validation

**Date:** May 30, 2026
**Status:** COMPLETE
**Impact on existing runtime:** NONE — 23/23 acceptance tests unaffected

---

## 1. GPU Detection

| Property | Value |
|----------|-------|
| GPU | NVIDIA RTX A2000 8GB Laptop GPU |
| Driver | 573.71 |
| CUDA | 12.8 |
| VRAM Total | 8192 MiB |
| VRAM Used (devstral loaded) | 7351 MiB |
| VRAM Free (devstral loaded) | 692 MiB |
| GPU Utilization (idle) | 11% |

GPU is detected and functional. CUDA 12.8 driver is production-ready.

---

## 2. Windows Ollama Installation

| Property | Value |
|----------|-------|
| Ollama Version | 0.24.0 |
| Install Type | Desktop app (user process) |
| Auto-start | Via Ollama tray app at user login |
| OLLAMA_HOST | 0.0.0.0 (system env var) |
| Listening | 0.0.0.0:11434 (TCP) |
| Service Mode | User process (not Windows Service) |
| Firewall | No explicit rule needed (Ollama app exception) |
| Reachable from Linux VM | YES (172.19.1.100 → 172.19.1.1:11434 ESTABLISHED) |

Note: Ollama runs as user process, not Windows Service. For production (Phase B), converting to a Windows Service (via nssm or scheduled task with SYSTEM account) is recommended for auto-restart on crash without user login.

---

## 3. Models Available

| Model | Size | Quantization | Status |
|-------|------|-------------|--------|
| devstral:latest | 13.3 GB | Q4_K_M (23.6B params) | Ready |
| devstral-k2s:latest | 13.3 GB | Q4_K_M (custom Modelfile) | Ready |
| qwen2.5:7b | 4.4 GB | Q4_K_M (7.6B params) | Ready |
| qwen2.5:3b | 1.8 GB | Q4_K_M (3.1B params) | Ready |

---

## 4. Benchmark Results

### 4.1 Simple Prompt ("What is Kubernetes in one sentence?")

| Model | Eval Time | Total Time | Tokens | Tok/s | Notes |
|-------|-----------|------------|--------|-------|-------|
| devstral:latest (GPU) | 4.48s | 6.01s | 21 | 4.7 | Partial GPU offload (model > VRAM) |
| qwen2.5:7b (GPU) | 0.63s | 1.5s* | 27 | 42.6 | Fully in VRAM |

*qwen2.5:7b warm total was masked by model swap. Actual warm total: ~1.5s.

### 4.2 Operational Reasoning (CrashLoopBackOff diagnosis)

| Model | Eval Time | Total Time | Tokens | Tok/s | Quality |
|-------|-----------|------------|--------|-------|---------|
| devstral:latest (GPU) | 66.0s | 68.6s | 256 | 3.9 | Excellent — correct OOM diagnosis, actionable commands |
| qwen2.5:7b (GPU) | 6.2s | 8.1s | 256 | 41.2 | Good — correct diagnosis, slightly less detailed |

### 4.3 Tool-Calling (function call generation)

| Model | Eval Time | Total Time | Tokens | Tok/s | Accuracy |
|-------|-----------|------------|--------|-------|----------|
| devstral:latest (GPU) | 7.03s | 8.8s | 32 | 4.5 | CORRECT — exact tool + params |
| qwen2.5:7b (GPU) | ~1s | ~2s | ~30 | ~40 | CORRECT (from prior acceptance tests) |

### 4.4 Cold Start (model load from disk)

| Model | Load Time | Notes |
|-------|-----------|-------|
| devstral:latest | ~33s | 13.3GB loaded to GPU+RAM |
| qwen2.5:7b | ~10s | 4.4GB loaded fully to GPU |

---

## 5. Critical Finding: VRAM Constraint

The NVIDIA RTX A2000 has **8GB VRAM**. devstral (13.3GB quantized) **does not fit entirely in GPU memory**. Ollama uses partial offloading:
- ~7.3GB in VRAM (GPU layers)
- ~6GB in system RAM (CPU layers)

This results in **mixed GPU/CPU inference** at ~4.5 tok/s (vs 42 tok/s for qwen2.5:7b which fits entirely in 8GB VRAM).

Impact on interactive use:
- Short responses (tool calls, 30 tokens): ~8s — ACCEPTABLE
- Medium responses (summaries, 100 tokens): ~25s — MARGINAL
- Long responses (detailed analysis, 256 tokens): ~65s — TOO SLOW for interactive chat

---

## 6. Resource Consumption

| Resource | devstral loaded | qwen2.5:7b loaded |
|----------|----------------|-------------------|
| GPU VRAM | 7351 MiB / 8192 MiB | ~4800 MiB / 8192 MiB |
| System RAM (Ollama process) | ~0.8 GB (runner separate) | ~0.8 GB |
| System RAM (model spillover) | ~6 GB | 0 GB |
| Total Host RAM | 31.6 GB | 31.6 GB |
| Free RAM (devstral) | ~10.6 GB | ~16 GB |

---

## 7. Existing Runtime Verification

| Check | Result |
|-------|--------|
| Deterministic shortcuts (status) | PASS — "All systems operational" (100ms) |
| Conversational workflow (A2A) | PASS — 200 OK (17s) |
| Ollama health from a2a-proxy | PASS — "healthy (53ms)" |
| Linux Ollama pod (K8s) | RUNNING — not affected |
| Kagent controller | RUNNING — not affected |
| No config changes made | CONFIRMED |

---

## 8. Comparison Summary

| Dimension | qwen2.5:7b (Windows GPU) | devstral (Windows GPU, partial) |
|-----------|-------------------------|-------------------------------|
| Inference speed | 41 tok/s (excellent) | 4.5 tok/s (slow) |
| Response quality | Good | Excellent |
| Tool-calling accuracy | Good | Excellent |
| Operational reasoning | Good | Excellent (more detailed) |
| VRAM fit | YES (4.4GB < 8GB) | NO (13.3GB > 8GB, spills to CPU) |
| Interactive viability | YES | SHORT RESPONSES ONLY |
| Cold start | 10s | 33s |

---

## 9. Recommendation

### GO for Phase B — with model selection adjustment

The Windows Ollama infrastructure is fully operational and validated. However, the **GPU VRAM constraint (8GB)** changes the model recommendation:

**REVISED RECOMMENDATION:**

For this hardware (RTX A2000 8GB):
- **Primary model:** `qwen2.5:7b` — fits entirely in GPU, 41 tok/s, excellent interactive experience
- **Alternative model:** `devstral:latest` — superior reasoning but 10x slower due to VRAM overflow

The Phase B cutover should:
1. Move Ollama from Linux K8s pod to Windows host (the infrastructure change)
2. Keep `qwen2.5:7b` as default model (best interactive performance on 8GB GPU)
3. Document that `devstral` is available for users with 16GB+ VRAM GPUs
4. Add `--model` parameter to allow user choice at enable time

**Key performance gain from Phase B cutover:**
- Current: qwen2.5:7b on Linux VM CPU → ~10-18s per response
- After: qwen2.5:7b on Windows GPU → ~1-2s per response (10x improvement)

This is the primary value proposition — **GPU-accelerated qwen2.5:7b**, not switching to devstral.

### Prerequisites for Phase B GO

- [x] Windows Ollama operational
- [x] GPU detected and functional
- [x] Models loaded and responding
- [x] Network reachability from Linux VM confirmed (172.19.1.1:11434)
- [x] Existing runtime unaffected (23/23 tests passing)
- [ ] Convert Ollama to Windows Service (auto-restart without user login)
- [ ] Add explicit firewall rule (defense-in-depth)

### GO/NO-GO: **GO** (conditional on service mode conversion during Phase B implementation)

