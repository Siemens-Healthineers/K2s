<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
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