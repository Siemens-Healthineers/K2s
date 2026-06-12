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
| `ghcr.io/headlamp-k8s/headlamp-plugin-flux:v0.6.0` | GitOps sync status, sources, failures | `flux-system` namespace **or** Flux kustomization CRD detected |
| `ghcr.io/headlamp-k8s/headlamp-plugin-cert-manager:v0.1.0` | Certificate list, expiry, TLS health | `cert-manager` namespace **or** `certificates.cert-manager.io` CRD detected |

Plugin images are **pre-built upstream images consumed directly from GHCR** (`ghcr.io/headlamp-k8s/...`). K2s does **not** build, repackage, or publish plugin images — there is no OCI build pipeline, no lock file, and no tar.gz bundle processing. Each image ships its compiled plugin bundle under `/plugins/<name>/`; an init-container copies that bundle into a shared `emptyDir` volume mounted by the Headlamp container.

### Plugin Lifecycle

**Flux plugin**

- **Activate**: When Flux CD becomes present in the cluster (the `flux-system` namespace or the `kustomizations.kustomize.toolkit.fluxcd.io` CRD is detected), the next `Sync-HeadlampPlugins` adds the `flux-plugin` init-container to the Headlamp deployment.
- **Deactivate**: When Flux is removed, the next sync removes the `flux-plugin` init-container.
- **Typical triggers**: `k2s addons enable/disable rollout` (fluxcd implementation), or any external install/removal of Flux followed by a `dashboard` enable/update.

**Cert Manager plugin**

- **Activate**: When cert-manager becomes present (the `cert-manager` namespace or the `certificates.cert-manager.io` CRD is detected), the next sync adds the `cert-manager-plugin` init-container.
- **Deactivate**: When cert-manager is no longer present in the cluster, the next sync removes the `cert-manager-plugin` init-container.
- **Typical triggers**: `k2s addons enable/disable` for `ingress/nginx`, `ingress/traefik`, `ingress/nginx-gw`, or `security` — any addon that installs or removes cert-manager.

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
| `rollout/fluxcd enable/disable` | Flux plugin added/removed |
| `ingress/nginx enable/disable` | cert-manager plugin synced |
| `ingress/traefik enable/disable` | cert-manager plugin synced |
| `ingress/nginx-gw enable/disable` | cert-manager plugin synced |
| `security enable/disable` | cert-manager plugin synced |

All sync operations are **idempotent** — calling `Sync-HeadlampPlugins` multiple times is always safe.

### Offline Compliance & Air-Gapped Behavior

Both plugin images are declared under `additionalImages` in `addon.manifest.yaml`:

```yaml
additionalImages:
  - ghcr.io/headlamp-k8s/headlamp-plugin-flux:v0.6.0
  - ghcr.io/headlamp-k8s/headlamp-plugin-cert-manager:v0.1.0
```

- **Discovery**: The offline packaging pipeline reads `additionalImages` (together with `additionalImagesFiles`) to discover every image the addon needs.
- **Export**: During `k2s system package` / export, the discovered GHCR images are pulled once and embedded in the offline bundle.
- **Import**: During import on the target host, these images are loaded into the local container registry/containerd image store.
- **Air-gapped runtime**: At enable/sync time the plugin init-containers reference the already-present images — **no network access to GHCR (or any registry) occurs at runtime**. Plugin activation works identically on air-gapped hosts.

> When bumping a plugin version, update the tag in **both** `addon.manifest.yaml` (`additionalImages`) and `Get-RegisteredHeadlampPlugins` in `dashboard.module.psm1` so the packaged image and the injected init-container stay in sync.

### Public API (for addon developers)

| Function | Description |
|---|---|
| `Sync-HeadlampPlugins` | Idempotent sync; call at the end of any `Enable.ps1` / `Disable.ps1` that can affect a capability |
| `Remove-HeadlampPluginPatch` | Removes all K2s plugin init-containers; called on `dashboard disable` only |
| `Test-FluxCapabilityAvailable` | Returns `$true` when Flux is present in the cluster |
| `Test-CertManagerCapabilityAvailable` | Returns `$true` when cert-manager is present in the cluster |

