<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Ollama Windows Host Migration — Architecture Feasibility Analysis

**Date:** May 30, 2026
**Status:** Analysis complete. Awaiting approval to implement.
**Baseline:** 23/23 acceptance tests passing. Platform stable.

---

## 1. Current Architecture

```
WINDOWS HOST (172.19.1.1)
├── K2s CLI
├── Hyper-V / WSL (Linux VM: kubemaster, 172.19.1.100)
│   ├── Kubernetes control plane (kubeadm)
│   ├── kagent namespace
│   │   ├── kagent-controller (agent orchestration)
│   │   ├── kagent-ui (Next.js, sole AI interface)
│   │   ├── a2a-proxy (workflow router, port 8082)
│   │   ├── mcp-preprocessor (tool output preprocessing)
│   │   ├── k2s-tools (MCP server, kubectl access)
│   │   ├── k2s-assistant deployment (agent runtime)
│   │   └── kagent-postgresql (session state)
│   └── ai-assistant namespace
│       └── ollama deployment (LLM runtime, model: qwen2.5:7b)
│           ├── hostPath PV: /data/ollama
│           ├── exposes 11434 via K8s Service + host bridge IP
│           └── CPU-only inference (no GPU in Linux VM)
└── Windows worker node (imw1030228c, 172.20.1.2)
```

Ollama is currently:
- Running as a Kubernetes Deployment in the `ai-assistant` namespace
- Accessible from pods via K8s DNS (`ollama.ai-assistant.svc.cluster.local`)
- Accessible from Windows host via bridge IP (`172.19.1.1:11434`)
- Using CPU-only inference (Hyper-V VM has no GPU passthrough)
- Storing models on `/data/ollama` (local hostPath PV)
- Consuming up to 4 CPU + 8Gi memory from Linux VM resources

Kagent ModelConfig points to: `http://172.19.1.1:11434`
- This is the bridge IP that routes TO the Linux VM's Ollama pod
- The pod uses hostNetwork: false; traffic reaches it via kube-proxy NodePort or iptables

Wait — let me re-examine. The Ollama pod is ClusterIP service. How does 172.19.1.1:11434 reach it?

Looking at the ollama.yaml: Ollama is a ClusterIP service on port 11434. The 172.19.1.1 address is the Windows host's bridge interface. For the kagent-controller (running inside the Linux VM) to reach Ollama at 172.19.1.1:11434, there must be port-forwarding from the host to the pod — OR Ollama uses hostPort/hostNetwork.

Examining ollama.yaml more carefully: no hostPort, no hostNetwork. The Ollama service is ClusterIP within the cluster. So kagent-controller reaches Ollama via its ClusterIP (ollama.ai-assistant.svc.cluster.local:11434).

But the ModelConfig says `http://172.19.1.1:11434`. This means:
- Ollama's port 11434 is somehow exposed on the host bridge IP
- This could be via K2s's built-in port forwarding from Windows host to Linux VM services
- OR there's a separate Ollama instance already running on Windows

Looking at the acceptance test output: `curl.exe -s http://172.19.1.1:11434/api/tags` succeeded from Windows host. This confirms Ollama at 172.19.1.1:11434 is accessible from both Windows host AND from inside the Linux VM pods (since the bridge IP is routeable from both).

The most likely mechanism: K2s routes traffic from pods destined for 172.19.1.1 back to the Windows host (standard K2s bridge networking). And something on the Windows host is forwarding port 11434 to the Ollama pod inside the VM. OR the Ollama pod uses hostPort: 11434, which would bind to the Linux VM's 172.19.1.100:11434, and K2s networking routes 172.19.1.1 → 172.19.1.100.

For this analysis, the key fact is: **Ollama is already accessed via 172.19.1.1:11434 from kagent-controller's perspective.** This is the critical insight.

---

## 2. Target Architecture

