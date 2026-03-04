<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Rollout — ArgoCD Implementation

## Introduction

ArgoCD is a declarative GitOps continuous delivery tool with a web UI and CLI. It monitors live cluster state against a desired state defined in Git and reports drift, providing manual or automatic sync. The K2s rollout addon installs ArgoCD into the `rollout` namespace.

## Enable ArgoCD

```console
k2s addons enable rollout
```

Or explicitly:

```console
k2s addons enable rollout argocd
```

### Enable with ingress (to expose the ArgoCD dashboard)

```console
k2s addons enable rollout argocd --ingress traefik
k2s addons enable rollout argocd --ingress nginx-gw
```

If the specified ingress addon is not already enabled, it will be enabled automatically.

### Skip addon-sync infrastructure

By default, enabling ArgoCD also deploys the addon-sync infrastructure for OCI-based addon delivery. To skip it:

```console
k2s addons enable rollout argocd --addon-sync=false
```

## Check Status

```console
k2s addons status rollout argocd
```

---

## Access the ArgoCD Dashboard

### Via ingress

Requires ingress nginx, nginx-gw, or traefik to be enabled alongside rollout.

```
https://k2s.cluster.local/rollout
```

### Via port-forwarding

```console
kubectl -n rollout port-forward svc/argocd-server 8080:443
```

Open `https://localhost:8080/rollout`. Accept the self-signed certificate.

---

## Deploy Applications with ArgoCD

### Via CLI

```console
# 1. Log in
argocd login k2s.cluster.local:443 --grpc-web-root-path "rollout"

# 2. Add your Git repository
argocd repo add https://github.com/myorg/myapp.git

# 3. Create an application
argocd app create myapp \
  --repo https://github.com/myorg/myapp.git \
  --path deploy \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default

# 4. Sync
argocd app sync myapp
```

For private repositories, add credentials: `argocd repo add <url> --username <user> --password <pass>`.

### Via Web UI

