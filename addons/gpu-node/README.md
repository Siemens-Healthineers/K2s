<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# gpu-node

## Introduction
The `gpu-node` addon provides the possibility to configure the KubeMaster Linux VM as GPU node in order to run GPU workloads. When enabling this addon the KubeMaster Linux VM is configured to use the WSL2 Linux Kernel which is able to access the GPU of the Windows host machine and use it as shared instance together with the Windows host machine. The [k8s device plugin](https://github.com/NVIDIA/k8s-device-plugin) from Nvidia is responsible for deploying GPU workloads.

> **Supported hosting variants:** The `gpu-node` addon is fully supported on both **Hyper-V** and **WSL2** K2s setups.

## Getting started

### Prerequisites

1. **WSL (Windows Subsystem for Linux)** must be installed on the Windows host. This provides the GPU paravirtualization library (`libdxcore.so`) required by both the Hyper-V and WSL2 hosting variants. No Linux distribution is needed:
   ```console
   wsl --install --no-distribution
   ```

2. **NVIDIA drivers** must be installed on the Windows host: https://www.nvidia.com/Download/index.aspx

**NOTE:** A reboot may be necessary after installing either component.

The gpu-node addon can be enabled using the k2s CLI by running the following command:
```console
k2s addons enable gpu-node
```

### GPU time-slicing (optional)

By default each pod gets exclusive access to the physical GPU. To share the GPU across multiple pods simultaneously, use the `--time-slices` flag:

```console
k2s addons enable gpu-node --time-slices 4
```

This configures the NVIDIA device plugin to advertise `4` virtual GPU slots backed by one physical GPU. Any integer between `2` and `16` is accepted. Pods schedule onto the GPU concurrently; CUDA time-slicing handles multiplexing transparently.

> **Note:** Time-slicing shares compute time but **does not** partition GPU memory. All pods on the same physical GPU share the same memory pool. Use exclusive mode (`--time-slices 1`, the default) for workloads with large memory requirements.

## Deploy a sample CUDA workload

The following example schedules a CUDA workload using the NVIDIA vectorAdd sample to verify GPU allocation and compute access:

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

Expected output includes `Test PASSED`. Works on both Hyper-V GPU-PV and WSL2 setups.


## External GPU Worker Nodes

In addition to the KubeMaster VM, you can add external Linux machines with NVIDIA GPUs as GPU-capable worker nodes. This allows scaling GPU workloads across multiple physical machines.

### Prerequisites for External GPU Workers

1. **NVIDIA kernel drivers** must be pre-installed on the external Linux machine
2. The machine must be accessible via SSH from the K2s host
3. The machine must have a physical network connection (not on the KubeSwitch)

### Adding a GPU-Capable External Worker

```console
# Online installation (downloads NVIDIA Container Toolkit from internet)
k2s node add --ip-addr 192.168.1.50 --username admin --enable-gpu

# Offline installation (uses pre-packaged artifacts)
k2s node add --ip-addr 192.168.1.50 --username admin --enable-gpu --node-package C:\packages\debian13-node-gpu.zip
```

The `--enable-gpu` flag instructs K2s to:
1. Verify NVIDIA drivers are installed and functional (nvidia-smi)
2. Install the NVIDIA Container Toolkit packages
3. Configure CRI-O with CDI support
4. Label the node with `gpu=true`, `accelerator=nvidia`, and `k2s.io/gpu-node=true`

### Creating an Offline GPU Node Package

To add GPU workers in air-gapped environments:

```console
# Create a node package with GPU support
k2s system package --node-package --os debian13 --include-gpu --target-dir C:\packages --name debian13-node-gpu.zip

# Transfer the package to the air-gapped environment and use it
k2s node add --ip-addr 192.168.1.50 --username admin --enable-gpu --node-package C:\packages\debian13-node-gpu.zip
```

### Lifecycle Considerations

- **Order-independent**: GPU workers can be added before or after enabling the gpu-node addon
- **The addon must be enabled** for GPU workloads to run: `k2s addons enable gpu-node`
- **Labels coordinate scheduling**: The NVIDIA device plugin DaemonSet targets nodes with `k2s.io/gpu-node=true`
- **Disabling the addon** removes the device plugin but preserves GPU configuration on external workers

### Check GPU Worker Status

```console
# View all GPU-capable nodes
kubectl get nodes -l k2s.io/gpu-node=true

# Check addon status including external workers
k2s addons status gpu-node
```


## Backup and restore

The gpu-node addon supports backup and restore via the `k2s` CLI for consistency with other addons.

Because gpu-node is a **pure infrastructure addon** (Hyper-V GPU passthrough, NVIDIA driver copy, WSL2 kernel swap, container toolkit installation, static Kubernetes manifests), there is **no user-configurable state to back up**. The backup writes a metadata-only manifest; restore succeeds without additional steps once the addon has been re-enabled.

### What gets backed up

- Metadata only (`backup.json` with addon name, K2s version, timestamp).

### What does not get backed up

- Hyper-V GPU partition adapter settings (recreated by enable)
- NVIDIA driver files and WSL2 kernel on the control-plane VM (reinstalled by enable)
- NVIDIA Container Toolkit APT packages (reinstalled by enable)
- NVIDIA Device Plugin Deployment and DCGM Exporter DaemonSet (reapplied from static manifests by enable)
- GPU configuration on external worker nodes (preserved; workers remain GPU-capable)

### Commands

```console
k2s addons backup gpu-node
k2s addons restore gpu-node -f C:\Temp\k2s\Addons\gpu-node_backup_YYYYMMDD_HHMMSS.zip
```

## Further Reading
- [WSL2 Linux Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
