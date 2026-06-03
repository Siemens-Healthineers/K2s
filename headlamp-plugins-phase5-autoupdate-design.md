<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Phase 5 — Headlamp Plugin Auto-Update Integration — Design

> **Status:** Proposed (approval artifact). **No automation is implemented by this document.**
> Implementation begins only after this design is approved.

This document specifies how the Phase 4 Headlamp plugin OCI image supply chain
(`addons/dashboard/build/`) integrates with the existing K2s auto-update
ecosystem in the `K2s-Support` repository (`K2s-Support/ci/autoupdate/`).

Scope: the three stable plugins — **flux**, **cert-manager**, **prometheus**.

---

## 1. Architecture overview

The integration adds **one** new Argo `WorkflowTemplate` to the existing daily
autoupdate cron. It detects new upstream plugin releases, rebuilds and republishes
the corresponding `shsk2s.azurecr.io/headlamp-plugin-*` images, and raises a PR
against K2s that bumps the version coordinates. It introduces **no new build
infrastructure and no new secrets** — it reuses the proven daemonless `crane`
build/publish pattern and the existing PR-raising machinery.

```
 ┌──────────────────────── K2s-Support repo (automation) ─────────────────────────┐
 │  0-daily-autoupdate-cron.yaml                                                    │
 │      └─► 38-update-addons-dashboard-headlamp-plugins.yaml  (NEW)                 │
 │              detect → compare → build+push → raise PR   (per plugin)             │
 └─────────────────────────────────────────────────────────────────────────────────┘
                    │ reads/writes (via PR)            │ pushes images
                    ▼                                  ▼
 ┌──────────────── K2s repo (source of truth) ───────┐   ┌──── shsk2s.azurecr.io ───┐
 │  addons/dashboard/build/headlamp-plugins.lock.json│   │ headlamp-plugin-flux:X   │
 │  addons/dashboard/addon.manifest.yaml             │   │ headlamp-plugin-cert-… :Y │
 │  addons/dashboard/dashboard.module.psm1           │   │ headlamp-plugin-prom… :Z │
 │  addons/dashboard/build/*.unit.tests.ps1 (gate)   │   └──────────────────────────┘
 └────────────────────────────────────────────────────┘
```

**Single source of truth:** `headlamp-plugins.lock.json`. Every other coordinate
(`addon.manifest.yaml` `additionalImages`, `Get-RegisteredHeadlampPlugins`) is
kept consistent with it and enforced by `headlamp-plugin-images.unit.tests.ps1`.

---

## 2. Relationship to existing k2s-support automation

The design is modeled directly on existing, shipping workflows. Nothing here is
novel infrastructure.

| Existing asset (`K2s-Support/ci/autoupdate/`) | Reused for |
|---|---|
| `0-daily-autoupdate-cron.yaml` | Scheduling; add one `run-…` step + resource template |
| `kustomization.yaml` | Register the new workflow file |
| `update-common` template (`compare-and-decide`) | Version comparison / update decision |
| `33-update-addons-logging.yaml` → `build-and-push-fluent-bit-win-image` | The daemonless **crane append + push** image build pattern |
| `33-…` → `create-fluentbit-update-pr` | The **PR-raising** pattern |
| `27-update-addons-dashboard.yaml` | Precedent for a dashboard-scoped updater (Headlamp *core*) |
| `fetch-latest-github-release` | Upstream release detection |
| Secrets `shsk2s-push-credentials`, `github-credentials-fetch`, `github-credentials-approve` | Registry push + PR auth (all already provisioned) |

**Why a separate workflow** (`38-…`) rather than extending `27-update-addons-dashboard.yaml`:
the Headlamp *core* chart and the *plugins* version independently, and plugins
require an image build step the core updater does not have. Separation keeps each
workflow single-purpose and matches the repo's one-file-per-concern convention.

Proposed filename follows the numbering convention (current max is
`37-update-addons-security.yaml`):

```
K2s-Support/ci/autoupdate/38-update-addons-dashboard-headlamp-plugins.yaml
```

