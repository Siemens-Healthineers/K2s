<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Rollout — Flux CD Implementation

## Introduction

Flux CD is a GitOps operator that continuously reconciles cluster state with sources of truth — Git repositories, Helm repositories, or OCI registries. Unlike ArgoCD, Flux has **no web UI** and is managed entirely via `kubectl` and YAML custom resources.

## Enable Flux

```console
k2s addons enable rollout fluxcd
```

### Optional: Enable ingress (for Git webhook notifications)

```console
k2s addons enable rollout fluxcd --ingress nginx
```

Most users don't need this — Flux polls its sources by default.

### Skip addon-sync infrastructure

By default, enabling Flux also deploys the **addon-sync** infrastructure that lets you deliver K2s addons from an OCI registry. To skip it:

```console
k2s addons enable rollout fluxcd --addon-sync=false
```

## Check Status

```console
k2s addons status rollout fluxcd
```

---

## Deploy Applications with Flux

### Git-based deployment

Create a `GitRepository` and a `Kustomization` pointing to your manifests:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: myapp
  namespace: rollout
spec:
  interval: 1m
  url: https://github.com/myorg/myapp
  ref:
    branch: main
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp
  namespace: rollout
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: myapp
  path: ./deploy
  prune: true
  targetNamespace: default
```

```console
kubectl apply -f gitrepository.yaml -f kustomization.yaml
```

### Helm chart deployment

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: bitnami
  namespace: rollout
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
---
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: nginx
  namespace: default
spec:
  interval: 5m
  chart:
    spec:
      chart: nginx
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: rollout
  values:
    replicaCount: 2
```

---

## GitOps Addon Delivery (Addon-Sync)

Addon-sync lets you deliver K2s addons (their definition files — manifests, scripts, Helm charts, config) from an OCI registry to the Windows host filesystem without copying files manually. After sync, the addon appears in `k2s addons ls` and can be enabled normally.

> **Sync vs. enable:** Addon-sync only copies the addon definition files to the local catalog. It does **not** start any Kubernetes workloads. You must explicitly run `k2s addons enable <addon>` after sync completes.

### How FluxCD addon-sync works

Each addon in the registry has its own per-addon `OCIRepository` resource that Flux polls every minute. When Flux detects a new highest semver tag in `addons/<name>`, it extracts the embedded `gitops-sync/` Job template from the OCI artifact and applies it. The resulting Windows HostProcess Job runs `Sync-Addons.ps1`, which pulls the full artifact and writes layers 0–3 (config, manifests, charts, scripts) to the K2s addons directory on the Windows host.

```
Consumer pushes versioned OCI artifact
  e.g. oras copy ... k2s.registry.local:30500/addons/monitoring:v1.2.3

  ↓  per-addon OCIRepository polls addons/monitoring every 1 minute
  ↓  Flux selects highest semver tag (ref.semver ">=0.0.0-0")
  ↓  Flux extracts manifests layer → applies gitops-sync/sync-job.yaml
  ↓  HostProcess Job runs Sync-Addons.ps1 -AddonName monitoring
  ↓  Layers 0-3 written to K2s addons directory on Windows host

k2s addons ls  →  monitoring appears
k2s addons enable monitoring  →  workloads start
```

> **Each addon has its own OCIRepository.** Pushing a new version of `monitoring` only triggers reconciliation for `monitoring`, not for all addons at once.

### Setup summary (what you need to do)

| Step | When | Command / Action |
|------|------|-----------------|
| 1. Enable rollout fluxcd | **Once per cluster** | `k2s addons enable rollout fluxcd` |
| 2. Enable registry | **Once per cluster** | `k2s addons enable registry` |
| 3. Register each addon for FluxCD sync | **Once per addon** | Apply per-addon templates (see below) |
| 4. Export addon as OCI artifact | **Each release** | `k2s addons export <name> -d C:\exports --omit-images --omit-packages` |
| 5. Push versioned tag to registry | **Each release** | `oras copy --from-oci-layout ...` |
| 6. Flux auto-detects and syncs | **Automatic** | Next poll cycle (≤1 minute) |
| 7. Enable the addon | **Each new addon** (or after update) | `k2s addons enable <name>` |