### Adding a New Plugin

1. Identify a pre-built upstream Headlamp plugin image on GHCR (compiled plugin files at `/plugins/<name>/`). K2s consumes the image as-is — do not build or republish it.
2. Add the image to `additionalImages` in `addon.manifest.yaml`.
3. Add a capability detector function `Test-<Name>CapabilityAvailable` to `dashboard.module.psm1`.
4. Register the plugin in `Get-RegisteredHeadlampPlugins` with its GHCR image and a `Detector` scriptblock.
5. Add `Sync-HeadlampPlugins` call to the addon's `Enable.ps1` and `Disable.ps1`.
6. Export the new capability function in `Export-ModuleMember`.
7. Add unit tests for the detector and the sync scenario.

## Testing Checklist

Use this checklist to validate the dashboard addon and its Headlamp plugin framework.

### Runtime validation

- [ ] **Dashboard enable** — `k2s addons enable dashboard`; Headlamp deployment becomes `Ready`.
- [ ] **Dashboard disable** — `k2s addons disable dashboard`; namespace `dashboard` and the `headlamp-admin` ClusterRoleBinding are removed.
- [ ] **Flux enable** — install Flux (e.g. `k2s addons enable rollout`); after sync, the `flux-plugin` init-container is present in the Headlamp deployment.
- [ ] **Flux disable** — remove Flux; after sync, the `flux-plugin` init-container is removed.
- [ ] **Cert Manager enable** — install cert-manager (e.g. via `ingress/nginx`, `ingress/traefik`, `ingress/nginx-gw`, or `security`); after sync, the `cert-manager-plugin` init-container is present.
- [ ] **Cert Manager disable** — remove cert-manager; after sync, the `cert-manager-plugin` init-container is removed.
- [ ] **Plugin add/remove reconciliation** — toggling a capability on/off repeatedly converges to the correct init-container set (idempotent; no duplicates, no leftovers).
- [ ] **Dashboard upgrade/update** — `dashboard update` re-syncs plugins to current cluster state; an image-tag bump in the registry triggers an in-place init-container update.

### Offline validation

- [ ] **additionalImages discovery** — packaging discovers both `ghcr.io/headlamp-k8s/headlamp-plugin-flux:v0.6.0` and `ghcr.io/headlamp-k8s/headlamp-plugin-cert-manager:v0.1.0`.
- [ ] **Export package** — `k2s system package` embeds both plugin images in the offline bundle.
- [ ] **Import package** — importing the bundle loads both plugin images into the target host's image store.
- [ ] **Air-gapped installation** — on a host with no internet access, `dashboard` enable and plugin sync succeed with no registry pulls.
- [ ] **Plugin activation after import** — with Flux and/or cert-manager present, the corresponding plugin init-containers activate using only the imported images.

### Regression validation

- [ ] **Existing dashboard functionality** — UI access via ingress and via port-forward both work; token login succeeds.
- [ ] **Headlamp startup** — the Headlamp pod starts cleanly with and without plugin init-containers.
- [ ] **No stale init containers** — no `prometheus-plugin` (removed) or other unexpected init-containers remain; only detected-capability plugins are present.
- [ ] **Sync-HeadlampPlugins behavior** — idempotent across repeated calls; skips silently when the dashboard addon is not enabled; never touches non-K2s init-containers.
- [ ] **Unit test execution** — `Invoke-Pester` on `dashboard.module.unit.tests.ps1` passes (tags `addon`, `dashboard`, `plugin`).

## Further Reading

- Headlamp Documentation: <https://headlamp.dev/docs/latest/>
- Headlamp GitHub: <https://github.com/kubernetes-sigs/headlamp>
