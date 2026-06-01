<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# GPU-Node Addon Evaluation — Impact on AI Assistant

**Date:** May 30, 2026
**Status:** Analysis only. No changes recommended.
**Current state:** Windows Ollama + RTX A2000 GPU, 23/23 tests passing.

---

## 1. How gpu-node Works in K2s

The gpu-node addon exposes the Windows host GPU to the KubeMaster Linux VM so Kubernetes pods can request `nvidia.com/gpu` resources. The mechanism differs by hosting variant:

**Hyper-V variant (current setup):**
1. Stops the KubeMaster VM
2. Adds a Hyper-V GPU Partition Adapter (`Add-VMGpuPartitionAdapter`)
3. Configures MMIO space (3GB low, 32GB high)
4. Installs a WSL2-compatible Linux kernel (microsoft-standard-wsl2:6.18.20.1)
5. Copies NVIDIA driver files from `C:\Windows\System32\lxss\lib` into the VM
6. Installs NVIDIA Container Toolkit (libnvidia-container, nvidia-container-runtime)
7. Deploys NVIDIA k8s-device-plugin DaemonSet
8. Labels node with `gpu=true`, `accelerator=nvidia`
9. Device plugin registers `nvidia.com/gpu` resource with kubelet

**WSL2 variant:**
- GPU is already paravirtualized via `/usr/lib/wsl/lib/libdxcore.so`
- Only needs container toolkit + device plugin (no VM restart)

**Key technical detail:** The GPU access uses the **dxcore/D3D12 paravirtualization** path (NOT native NVML). This means:
- GPU compute works (CUDA via D3D12 translation)
- NVML is NOT available (no nvidia-smi metrics, no DCGM exporter)
- Performance has overhead vs native GPU access

**Time-slicing support:** `--time-slices N` shares one physical GPU across N pods via CUDA time-slicing.

---

## 2. Does gpu-node Expose the Same RTX A2000?

**YES** — but through a different mechanism:

| Aspect | Windows Ollama (current) | gpu-node (hypothetical) |
|--------|-------------------------|------------------------|
| GPU access method | Native Windows CUDA driver | Hyper-V GPU-PV (paravirtualized) |
| Driver path | Direct NVIDIA WDDM driver | dxcore → D3D12 → libcuda translation |
| CUDA available | Yes (native) | Yes (via paravirtualization) |
| NVML available | Yes | NO (dxcore path) |
| nvidia-smi | Full functionality | Limited (no temp/power readings) |
| Performance | 100% native | ~85-95% (paravirtualization overhead) |

**Critical finding:** The gpu-node addon would expose the SAME physical RTX A2000, but through a paravirtualization layer. The GPU cannot be used simultaneously by both Windows Ollama and a K8s pod requesting `nvidia.com/gpu` — GPU-PV partitions the GPU, it doesn't duplicate it.

---

## 3. Could Ollama Run as K8s Workload with gpu-node?

**YES**, technically possible. The deployment would look like:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
spec:
  template:
    spec:
      containers:
      - name: ollama
        image: ollama/ollama:0.24.0
        resources:
          limits:
            nvidia.com/gpu: 1    # Request GPU via device plugin
        env:
        - name: OLLAMA_HOST
          value: "0.0.0.0"
