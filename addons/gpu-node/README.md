<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# gpu-node

## Introduction
The `gpu-node` addon provides the possibility to configure the KubeMaster Linux VM as GPU node in order to run GPU workloads. When enabling this addon the KubeMaster Linux VM is configured to use the WSL2 Linux Kernel which is able to access the GPU of the Windows host machine and use it as shared instance together with the Windows host machine. The [k8s device plugin](https://github.com/NVIDIA/k8s-device-plugin) from Nvidia is responsible for deploying GPU workloads.

## Getting started

### Prerequisites
In order to configure the GPU node you need to install the latest Nvidia drivers for the GPU on the Windows host machine first: https://www.nvidia.com/Download/index.aspx

**NOTE:** A reboot may be necessary.

The gpu-node addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable gpu-node
```

## Deploy a sample CUDA workload

The following example shows how to schedule a sample CUDA workload on the GPU node:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: vectorAdd
spec:
  restartPolicy: OnFailure
  containers:
  - name: vectorAdd
    image: k8s.gcr.io/cuda-vector-add:v0.1
    resources:
      limits:
        nvidia.com/gpu: 1
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

### Commands

```console
k2s addons backup gpu-node
k2s addons restore gpu-node -f C:\Temp\Addons\gpu-node_backup_YYYYMMDD_HHMMSS.zip
```

## Further Reading
- [WSL2 Linux Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