---

## 3. Plugin lifecycle

```
 upstream release            K2s-Support autoupdate                 K2s repo
 ───────────────             ─────────────────────                 ────────
 headlamp-k8s/plugins  ──►  detect new <name>-X.Y.Z
   tag flux-0.7.0            │
                            compare vs lock.json .version
                             │ (newer?)
                            build image  busybox + plugin layer
                            push  shsk2s.azurecr.io/headlamp-plugin-flux:0.7.0
                             │
                            open PR  ───────────────────────────►  bump 4 coordinates
                                                                    │
                                                  CI parity gate ◄──┘
                                                   (7 tests)
                                                    │ pass
                            human review/merge ◄────┘
                                                    │
                            next k2s system package picks up new image (offline bundle)
                                                    │
                            k2s addons enable/update dashboard → Sync-HeadlampPlugins injects init-container
```

A plugin's lifecycle states: **tracked** (in lock.json) → **update-detected** →
**image-published** → **PR-open** → **merged** → **packaged** → **runtime-injected**.

---

## 4. Version detection strategy

**Primary source: GitHub Releases of `headlamp-k8s/plugins`.** The monorepo tags
each plugin independently as `<plugin>-X.Y.Z` (e.g. `flux-0.6.0`,
`cert-manager-0.1.0`, `prometheus-0.8.2`). The workflow:

1. Calls the GitHub releases API (token: `github-credentials-fetch`, via proxy),
   filters tags matching the plugin's `tagPattern`, selects the highest semver.
2. Strips the `<plugin>-` prefix to a bare semver.
3. Reads the current `version` straight from `headlamp-plugins.lock.json` via
   `raw.githubusercontent.com` (same raw-fetch approach as
   `fetch-k2s-logging-versions`).
4. Delegates the decision to `update-common / compare-and-decide` →
   `should-update` boolean.

This reuses the existing `fetch-latest-github-release` mechanism verbatim, so no
new detection code is introduced.

See §9 for why GitHub Release assets are the acquisition source for both detection and download.

---

## 5. Image build strategy

**Daemonless `crane append`**, identical in shape to
`build-and-push-fluent-bit-win-image`:

1. Run in a plain `alpine` pod (no Docker/containerd daemon, no privileged pod).
2. Install `crane` (google/go-containerregistry, pinned version).
3. Acquire the compiled plugin bundle:
   * **prebuilt** (default): download the GitHub Release asset (`prebuilt.url`,
     resolved dynamically from the Releases API at PR time), compute/verify SHA256.
   * **source** (opt-in via lock `acquisition`): build with `@headlamp-k8s/headlamp-plugin`.
4. Pack the bundle as a gzip layer with paths `plugins/<pluginDir>/…`.
5. `crane append --base busybox:1.36 --new_layer … --new_tag shsk2s.azurecr.io/headlamp-plugin-<name>:<ver>`.

This is exactly what `Build-HeadlampPluginImages.ps1` already does locally; the
workflow performs the same steps in CI. The Phase 4 layout contract
(`/plugins/<pluginDir>/main.js`, shell + `mkdir` + `cp` from busybox) is preserved.

**Runtime contract enforced at build:** the workflow runs the equivalent of
`Test-PluginBundleLayout` / `Test-PluginImageLayout` so a malformed image never
gets published.

---

## 6. OCI publishing strategy

* Registry: `shsk2s.azurecr.io` (same as all bundled K2s images).
* Auth: `crane auth login shsk2s.azurecr.io` using the existing
  `shsk2s-push-credentials` secret (username/password via `--password-stdin`;
  the password never appears as a CLI arg) — identical to the fluent-bit step.
* Tag scheme: `headlamp-plugin-<name>:<version>` (immutable per release).
* Publishing happens **before** the PR step. Rationale (mirroring fluent-bit):
  by the time the PR references the new tag, the image is guaranteed pullable, so
  the PR's CI and any subsequent `k2s system package` cannot reference a missing image.

---