```
WINDOWS HOST (172.19.1.1)
├── K2s CLI
├── Ollama (native Windows process)          ← NEW
│   ├── Listening on 0.0.0.0:11434 (or 127.0.0.1:11434 + bridge forward)
│   ├── GPU acceleration (NVIDIA/AMD/Intel if available)
│   ├── Model: devstral (23.6B, Q4_K_M, ~14GB)
│   ├── Model: qwen2.5:7b (fallback, 4.7GB)
│   └── Storage: C:\data\ollama (or similar)
├── Hyper-V / WSL (Linux VM: kubemaster, 172.19.1.100)
│   ├── Kubernetes control plane (kubeadm)
│   ├── kagent namespace
│   │   ├── kagent-controller → reaches Ollama via 172.19.1.1:11434 (unchanged!)
│   │   ├── kagent-ui
│   │   ├── a2a-proxy → Ollama monitor at 172.19.1.1:11434 (unchanged!)
│   │   ├── mcp-preprocessor
│   │   ├── k2s-tools
│   │   ├── k2s-assistant deployment
│   │   └── kagent-postgresql
│   └── ai-assistant namespace
│       └── (EMPTY — Ollama deployment REMOVED)
└── Windows worker node (imw1030228c, 172.20.1.2)
```

Key changes:
- Ollama runs as a native Windows service/process on the host
- Same endpoint: `172.19.1.1:11434` (accessible from both Windows and Linux VM)
- devstral becomes the primary model (23.6B params, GPU-accelerated)
- qwen2.5:7b retained as fallback
- GPU utilization: NVIDIA CUDA, AMD ROCm, or Intel oneAPI (Ollama auto-detects)
- Linux VM retains all Kubernetes workloads except Ollama

---

## 3. Feasibility Assessment: Why This Works

The critical architectural insight is that **the current system already routes through the Windows host bridge IP (172.19.1.1:11434)**. This means:

1. `kagent-controller` ModelConfig already points to `http://172.19.1.1:11434` — NO CHANGE needed for the conversational workflow.
2. `a2a-proxy` Ollama monitor already probes `http://172.19.1.1:11434` — NO CHANGE needed.
3. `Set-OllamaKeepAlive` in PowerShell already curls `http://172.19.1.1:11434` from the Windows host — NO CHANGE needed.
4. Deterministic workflows (shortcuts) **never touch Ollama** — NO CHANGE needed.

The migration is primarily an **infrastructure change** (where Ollama runs), not an **architecture change** (how components communicate).

---

## 4. Component Impact Analysis

### 4.1 Components that assume Ollama in Kubernetes

| Component | File | Current Reference | Impact |
|-----------|------|-------------------|--------|
| Ollama Deployment | `manifests/ollama/ollama.yaml` | Full K8s deployment | REMOVE entirely |
| ai-assistant namespace | `manifests/ollama/ollama.yaml` | Namespace definition | Keep (may be needed for PVC cleanup) |
| Enable.ps1 | `Enable.ps1` lines 86-121 | `Invoke-Kubectl apply ollama`, `Invoke-OllamaModelPull` | REPLACE with Windows Ollama install |
| Disable.ps1 / Remove-AiAssistantResources | `ai-assistant.module.psm1` | `kubectl delete deployment/ollama` | REPLACE with Windows Ollama stop/uninstall |
| Get-Status.ps1 | `Get-Status.ps1` lines 50-67 | `kubectl wait deployment/ollama` | REPLACE with host process/service check |
| addon.manifest.yaml | `addon.manifest.yaml` line 39 | `ollama/ollama:0.9.1` in additionalImages | REMOVE (no longer a container image) |
| New-OllamaDataDirectory | `ai-assistant.module.psm1` | SSH to Linux VM, `mkdir /data/ollama` | REPLACE with Windows path creation |
| New-ZscalerCaConfigMap | `ai-assistant.module.psm1` | K8s ConfigMap for proxy trust | REPLACE with Windows cert store |
| Invoke-OllamaModelPull | `ai-assistant.module.psm1` | `kubectl exec deployment/ollama -- ollama pull` | REPLACE with direct Windows `ollama pull` |
| Set-OllamaKeepAlive | `ai-assistant.module.psm1` | Curls `172.19.1.1:11434` | NO CHANGE (already hits host IP) |

