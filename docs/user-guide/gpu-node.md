<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# GPU Node

The `gpu-node` addon configures the K2s control-plane Linux VM as a GPU node so that Kubernetes pods can request and use the NVIDIA GPU of the Windows host machine. GPU access is shared between the Windows host and the Linux VM simultaneously.

GPU workloads are scheduled via the [NVIDIA Device Plugin](https://github.com/NVIDIA/k8s-device-plugin) using the **CDI (Container Device Interface)** injection model — the same approach used by upstream Kubernetes.

---

## Prerequisites

- **NVIDIA drivers** must be installed on the Windows host before enabling the addon.
  Download from: [https://www.nvidia.com/Download/index.aspx](https://www.nvidia.com/Download/index.aspx)

!!! note
    A reboot of the Windows host may be required after driver installation.

- For **WSL2 hosting variant**: after installing or updating NVIDIA drivers you must restart the K2s cluster before enabling the addon:
  ```console
  k2s stop
  k2s start
  ```

---

## Enabling the Addon

### Exclusive GPU access (default)

Each pod gets exclusive access to the physical GPU:

```console
k2s addons enable gpu-node
```

### GPU time-slicing (shared access)

To allow multiple pods to share the GPU simultaneously, use the `--time-slices` flag:

```console
k2s addons enable gpu-node --time-slices 4
```

This configures the NVIDIA device plugin to advertise `4` virtual GPU slots backed by one physical GPU. Any integer from `2` to `16` is accepted. CUDA time-slicing handles multiplexing transparently — pods see `nvidia.com/gpu: 1` each and execute concurrently.

!!! warning
    Time-slicing shares **compute time** but does **not** partition GPU memory. All pods on the same physical GPU share the same memory pool. Use exclusive mode (`--time-slices 1`) for workloads with large VRAM requirements.

---

## Checking Status

```console
k2s addons status gpu-node
```

The status output reports:

| Property | Description |
|----------|-------------|
| `IsDevicePluginRunning` | Whether the NVIDIA Device Plugin DaemonSet is ready |
| `IsDCGMExporterRunning` | Whether the DCGM metrics exporter is running (see [Known Limitations](#known-limitations)) |
| `NodeGpuLabels` | Whether the node has `gpu=true` and `accelerator=nvidia` labels |
| `GpuAllocatable` | Number of GPU slots advertised to Kubernetes (reflects time-slicing replicas) |
| `GpuInUse` | Number of GPU slots currently held by running pods |

---

## Hosting a GPU Pod

### Pod spec

Pods request GPU access by declaring a resource limit on `nvidia.com/gpu`. No `runtimeClassName` is required:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-gpu-workload
spec:
  restartPolicy: Never
  containers:
    - name: workload
      image: <your-cuda-image>
      resources:
        limits:
          nvidia.com/gpu: 1
```

The NVIDIA Device Plugin allocates a GPU slot and injects the device into the container via CDI annotations. The container gains access to `/dev/dxg` and the NVIDIA driver libraries under `/usr/lib/wsl/`.

### Targeting the GPU node explicitly

The control-plane node is automatically labeled `gpu=true` and `accelerator=nvidia` when the addon is enabled. Use these labels in `nodeSelector` to pin GPU workloads to it:

```yaml
spec:
  nodeSelector:
    gpu: "true"
    accelerator: nvidia
```

This is useful in multi-node K2s setups where you want to ensure the pod lands on the GPU node.

### Requesting multiple slots (time-slicing only)

When time-slicing is enabled with e.g. `--time-slices 4`, you can schedule up to 4 pods each requesting one slot:

```yaml
resources:
  limits:
    nvidia.com/gpu: 1   # each pod requests one slot; up to 4 can run concurrently
```

Requesting more than 1 `nvidia.com/gpu` per pod is not supported with time-slicing.

---

## Sample CUDA Workload

The following pod runs the NVIDIA vectorAdd CUDA sample to verify GPU allocation and compute access:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
spec:
  restartPolicy: Never
  containers:
    - name: gpu-test
      image: nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda11.7.1
      imagePullPolicy: IfNotPresent
      resources:
        limits:
          nvidia.com/gpu: 1
```

```console
kubectl apply -f gpu-test.yaml
kubectl wait pod gpu-test --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s
kubectl logs gpu-test
kubectl delete pod gpu-test
```

Expected output:

```
[Vector addition of 50000 elements]
Copy input data from the host memory to the CUDA device
CUDA kernel launch with 196 blocks of 256 threads
Copy output data from the CUDA device to the host memory
Test PASSED
```

This works on both Hyper-V GPU-PV and WSL2 setups.

---

## Offline Usage

In air-gapped environments where the Linux VM cannot reach the internet, use the export/import workflow:

```console
# On a machine with internet access:
k2s addons export gpu-node -d C:\Exports

# Transfer the exported .oci.tar file to the restricted host, then:
k2s addons import gpu-node -f C:\Exports\gpu-node_*.oci.tar

# Now enable normally — no internet required:
k2s addons enable gpu-node
```

---

## Disabling the Addon

```console
k2s addons disable gpu-node
```

This removes the Device Plugin and DCGM Exporter DaemonSets, uninstalls the NVIDIA Container Toolkit packages from the Linux VM, reverts the GRUB boot entry to the default kernel (Hyper-V only), removes the GPU partition adapter from the VM (Hyper-V only), and removes the `gpu=true` / `accelerator=nvidia` node labels.

---

## Known Limitations

| Limitation | Details |
|------------|---------|
| **DCGM / nvidia-smi full NVML** | NVML is unavailable on the dxcore/D3D12 driver path used by both WSL2 and Hyper-V GPU-PV. `nvidia-smi` works for UUID queries but NVML-dependent tools (DCGM metrics) do not function. CUDA workloads are unaffected. |
| **`nvidia-smi` reports limited info** | Only UUID queries work reliably. Power draw, temperature, and utilization queries are not available via dxcore. |
| **Single GPU only** | Only one physical GPU is exposed to the VM per K2s node. Multi-GPU passthrough is not supported. |
| **Hyper-V requirement** | GPU-PV (Hyper-V path) requires Windows 10 version 20H1 (build 19041) or later and a GPU with a WDDM 2.9+ driver. |

---

## Further Reading

- [NVIDIA Device Plugin for Kubernetes](https://github.com/NVIDIA/k8s-device-plugin)
- [WSL2 Linux Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
- [Container Device Interface (CDI) specification](https://github.com/cncf-tags/container-device-interface)
- [Addons overview](addons.md)