## 7. PR generation strategy

Reuses the `create-fluentbit-update-pr` structure (token:
`github-credentials-approve`):

1. Clone K2s, create branch `autoupdate/dashboard-headlamp-plugins-<name>-<ver>`.
2. Edit the **four coordinates** for that plugin:
   * `headlamp-plugins.lock.json` → `version`, `image`, `prebuilt.sha256` (the
     freshly computed digest, replicating `-UpdateLock`).
   * `addon.manifest.yaml` → the `additionalImages` tag.
   * `dashboard.module.psm1` → the `Get-RegisteredHeadlampPlugins` image tag.
   * (BOM files under `build/bom/` only if they pin the tag explicitly.)
3. Commit, open PR with labels `dependencies`, `automated`.
4. CI on the PR runs `headlamp-plugin-images.unit.tests.ps1` (the three-way parity
   gate) automatically.

**Operational example — PR body (flux 0.6.0 → 0.7.0):**

```
Title:  chore(dashboard): bump headlamp-plugin-flux 0.6.0 → 0.7.0
Branch: autoupdate/dashboard-headlamp-plugins-flux-0.7.0
Labels: dependencies, automated

Files changed:
  addons/dashboard/build/headlamp-plugins.lock.json   (version, image, prebuilt.sha256)
  addons/dashboard/addon.manifest.yaml                (additionalImages)
  addons/dashboard/dashboard.module.psm1              (Get-RegisteredHeadlampPlugins)

Image published: shsk2s.azurecr.io/headlamp-plugin-flux:0.7.0  (sha256:…)
Upstream:        headlamp-k8s/plugins @ flux-0.7.0
```

---

## 8. One-PR-per-plugin rationale

**Recommendation: one PR per plugin.**

| Aspect | Per-plugin PR (recommended) | Combined PR |
|---|---|---|
| Versioning | Matches independent upstream tags | Forces lockstep that doesn't exist |
| CI signal | Isolated — a failure blocks only that plugin | One failure blocks all three |
| Review | Small, single-purpose diff | Larger, mixed diff |
| Rollback | Revert one plugin cleanly (§11) | Revert reverts unrelated bumps |
| Cadence | Each plugin merges when ready | Slowest plugin gates the rest |

The plugins release on independent schedules (flux, cert-manager, prometheus have
unrelated version lines), so per-plugin PRs are the natural unit. The workflow
fans out over the three plugins and opens an independent PR for each that has an
update.

---

## 9. Acquisition source rationale (GitHub Release assets)

**Both detection and download use GitHub Releases of `headlamp-k8s/plugins`.**

The upstream releaser (`tools/releaser`) tags each plugin `<plugin>-X.Y.Z`, builds the
compiled bundle (`npm run package`), and **uploads the tarball as a GitHub Release
asset** — that asset is the canonical published artifact, and its SHA256 is what
upstream also records in `artifacthub-pkg.yml` (`archive-checksum`).

| Criterion | GitHub Release assets | ArtifactHub |
|---|---|---|
| Existing repo mechanism | ✅ `fetch-latest-github-release` already used | ❌ no precedent |
| Authoritative version tags | ✅ `<plugin>-X.Y.Z` on the source monorepo | ⚠️ derived/republished |
| Auth & proxy already handled | ✅ `github-credentials-fetch` | ⚠️ separate API |
| Hosts the compiled artifact | ✅ release asset (the actual tarball) | ❌ catalog only — its `archive-url` points back to the GitHub asset |
| Covers all three plugins | ✅ flux, cert-manager, prometheus | ❌ no `prometheus` package on ArtifactHub |

**Decision:** detect the version **and** download the compiled bundle from the GitHub
Release asset. Because asset filenames are not uniform across plugins
(`headlamp-k8s-flux-*.tar.gz` vs `prometheus-*.tar.gz`), the asset is resolved
dynamically from the Releases API (prefer `*.tar.gz`, fall back to `*.tgz`); the
resolved concrete URL and its computed SHA256 are pinned into `prebuilt.url` /
`prebuilt.sha256`. ArtifactHub is **not** on the acquisition path. If a release asset
is ever missing, the lock's `acquisition: "source"` flag lets the workflow fall back
to building from the pinned git tag.

