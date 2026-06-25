<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# GitOps Addon-Sync Implementation Guide

## 1. Feature Overview

K2s addon-sync enables continuous delivery of Kubernetes addons via FluxCD or ArgoCD.
When upstream addon OCI artifacts change (digest change), addon-sync automatically
updates the local cluster by invoking addon lifecycle scripts from the extracted addon
content on the host.

Two delivery paths are supported:

- FluxCD: per-addon `OCIRepository` + `Kustomization` pipeline
- ArgoCD: periodic digest polling via `addon-sync-poller` CronJob

Both paths converge on the same HostProcess processor script:
[addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1](../../addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1)

Key guarantee: operations are deterministic and offline-capable. No implicit runtime
downloads are introduced by addon-sync itself, and stateful data is guarded against
GitOps prune/cascade-delete for protected PV/PVC resources.

## 2. CLI Contract

### Export Flags

The `k2s addons export` command supports:

- `--omit-images` (default: `false`)
  - Semantics: when set, skip image acquisition in export output.
  - Mapping: this is inverted into PowerShell `-AcquireImages` behavior.
  - Example:

```console
k2s addons export registry -d my-package.oci --omit-images
```

- `--omit-packages` (default: `false`)
  - Semantics: when set, skip package acquisition in export output.
  - Example:

```console
k2s addons export registry -d my-package.oci --omit-packages
```

Rationale for inversion:

- CLI UX is include-by-default with explicit omit flags.
- PowerShell export wiring uses acquisition semantics.
- The CLI layer translates between those models.