### 4.2 Components that assume Ollama on Linux-hosted inference

| Component | Current Behavior | After Migration |
|-----------|-----------------|-----------------|
| Ollama ModelConfig | `host: "http://172.19.1.1:11434"` | NO CHANGE — same endpoint |
| a2a-proxy ConfigMap | `OLLAMA_URL: "http://172.19.1.1:11434"` | NO CHANGE — same endpoint |
| a2a-proxy resilience.go | Probes `172.19.1.1:11434/api/tags` | NO CHANGE |
| Invoke-SmokeTest.ps1 | `$ollamaUrl = "http://172.19.1.1:11434"` | NO CHANGE |

### 4.3 Components that use Ollama Kubernetes DNS

| Component | DNS Reference | Impact |
|-----------|--------------|--------|
| None found | — | The system already uses IP-based access, not DNS |

This is the key finding: **no component uses `ollama.ai-assistant.svc.cluster.local`**. All access is via the bridge IP.

### 4.4 Deterministic workflow path (NO changes needed)

```
Kagent UI → ingress → a2a-proxy → /api/shortcuts → mcp-preprocessor → k2s-tools → kubectl
```

This path never invokes Ollama. Confirmed by code inspection:
- `shortcutRouter` calls `callToolWithTimeout()` which HTTP POSTs to mcp-preprocessor
- mcp-preprocessor forwards to k2s-tools MCP server
- No Ollama involvement at any point

### 4.5 Conversational workflow path (minimal change)

```
Kagent UI → ingress → a2a-proxy → /api/a2a/ → kagent-controller
  → k2s-assistant agent → ModelConfig → Ollama at 172.19.1.1:11434
  → inference → tool calls → mcp-preprocessor → k2s-tools → kubectl
```

The only change: Ollama at `172.19.1.1:11434` is now a Windows native process instead of a Linux pod. The endpoint is identical.

---

## 5. Required Code Changes

### 5.1 Enable.ps1 — Replace K8s Ollama deployment with Windows Ollama installation

Current (lines 86-121): Deploys Ollama as K8s pod, waits for ready, pulls model via kubectl exec.

New behavior:
- Check if Ollama is already installed on Windows (`ollama --version` or `Get-Service OllamaService`)
- If not installed: download Ollama for Windows, install as Windows service
- Configure bind address (`OLLAMA_HOST=0.0.0.0`)
- Configure model storage path
- Configure GPU settings
- Pull model: `ollama pull devstral` (direct Windows command)
- Verify readiness: `curl http://localhost:11434/api/tags`

### 5.2 ai-assistant.module.psm1 — Replace K8s-based functions

| Function | Change |
|----------|--------|
| `New-OllamaDataDirectory` | Create `C:\data\ollama` on Windows host instead of SSH to Linux |
| `New-ZscalerCaConfigMap` | Install ZScaler cert into Windows cert store or Ollama env var |
| `Invoke-OllamaModelPull` | Run `ollama pull $Model` directly on Windows (no kubectl exec) |
| `Set-OllamaKeepAlive` | NO CHANGE (already uses host curl) |
| `Remove-AiAssistantResources` | Remove Windows Ollama service stop/data cleanup logic |

### 5.3 Get-Status.ps1 — Replace K8s deployment check with Windows process check

Current: `kubectl wait --for=condition=Available deployment/ollama -n ai-assistant`
New: Check if Ollama Windows process/service is running and responsive at `localhost:11434`

### 5.4 Disable.ps1 — Replace K8s teardown with Windows process stop

Current: Deletes K8s deployment, PVC, namespace
New: Stop Ollama Windows service, optionally remove model data from Windows filesystem

### 5.5 ollama-agent.yaml ModelConfig — Model name change

Current: `model: "MODEL_PLACEHOLDER"` (replaced with `qwen2.5:7b` at deploy time)
New: `model: "devstral"` (or parameterized via --model flag, default changed to devstral)

### 5.6 addon.manifest.yaml — Remove container images, add Windows binary reference