Steps 1–3 are one-time setup. Steps 4–6 are your repeating release workflow. Step 7 is only manual for new addons — re-enabling is only needed if you update an already-enabled addon.

---

### Step 1 — One-time cluster setup

Run once when setting up a new K2s cluster:

```console
k2s addons enable registry
k2s addons enable rollout fluxcd
```

`Enable.ps1` automatically deploys the addon-sync infrastructure into the `k2s-addon-sync` namespace:

| Resource | Kind | Purpose |
|----------|------|---------|
| `k2s-addon-sync` | `Namespace` | Isolates addon-sync workloads from application namespaces |
| `addon-sync-processor` | `ServiceAccount` | Identity for HostProcess Jobs (no K8s API RBAC needed — accesses host filesystem directly) |
| `addon-sync-config` | `ConfigMap` | Registry base URL, K2s install directory, insecure flag |
| `addon-sync-script` | `ConfigMap` | `Sync-Addons.ps1` script (generated from file, mounted into every sync Job) |

Verify the infrastructure is ready:

```console
kubectl get all -n k2s-addon-sync
```

---

### Step 2 — One-time per-addon: register for FluxCD sync

For each addon you want to deliver via GitOps, you must create two resources in `k2s-addon-sync`:

- `OCIRepository addon-sync-<name>` — polls `addons/<name>` for new highest semver tags
- `Kustomization addon-sync-<name>` — applies the `gitops-sync/` Job from the extracted manifests layer

Template files are in:

```
<K2S_INSTALL_DIR>\addons\common\manifests\addon-sync\fluxcd\per-addon\
  ocirepository-template.yaml
  kustomization-template.yaml
```

Use this script to fill placeholders and apply in one step:

```powershell
$k2sInstallDir = (kubectl get configmap addon-sync-config -n k2s-addon-sync -o jsonpath='{.data.K2S_INSTALL_DIR}').Trim()
$addonName     = 'monitoring'                        # <-- change to your addon folder name
$registryHost  = 'k2s.registry.local:30500'          # <-- change to your registry host:port
$insecure      = 'true'                              # <-- set to 'false' for TLS registries

$templateDir = Join-Path $k2sInstallDir 'addons\common\manifests\addon-sync\fluxcd\per-addon'
$tmpDir      = Join-Path $env:TEMP "addon-sync-register-$addonName"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

foreach ($template in @('ocirepository-template.yaml', 'kustomization-template.yaml')) {
    $content = Get-Content (Join-Path $templateDir $template) -Raw
    $content = $content -replace 'ADDON_NAME_PLACEHOLDER',    $addonName
    $content = $content -replace 'REGISTRY_HOST_PLACEHOLDER', $registryHost
    $content = $content -replace 'INSECURE_PLACEHOLDER',      $insecure
    Set-Content -Path (Join-Path $tmpDir $template) -Value $content -Encoding UTF8
}

kubectl apply -f $tmpDir
Remove-Item $tmpDir -Recurse -Force
```

Verify the resources are ready:

```console
kubectl get ocirepository addon-sync-monitoring -n k2s-addon-sync
kubectl get kustomization addon-sync-monitoring -n k2s-addon-sync
```

`READY` should be `True`. If the registry `addons/monitoring` repository does not exist yet, Flux will show `not found` — that is normal until you push the first artifact in the next step.

> **Register once, push many times.** These resources stay in the cluster permanently. All future pushes of new versioned tags to `addons/<name>` are detected automatically — you do not re-apply these templates.

#### Registering multiple addons

Repeat the registration script for each addon name. Each addon gets independent `OCIRepository` and `Kustomization` resources:

