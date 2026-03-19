<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Assignment of Cluster IP Addresses for Services

*K2s* includes a **mutating admission webhook** that automatically assigns Cluster IPs to Services based on their target OS. You no longer need to specify `clusterIP` manually in your Service manifests.

- **Linux** services receive IPs from `172.21.0.50–254` (subnet `172.21.0.0/24`)
- **Windows** services receive IPs from `172.21.1.50–254` (subnet `172.21.1.0/24`)
- IPs up to `.49` in each subnet are reserved for *K2s* infrastructure.

## *Linux*-based workloads
Linux is the default. Simply create a Service without any special label — the webhook assigns a `172.21.0.x` Cluster IP automatically.

!!! example
    ```yaml linenums="1" title="example-service-manifest.yaml"
    apiVersion: v1
    kind: Service
    metadata:
      name: linux-example
    spec:
      selector:
        app: linux-example
      ports:
        - protocol: TCP
          port: 80
          targetPort: 80
    ```

## *Windows*-based workloads
No special label is needed. The webhook automatically detects that the Service targets a Windows workload by inspecting the `nodeSelector` of matching Deployments, StatefulSets, or DaemonSets. If the workload has `kubernetes.io/os: windows` in its `nodeSelector`, the Service receives a `172.21.1.x` Cluster IP.

!!! example
    ```yaml linenums="1" title="example-service-manifest.yaml"
    apiVersion: v1
    kind: Service
    metadata:
      name: windows-example
    spec:
      selector:
        app: windows-example
      ports:
        - protocol: TCP
          port: 80
          targetPort: 80
    ```

## How it works

The `clusterip-webhook` runs as a Deployment in the `k2s-webhook` namespace. On every `Service` CREATE request, it:

1. Checks if the Service already has an explicit `clusterIP` (or is headless / ExternalName) — if so, it does nothing.
2. Looks up Deployments, StatefulSets, and DaemonSets in the same namespace whose pod template labels match the Service selector. If the workload has `kubernetes.io/os: windows` in its `nodeSelector`, the Windows subnet is used.
3. If no matching workload is found, checks running Pods and their Node's `kubernetes.io/os` label as a fallback.
4. Defaults to the Linux subnet if no OS can be determined.
5. Lists existing Services to find which IPs are already in use.
6. Picks the first free IP in the target subnet range (`.50` – `.254`).
7. Returns a JSON Patch that sets `spec.clusterIP` on the Service.

TLS certificates for the webhook are generated automatically via init Jobs during cluster setup.

!!! note
    You can still set `clusterIP` manually if needed (e.g., for infrastructure services in the reserved `.0–.49` range). The webhook will skip any Service that already has `clusterIP` set.