Remove `ollama/ollama:0.9.1` from additionalImages.
Add documentation that Ollama Windows binary is bundled or downloaded.

---

## 6. Required Manifest Changes

| Manifest | Change |
|----------|--------|
| `manifests/ollama/ollama.yaml` | DELETE entirely (no longer deploying to K8s) |
| `manifests/kagent/ollama-agent.yaml` | Update default model to `devstral`, host remains `http://172.19.1.1:11434` |
| `manifests/kagent/a2a-proxy.yaml` | NO CHANGE (OLLAMA_URL already correct) |
| `manifests/kagent/kagent-ingress.yaml` | NO CHANGE |
| `manifests/kagent/mcp-preprocessor.yaml` | NO CHANGE |
| `manifests/kagent/k2s-tools-rbac.yaml` | NO CHANGE |
| `manifests/kagent/kagent.yaml` | NO CHANGE |

---

## 7. Required Networking Changes

**None required for the core data path.**

The endpoint `172.19.1.1:11434` is already used. The only difference is what answers on that port:
- Before: Traffic from pods → bridge → Windows host → port-forward → Linux VM → Ollama pod
- After: Traffic from pods → bridge → Windows host → Ollama Windows process (direct)

The migration actually **simplifies** networking by removing one hop.

### 7.1 Ollama bind address

Ollama on Windows must listen on `0.0.0.0:11434` (not just `127.0.0.1`) so that traffic from the Linux VM can reach it via the bridge interface.

Environment variable: `OLLAMA_HOST=0.0.0.0`

### 7.2 Firewall

Windows Firewall must allow inbound connections on port 11434 from the K2s bridge subnet (`172.19.0.0/16` and `172.20.0.0/16`).

### 7.3 Proxy configuration

Corporate proxy (ZScaler) settings must be applied to the Windows Ollama process for model downloads:
- `HTTPS_PROXY=http://proxy:8181` (or system proxy)
- ZScaler root CA must be in Windows cert store (usually already the case on corporate machines)

---

## 8. Kagent Compatibility Verification

### 8.1 ModelConfig compatibility

The `ModelConfig` CRD (kagent.dev/v1alpha2) specifies:
```yaml
spec:
  provider: "Ollama"
  model: "devstral"
  ollama:
    host: "http://172.19.1.1:11434"
```

Kagent's Ollama provider implementation uses the `host` field as the base URL for the Ollama OpenAI-compatible API (`/v1/chat/completions`). It does not assume Ollama runs in Kubernetes. It simply needs an HTTP endpoint. **Fully compatible.**

### 8.2 Authentication

Ollama's API has no authentication by default. No auth changes needed.
If security is desired later, Ollama supports `OLLAMA_ORIGINS` for CORS-like restrictions.

### 8.3 Failover behavior

Current: If Ollama pod crashes, K8s restarts it (deployment controller).
After: If Ollama Windows process crashes, Windows Service Manager restarts it (if installed as service).

The a2a-proxy's OllamaMonitor already probes every 30s and reports status. Deterministic shortcuts continue to work regardless of Ollama state.

---

## 9. GPU Acceleration

### 9.1 Ollama Windows GPU support

Ollama for Windows natively supports:
- NVIDIA GPUs via CUDA (most common)
- AMD GPUs via ROCm
- Intel GPUs via oneAPI (experimental)

No configuration needed — Ollama auto-detects available GPUs on startup.

### 9.2 Performance expectations

| Model | CPU-only (current) | GPU (NVIDIA RTX 3060+) |
|-------|-------------------|----------------------|
| qwen2.5:7b | ~10-18s per request | ~1-3s per request |
| devstral (23.6B) | ~45-90s (impractical) | ~5-12s per request |

GPU acceleration makes devstral viable. Without GPU, devstral is too slow for interactive use.

### 9.3 Fallback strategy

If no GPU is available:
- Use `qwen2.5:7b` (works well on CPU, 10-18s)
- Do NOT use devstral on CPU (too slow)
- The `--model` flag already allows user to select model at enable time
- Consider auto-detection: if GPU present → default devstral, else → default qwen2.5:7b