```powershell
foreach ($addon in @('monitoring', 'security', 'registry')) {
    $addonName = $addon
    $templateDir = Join-Path $k2sInstallDir 'addons\common\manifests\addon-sync\fluxcd\per-addon'
    $tmpDir = Join-Path $env:TEMP "addon-sync-register-$addonName"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    foreach ($template in @('ocirepository-template.yaml', 'kustomization-template.yaml')) {
        $content = Get-Content (Join-Path $templateDir $template) -Raw
        $content = $content -replace 'ADDON_NAME_PLACEHOLDER',    $addonName
        $content = $content -replace 'REGISTRY_HOST_PLACEHOLDER', $registryHost
        $content = $content -replace 'INSECURE_PLACEHOLDER',      $insecure
        Set-Content -Path (Join-Path $tmpDir $template) -Value $content -Encoding UTF8
    }

    kubectl apply -f $tmpDir
    Remove-Item $tmpDir -Recurse -Force
    Write-Host "Registered $addonName for FluxCD addon-sync"
}
```

Check all registered addons:

```console
kubectl get ocirepository,kustomization -n k2s-addon-sync
```

---

### Step 3 — Recurring: export and push an addon

Every time you want to publish a new or updated addon version:

#### 3a. Export the addon

```console
k2s addons export monitoring -d C:\exports --omit-images --omit-packages
```

`--omit-images` and `--omit-packages` skip container image and OS package layers (4-6). In GitOps mode, images are pulled directly from the registry at `k2s addons enable` time.

This produces a file like `K2s-<version>-addons-monitoring.oci.tar` — an OCI Image Layout archive.

#### 3b. Discover the version tag

```powershell
$tar = (Get-ChildItem C:\exports -Filter *monitoring*.oci.tar)[0].FullName

$tempDir = Join-Path $env:TEMP 'oci-inspect'
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
tar -xf $tar -C $tempDir oci-layout index.json
$tag = (Get-Content "$tempDir\index.json" | ConvertFrom-Json).manifests[0].annotations.'org.opencontainers.image.ref.name'
Remove-Item $tempDir -Recurse -Force

Write-Host "Tag: $tag"   # e.g. v1.2.3
```

#### 3c. Push to the registry

```powershell
$k2sInstallDir = 'C:\k'   # or read from addon-sync-config
$orasExe = Join-Path $k2sInstallDir 'bin\oras.exe'

& $orasExe copy --from-oci-layout "${tar}:${tag}" --to-plain-http k2s.registry.local:30500/addons/monitoring:$tag
```

> **Use `oras copy --from-oci-layout`, not `oras push`.** The `--from-oci-layout` flag preserves the full multi-layer OCI artifact structure (layer media types, manifest annotations) that Flux's `layerSelector` and `Sync-Addons.ps1` depend on. `oras push` uploads blobs without structure.

> **One push is enough.** FluxCD's `OCIRepository` uses `ref.semver: ">=0.0.0-0"` to select the highest semver tag. A single versioned push (`v1.2.3`) is sufficient — no `latest` tag is needed.

#### 3d. FluxCD detects and syncs automatically

Within one polling cycle (≤1 minute by default), FluxCD detects the new highest semver tag in `addons/monitoring` and:

1. Extracts the manifests layer from the artifact
2. Applies `gitops-sync/sync-job.yaml` via `Kustomization addon-sync-monitoring`
3. The HostProcess Job runs `Sync-Addons.ps1 -AddonName monitoring`, writing addon layers 0–3 to the K2s addons directory

Monitor the sync:

```console
kubectl get kustomization addon-sync-monitoring -n k2s-addon-sync -w
kubectl logs -n k2s-addon-sync -l app.kubernetes.io/component=processor --tail=50
```

#### 3e. Enable the addon

Once sync completes:

```console
k2s addons ls             # monitoring should appear
k2s addons enable monitoring
```

---

### Multi-addon delivery workflow

You can export and push multiple addons in a single batch, or push them independently. Each registered addon has its own independent reconciliation loop.

#### Push multiple addons independently