> Historical note: an earlier draft of this design routed the *download* through
> ArtifactHub on the assumption it offered a "stable prebuilt tarball URL". That was
> incorrect — ArtifactHub does not host the bundle (its `archive-url` redirects to the
> GitHub asset) and does not list every plugin (no `prometheus`). The acquisition path
> was corrected to GitHub Release assets.

---

## 10. Failure handling

| Failure point | Behavior | Operator outcome |
|---|---|---|
| Detect step (GitHub API/proxy) | Step fails; cron `continueOn.failed: true` keeps other addons running | Logged in cron summary; retried next day |
| No new version | `should-update=false`; workflow no-ops | No PR, no noise |
| Tarball download / SHA mismatch | Build step fails **before** push | No image published, no PR; alert in summary |
| `crane append`/push (registry/auth) | Build step fails | No PR raised (publish precedes PR); image tag never half-exists |
| Image layout check fails | Build step fails | Malformed image never published |
| PR creation (GitHub API) | PR step fails after successful push | Image exists but no PR — safe; re-run opens PR (idempotent tag) |
| CI parity test fails on PR | PR blocked from merge | Human fixes the out-of-sync coordinate |

**Idempotency:** re-running the workflow for an already-published tag is safe —
`crane append` re-pushes the same content-addressed layers; the PR branch name is
deterministic so a re-run updates the existing PR rather than duplicating it.

---

## 11. Rollback strategy

Because publishing precedes the PR and tags are immutable per version, rollback is
a **revert of the K2s PR**, not a registry operation:

1. **Before merge:** close the PR. Nothing in K2s changed; the unused image tag in
   ACR is harmless (no manifest references it).
2. **After merge, pre-release:** open a revert PR restoring the previous
   `version`/`image`/`sha256` across the four coordinates. The parity gate ensures
   the revert is internally consistent. The prior image tag still exists in ACR, so
   the revert is immediately pullable/packageable.
3. **After offline package shipped:** the package is immutable; roll forward with a
   corrected version bump (standard K2s release practice). No air-gapped site is
   affected retroactively.

The previous image tag is **never deleted** by the workflow, guaranteeing every
rollback target remains pullable.

---

## 12. CI validation gates

The merge gate is the existing Phase 4 guard, run automatically on the PR:

`addons/dashboard/build/headlamp-plugin-images.unit.tests.ps1` (7 tests):

1. Lock declares exactly three plugins.
2. Each plugin's `pluginDir` matches its image name/version.
3. Every image uses the `shsk2s.azurecr.io` registry.
4. Every lock image has an `addon.manifest.yaml` `additionalImages` entry.
5. Every manifest plugin image has a lock entry.
6. Each lock image is registered under the matching init-container name.
7. No registered plugin lacks a lock entry.

Any drift between the **lock**, the **manifest**, and the **runtime registry** —
the exact Phase 3 failure mode — fails the build and blocks the merge. The
workflow also performs the build-time bundle/image layout checks (§5) so a broken
image cannot be published in the first place.

---

## 13. Future plugin onboarding process

Adding a fourth plugin (e.g. `headlamp-plugin-keda`) once it reaches stable:

1. Add an entry to `headlamp-plugins.lock.json` (`name`, `pluginDir`, `version`,
   `image`, `source`, `prebuilt`, plus the §3 metadata: `upstreamReleaseRef`,
   `detectionSource`, `acquisition`).
2. Add the image to `addon.manifest.yaml` `additionalImages`.
3. Register it in `Get-RegisteredHeadlampPlugins` (with its capability detector).
4. Run `Build-HeadlampPluginImages.ps1 -PluginName keda -UpdateLock` to pin the
   checksum and produce the first image; push with `-Push`.
5. The parity test now expects four plugins — update test count expectation if it
   asserts an exact count.