Code location:
[k2s/cmd/k2s/cmd/addons/export/export.go](../../k2s/cmd/k2s/cmd/addons/export/export.go#L174)

## 3. Backoff Policy: Fail-Visible, Digest-Keyed

### Overview

When sync fails (for example, during `Update.ps1`), addon-sync records a digest-keyed
failure state and uses exponential backoff. Retries are skipped until:

1. Backoff window expires, or
2. A different digest is detected.

This avoids hammering repeated failures while still allowing fast recovery on genuine
upstream change.

### Failure State Tracking

Storage:

- `.addon-sync-digests/<addon-name>.failure`

Schema:

```json
{
  "CurrentDigest": "sha256:xyz...",
  "AttemptCount": 2,
  "LastAttemptUtc": "2026-06-23T10:15:30.1234567Z"
}
```

### Backoff Window Formula

$$
\operatorname{backoffMinutes} = \min(2^{\operatorname{attemptCount}}, 60)
$$

Examples:

- Attempt 1: 2 minutes
- Attempt 2: 4 minutes
- Attempt 3: 8 minutes
- Attempt 4: 16 minutes
- Attempt 5: 32 minutes
- Attempt 6+: 60 minutes (cap)

### Auto-Recovery on Digest Change

If a new digest appears while currently in backoff for an older digest:

- backoff is bypassed immediately,
- sync proceeds,
- success clears failure state,
- a new failure re-creates failure state with `AttemptCount = 1` for the new digest.

### Backup Retention Rule

During `ApplyIfEnabled` lifecycle:

- if `Backup.ps1` exists but fails, addon-sync aborts the update lifecycle before
  `Update.ps1` runs (safe-fail behavior, no unprotected update).
- if `Update.ps1` fails and `Restore.ps1` is missing, backup is retained at
  `.addon-sync-backups/<addon-name>/<timestamp>/` for manual recovery.
- if restore is possible and attempted, temporary backup is cleaned afterward.

Code locations:

- [addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1](../../addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1#L714)
- [addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1](../../addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1#L619)

## 4. Update.ps1 Requirement

Requirement:

- Addons that must support automatic in-place update from addon-sync should provide
  `Update.ps1`.

Behavior details:

- `Update.ps1` missing: addon-sync logs skip for update lifecycle and continues.
- `Update.ps1` present and succeeds: addon version is updated in `setup.json`.
- `Update.ps1` present and fails: sync is marked failed, failure state enters backoff.

Example shape:

```powershell
# addons/myaddon/Update.ps1
param(
    [string]$Namespace,
    [string]$ChartVersion,
    [string]$DeploymentVersion
)

$current = kubectl get deployment -n $Namespace myapp -o jsonpath='{.spec.template.spec.containers[0].image}'

helm upgrade myapp myrepo/myapp --version $ChartVersion -n $Namespace

kubectl wait --for=condition=Available deployment/myapp -n $Namespace --timeout=120s
```

Lifecycle implementation:
[addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1](../../addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1#L536)

## 5. Security and Hardening

### ExecutionPolicy

Addon-sync uses `RemoteSigned` (not `Bypass`) when launching PowerShell in both
Flux and Argo delivery manifests.

Deployments:

- [addons/common/manifests/addon-sync/gitops-sync/sync-job.yaml](../../addons/common/manifests/addon-sync/gitops-sync/sync-job.yaml#L77)
- [addons/common/manifests/addon-sync/argocd/addon-sync-poller.yaml](../../addons/common/manifests/addon-sync/argocd/addon-sync-poller.yaml#L77)

### Status ConfigMap Patching

Sync status is written via `kubectl patch configmap addon-sync-status` in the
`k2s-addon-sync` namespace:

- [addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1](../../addons/common/manifests/addon-sync/base/scripts/Sync-Addons.ps1#L689)

Current addon-sync base manifest ships the service account and hardening control,
and does not introduce wildcard RBAC objects in addon-sync manifests:

- [addons/common/manifests/addon-sync/base/rbac.yaml](../../addons/common/manifests/addon-sync/base/rbac.yaml)

### ServiceAccount Token Hardening

`automountServiceAccountToken` is set to `false`.

- [addons/common/manifests/addon-sync/base/rbac.yaml](../../addons/common/manifests/addon-sync/base/rbac.yaml#L18)

## 6. E2E Test Coverage

### Determinism Tests

Location:
[k2s/test/e2e/addons/gitopssync/determinism_test.go](../../k2s/test/e2e/addons/gitopssync/determinism_test.go)

Coverage:

- repeated exports with unchanged inputs yield identical manifest digest,
- config digest remains stable,
- sync-content hash remains stable.

### FluxCD Suite Coverage

Location:
[k2s/test/e2e/addons/rollout/fluxcd/gitops-sync/gitops_sync_fluxcd_test.go](../../k2s/test/e2e/addons/rollout/fluxcd/gitops-sync/gitops_sync_fluxcd_test.go)

Coverage includes:

1. Initial sync and successful processing (`Synced: 1`)
2. No-op behavior on unchanged digest
3. Forced re-sync after digest override
4. Lifecycle failure path with failed status propagation
5. Backup gate unit coverage (`Backup.ps1` failure aborts `Update.ps1`)

### ArgoCD Suite Coverage

Location:
[k2s/test/e2e/addons/rollout/argocd/gitops-sync/gitops_sync_argocd_test.go](../../k2s/test/e2e/addons/rollout/argocd/gitops-sync/gitops_sync_argocd_test.go)

Coverage mirrors Flux behavior and explicitly includes apply-if-enabled
initial/no-op/forced re-sync scenarios.

### Manifest Data-Safety Coverage

Location:
[addons/addon-sync.unit.tests.ps1](../../addons/addon-sync.unit.tests.ps1)

Coverage includes:

1. Protected stateful PV/PVC manifests include Flux anti-prune annotation:
  `kustomize.toolkit.fluxcd.io/prune: disabled`
2. Protected stateful PV/PVC manifests include Argo anti-delete/prune sync option:
  `argocd.argoproj.io/sync-options: Prune=false,Delete=false`
3. Protected PV manifests enforce `persistentVolumeReclaimPolicy: Retain`

## 7. Offline Guarantees

Addon-sync keeps K2s offline-first behavior:

1. No implicit runtime package/image download is introduced by addon-sync logic.
2. Same addon content and digest yield stable exported artifacts.
3. Update logic is explicit and auditable through addon scripts and logs.
4. Failure state is persisted and visible via digest failure files plus sync logs.

Status reporting is also written to `addon-sync-status` ConfigMap for operator
visibility.

## 8. Typical Workflow

### Developer Workflow: Addon Onboarding for addon-sync

1. Create addon folder in `addons/<name>/`.
2. Add manifests in `addons/<name>/manifests/`.
3. Implement `Enable.ps1`, `Disable.ps1`, `Get-Status.ps1`.
4. Implement `Update.ps1` if automatic updates are required.
5. Validate addon locally.
6. Export and verify deterministic output.

```console
k2s addons enable myfeature
k2s addons export myfeature -d test.oci
```

Note: this is the addon export CLI, not the system package export command.

### Operator Workflow: GitOps Delivery

1. Deploy rollout integration (FluxCD or ArgoCD) with addon-sync manifests.
2. Register/configure addon source.
3. Monitor sync status and job logs.
4. On failure, inspect logs and `.addon-sync-digests/*.failure` on host.
5. Retry via digest change (or after backoff expiry).

Useful commands:

```console
kubectl get configmap addon-sync-status -n k2s-addon-sync
kubectl get jobs -n k2s-addon-sync --sort-by=.metadata.creationTimestamp
kubectl logs -n k2s-addon-sync -l app.kubernetes.io/component=poller --tail=100
```

## 9. Troubleshooting

### "addon-sync skipped: backoff active"

- Previous sync failed for the same digest.
- Wait for backoff expiry, or publish a new digest to trigger immediate retry.

### "Update.ps1 not found"

- Addon is synced to disk but has no automatic update lifecycle.
- Add `Update.ps1` to enable in-place update behavior.

### "Backup retained in .addon-sync-backups"

- `Update.ps1` failed and no `Restore.ps1` was available.
- Inspect retained backup, fix root cause, retry with new digest.

### "Backup failed - aborting update (no recovery point)"

- `Backup.ps1` exists but returned an error.
- addon-sync intentionally aborts before `Update.ps1` to avoid unprotected data changes.
- Fix backup logic and retry on the next poll or with a new digest.

## 10. Future Enhancements

- Scheduled/operator-tunable backoff reset policies.
- Optional automatic rollback orchestration for failed updates.
- Metrics export for retries, failures, and backoff windows.
- Extended GitOps source modes where needed.

## Requirements Met

1. Replaced stale text with implemented digest-keyed backoff behavior.
2. Documented security hardening: `RemoteSigned`, token automount hardening,
   and status patch behavior.
3. Documented `Update.ps1` role, invocation context, and failure handling.
4. Added FluxCD/ArgoCD parity and determinism test coverage references.
5. Documented offline guarantees and failure transparency.
6. Added troubleshooting guidance for operators.
7. Added direct links to code and tests.
