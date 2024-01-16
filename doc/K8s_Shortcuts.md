<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Cluster shortcuts

[ Home ](../README.md)

This page describes the shortcuts to interact with K2s cluster.

| Shortcut | Command                                                                | Description                                     |
| -------- | ---------------------------------------------------------------------- | ----------------------------------------------- |
| c        | crictl                                                                 | Client for CRI                                  |
| d        | docker                                                                 | A self-sufficient runtime for containers        |
| k        | kubectl                                                                | kubectl controls the Kubernetes cluster manager |
| ka       | kubectl apply                                                          | Apply something to cluster                      |
| kaf      | kubectl apply -f                                                       | Apply specified yaml manifest                   |
| kcp      | kubectl delete pod --field-selector=status.phase==Succeeded,Evicted -A | Cleanup of all succeeded pods                   |
| kd       | kubectl describe                                                       | Describe kubernetes resource                    |
| kdp      | kubectl describe pod                                                   | Describe pod                                    |
| kdpn     | kubectl describe pod -n                                                | Describe all pods in specified namespace        |
| kg       | kubectl get                                                            | Get kubernetes resource                         |
| kgn      | kubectl get nodes -o wide                                              | Get nodes of cluster                            |
| kgp      | kubectl get pods -o wide -A                                            | Get pods of all namespaces in cluster           |
| kl       | kubectl logs                                                           | Show logs of kubernetes resource                |
| krp      | kubectl delete pod                                                     | Remove specified pod                            |