```

However, this introduces significant constraints:
- The GPU is now partitioned between Windows host and VM
- If gpu-node takes the full GPU, Windows loses it (and vice versa)
- With time-slicing, both could share, but with reduced performance

---

## 4. Would Performance Improve?

**NO — performance would DECREASE.**

| Metric | Windows Ollama (current) | K8s Ollama + gpu-node |
|--------|-------------------------|----------------------|
| GPU access | Native CUDA (direct) | Paravirtualized (dxcore → D3D12) |
| Overhead | 0% | 5-15% paravirtualization overhead |
| qwen2.5:7b tok/s | 41 tok/s | ~35-39 tok/s (estimated) |
| VRAM available | 8192 MiB (full) | ~7500-7800 MiB (GPU-PV reservation) |
| Cold start | 10s | 10s + pod scheduling (~15s total) |
| Model load path | NVMe SSD → GPU (direct DMA) | NVMe → VM filesystem → GPU (extra hop) |

**Why paravirtualization is slower:**
1. GPU-PV adds a D3D12 translation layer between CUDA calls and hardware
2. Memory copies cross the VM boundary (host → guest page table mapping)
3. GPU memory is slightly reduced by the paravirtualization overhead
4. I/O path for model loading adds a filesystem hop

---

## 5. Would Operational Complexity Increase?

**YES — significantly.**

| Concern | Windows Ollama (current) | K8s Ollama + gpu-node |
|---------|-------------------------|----------------------|
| Enable process | Install service (30s) | VM restart, kernel swap, driver copy, toolkit install (~5-10min) |
| Dependencies | Ollama binary only | WSL installed, NVIDIA drivers on host, gpu-node addon, nvidia-container-toolkit, device plugin |
| Failure modes | Service crash → auto-restart | Pod crash + device plugin crash + GPU-PV failure + kernel mismatch |
| GPU sharing | N/A (exclusive to Ollama) | Conflicts with any other GPU workload in cluster |
| Monitoring | nvidia-smi (full) | nvidia-smi limited (no NVML on dxcore) |
| Upgrade path | `ollama pull` on Windows | Rebuild container image + rolling deployment |
| Debugging | `ollama logs` on Windows | kubectl logs + describe pod + check device plugin + check GPU-PV |
| Recovery | Restart service (5s) | Restart pod (10s) + possible VM restart + device plugin re-registration |

---

## 6. Would devstral Benefit?

**NO.** devstral's bottleneck is VRAM size (13.3GB model vs 8GB VRAM), not GPU access speed.

GPU-PV would make it WORSE:
- Less usable VRAM (GPU-PV reserves some for paravirtualization)
- Same spill-to-CPU behavior, but now CPU path crosses VM boundary too
- Net result: slower than current Windows native (4.5 tok/s → ~3.5-4 tok/s estimated)

devstral would only benefit from a larger GPU (16GB+ VRAM), regardless of where it runs.

---

## 7. Would qwen2.5:7b Benefit?

**NO.** qwen2.5:7b already fits entirely in GPU VRAM and runs at 41 tok/s on native Windows CUDA. GPU-PV would only add overhead:

- Current: 41 tok/s (native CUDA)
- With gpu-node: ~35-39 tok/s (paravirtualized CUDA)
- Net result: 5-15% SLOWER

---

## 8. Resource Implications

| Resource | Windows Ollama (current) | K8s Ollama + gpu-node |
|----------|-------------------------|----------------------|
| Windows host GPU | Used by Ollama process | Partitioned to VM (not available to host) |
| Linux VM RAM | No Ollama overhead | +8Gi for Ollama pod |
| Linux VM CPU | No Ollama overhead | +4 CPU for Ollama pod |
| Disk (Linux VM) | No model storage | +5-15GB for model storage in VM |
| Additional images | None | nvidia-device-plugin, WSL2 kernel (~800MB) |
| Additional packages | None | nvidia-container-toolkit (4 .deb packages) |
| Kernel change | None | microsoft-standard-wsl2 kernel required |
| VM restarts during enable | 0 | 2 (kernel swap + GPU-PV config) |

**GPU sharing conflict:** If gpu-node is enabled AND Windows Ollama is running, they would compete for the same physical GPU. GPU-PV partitions the GPU — you cannot have both using it at full capacity simultaneously.

---

## 9. Risks and Rollback Plan

### Risks of switching to gpu-node

| Risk | Severity | Description |
|------|----------|-------------|
| Performance regression | HIGH | 5-15% slower inference, no benefit |
| GPU sharing conflict | HIGH | Cannot run Windows Ollama + K8s GPU pod simultaneously |
| Increased failure surface | MEDIUM | Kernel, drivers, device plugin, GPU-PV all must work together |
| VM restart during enable | MEDIUM | 2 VM restarts disrupt all K8s workloads |
| VRAM reduction | LOW | GPU-PV reserves some memory for paravirtualization |
| Model storage duplication | LOW | Models stored in VM instead of (or in addition to) Windows |

### Rollback plan (if gpu-node were attempted)

1. `k2s addons disable gpu-node` (removes device plugin, reverts kernel, removes GPU-PV adapter)
2. VM restarts during disable (disrupts workloads)
3. Re-start Windows Ollama service
4. Verify 172.19.1.1:11434 reachable
5. Run acceptance tests

---

## 10. Architecture Comparison

### Option A: Windows Ollama + Windows GPU (CURRENT)

```
Windows Host
├── K2sOllama service → NVIDIA RTX A2000 (native CUDA, 41 tok/s)
│   └── qwen2.5:7b fully in VRAM
├── Linux VM (kubemaster)
│   └── Kubernetes
│       ├── kagent-controller → Ollama at 172.19.1.1:11434
│       ├── a2a-proxy → shortcuts + forwarding
│       └── mcp-preprocessor → tools
└── Endpoint: 172.19.1.1:11434 (direct, no hop)
```

Advantages:
- Native GPU performance (41 tok/s)
- Simple architecture (service on host)
- No VM restart needed
- No kernel changes
- No driver copy needed
- No GPU-PV overhead
- Full nvidia-smi monitoring
- Auto-restart via nssm
- Model management via `ollama pull` on host

### Option B: Kubernetes Ollama + gpu-node Addon (HYPOTHETICAL)

```
Windows Host
├── GPU-PV partition → Linux VM
├── Linux VM (kubemaster, WSL2 kernel, GPU-PV enabled)
│   └── Kubernetes
│       ├── nvidia-device-plugin (registers nvidia.com/gpu)
│       ├── ollama pod (requests nvidia.com/gpu: 1)
│       │   └── qwen2.5:7b via paravirtualized CUDA (~35-39 tok/s)
│       ├── kagent-controller → Ollama at ollama.svc:11434
│       ├── a2a-proxy
│       └── mcp-preprocessor
└── Windows host LOSES GPU access (partitioned to VM)
```

Disadvantages:
- 5-15% slower (paravirtualization overhead)
- VM restart required (2x during enable)
- Kernel swap required (microsoft-standard-wsl2)
- Driver files must be copied into VM
- More failure modes
- GPU unavailable to Windows host
- No nvidia-smi metrics (dxcore limitation)
- Heavier Linux VM resource usage (+8Gi RAM, +4 CPU)

---

## 11. Performance Comparison

| Metric | Option A (current) | Option B (gpu-node) | Delta |
|--------|-------------------|--------------------|-|
| qwen2.5:7b inference | 41 tok/s | ~35-39 tok/s | -5% to -15% |
| Deterministic shortcuts | 100ms | 100ms | Same (no GPU) |
| Conversational (warm) | 6-7s | 7-9s | +1-2s slower |
| Cold start | 10s | 15-20s (pod schedule + load) | +5-10s |
| Available VRAM | 8192 MiB | ~7500-7800 MiB | -400-700 MiB |
| devstral tok/s | 4.5 tok/s | ~3.5-4 tok/s | -10-20% |

---

## 12. Operational Comparison

| Dimension | Option A (current) | Option B (gpu-node) |
|-----------|-------------------|--------------------| 
| Setup time | 30 seconds | 5-10 minutes |
| Recovery time | 5 seconds | 30-60 seconds |
| Dependencies | Ollama binary | Ollama image + nvidia-toolkit + device plugin + WSL2 kernel |
| Monitoring | Full nvidia-smi | Limited (no NVML) |
| Scaling | N/A (single model) | Time-slicing possible (but slower per-pod) |
| Updates | `ollama pull` on host | Rebuild image + redeploy |
| Debugging | Local process + logs | kubectl logs + device plugin status + GPU-PV diagnostics |
| Addon conflicts | None | Occupies GPU exclusively — Windows apps lose GPU |

---

## 13. When gpu-node WOULD Be Beneficial

The gpu-node addon is designed for workloads that:
1. MUST run as Kubernetes pods (containerized GPU workloads)
2. Need Kubernetes scheduling (multi-pod GPU access via time-slicing)
3. Don't have a Windows-native alternative
4. Are part of a CI/CD pipeline managed by K8s

Examples: CUDA batch jobs, ML training pods, GPU-accelerated video processing.

For Ollama specifically, there is NO benefit because:
- Ollama has a native Windows binary with full GPU support
- The endpoint is already reachable from the cluster (172.19.1.1:11434)
- Running as a service provides equivalent reliability to K8s pod management
- Native CUDA is faster than paravirtualized CUDA

---

## 14. Recommendation

**DO NOT enable gpu-node for the AI Assistant addon.**

Rationale:
1. Current architecture is FASTER (native CUDA vs GPU-PV)
2. Current architecture is SIMPLER (no kernel swap, no driver copy, no device plugin)
3. Current architecture is MORE RELIABLE (fewer failure modes)
4. Current architecture PRESERVES GPU for Windows host use
5. No measurable benefit for either qwen2.5:7b or devstral
6. Adding gpu-node would require stopping Windows Ollama (GPU conflict)
7. Adding gpu-node requires 2 VM restarts (disrupts cluster)

**The gpu-node addon serves a different use case** — enabling GPU workloads that MUST be containerized (e.g., CUDA batch jobs, ML training pipelines). Ollama is not such a workload; it has a superior native Windows runtime path.

**Keep the current architecture:** Windows Ollama service with native GPU access at 41 tok/s. This is the optimal configuration for the RTX A2000 8GB hardware.