```powershell
$registry  = 'k2s.registry.local:30500'
$orasExe   = 'C:\k\bin\oras.exe'
$exportDir = 'C:\exports'

foreach ($addonName in @('monitoring', 'security', 'registry')) {
    # Export
    k2s addons export $addonName -d $exportDir --omit-images --omit-packages

    # Find tar
    $tar = (Get-ChildItem $exportDir -Filter "*${addonName}*.oci.tar")[0].FullName

    # Get tag
    $tmpDir = Join-Path $env:TEMP "oci-$addonName"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    tar -xf $tar -C $tmpDir oci-layout index.json
    $tag = (Get-Content "$tmpDir\index.json" | ConvertFrom-Json).manifests[0].annotations.'org.opencontainers.image.ref.name'
    Remove-Item $tmpDir -Recurse -Force

    # Push
    & $orasExe copy --from-oci-layout "${tar}:${tag}" --to-plain-http "${registry}/addons/${addonName}:${tag}"
    Write-Host "Pushed $addonName $tag"
}
```

Each addon triggers its own independent sync cycle — Flux reconciles `addon-sync-monitoring`, `addon-sync-security`, and `addon-sync-registry` independently based on which registries changed.

---

### Verify sync status

Check all FluxCD addon-sync resources at once:

```console
kubectl get ocirepository,kustomization -n k2s-addon-sync
```

Check a specific addon's sync state:

```console
kubectl get ocirepository addon-sync-monitoring -n k2s-addon-sync -o yaml
kubectl get kustomization addon-sync-monitoring -n k2s-addon-sync -o yaml
```

Look for `status.conditions` with `Ready: True`. The `status.artifact.revision` shows the currently selected digest.

Check sync Job logs:

```console
kubectl logs -n k2s-addon-sync -l app.kubernetes.io/name=addon-sync --tail=100
```

Log prefixes to look for:

| Prefix | Meaning |
|--------|---------|
| `[AddonSync] Extracting layer` | Normal extraction in progress |
| `[AddonSync] Digest changed -- proceeding` | New artifact detected by poller |
| `[AddonSync][ERROR]` | Sync failure with details |

---

### Customization

#### Change the registry URL

```console
kubectl edit configmap addon-sync-config -n k2s-addon-sync
```

| Key | Default | Description |
|-----|---------|-------------|
| `REGISTRY_URL` | `oci://k2s.registry.local:30500` | Registry host (no path/tag) |
| `K2S_INSTALL_DIR` | `C:\k` | K2s installation directory on the Windows host |
| `INSECURE` | `true` | Allow HTTP connections to registry |

#### Change the polling interval for a specific addon

```console
kubectl edit ocirepository addon-sync-monitoring -n k2s-addon-sync
```

Change `spec.interval` (e.g., `30s` for near-real-time, `10m` to reduce load).

#### Registry without catalog API

If your registry disables `GET /v2/_catalog` (e.g., RBAC-restricted Harbor, GHCR), you can either:

- Use per-addon registration as described above (each `OCIRepository` polls a specific `addons/<name>` path — no catalog discovery needed), or
- Set `ADDON_REPOS` in the config as fallback for the ArgoCD poller approach.

Per-addon FluxCD registration is inherently compatible with restricted registries because each `OCIRepository` targets a specific repository path, not the catalog endpoint.

---

## Disable Flux

```console
k2s addons disable rollout fluxcd
```

Removes all Flux controllers, CRDs from the `rollout` namespace, and the `k2s-addon-sync` namespace (including all `OCIRepository` and `Kustomization` resources registered for addon-sync).

---

## Backup and Restore

Backup/restore is scoped to the `rollout` namespace only.

### What gets backed up

- Flux CD custom resources in namespace `rollout` (`GitRepository`, `Kustomization`, `HelmRelease`, notifications, image automation)
- Secrets in namespace `rollout` referenced by Flux resources (`secretRef.name`)
- Optional webhook Ingress resources in namespace `rollout`

### What does not get backed up

- Flux controllers and CRDs (re-installed by `k2s addons enable rollout fluxcd` during restore)
- Resources outside of the `rollout` namespace
- `k2s-addon-sync` namespace resources — re-register per-addon FluxCD resources after restore

### Commands

```console
k2s addons backup rollout fluxcd
k2s addons restore rollout fluxcd <path-to-backup-zip>
```

---

## Further Reading

- [Flux Documentation](https://fluxcd.io/docs/)
- [Flux Guides](https://fluxcd.io/flux/guides/)
- [GitOps Addon Delivery — Full Operational Guide](../../../docs/op-manual/gitops-addon-delivery.md)
