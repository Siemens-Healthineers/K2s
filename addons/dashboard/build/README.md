<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Headlamp Plugin OCI Image Supply Chain

Reproducible build pipeline for the three K2s Headlamp plugin images injected by
the **dashboard** addon:

| Image | Plugin dir (init-container name) | Upstream |
|---|---|---|
| `shsk2s.azurecr.io/headlamp-plugin-flux:0.6.0` | `flux-plugin` | headlamp-k8s/plugins · `flux` |
| `shsk2s.azurecr.io/headlamp-plugin-cert-manager:0.1.0` | `cert-manager-plugin` | headlamp-k8s/plugins · `cert-manager` |
| `shsk2s.azurecr.io/headlamp-plugin-prometheus:0.8.2` | `prometheus-plugin` | headlamp-k8s/plugins · `prometheus` |

> **Acquisition source:** the compiled plugin bundle is the **GitHub Release asset**
> published by `headlamp-k8s/plugins` (tag `<plugin>-<version>`, e.g.
> `https://github.com/headlamp-k8s/plugins/releases/download/flux-0.6.0/headlamp-k8s-flux-0.6.0.tar.gz`).
> This is the canonical artifact produced by the upstream releaser (`tools/releaser`),
> which uploads the tarball as a release asset and records its SHA256. ArtifactHub is
> **not** used for acquisition — it is only an upstream catalog whose `archive-url`
> points back at these same GitHub assets and does not list every plugin (e.g. there
> is no ArtifactHub entry for `prometheus`). Asset filenames are not uniform
> (`headlamp-k8s-flux-*.tar.gz` vs `prometheus-*.tar.gz`), so the auto-update workflow
> resolves the asset dynamically from the GitHub Releases API.

## Why this exists

`addons/dashboard/addon.manifest.yaml` lists these images under
`offline_usage.linux.additionalImages`. The K2s BOM (`build/bom/DumpK2sImages.ps1`),
`addons/Export.ps1` (`buildah pull`) and `addons/Import.ps1` all expect them to be
**pullable from `shsk2s.azurecr.io`**. This folder is the **producer** that makes
that true and keeps it reproducible.

## Architecture

```
headlamp-plugins.lock.json   ── single source of truth (versions, sources, sha256, image refs, vendored localPath)
        │
        ▼
Build-HeadlampPluginImages.ps1  (thin orchestrator)
        │  dot-sources
        ▼
Build-HeadlampPluginImages.Methods.ps1
   1. acquire bundle  (vendored tarball @ prebuilt.localPath  →  prebuilt URL fallback  |  build-from-source)
   2. validate bundle layout  (main.js + package.json present)
   3. pack layer tar  plugins/<pluginDir>/...
   4. crane append onto pinned busybox base  → OCI tarball  (offline artifact)
   5. validate image layout  (/plugins/<pluginDir>/main.js present)
   6. crane push  (optional, with -Push)
```

`crane` (google/go-containerregistry) is used **daemonless**, matching the
existing fluent-bit pipeline in `K2s-Support/ci/autoupdate/33-update-addons-logging.yaml`.
No Docker/containerd daemon is required to build these static-file images.

`Dockerfile.headlamp-plugin` is provided as an equivalent `docker`/`nerdctl`
build path for environments that prefer a daemon; it copies the same
`plugins/` build context to `/plugins/`.

## Image layout (runtime contract)

The dashboard addon patches the Headlamp Deployment with an init-container
(`Build-PluginPatchJson` in `dashboard.module.psm1`) that runs:

```sh
mkdir -p /tmp/headlamp/plugins/<pluginDir> && cp -r /plugins/<pluginDir>/. /tmp/headlamp/plugins/<pluginDir>/
```

Therefore every image **must**:

1. expose the compiled bundle at `/plugins/<pluginDir>/` (`main.js`, `package.json`), and
2. provide a POSIX shell + `mkdir` + `cp` — satisfied by the pinned `busybox` base.

`<pluginDir>` is the init-container **Name** (`flux-plugin`, `cert-manager-plugin`,
`prometheus-plugin`), not the upstream package name. The mapping lives in the lock file.

