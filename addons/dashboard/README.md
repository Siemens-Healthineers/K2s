<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# dashboard

## Introduction

The `dashboard` addon provides **Headlamp** — a lightweight, extensible Kubernetes web UI developed under the `kubernetes-sigs` organization (CNCF sandbox project). It allows users to browse and manage cluster resources, inspect workloads, view logs, and troubleshoot containerized applications.

## Components used

- [Headlamp](https://github.com/kubernetes-sigs/headlamp) — the Kubernetes web UI, deployed via its official Helm chart into the `dashboard` namespace.
- Optional Headlamp ecosystem plugins (Flux, cert-manager) injected automatically based on detected cluster capabilities — see [Headlamp Plugin Integration](#headlamp-plugin-integration).

## Getting started

The Headlamp dashboard can be enabled using the k2s CLI:

```console
k2s addons enable dashboard
```

### Integration with metrics addon

By enabling the metrics addon, Headlamp can display resource usage metrics (CPU/memory) for pods and nodes.

```console
k2s addons enable metrics
k2s addons enable dashboard
```

Or enable both together:

```console
k2s addons enable dashboard --enable-metrics
```

### Integration with ingress addons

The dashboard addon can be integrated with the ingress nginx, ingress traefik, or ingress nginx-gw addon to expose Headlamp outside the cluster.

```console
k2s addons enable dashboard --ingress traefik
```

```console
k2s addons enable dashboard --ingress nginx
```

```console
k2s addons enable dashboard --ingress nginx-gw
```

_Note:_ The above commands will enable the respective ingress addon if it is not already enabled.

## Accessing the dashboard

### Access using ingress

Once an ingress addon is enabled, the Headlamp UI is accessible at:

```
https://k2s.cluster.local/dashboard/
```

_Note:_ If a proxy server is configured in Windows Proxy settings, add `k2s.cluster.local` as a proxy override.

### Access using port-forwarding

```console
kubectl port-forward svc/headlamp -n dashboard 4466:4466
```

The Headlamp UI will be accessible at: <http://localhost:4466/dashboard/>

_Note:_ Any available local port can be substituted for `4466`.

### Authentication

When you open Headlamp for the first time, a **token login screen is displayed — this is expected and normal**. Headlamp requires a bearer token for cluster access.

To generate a ServiceAccount token and log in:

```console
kubectl -n dashboard create token headlamp --duration 24h
```

Copy the printed token and paste it into the Headlamp login screen, then click **Authenticate**.

> **Tip:** The `headlamp` ServiceAccount has `cluster-admin` rights, so it can see all cluster resources.

## Disable dashboard

```console
k2s addons disable dashboard
```

_Note:_ Only the dashboard addon is disabled. Other addons enabled alongside it (e.g. ingress) are not disabled.

## Backup and restore

The dashboard addon supports backup and restore via the `k2s` CLI.

Backup stores restore-relevant metadata:
- Selected ingress integration (`none`/`nginx`/`traefik`/`nginx-gw`)
- Whether the `metrics` addon was enabled

```console
k2s addons backup dashboard
k2s addons restore dashboard -f C:\Temp\k2s\Addons\dashboard_backup_YYYYMMDD_HHMMSS.zip
```

## Headlamp Plugin Integration

The dashboard addon automatically enables Headlamp UI plugins when the matching capability is detected in your cluster. No manual configuration is required.

| Plugin | What it adds to Headlamp | Enabled automatically when |
|---|---|---|
| Flux | GitOps sync status, sources, failures | Flux CD is present in the cluster |
| Cert Manager | Certificate list, expiry, TLS health | cert-manager is present in the cluster |

Plugins are pre-built upstream images consumed directly from GHCR; K2s neither builds nor republishes them.

### How activation works

Plugin activation follows the **actual state of the cluster**, not which addon installed a capability. For example, cert-manager can be provided by any of the ingress addons or by the security addon — the Cert Manager plugin appears whenever cert-manager is present and disappears once it is gone.

Activation stays in sync automatically as you enable or disable related addons (for example `k2s addons enable rollout`, `k2s addons enable security`, or any of the `ingress` addons). Re-running these operations is always safe.

### Offline & air-gapped behavior

Both plugin images are part of the offline package, so plugin activation works without internet access:

- They are pulled and embedded when you create an offline package (`k2s system package`).
- They are loaded into the local image store on import.
- At runtime the dashboard references the already-present images — no registry access occurs.

> **Developers:** the plugin registry, capability detectors, and their unit tests live in the addon source under `addons/dashboard/`.

## Further Reading

- Headlamp Documentation: <https://headlamp.dev/docs/latest/>
- Headlamp GitHub: <https://github.com/kubernetes-sigs/headlamp>