1. Visit the dashboard URL (see [Access the ArgoCD Dashboard](#access-the-argocd-dashboard))
2. **Settings → Repositories → Connect Repo** — add your Git repository
3. **Applications → New App** — fill in source (repo, path, revision) and destination (cluster, namespace)
4. Click **Sync** in the application overview to deploy

---

## GitOps Addon Delivery (Addon-Sync)

Addon-sync lets you deliver K2s addons — their definition files (manifests, scripts, Helm charts, config) — from an OCI registry to the Windows host filesystem. After sync, the addon appears in `k2s addons ls` and can be enabled normally.

### Placeholder conventions used below

- `<REGISTRY_HOST>`: OCI registry host (example only: `k2s.registry.local:30500`)
- `<REGISTRY_URL>`: `oci://<REGISTRY_HOST>`
- `<ADDON_NAME>`: addon repository name under `addons/` (for example `monitoring`)
- `<TAG>`: version tag (for example `v1.2.3`)

The built-in local registry addon is optional and mainly useful for development/testing.

> **Sync vs. enable:** Addon-sync only copies the addon definition files (layers 0–3) to the local addon catalog. It does **not** start any Kubernetes workloads. Run `k2s addons enable <addon>` to deploy workloads after sync.

### How ArgoCD addon-sync works

ArgoCD has no native OCI registry watcher for raw artifact layers. Instead, a Windows HostProcess **CronJob** (`addon-sync-poller`) polls the OCI registry directly every 5 minutes, running the same `Sync-Addons.ps1` script used by FluxCD sync Jobs. It discovers all `addons/*` repositories via `oras repo ls`, selects the highest semver tag per repo, and compares the manifest digest against a per-addon digest file on the Windows host filesystem. Only changed addons are synced.

```
Consumer pushes versioned OCI artifact
  e.g. oras copy ... <REGISTRY_HOST>/addons/<ADDON_NAME>:<TAG>

  ↓  addon-sync-poller CronJob runs every 5 minutes (Windows HostProcess)
  ↓  oras repo ls → discovers addons/monitoring, addons/security, ...
  ↓  selects highest semver tag per repo
  ↓  fetches manifest digest from registry
  ↓  compares against K2sInstallDir\addons\.addon-sync-digests\monitoring on host
  ↓  digest unchanged? skip. digest changed? proceed.
  ↓  oras pull → extract layers 0-3 to K2s addons directory

k2s addons ls  →  monitoring appears
k2s addons enable monitoring  →  workloads start
```

> **No per-addon registration needed.** The shared `addon-sync-poller` CronJob discovers all `addons/*` repositories automatically. You only push a new artifact — the poller handles the rest.

### Setup summary (what you need to do)

| Step | When | Command / Action |
|------|------|-----------------|
| 1. Enable rollout argocd | **Once per cluster** | `k2s addons enable rollout argocd` |
| 2. Ensure reachable OCI registry | **Once per cluster** | External registry, or optional local setup: `k2s addons enable registry` |
| 3. Export addon as OCI artifact | **Each release** | `k2s addons export <name> -d C:\exports --omit-images --omit-packages` |
| 4. Push versioned tag to registry | **Each release** | `oras copy --from-oci-layout ...` |
| 5. Poller auto-detects and syncs | **Automatic** | Within next 5-minute poll cycle |
| 6. Enable the addon | **Each new addon** (or after update) | `k2s addons enable <name>` |

Steps 1–2 are one-time. Steps 3–5 are the repeating release workflow. Step 6 is manual for new addons and only needed again when re-enabling an updated addon.

---

### Step 1 — One-time cluster setup

Run once on a new cluster (ensure your chosen OCI registry is reachable from the cluster/host):

```console
k2s addons enable rollout argocd
```

Optional local dev/test setup:

```console
k2s addons enable registry
```

`Enable.ps1` deploys the addon-sync infrastructure into the `k2s-addon-sync` namespace:

| Resource | Kind | Purpose |
|----------|------|---------|
| `k2s-addon-sync` | `Namespace` | Isolates addon-sync workloads |
| `addon-sync-poller` | `CronJob` | Windows HostProcess; runs `Sync-Addons.ps1 -CheckDigest true` every 5 min |
| `addon-sync-processor` | `ServiceAccount` | Identity for the poller (no K8s API RBAC — writes state to host filesystem) |
| `addon-sync-config` | `ConfigMap` | Registry base URL, K2s install directory, insecure flag |
| `addon-sync-script` | `ConfigMap` | `Sync-Addons.ps1` script, mounted into the CronJob pod |

Verify the infrastructure is ready:

```console
kubectl get all -n k2s-addon-sync
kubectl get cronjob addon-sync-poller -n k2s-addon-sync
```

> **No per-addon resources to register.** Unlike FluxCD, no per-addon `OCIRepository` or `Kustomization` needs to be applied. The poller discovers all `addons/*` repositories in the registry automatically on each run.

---

### Step 2 — Recurring: export and push an addon

Every time you want to publish a new or updated addon version:

#### 2a. Export the addon

```console
k2s addons export monitoring -d C:\exports --omit-images --omit-packages
```

`--omit-images` and `--omit-packages` skip container image and OS package layers (4-6). In GitOps mode, images are pulled directly from the registry at enable time.

This produces a file like `K2s-<version>-addons-monitoring.oci.tar` — an OCI Image Layout archive.

#### 2b. Discover the version tag

```powershell
$tar = (Get-ChildItem C:\exports -Filter *monitoring*.oci.tar)[0].FullName

$tempDir = Join-Path $env:TEMP 'oci-inspect'
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
tar -xf $tar -C $tempDir oci-layout index.json
$tag = (Get-Content "$tempDir\index.json" | ConvertFrom-Json).manifests[0].annotations.'org.opencontainers.image.ref.name'
Remove-Item $tempDir -Recurse -Force

Write-Host "Tag: $tag"   # e.g. v1.2.3
```

#### 2c. Push to the registry

```powershell
$k2sInstallDir = 'C:\k'   # or read from: kubectl get configmap addon-sync-config -n k2s-addon-sync -o jsonpath='{.data.K2S_INSTALL_DIR}'
$orasExe = Join-Path $k2sInstallDir 'bin\oras.exe'
$registryHost = '<REGISTRY_HOST>'
$addonName = 'monitoring'

& $orasExe copy --from-oci-layout "${tar}:${tag}" --to-plain-http "${registryHost}/addons/${addonName}:${tag}"
```

> **Use `oras copy --from-oci-layout`, not `oras push`.** `--from-oci-layout` preserves the full multi-layer OCI artifact structure that `Sync-Addons.ps1` depends on. `oras push` uploads blobs without the layer media types and manifest annotations needed for extraction.

> **No `latest` tag needed.** The ArgoCD poller selects the highest semver tag automatically. A single versioned push (`v1.2.3`) is sufficient.

#### 2d. Poller detects and syncs automatically

Within the next 5-minute CronJob cycle, `addon-sync-poller` will:

1. Discover `addons/monitoring` via `oras repo ls`
2. Select the highest semver tag (`v1.2.3`)
3. Compare the manifest digest against the stored digest in `<K2sInstallDir>\addons\.addon-sync-digests\monitoring`
4. Pull the artifact and extract layers 0–3 to the K2s addons directory

#### 2e. Enable the addon

Once sync completes:

```console
k2s addons ls               # monitoring should appear
k2s addons enable monitoring
```

---

### Multi-addon delivery workflow

The ArgoCD poller automatically handles any number of addons from a single shared CronJob. No per-addon configuration changes are needed as you add new addons to the registry.

#### Push multiple addons independently

```powershell
$registryHost = '<REGISTRY_HOST>'
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
    & $orasExe copy --from-oci-layout "${tar}:${tag}" --to-plain-http "${registryHost}/addons/${addonName}:${tag}"
    Write-Host "Pushed $addonName $tag"
}
```

On the next poller run, all changed addons are synced in a single Job execution. Unchanged addons (same digest on host) are skipped automatically.

---

### Verify sync status

Check the CronJob and recent Job runs:

```console
kubectl get cronjob addon-sync-poller -n k2s-addon-sync
kubectl get jobs -n k2s-addon-sync --sort-by=.metadata.creationTimestamp
```

Check the latest Job logs:

```console
kubectl logs -n k2s-addon-sync -l app.kubernetes.io/component=poller --tail=100
```

Log prefixes to look for:

| Prefix | Meaning |
|--------|---------|
| `[AddonSync] Digest changed -- proceeding` | New artifact detected, sync starting |
| `[AddonSync] Digest unchanged -- skipping` | Addon already up to date, skipped |
| `[AddonSync] Extracting layer` | Extraction in progress |
| `[AddonSync][ERROR]` | Failure with details |

Trigger an immediate manual sync (without waiting for the next 5-minute schedule):

```console
kubectl create job addon-sync-manual --from=cronjob/addon-sync-poller -n k2s-addon-sync
kubectl logs -n k2s-addon-sync job/addon-sync-manual -f
```

---

### Customization

#### Change the registry URL or K2s install directory

```console
kubectl edit configmap addon-sync-config -n k2s-addon-sync
```

| Key | Default | Description |
|-----|---------|-------------|
| `REGISTRY_URL` | `<REGISTRY_URL>` (example: `oci://k2s.registry.local:30500`) | Registry host (no path/tag) — poller appends `/addons/<name>` |
| `K2S_INSTALL_DIR` | `C:\k` | K2s root directory on the Windows host |
| `INSECURE` | `true` | Controls plain HTTP vs HTTPS behavior for your registry endpoint |

For TLS and authentication, configure the registry and ORAS/runtime credentials according to your chosen registry product.

#### Change the polling interval

```console
kubectl edit cronjob addon-sync-poller -n k2s-addon-sync
```

Modify `spec.schedule` (e.g., `*/2 * * * *` for 2-minute polling, `*/10 * * * *` for 10-minute polling).

#### Registry without catalog API

If your registry disables `GET /v2/_catalog` (common with RBAC-restricted Harbor, GHCR, ECR), `oras repo ls` returns no results and the poller skips all addons. Fix this by explicitly listing the addon repositories:

```console
kubectl patch configmap addon-sync-config -n k2s-addon-sync --type merge \
  -p '{"data":{"ADDON_REPOS":"monitoring,security,registry"}}'
```

`Sync-Addons.ps1` reads `ADDON_REPOS` and uses it instead of catalog discovery. Update this list when you add new addons to the registry.

---

## Backup and Restore

Backup/restore is **scoped to the `rollout` namespace only**.

### What gets backed up

- `argocd admin export -n rollout` output (applications, projects, repository connections, settings)
- Optional dashboard ingress resources in namespace `rollout`

> **Note:** The ArgoCD export contains repository credentials. Store the backup archive securely.

### What does not get backed up

- ArgoCD controller manifests and CRDs (re-installed by `k2s addons enable rollout argocd` during restore)
- Resources outside the `rollout` namespace
- The `k2s-addon-sync` namespace — re-deployed automatically when rollout is re-enabled

### Commands

```console
k2s addons backup rollout argocd
k2s addons restore rollout argocd <path-to-backup-zip>
```

### Admin import/export

If you need to use `argocd admin export`/`import` directly, specify the `rollout` namespace:

```console
argocd admin export -n rollout > backup.yaml
Get-Content -Raw .\backup.yaml | argocd admin import -n rollout -
```

---

## Disable ArgoCD

```console
k2s addons disable rollout argocd
```

Removes ArgoCD from the `rollout` namespace, the `k2s-addon-sync` namespace, and all addon-sync resources. Ingress addons enabled alongside rollout are not disabled.

---

## Further Reading

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/en/stable/)
- [GitOps Addon Delivery — Full Operational Guide](../../../docs/op-manual/gitops-addon-delivery.md)