# AI Coding Assistant Project Instructions (K2s)

These instructions make an AI agent immediately productive in this repository. Keep responses concise, apply these conventions automatically, and prefer concrete edits (not vague advice).

## 1. Big Picture
K2s is a Windows‑first Kubernetes distribution bundling a Linux VM (Hyper-V or WSL) plus curated OSS components, with strong offline support. Repo delivers:
- `k2s.exe` CLI (Go) under `k2s/cmd/...` operating orchestration & lifecycle.
- PowerShell modules & scripts for host provisioning, packaging, offline builds, addon management (`lib/modules`, `lib/scripts`, `addons/`).
- Addon system: each addon = folder with `addon.manifest.yaml`, enable/disable scripts, and manifests.
- Offline packaging pipeline producing large ZIPs containing binaries, images, VHDX base disks, and addon assets.
- Documentation site built via MkDocs (`mkdocs.yml`, `docs/`).

## 2. Key Directories
- `k2s/` Go sources (CLI root). Subdirs `cmd/*` for individual commands; shared logic in `internal/`.
- `lib/modules/k2s.*.module/` PowerShell modules (logging, infra, node, cluster, signing, etc.).
- `lib/scripts/k2s/system/package/` Packaging & delta generation scripts (`New-K2sDeltaPackage.ps1`, helpers file).
- `addons/` Addon definitions; each addon has `Enable.ps1`, `Disable.ps1`, optional `Get-Status.ps1`, `Update.ps1`, `README.md`.
- `smallsetup/` Windows environment bootstrap (loopback adapter, HNS, kubeadm flags, etc.).
- `bin/` Pre-bundled third‑party executables (kubectl, helm, nerdctl, jq, plink, etc.). Do NOT modify vendored binaries—never rewrite.
- `build/` BOM, catalog metadata used for reproducibility & signing.
- `docs/` MkDocs sources; includes dev guide, ops manual, troubleshooting.

## 3. PowerShell Conventions
- All logging goes through functions from `k2s.infra.module` (`Write-Log`, `Write-ErrorMessage`). Don’t use `Write-Host` directly for new code.
- Scripts meant for reuse go into a helper `.ps1` and are dot-sourced; keep orchestration thin (see `New-K2sDeltaPackage.ps1` + `New-K2sDeltaMethods.ps1`).
- Long phases wrapped with `Start-Phase` / `Stop-Phase` for timing.
- Hash objects expose both `.Sha256` and `.Hash` for backward compatibility.
- Avoid assigning to automatic variables (`$args`). Use explicit names (`$sshParams`, `$scpParams`).
- When adding guest/Hyper-V interactions, clean up resources (switch, NAT, VM) even on error.
- Secure inputs: new code should accept `SecureString` or `PSCredential` for secrets (legacy plain strings exist—don’t proliferate).

## 4. Delta Packaging Pattern
- Extraction: `Expand-ZipWithProgress` with path sanitization & traversal prevention.
- Hashing: `Get-FileMap` builds maps; diff logic excludes wholesale directories & special large artifacts (VHDX, MSI, archives).
- Debian diff: Boot temporary VM from Kubemaster VHDX → SSH → `dpkg-query` → compute Added/Removed/Changed. Offline acquisition attempts to download changed .deb files (`Invoke-GuestDebAcquisition`).
- Generated artifacts under staging include `delta-manifest.json`, optionally `debian-delta/*` (lists, scripts, downloaded packages).

## 5. Addon Pattern
Each addon folder contains:
- `addon.manifest.yaml` (metadata, dependencies, toggles).
- Enable/Disable scripts modify cluster state via kubectl/helm/yaml manifests under `manifests/`.
- Status scripts typically query deployments/CRDs; follow existing naming.
New addon: copy a minimal existing one (e.g. `addons/autoscaling/`) and adjust manifest + scripts.

## 6. Go Code (CLI)
- Each command in `k2s/cmd/<name>` with its own `main.go` or cobra-style setup (inspect existing patterns before introducing new flags/roots).
- Shared functionality lives under `k2s/internal/...`. Reuse before creating duplicates.
- Keep binaries buildable offline: avoid introducing network-time fetches at runtime.

## 7. Build & CI Workflows
See `.github/workflows/` for canonical pipelines:
- `build-k2s-cli*.yml` builds Go CLI.
- `build-k2s-artifacts.yml` assembles offline package.
- `build-docs-next.yml` builds MkDocs site.
- `ci-reuse-checks.yml` SPDX/license compliance.
- `ci-unit-tests.yml` runs test suites (PowerShell / Go where applicable).
When modifying build steps, mirror variables & caching patterns used in existing workflows.

## 8. Testing Strategy
- PowerShell: unit-like tests live in module folders or `test/*.ps1` (see `addons.module.unit.tests.ps1`). Prefer parameterized helper functions for testability.
- Go: standard `*_test.go` files under related package directories.
- Avoid flaking Hyper-V dependent tests in CI—mock or guard with environment checks.

## 9. Security & Offline
- Never introduce code that silently pulls images or packages at runtime without explicit user action—offline reproducibility is a core promise.
- Large artifacts (VHDX, rootfs tarballs, MSI, WindowsNodeArtifacts.zip) are excluded from delta content; maintain the skip list in one place.
- Always sanitize zip extraction targets (already implemented—follow that pattern for any new archival logic).

## 10. Logging & Diagnostics
- Prefix category tags in logs: `[DebPkg]`, `[Expand]`, `[Hash]`, `[StageCleanup]`, etc. Follow existing style for new subsystems.
- On guest operations: gather diagnostics when expected artifacts are missing instead of failing silently.

## 11. Adding New Automation
When adding a new packaging / diff feature:
1. Put core logic in `New-...Methods.ps1` helper file.
2. Reference via dot-sourcing from orchestrator script.
3. Reuse phase timing & logging helpers.
4. Update or create manifest JSON with new metadata fields (keep camelCase keys consistent).

## 12. Style & Quality
- Preserve existing file headers & SPDX identifiers.
- Do not rename public functions consumed by scripts unless updating all call sites.
- PSScriptAnalyzer: avoid automatic variable assignment, prefer approved verbs; add suppressions only with justification in a comment.

## 13. Typical Commands (Local Dev)
- Build CLI (Go): `go build ./k2s/cmd/k2s` (respect existing Go module).
- Run delta packaging: `powershell -File lib/scripts/k2s/system/package/New-K2sDeltaPackage.ps1 ...`.
- Serve docs locally: `mkdocs serve` (ensure python + mkdocs installed).

## 14. When Unsure
Prefer searching existing examples (addon scripts, helper functions) before inventing new patterns. Keep new code incremental and testable.

---
If a needed pattern isn’t described here, surface a question in PR or propose a minimal extension and document it in this file.