6. The autoupdate workflow fans out over the lock file, so **no workflow change is
   required** — the new plugin is picked up automatically on the next run.

The lock file being the single source of truth means onboarding is a data change
plus a one-time checksum pin; the automation generalizes without edits.

---

## Required metadata additions (for approval)

Per-plugin fields to add to `headlamp-plugins.lock.json` so automation self-drives:

```jsonc
{
  "name": "flux",
  "pluginDir": "flux-plugin",
  "version": "0.6.0",
  "image": "shsk2s.azurecr.io/headlamp-plugin-flux:0.6.0",
  "upstreamReleaseRef": { "owner": "headlamp-k8s", "repo": "plugins", "tagPattern": "flux-{version}" },
  "detectionSource": "github-releases",
  "acquisition": "prebuilt",
  "source":   { "type": "git", "repo": "https://github.com/headlamp-k8s/plugins.git", "ref": "flux-0.6.0", "subdir": "flux" },
  "prebuilt": { "url": "https://github.com/headlamp-k8s/plugins/releases/download/flux-0.6.0/headlamp-k8s-flux-0.6.0.tar.gz", "sha256": "28a9c74e0e312a22a67517062ce06c09bc83f9e3c72d8481c20eb5aca49339d0" }
}
```

---

## Sequence diagram — full update run (one plugin)

```
Cron        Workflow(38)      GitHub        K2s raw       ACR(shsk2s)     K2s PR        CI
 │  trigger    │                │             │              │              │            │
 ├────────────►│                │             │              │              │            │
 │             │ get releases   │             │              │              │            │
 │             ├───────────────►│             │              │              │            │
 │             │ flux-0.7.0     │             │              │              │            │
 │             │◄───────────────┤             │              │              │            │
 │             │ read lock .version           │              │              │            │
 │             ├─────────────────────────────►│              │              │            │
 │             │ 0.6.0                         │              │              │            │
 │             │◄─────────────────────────────┤              │              │            │
 │             │ compare-and-decide → update  │              │              │            │
 │             │ download tarball, verify sha256             │              │            │
 │             │ crane append busybox + layer │              │              │            │
 │             │ push headlamp-plugin-flux:0.7.0             │              │            │
 │             ├────────────────────────────────────────────►│              │            │
 │             │ open PR (4 coordinates)                      │              │            │
 │             ├──────────────────────────────────────────────────────────►│            │
 │             │                                              │   run parity gate        │
 │             │                                              │              ├───────────►│
 │             │                                              │              │  7/7 pass  │
 │             │                                              │              │◄───────────┤
 │ summary◄────┤                                              │       (await human merge) │
```

## Sequence diagram — no-update run

```
Cron ─► Workflow(38) ─► GitHub: latest = 0.6.0 ─► K2s raw: lock = 0.6.0
                        compare-and-decide → should-update = false
                        (no build, no push, no PR) ─► cron summary: "up to date"
```

---

## Manual steps remaining

1. **First-run checksum pinning:** the three `prebuilt.sha256: "TO-PIN"` values are
   pinned once (manual `-UpdateLock` or the first CI build), because detection
   compares versions, not digests.
2. **Human PR review/merge:** no auto-merge (per the autoupdate README best
   practice); the parity gate is the automated guard, a human approves the merge.
3. **Secrets:** none new — `shsk2s-push-credentials`, `github-credentials-fetch`,
   `github-credentials-approve` are reused.

---

## Approval checklist

- [ ] Separate workflow `38-update-addons-dashboard-headlamp-plugins.yaml` (vs extending `27`).
- [ ] GitHub Release assets for both detection and download (no ArtifactHub on the acquisition path).
- [ ] One PR per plugin.
- [ ] Lock-file metadata additions (`upstreamReleaseRef`, `detectionSource`, `acquisition`).
- [ ] Publish-before-PR ordering.
- [ ] Parity test as the merge gate.

Once approved, implementation proceeds against §2 "Required k2s-support changes".

