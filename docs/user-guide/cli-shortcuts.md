<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# CLI Shortcuts
To interact with the *K2s* cluster, the following shortcuts can be used:

| Shortcut | Command                                                                  | Description                                         |
| -------- | ------------------------------------------------------------------------ | --------------------------------------------------- |
| `c`      | `crictl`                                                                 | Client for CRI                                      |
| `d`      | `docker`                                                                 | A self-sufficient runtime for containers            |
| `k`      | `kubectl`                                                                | *kubectl* controls the *Kubernetes* cluster manager |
| `ka`     | `kubectl apply`                                                          | Apply something to cluster                          |
| `kaf`    | `kubectl apply -f`                                                       | Apply specified YAML manifest                       |
| `kcp`    | `kubectl delete pod --field-selector=status.phase==Succeeded,Evicted -A` | Cleanup of all succeeded *Pods*                     |
| `kd`     | `kubectl describe`                                                       | Describe *Kubernetes* resource                      |
| `kdp`    | `kubectl describe pod`                                                   | Describe *Pod*                                      |
| `kdpn`   | `kubectl describe pod -n`                                                | Describe all *Pods* inside the specified namespace  |
| `kg`     | `kubectl get`                                                            | Get *Kubernetes* resource                           |
| `kgn`    | `kubectl get nodes -o wide`                                              | Get all cluster nodes                               |
| `kgp`    | `kubectl get pods -o wide -A`                                            | Get all *Pods* of all namespaces                    |
| `kl`     | `kubectl logs`                                                           | Show logs of *Kubernetes* resource                  |
| `krp`    | `kubectl delete pod`                                                     | Remove specified *Pod*                              |
| `ks`     | `k2s status -o wide`                                                     | Inspect *K2s* system health                         |

## Krew support

*K2s* bundles [Krew](https://krew.sigs.k8s.io/){target="_blank"}, the official *kubectl* plugin
manager, together with *kubectl*. Krew is included in the offline package, so no additional download
is required — after installing *K2s* you can immediately run:

```powershell
kubectl krew version
```

!!! note
    Installing plugins (for example `kubectl krew install ctx`) fetches the plugin index and packages
    from the internet and is therefore an online, user-initiated action. It is never performed during
    *K2s* installation, preserving *K2s*'s offline guarantees.

Krew installs plugins into the per-user directory `%USERPROFILE%\.krew\bin`. For the user who installed
*K2s*, this directory is added to `PATH` automatically, so installed plugins are discoverable right away.
Any additional Windows user follows Krew's standard [one-time PATH setup](https://krew.sigs.k8s.io/docs/user-guide/setup/install/){target="_blank"}
to expose their own plugins.
