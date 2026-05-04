<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Customizing Kubelet Configuration

By default, *K2s* installs kubelet with standard Kubernetes defaults on both the Linux control-plane node and the Windows worker node. This page describes how to customize kubelet settings using the **kubelet configuration drop-in directory**, a feature that became generally available in Kubernetes 1.30.

## Overview

Kubelet reads its configuration from a base file (`config.yaml`, managed by kubeadm) and then merges any partial override files found in a **drop-in directory**:

| Node | Base config | Drop-in directory |
|------|------------|-------------------|
| Linux control-plane | `/var/lib/kubelet/config.yaml` | `/etc/kubernetes/kubelet.conf.d/` |
| Windows worker | `C:\var\lib\kubelet\config.yaml` | `C:\etc\kubernetes\kubelet.conf.d\` |

Drop-in files are read in **alphabetical order**. Each file is a partial `KubeletConfiguration` — only include the fields you want to override. Later files override earlier ones, and all override the base config.

!!! note
    This approach requires **no changes to K2s itself**. You are working directly with the standard Kubernetes kubelet configuration mechanism.

## Customizing the Linux Control-Plane Node

### 1. Create an override file

Create a YAML file containing only the `KubeletConfiguration` fields you want to change. For example, to reserve resources for the system and set eviction thresholds:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 200
systemReserved:
  cpu: "500m"
  memory: "1Gi"
kubeReserved:
  cpu: "250m"
  memory: "512Mi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
```

Save this file locally, e.g. as `C:\temp\20-custom.conf`.

### 2. Copy the file to the Linux node

```console
k2s node copy -i 172.19.1.100 -u remote -s C:\temp\20-custom.conf -t /tmp/20-custom.conf
```

### 3. Place it in the drop-in directory

```console
k2s node exec -i 172.19.1.100 -u remote -c "sudo mkdir -p /etc/kubernetes/kubelet.conf.d && sudo cp /tmp/20-custom.conf /etc/kubernetes/kubelet.conf.d/20-custom.conf"
```

### 4. Restart kubelet

```console
k2s node exec -i 172.19.1.100 -u remote -c "sudo systemctl restart kubelet"
```

### 5. Verify

```console
k2s node exec -i 172.19.1.100 -u remote -c "cat /var/lib/kubelet/config.yaml" -r
```

Check that the node reflects the new settings:

```console
kubectl describe node kubemaster
```

Look for `Allocatable` and `Capacity` in the output.

## Customizing the Windows Worker Node

### 1. Create the drop-in directory and override file

Open an **elevated PowerShell** prompt on the Windows host:

```powershell
New-Item -ItemType Directory -Force -Path "C:\etc\kubernetes\kubelet.conf.d"

@"
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
maxPods: 100
systemReserved:
  cpu: "500m"
  memory: "1Gi"
"@ | Set-Content -Path "C:\etc\kubernetes\kubelet.conf.d\20-custom.conf" -Encoding UTF8
```

### 2. Restart the cluster

```console
k2s stop
k2s start
```

Alternatively, restart only the kubelet service:

```powershell
nssm restart kubelet
```

### 3. Verify

```console
kubectl describe node %COMPUTERNAME%
```

Check kubelet logs for any configuration errors:

```powershell
Get-Content "C:\var\log\kubelet\kubelet_stderr.log" -Tail 50
```

## Common Kubelet Settings

The table below lists commonly customized `KubeletConfiguration` fields. For the full reference, see the [Kubernetes KubeletConfiguration API](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/).

| Field | Description | Default |
|-------|-------------|---------|
| `maxPods` | Maximum number of pods per node | `110` |
| `systemReserved` | Resources reserved for OS processes | *(none)* |
| `kubeReserved` | Resources reserved for Kubernetes system daemons | *(none)* |
| `evictionHard` | Hard eviction thresholds (pods evicted immediately) | `memory.available: "100Mi"`, `nodefs.available: "10%"` |
| `evictionSoft` | Soft eviction thresholds (grace period before eviction) | *(none)* |
| `evictionSoftGracePeriod` | How long soft thresholds must be exceeded | *(none)* |
| `containerLogMaxSize` | Maximum size of a container log file before rotation | `"10Mi"` |
| `containerLogMaxFiles` | Maximum number of rotated container log files | `5` |
| `imageGCHighThresholdPercent` | Disk usage percentage that triggers image garbage collection | `85` |
| `imageGCLowThresholdPercent` | Disk usage percentage at which image GC stops | `80` |
| `clusterDNS` | DNS server IP addresses for pods | *(set by kubeadm)* |
| `cpuManagerPolicy` | CPU management policy (`none` or `static`) | `"none"` |
| `topologyManagerPolicy` | NUMA topology management policy | `"none"` |

## Example: Resource Reservation

A practical example that prevents kubelet from advertising all system resources as available capacity:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
systemReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "1Gi"
kubeReserved:
  cpu: "250m"
  memory: "512Mi"
evictionHard:
  memory.available: "200Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
```

With these settings, the Kubernetes scheduler sees reduced `Allocatable` resources, preventing workloads from consuming all node capacity.

## Important Notes

!!! warning "Persistence"
    Drop-in files **persist** across `k2s stop` / `k2s start` cycles — kubelet re-reads them on every startup. However, they are **lost on `k2s install`** (reinstall). Keep a backup of your override files externally.

!!! info "Windows `enforceNodeAllocatable`"
    *K2s* passes `--enforce-node-allocatable=""` as a CLI flag to the Windows kubelet. CLI flags take precedence over config file values for this specific setting. To change this behavior, modify `StartKubelet.ps1` in `<k2s-install-dir>\smallsetup\common\`.

!!! info "Validation"
    Kubelet validates the merged configuration on startup. If an override file contains invalid field names or values, kubelet will fail to start. Always check kubelet logs after applying changes.

!!! info "Windows field support"
    Not all `KubeletConfiguration` fields are supported on Windows. Unsupported fields may be silently ignored or cause startup errors. Consult the [Kubernetes Windows documentation](https://kubernetes.io/docs/concepts/windows/) for details.
