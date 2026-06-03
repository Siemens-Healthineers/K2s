<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# dashboard

## Introduction

The `dashboard` addon provides **Headlamp** — a lightweight, extensible Kubernetes web UI developed under the `kubernetes-sigs` organization (CNCF sandbox project). It allows users to browse and manage cluster resources, inspect workloads, view logs, and troubleshoot containerized applications.

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

The dashboard addon includes a **plugin framework** that automatically injects Headlamp ecosystem plugins as Kubernetes init-containers whenever their corresponding capabilities are detected in the cluster.

### Active Plugins

| Plugin | Headlamp Feature | Activated When |
|---|---|---|
| `headlamp-plugin-flux:0.6.0` | GitOps sync status, sources, failures | `flux-system` namespace **or** Flux kustomization CRD detected |
| `headlamp-plugin-cert-manager:0.1.0` | Certificate list, expiry, TLS health | `cert-manager` namespace **or** `certificates.cert-manager.io` CRD detected |
| `headlamp-plugin-prometheus:0.8.2` | CPU/Memory/Network charts | `prometheuses.monitoring.coreos.com` CRD **or** `prometheus-operated` service detected |

### Capability-Based Activation

Plugin activation is driven by **actual cluster state**, not addon ownership.

**Example**: cert-manager is installed by `ingress/nginx`, `ingress/traefik`, `ingress/nginx-gw`, **and** `security`. The cert-manager plugin activates whenever `cert-manager` is present — regardless of which addon (or external tool) installed it.

This means the following order-independent scenarios all converge to the same Headlamp state:

```
ingress/nginx enabled → cert-manager plugin appears in Headlamp
security enabled (nginx already present) → cert-manager plugin already active (no-op)
ingress/nginx disabled (security still present) → cert-manager plugin stays active
security disabled → cert-manager removed → cert-manager plugin removed
```

### Bidirectional Sync

`Sync-HeadlampPlugins` is called from every addon lifecycle script that can affect a registered capability:

| Addon lifecycle event | Plugin effect |
|---|---|
| `dashboard enable` | All available capabilities detected and activated |
| `dashboard update` | Re-syncs to current cluster state |
| `monitoring enable/disable` | Prometheus plugin added/removed |
| `rollout/fluxcd enable/disable` | Flux plugin added/removed |
| `ingress/nginx enable/disable` | cert-manager plugin synced |
| `ingress/traefik enable/disable` | cert-manager plugin synced |
| `ingress/nginx-gw enable/disable` | cert-manager plugin synced |
| `security enable/disable` | cert-manager plugin synced |

All sync operations are **idempotent** — calling `Sync-HeadlampPlugins` multiple times is always safe.

### Offline Compliance

Plugin OCI images are declared under `additionalImages` in `addon.manifest.yaml` so the packaging pipeline caches them in the offline bundle. No network access occurs at runtime.

### Public API (for addon developers)

| Function | Description |
|---|---|
| `Sync-HeadlampPlugins` | Idempotent sync; call at the end of any `Enable.ps1` / `Disable.ps1` that can affect a capability |
| `Remove-HeadlampPluginPatch` | Removes all K2s plugin init-containers; called on `dashboard disable` only |
| `Test-FluxCapabilityAvailable` | Returns `$true` when Flux is present in the cluster |
| `Test-CertManagerCapabilityAvailable` | Returns `$true` when cert-manager is present in the cluster |
| `Test-PrometheusCapabilityAvailable` | Returns `$true` when Prometheus is present in the cluster |

### Adding a New Plugin

1. Build the plugin OCI image containing compiled plugin files at `/plugins/<name>/`.
2. Add the image to `additionalImages` in `addon.manifest.yaml`.
3. Add a capability detector function `Test-<Name>CapabilityAvailable` to `dashboard.module.psm1`.
4. Register the plugin in `Get-RegisteredHeadlampPlugins` with a `Detector` scriptblock.
5. Add `Sync-HeadlampPlugins` call to the addon's `Enable.ps1` and `Disable.ps1`.
6. Export the new capability function in `Export-ModuleMember`.
7. Add unit tests for the detector and the sync scenario.

## Further Reading

- Headlamp Documentation: <https://headlamp.dev/docs/latest/>
- Headlamp GitHub: <https://github.com/kubernetes-sigs/headlamp>