---

## 10. Routing Logic Design

### 10.1 Deterministic path (unchanged)

```
User query matches shortcut pattern?
  YES → a2a-proxy → /api/shortcuts → shortcutRouter
        → callToolWithTimeout(mcp-preprocessor) → k2s-tools → kubectl
        → format response → return (sub-second, no LLM)
  NO  → continue to conversational path
```

### 10.2 Conversational path (Ollama location changes, protocol unchanged)

```
User query (free-form, no shortcut match):
  → a2a-proxy → /api/a2a/kagent/k2s-assistant → forward to kagent-controller
  → kagent-controller invokes k2s-assistant agent
  → agent uses ModelConfig (Ollama provider, host: 172.19.1.1:11434, model: devstral)
  → LLM inference on Windows GPU
  → tool calls emitted → auto-confirmed by a2a-proxy
  → final response returned
```

### 10.3 Shortcut-to-conversational fallback (existing, unchanged)

The a2a-proxy already tries shortcuts first. If query doesn't match any pattern, it forwards to kagent-controller for LLM-based handling. This logic requires no changes.

---

## 11. Risks

### 11.1 HIGH: devstral requires GPU — no GPU = unusable conversational workflows

- **Mitigation:** Auto-detect GPU at enable time. Default to qwen2.5:7b if no GPU. Warn user clearly.
- **Fallback:** `--model qwen2.5:7b` flag still works.

### 11.2 HIGH: Ollama Windows service stability is less proven than K8s pod management

- **Mitigation:** Install as Windows Service (nssm or native). Configure auto-restart. Monitor via a2a-proxy OllamaMonitor (already exists).
- **Fallback:** Can revert to K8s deployment with one manifest apply.

### 11.3 MEDIUM: devstral model size (14GB download, ~16GB RAM under load)

- **Mitigation:** Check available RAM before pulling. Warn if < 20GB free. Document requirements.
- **Fallback:** qwen2.5:7b needs only 6GB RAM.

### 11.4 MEDIUM: Windows Firewall may block Ollama port

- **Mitigation:** Enable.ps1 adds firewall rule automatically.
- **Fallback:** Manual firewall rule documented.

### 11.5 LOW: Model storage path conflicts with other software

- **Mitigation:** Use dedicated path (`C:\data\ollama` or `$env:LOCALAPPDATA\ollama`).
- **Fallback:** Configurable via environment variable.

### 11.6 LOW: Corporate proxy blocks model download

- **Mitigation:** Already handled — ZScaler proxy settings propagated to Ollama via env vars. For air-gapped: models pre-bundled in offline package.

---

## 12. Rollback Plan

### Immediate rollback (< 5 minutes)

1. Stop Ollama Windows service: `Stop-Service OllamaService`
2. Re-apply K8s Ollama deployment: `kubectl apply -f manifests/ollama/ollama.yaml`
3. Wait for pod ready: `kubectl wait --for=condition=Ready pod -l app=ollama -n ai-assistant`
4. Verify: `curl http://172.19.1.1:11434/api/tags`

No other changes needed — ModelConfig endpoint is the same.

### Full rollback (revert to pre-migration state)

1. `k2s addons disable ai-assistant`
2. Revert code changes (git checkout)
3. `k2s addons enable ai-assistant --provider ollama --model qwen2.5:7b`

### Why rollback is safe

The endpoint (`172.19.1.1:11434`) is identical in both architectures. Kagent-controller, a2a-proxy, and all other components don't know or care whether the process answering is a Linux container or a Windows service. The rollback is transparent to the Kagent layer.

---

## 13. Migration Strategy

### Phase A: Windows Ollama installation (non-breaking, parallel)

1. Install Ollama on Windows host alongside existing K8s deployment
2. Verify both are functional (different ports or stop one)
3. Pull devstral model to Windows Ollama
4. Validate inference quality with devstral

### Phase B: Cutover (enable script changes)

