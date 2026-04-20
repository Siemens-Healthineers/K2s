<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Headlamp Plugin Integration — Design Analysis

Migration to Headlamp is complete. Next step: auto-inject Headlamp ecosystem plugins when their corresponding K2s addons are enabled/disabled.

## Plugins in Scope (stable only)

| Plugin | K2s Addon Trigger | Adds in Headlamp |
|---|---|---|
| `headlamp-plugin-flux` v0.6.0 | `k2s addons enable rollout` (fluxcd) | GitOps sync status, sources, failures |
| `headlamp-plugin-cert-manager` v0.1.0 | `k2s addons enable security` | Certificate list, expiry, TLS health |
| `headlamp-plugin-prometheus` v0.8.2 | `k2s addons enable monitoring` | CPU/Memory/Network charts in pod & deployment pages |

> KEDA (beta) and AI Assistant (alpha) plugins are **deferred** until stable.

## How It Works

Plugin `.tar.gz` files are already present in `addons/dashboard/manifests/chart/`. These get wrapped as offline OCI images (`shsk2s.azurecr.io/headlamp-plugin-*`) during K2s packaging and added to `dashboard/addon.manifest.yaml` under `additionalImages` — same pattern as Linkerd proxy images in `security/addon.manifest.yaml`.

At runtime, a new central function `Sync-HeadlampPlugins` (in `dashboard.module.psm1`) checks which addons are currently enabled and patches the Headlamp deployment with the matching init-containers. Each init-container copies its plugin bundle into the shared plugins volume that Headlamp reads on startup.

## Bidirectional Sync

- **Dashboard enabled after Rollout/Security/Monitoring** → `dashboard/Enable.ps1` calls `Sync-HeadlampPlugins` at the end, picks up already-enabled addons automatically.
- **Rollout/Security/Monitoring enabled after Dashboard** → their `Enable.ps1` calls `Sync-HeadlampPlugins`, plugin appears in Headlamp without any manual step.
- **Any of those addons disabled** → their `Disable.ps1` calls `Sync-HeadlampPlugins`, plugin section is removed from Headlamp.

This follows the exact same patch-on-enable / revert-on-disable contract already used for Linkerd in `dashboard/Update.ps1`.

## Detailed Design

### Step 1 — Offline-compliant Plugin OCI Images

The three plugin `.tar.gz` archives are already present in `addons/dashboard/manifests/chart/`:

```
headlamp-k8s-flux-0.6.0.tar.gz
headlamp-k8s-cert-manager-0.1.0.tar.gz
prometheus-0.8.2.tar.gz
```

Each archive is wrapped into a minimal OCI image with compiled plugin files at `/plugins/<plugin-name>/`.
A single parameterized `Dockerfile` handles all three builds.

The resulting images use the `shsk2s.azurecr.io` prefix — consistent with all other bundled images in K2s:

```
shsk2s.azurecr.io/headlamp-plugin-flux:0.6.0
shsk2s.azurecr.io/headlamp-plugin-cert-manager:0.1.0
shsk2s.azurecr.io/headlamp-plugin-prometheus:0.8.2
```

These images are built **once** during the K2s packaging/install pipeline (not at runtime), satisfying the offline-first requirement.

### Step 2 — `Sync-HeadlampPlugins` in `dashboard.module.psm1`

```powershell
function Sync-HeadlampPlugins {
    # 1. Detect which plugin-related addons are currently enabled
    $fluxEnabled       = Test-IsAddonEnabled -Addon ([pscustomobject]@{Name='rollout'; Implementation='fluxcd'})
    $securityEnabled   = Test-IsAddonEnabled -Addon ([pscustomobject]@{Name='security'})
    $monitoringEnabled = Test-IsAddonEnabled -Addon ([pscustomobject]@{Name='monitoring'})

    # 2. Build initContainers list — one per active plugin
    $initContainers = @()
    if ($fluxEnabled) {
        $initContainers += New-PluginInitContainer -Name 'flux-plugin' `
            -Image 'shsk2s.azurecr.io/headlamp-plugin-flux:0.6.0'
    }
    if ($securityEnabled) {
        $initContainers += New-PluginInitContainer -Name 'cert-manager-plugin' `
            -Image 'shsk2s.azurecr.io/headlamp-plugin-cert-manager:0.1.0'
    }
    if ($monitoringEnabled) {
        $initContainers += New-PluginInitContainer -Name 'prometheus-plugin' `
            -Image 'shsk2s.azurecr.io/headlamp-plugin-prometheus:0.8.2'
    }

    # 3. Patch Headlamp deployment with current init-container set
    Apply-HeadlampPluginPatch -InitContainers $initContainers
}
```

Each init-container copies its `/plugins/<name>/` content into the shared `emptyDir` volume mounted at
`/headlamp/plugins`, which Headlamp reads on startup (configured via `config.pluginsDir` in `values.yaml`).

### Step 3 — Call Sites

`Sync-HeadlampPlugins` is called from:

| File | When |
|---|---|
| `dashboard/Enable.ps1` | After `Install-HeadlampViaHelm` succeeds — picks up any previously enabled addons |
| `dashboard/Update.ps1` | Existing update flow — keeps plugins in sync on re-runs |
| `rollout/fluxcd/Enable.ps1` | After Flux is up — adds Flux plugin if dashboard is enabled |
| `rollout/fluxcd/Disable.ps1` | After Flux teardown — removes Flux plugin if dashboard is enabled |
| `monitoring/Enable.ps1` | After Prometheus stack is up — adds Prometheus plugin if dashboard is enabled |
| `monitoring/Disable.ps1` | After monitoring teardown — removes plugin if dashboard is enabled |
| `security/Enable.ps1` | After cert-manager is up — adds cert-manager plugin if dashboard is enabled |
| `security/Disable.ps1` | After cert-manager teardown — removes plugin if dashboard is enabled |

### Step 4 — `addon.manifest.yaml` Changes (dashboard)

```yaml
offline_usage:
  linux:
    additionalImages:
      - shsk2s.azurecr.io/headlamp-plugin-flux:0.6.0
      - shsk2s.azurecr.io/headlamp-plugin-cert-manager:0.1.0
      - shsk2s.azurecr.io/headlamp-plugin-prometheus:0.8.2
```

> **Why `additionalImages` even in online environments?**
> Without this entry the packaging pipeline does not pull/cache these images.
> Omitting it would break air-gapped deployments silently.

## Linkerd Precedent

The same bidirectional patch pattern already exists for **Linkerd** in `dashboard/Update.ps1`:
- `Test-LinkerdServiceAvailability` → patch deployment with `linkerd.io/inject: enabled`
- Linkerd removed → patch reverted

The Headlamp plugin injection follows the exact same contract, making this a natural extension of what is already shipping.

## Out of Scope (this issue)

- KEDA plugin — wait for GA
- AI Assistant plugin — new `ai-assistant` addon to be designed separately