## Build flow

First build (pins the currently `TO-PIN` checksums after manual verification):

```powershell
.\Build-HeadlampPluginImages.ps1 -UpdateLock
```

Build + publish to the registry (CI, authenticated to `shsk2s.azurecr.io`):

```powershell
.\Build-HeadlampPluginImages.ps1 -Push
```

Build a single plugin from upstream source instead of a prebuilt tarball:

```powershell
.\Build-HeadlampPluginImages.ps1 -PluginName flux -Mode source
```

Offline OCI tarballs are written to `.\out\headlamp-plugin-<name>-<version>.tar`.

## Vendored plugin bundles (offline, reproducible from a clean checkout)

The compiled plugin bundle tarballs are **vendored in-repo** under `plugins/`, the
same convention this repo already uses for `manifests/chart/headlamp-*.tgz` (chart)
and `addons/security/manifests/kyverno/kyverno-*.tgz` (Kyverno chart). The lock file
records the path in `prebuilt.localPath`.

`Build-HeadlampPluginImages.ps1` prefers the vendored tarball when present and **falls
back to `prebuilt.url` (the GitHub Release asset)** when it is absent — so the pipeline
keeps working before the first vendoring run. Both sources are verified against
`prebuilt.sha256`, so the vendored bundle can never drift from the pinned checksum.

This keeps the **OCI image as the deployment mechanism** and leaves the
`additionalImages` offline-packaging and `Export.ps1` / `Import.ps1` air-gapped flow
**unchanged** — only the build's bundle source moves in-repo. The auto-update
workflow refreshes the vendored tarball in its version-bump PR (publish-before-PR is
preserved). See `plugins/README.md`.

## Packaging flow (offline / air-gapped)

```
Build-HeadlampPluginImages.ps1 -Push      (produces & publishes images to ACR)
        │
        ▼
k2s system package                         (online build host)
   build/bom/DumpK2sImages.ps1  reads additionalImages → BOM
   addons/Export.ps1            buildah pull <image> → bundles image tars into the addon OCI artifact
        │   (carry ZIP / .oci.tar to the air-gapped site)
        ▼
addons/Import.ps1                          (air-gapped host)
   imports the bundled image tars into containerd  → images are local, no pull needed
        │
        ▼
k2s addons enable dashboard                Sync-HeadlampPlugins patches Deployment with init-containers
                                           that reference the now-local images
```

## Updating versions

1. Bump `version` + `image` + `source.ref` and set `prebuilt.url` to the new
   GitHub Release asset (`https://github.com/headlamp-k8s/plugins/releases/download/<plugin>-<version>/<asset>.tar.gz`)
   in `headlamp-plugins.lock.json`.
2. Mirror the `image` change in `addons/dashboard/addon.manifest.yaml`
   (`additionalImages`) and `Get-RegisteredHeadlampPlugins` in
   `dashboard.module.psm1`.
3. Run `Build-HeadlampPluginImages.ps1 -UpdateLock` to re-pin checksums, then commit
   the refreshed `plugins/<plugin>-<version>.tar.gz` (+ `.license`) and update
   `prebuilt.localPath`. (The auto-update workflow does steps 1-3 automatically.)
4. `headlamp-plugin-images.unit.tests.ps1` enforces that all three stay in sync and
   that any present vendored tarball matches `prebuilt.sha256`.

## Files

| File | Purpose |
|---|---|
| `headlamp-plugins.lock.json` | Pinned build inputs (single source of truth) |
| `plugins/` | Vendored compiled plugin bundle tarballs (`<plugin>-<version>.tar.gz`) + `.license` sidecars |
| `Dockerfile.headlamp-plugin` | Parameterized daemon-based build path |
| `Build-HeadlampPluginImages.ps1` | Orchestrator (acquire → build → validate → push) |
| `Build-HeadlampPluginImages.Methods.ps1` | Core build/acquire/validate methods |
| `headlamp-plugin-images.unit.tests.ps1` | Lock ⇄ manifest ⇄ registry consistency guard |

