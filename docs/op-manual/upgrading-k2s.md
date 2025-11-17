<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Upgrading *K2s*

This guide explains how to upgrade an existing *K2s* cluster in-place to a newer released version using the `k2s system upgrade` command.

## Versioning
*K2s* release versions follow semantic versioning: `MAJOR.MINOR.PATCH` (see the [Releases page](https://github.com/Siemens-Healthineers/K2s/releases){target="_blank"}).

Supported upgrade path:
- Standard path: upgrade only from `MINOR-1` to the next `MINOR` within the same `MAJOR` (e.g. `1.4.x` → `1.5.y`).
- Skipping multiple minor versions: perform sequential upgrades through each intermediate minor release.
- Using `--force` (or `-f` if supported): attempts a direct upgrade between any two versions, but only a subset of combinations are continuously tested.

Recommendation: If the currently installed version is several minor releases behind, back up persistent data (application volumes, etc.) before proceeding or use a staging environment to validate.

Upgrade support is available starting from *K2s* `v1.1.0`.

<figure markdown="span">
  ![Cluster Upgrade](assets/Upgrade.png){ loading=lazy }
  <figcaption>K2s Cluster Upgrade Versioning Semantics</figcaption>
</figure>

## Upgrade Procedure
!!! info
  The upgrade process re-installs the cluster binaries, then migrates (exports/imports) Kubernetes resources and re-enables addons.

1. Extract the new *K2s* release package into a directory (e.g. `C:\k2s\v1.5.0`).
2. Open an elevated (Administrator) PowerShell or command prompt in that directory.
3. Run the upgrade command:
   ```console
   k2s system upgrade
   ```

### Common Flags (please check all possible flags on the cli)

| Flag | Purpose |
|------|---------|
| `-d` | Delete previously cached artifacts after upgrade (cleans local cache). |
| `-c <file>` | Supply a new configuration file to override existing cluster settings (memory, CPU, storage…). |
| `-p <http-proxy>` | Use the specified HTTP proxy for any required network access during the upgrade. |
| `--force` | Attempt upgrade even if skipping multiple minor versions. Use with caution; take a backup first. |

Examples:
```console
# Override settings using a new config
k2s system upgrade -c my-settings.yaml

# Use proxy and remove cached artifacts after success
k2s system upgrade -p http://proxy.local:8080 -d

# Force upgrade across multiple minor jumps
k2s system upgrade --force
```

### Configuration Override
If you omit `-c`, the previous cluster's effective settings (memory, CPU, storage paths) are reused. To change them during an upgrade, provide a config file as described in [Installing Using Config Files](installing-k2s.md#installing-using-config-files).

### What the Command Does
Internally the following high‑level steps are performed:
1. Export all existing workloads (cluster‑scoped resources and namespaced resources).
2. Persist addon state (which addons are enabled and their data/persistence volumes).
3. Uninstall the existing cluster components.
4. Install the new version from the extracted package.
5. Import previously exported workloads.
6. Re-enable addons and restore their persisted data.
7. Verify workload health (basic readiness checks).
8. Final cluster availability validation.

### Rollback Considerations
There is no automatic rollback. If an upgrade fails:
- Review logs under the K2s log directory.
- Re-run with increased verbosity (if supported) or `--force` only after assessing the cause.
- If recovery is not feasible, you can reinstall the previous version then import a backup (if you captured one beforehand) or re-run your deployment manifests.

### Backups (Recommended)
Before upgrading across more than one minor version, back up:
- Application persistent volumes (if external, ensure snapshots exist).
- Custom configuration files and secrets (outside of version-controlled items).

### Proxy Usage
If your environment requires HTTP(S) proxy access, specify it with `-p`. Ensure the proxy allows access to any required artifact repositories; otherwise offline packages should include all needed assets.

### After Upgrade
Validate cluster:
```console
kubectl get nodes
kubectl get pods -A
```
Check addon status:
```console
k2s addons status
```
If any workload fails readiness, inspect its namespace events and logs before proceeding with further changes.