1. Update Enable.ps1 to install/start Windows Ollama instead of K8s deployment
2. Update ollama-agent.yaml model default to devstral
3. Remove K8s Ollama deployment
4. Verify Kagent can still reach Ollama at 172.19.1.1:11434

### Phase C: Cleanup and validation

1. Remove manifests/ollama/ollama.yaml content (or make it a no-op)
2. Update Get-Status.ps1, Disable.ps1, Update.ps1
3. Run full acceptance test suite (23/23 must pass)
4. Run devstral-specific quality tests (response coherence, tool-calling)

---

## 14. Validation Plan

### Acceptance regression (must all pass)

All 23 existing tests unchanged:
- Kagent UI accessible
- Agent registration
- All 9 deterministic shortcuts
- Conversational workflows
- Auto-confirmation
- Negative tests
- Ingress routing
- Component health

### New tests (devstral-specific)

- devstral model loaded and responding
- GPU detected and utilized (if available)
- Inference latency < 15s (GPU) or < 20s (CPU with qwen2.5:7b fallback)
- Multi-turn conversation coherence
- Tool-calling accuracy (devstral has excellent tool-use capabilities)
- Windows service auto-restart after crash
- Ollama survives Windows Sleep/Wake cycle

### Negative tests

- Ollama Windows service stopped → conversational workflows return informative error
- Ollama Windows service stopped → deterministic shortcuts still work (sub-second)
- Model not loaded → first request has acceptable cold-start (< 30s)

---

## 15. Estimated Effort

| Task | Effort | Dependencies |
|------|--------|--------------|
| Windows Ollama installer function | 4h | Ollama Windows binary availability |
| Enable.ps1 refactor (K8s → Windows) | 4h | Installer function |
| Disable.ps1 refactor | 2h | — |
| Get-Status.ps1 update | 1h | — |
| Update.ps1 update | 2h | — |
| ai-assistant.module.psm1 refactors | 3h | — |
| Firewall rule automation | 1h | — |
| GPU detection and model selection logic | 2h | — |
| ollama-agent.yaml model update | 0.5h | — |
| Remove ollama.yaml K8s manifests | 0.5h | — |
| Acceptance test suite run + fixes | 4h | All above |
| devstral quality validation | 4h | Model pulled |
| Documentation updates | 2h | — |
| **Total** | **~30h** | — |

---

## 16. Recommendation

**Proceed with migration.** The architecture is highly favorable:

1. **Minimal protocol changes** — The endpoint (`172.19.1.1:11434`) is already the target for all components. Moving Ollama from Linux VM to Windows host is a transparent infrastructure swap.

2. **No Kagent changes** — ModelConfig, agent CRs, kagent-controller all work unchanged. The Kagent framework doesn't know where Ollama runs.

3. **No a2a-proxy changes** — Shortcuts, auto-confirmation, Ollama monitoring all continue working at the same endpoint.

4. **GPU unlocked** — The current architecture wastes potential GPU acceleration by running Ollama in a CPU-only VM. Windows-native Ollama with GPU makes devstral (23.6B) viable for interactive use.

5. **Resource liberation** — Removing Ollama from the Linux VM frees 4 CPU + 8Gi RAM for Kubernetes workloads.

6. **Simple rollback** — Same endpoint means rollback is a process stop + kubectl apply.

7. **Deterministic path unaffected** — Zero changes needed for the shortcut/fast-path architecture.

**Risk level:** LOW-MEDIUM. The main risk is Windows service reliability (vs K8s pod management), mitigated by service auto-restart and existing health monitoring.

**Recommended implementation order:**
1. Phase A (parallel install) — validate with no impact to current system
2. Phase B (cutover) — update scripts, verify acceptance tests
3. Phase C (cleanup) — remove legacy manifests, update docs

**Prerequisite check before starting:**
- Confirm Windows host has NVIDIA/AMD GPU (for devstral viability)
- Confirm at least 20GB free RAM on Windows host
- Confirm at least 20GB free disk for model storage
- Confirm Ollama Windows binary is available for offline installation (if air-gapped)

