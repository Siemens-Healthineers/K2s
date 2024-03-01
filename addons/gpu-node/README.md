<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# gpu-node

## Introduction
The `gpu-node` addon provides the possibility to configure the KubeMaster Linux VM as GPU node in order to run GPU workloads. When enabling this addon the KubeMaster Linux VM is configured to use the WSL2 Linux Kernel which is able to access the GPU of the Windows host machine and use it as shared instance together with the Windows host machine. The [k8s device plugin](https://github.com/NVIDIA/k8s-device-plugin) from Nvidia is responsible for deploying GPU workloads.

## Getting started

### Prerequisites
In order to configure the GPU node you need to install the Nvidia drivers for the GPU on the Windows host machine first: https://www.nvidia.com/Download/index.aspx

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

## Further Reading
- [WSL2 Linux Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
