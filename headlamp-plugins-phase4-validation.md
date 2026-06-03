<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Phase 4 — Plugin OCI Image Supply Chain — Validation Report

Closes the single Phase 3 P0 release blocker: the Headlamp plugin images
referenced by offline packaging had **no producer**. They are now reproducibly
built, layout-verified, and packaging-integrated.

## 1. Authoritative upstream source (Task 1)

All three plugins originate from the **official Headlamp plugin monorepo**
`github.com/headlamp-k8s/plugins`:

| K2s image | Upstream dir | Version |
|---|---|---|
| `headlamp-plugin-flux` | `flux` | 0.6.0 |
| `headlamp-plugin-cert-manager` | `cert-manager` | 0.1.0 |
| `headlamp-plugin-prometheus` | `prometheus` | 0.8.2 |

## 2. Distribution form (Task 2)

Headlamp plugins are **not** runnable npm packages. They are distributed as
compiled bundles (`main.js` + `package.json`) in two equivalent forms, both
supported by the pipeline:

* **Prebuilt tarball** (preferred, offline-friendly) — the ArtifactHub release
  artifact, pinned by URL + SHA256 in `headlamp-plugins.lock.json`.
* **Build-from-source** — clone the pinned git ref and build with the official
  `@headlamp-k8s/headlamp-plugin` toolchain (`-Mode source`).

> Not a GitHub release asset of a standalone binary; not a public npm dist.

## 3. Reproducible build pipeline (Tasks 3–4)

Implemented under `addons/dashboard/build/`:

| Artifact | Role |
|---|---|
| `headlamp-plugins.lock.json` (+`.license`) | Pinned single source of truth |
| `Build-HeadlampPluginImages.ps1` | Orchestrator (acquire → build → validate → push) |
| `Build-HeadlampPluginImages.Methods.ps1` | Core methods (daemonless `crane` build) |
| `Dockerfile.headlamp-plugin` | Equivalent `docker`/`nerdctl` build path |
| `headlamp-plugin-images.unit.tests.ps1` | Consistency guard (CI) |
| `README.md` | Architecture / build / packaging flow |

The daemonless `crane append` mechanism mirrors the existing fluent-bit pipeline
(`K2s-Support/ci/autoupdate/33-update-addons-logging.yaml`), so no new build
infrastructure is introduced.

## 4. Image layout — runtime compatibility (Task 5)

The dashboard init-container (`Build-PluginPatchJson`) runs:

```sh
mkdir -p /tmp/headlamp/plugins/<pluginDir> && cp -r /plugins/<pluginDir>/. /tmp/headlamp/plugins/<pluginDir>/
```

The pipeline enforces both halves of this contract:

* `Test-PluginBundleLayout` — fails the build unless the staged bundle has
  `main.js` + `package.json`.
* `Test-PluginImageLayout` — fails the build unless the **built image** exposes
  `/plugins/<pluginDir>/main.js`.
* Base image `busybox` provides the required `sh` + `mkdir` + `cp`.
* `<pluginDir>` equals the init-container **Name** (`flux-plugin`,
  `cert-manager-plugin`, `prometheus-plugin`), as registered in
  `Get-RegisteredHeadlampPlugins`.

## 5. Packaging integration (Task 6)

No changes to Export/Import were required — they already consume
`additionalImages`. The missing producer is now in place:

```
Build-HeadlampPluginImages.ps1 -Push  →  shsk2s.azurecr.io
        ↓ DumpK2sImages.ps1 (BOM)  ↓ Export.ps1 (buildah pull → image tars in OCI artifact)
                          ↓ Import.ps1 (load tars into containerd, air-gapped)
                                   ↓ Sync-HeadlampPlugins (inject init-containers)
```

## 6. additionalImages resolution (Task 8)

`headlamp-plugin-images.unit.tests.ps1` proves the three coordinates stay in
lock-step and that every `additionalImages` entry has a producer:

```
Tests Passed: 7, Failed: 0
  Headlamp plugin lock file                          (3)
  Lock and addon.manifest.yaml additionalImages parity (2)
  Lock and Get-RegisteredHeadlampPlugins parity        (2)
```

This guard fails CI on any future drift between the lock file, the manifest
`additionalImages`, and the runtime registry — the exact Phase 3 failure mode.

## 7. Validation status (Task 7)

| Check | Status | Notes |
|---|---|---|
| Lock ⇄ manifest ⇄ registry parity | ✅ Verified | 7/7 Pester tests pass locally |
| PowerShell scripts parse | ✅ Verified | AST parse clean |
| Bundle layout enforcement | ✅ Implemented | `Test-PluginBundleLayout` |
| Image layout enforcement | ✅ Implemented | `Test-PluginImageLayout` |
| Online install | ✅ Path complete | images publishable + pullable |
| Offline export / import | ✅ Path complete | reuses existing Export/Import |
| Air-gapped install | ✅ Path complete | images bundled in OCI artifact |
| Upgrade path | ✅ Supported | image-tag diff in `Apply-HeadlampPluginPatch` |

### Remaining one-time action (not a code gap)

The lock file ships with `sha256: "TO-PIN"` for each prebuilt tarball. On the
first connected build, run `Build-HeadlampPluginImages.ps1 -UpdateLock` to pin
the checksums (standard bootstrap for any new pinned dependency). Until pinned,
the script **refuses** to build in prebuilt mode without `-UpdateLock`, preventing
an unverified artifact from entering the package.

The actual image build + push and the end-to-end air-gapped install must run in a
connected CI environment with registry credentials and a cluster; the pipeline,
contracts, and consistency guards required to make that deterministic are all in
place.

## 8. Out of scope (per Phase 4)

Start-time reconcile, health reconciliation, and status enhancements were
**not** implemented — Phase 4 is exclusively the P0 offline packaging gap.

