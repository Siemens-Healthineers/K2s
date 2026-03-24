<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Dashboard Addon (Headlamp) — Testing Checklist

This document covers **all** testing required before raising a PR for the Headlamp dashboard addon migration (`kubernetes-sigs/headlamp`).

---

## How to run all automated tests

```powershell
# Unit tests (PowerShell / Pester)
.\test\execute_all_tests.ps1 -Tags "unit","dashboard"

# E2E tests — run from k2s/ directory (go.mod lives there)
cd C:\ws\K2s\k2s
go test ./test/e2e/addons/dashboard/...              -v -timeout 30000s -count=1 -tags acceptance
go test ./test/e2e/addons/dashboard/backuprestore/... -v -timeout 30000s -count=1 -tags acceptance
go test ./test/e2e/addons/dashboard/securityenhanced/ -v -timeout 30000s -count=1 -tags acceptance
go test ./test/e2e/addons/dashboard/exportimport/...  -v -timeout 30000s -count=1 -tags acceptance
```

> **Important:** All addons must be **disabled** before running any e2e suite.  
> `BeforeSuite` fails with `"All addons should be disabled"` if any addon is still enabled.

---

## 1. Unit Tests (Automated — CI)

### 1.1 `dashboard.module.psm1`

Run:
```powershell
Invoke-Pester addons\dashboard\dashboard.module.unit.tests.ps1 -Tag 'unit'
```

| Test | Expected |
|------|----------|
| `Get-HeadlampManifestsDirectory` returns path ending with `\manifests\headlamp` | Pass |
| `Get-HeadlampChartDirectory` returns path ending with `\manifests\chart` | Pass |
| `Wait-ForHeadlampAvailable` calls `Wait-ForPodCondition` with label `app.kubernetes.io/name=headlamp`, namespace `dashboard`, timeout 200s | Pass |
| `Wait-ForHeadlampAvailable` returns `$true` when pod becomes ready | Pass |
| `Wait-ForHeadlampAvailable` returns `$false` when pod does not become ready | Pass |
| `Write-HeadlampUsageForUser` writes multiple log messages via `Write-Log` | Pass |
| `Write-HeadlampUsageForUser` mentions `Headlamp` | Pass |
| `Write-HeadlampUsageForUser` mentions `svc/headlamp` and port `4466` | Pass |
| `Write-HeadlampUsageForUser` mentions `localhost:4466/dashboard/` | Pass |
| `Write-HeadlampUsageForUser` mentions `token login screen` | Pass |
| `Write-HeadlampUsageForUser` does NOT mention `kubernetes-dashboard`, `kong-proxy`, or port `8443` | Pass |
| `Write-HeadlampUsageForUser` mentions `k2s.cluster.local/dashboard` | Pass |
| `Write-HeadlampUsageForUser` mentions `create token headlamp` | Pass |
| Module exports `Get-HeadlampManifestsDirectory` | Pass |
| Module exports `Get-HeadlampChartDirectory` | Pass |
| Module exports `Wait-ForHeadlampAvailable` | Pass |
| Module exports `Write-HeadlampUsageForUser` | Pass |
| Module does NOT export old functions (`Get-HeadlampConfig`, `Test-SecurityAddonAvailability`) | Pass |
| Linkerd null-safety: deployment with no `annotations` object → `linkerd.io/inject` is `$null` | Pass |
| Linkerd null-safety: deployment with `null` annotations → `linkerd.io/inject` is `$null` | Pass |
| Linkerd null-safety: deployment with annotation `enabled` → detected correctly | Pass |
| Linkerd null-safety: deployment with empty annotations `{}` → `linkerd.io/inject` is `$null` | Pass |
| Linkerd else-branch: annotation `$null` → no patch applied | Pass |
| Linkerd else-branch: annotation `enabled` → remove patch applied | Pass |

### 1.2 `Get-Status.ps1` — JSON array serialization fix

| Behaviour | Expected |
|-----------|----------|
| `Get-Status.ps1` returns `$prop, $prop` (two values) → PowerShell serializes as JSON array `[]` not object `{}` | Pass |
| `k2s addons status dashboard -o json` — `props` field parses as `[]AddonStatusProp` without unmarshal error | Pass |

### 1.3 `addons.module.psm1` — ingress functions

Run:
```powershell
Invoke-Pester addons\addons.module.unit.tests.ps1 -Tag 'unit'
```

| Test | Expected |
|------|----------|
| `Remove-IngressForNginx` — neither dir exists → no kubectl call | Pass |
| `Remove-IngressForNginx` — only standard dir exists → deletes `ingress-nginx/` only | Pass |
| `Remove-IngressForNginx` — only secure dir exists → deletes `ingress-nginx-secure/` only | Pass |
| `Remove-IngressForNginx` — both dirs exist → deletes both | Pass |
| `Remove-IngressForNginx` — passes `--ignore-not-found` to kubectl | Pass |
| `Remove-IngressForNginx` — no addon specified → throws | Pass |
| `Remove-IngressForTraefik` — neither dir exists → no kubectl call | Pass |
| `Remove-IngressForTraefik` — only standard dir exists → deletes `ingress-traefik/` only | Pass |
| `Remove-IngressForTraefik` — only secure dir exists → deletes `ingress-traefik-secure/` only | Pass |
| `Remove-IngressForTraefik` — both dirs exist → deletes both | Pass |
| `Remove-IngressForTraefik` — passes `--ignore-not-found` to kubectl | Pass |
| `Remove-IngressForTraefik` — no addon specified → throws | Pass |
| `Remove-IngressForNginxGateway` — neither dir exists → no kubectl call | Pass |
| `Remove-IngressForNginxGateway` — only standard dir exists → deletes standard only | Pass |
| `Remove-IngressForNginxGateway` — only secure dir exists → deletes secure only | Pass |
| `Remove-IngressForNginxGateway` — both dirs exist → deletes both | Pass |
| `Remove-IngressForNginxGateway` — passes absolute path (not bare `ingress-nginx-gw`) to kubectl | Pass |
| `Remove-IngressForNginxGateway` — path contains addon directory name | Pass |
| `Remove-IngressForNginxGateway` — no addon specified → throws | Pass |
| `Update-IngressForTraefik` — no security → applies `ingress-traefik/` | Pass |
| `Update-IngressForTraefik` — Keycloak + secure dir exists → applies `ingress-traefik-secure/` | Pass |
| `Update-IngressForTraefik` — Hydra + secure dir exists → applies `ingress-traefik-secure/` | Pass |
| `Update-IngressForTraefik` — Keycloak + secure dir missing → falls back to `ingress-traefik/` | Pass |
| `Update-IngressForTraefik` — logs say `traefik` (not `nginx`) | Pass |
| `Update-IngressForTraefik` — logs `Successfully applied` | Pass |
| `Update-IngressForTraefik` — no addon specified → throws | Pass |
| `Update-IngressForNginxGateway` — no security → applies absolute path to `ingress-nginx-gw/` | Pass |
| `Update-IngressForNginxGateway` — Keycloak + secure dir exists → applies `ingress-nginx-gw-secure/` | Pass |
| `Update-IngressForNginxGateway` — Hydra + secure dir exists → applies `ingress-nginx-gw-secure/` | Pass |
| `Update-IngressForNginxGateway` — Keycloak + secure dir missing → falls back to standard | Pass |
| `Update-IngressForNginxGateway` — addon name not doubled in logs | Pass |
| `Update-IngressForNginxGateway` — logs `Successfully applied` | Pass |
| `Update-IngressForNginxGateway` — no addon specified → throws | Pass |

---

## 2. Manual Tests — Core Lifecycle

### 2.1 Basic Enable/Disable (no ingress)

```console
k2s addons enable dashboard -o
```

- [ ] `helm list -n dashboard` shows release `headlamp` with status `deployed`
- [ ] Headlamp deployment in namespace `dashboard` becomes available
- [ ] Pod label `app.kubernetes.io/name=headlamp` is present
- [ ] Service `headlamp` on port `4466` is present
- [ ] `kubectl get clusterrolebinding headlamp-admin` exists (applied from `headlamp-service-account.yaml`)
- [ ] `k2s addons status dashboard` shows `IsHeadlampRunning: true` and no error
- [ ] `k2s addons status dashboard -o json` → `props[0].Name=IsHeadlampRunning`, `props[0].Value=true`
- [ ] Enabling again → error: `"Addon 'dashboard' is already enabled"`

```console
k2s addons disable dashboard -o
```

- [ ] `helm list -n dashboard` shows no `headlamp` release (uninstalled)
- [ ] Namespace `dashboard` deleted
- [ ] `kubectl get clusterrolebinding headlamp-admin` → not found (deleted before helm uninstall)
- [ ] Addon removed from addons config
- [ ] `k2s addons status dashboard` shows addon as disabled
- [ ] Disabling again → error: `"Addon 'dashboard' is not enabled"`

### 2.2 Port-Forward Access

```console
k2s addons enable dashboard -o
kubectl port-forward svc/headlamp -n dashboard 4466:4466
```

- [ ] `http://localhost:4466/dashboard/` opens in browser
- [ ] Headlamp shows **token login screen** — expected and normal
- [ ] `kubectl -n dashboard create token headlamp --duration 24h` → token generated, login succeeds, cluster resources visible
- [ ] No 404 or redirect loops

---

## 3. Manual Tests — Ingress Integration

> Before each ingress test: ensure previous ingress is disabled.

### 3.1 Nginx Ingress

```console
k2s addons enable ingress nginx -o
k2s addons enable dashboard --ingress nginx -o
```

- [ ] Log shows `"Applying nginx ingress manifest for dashboard..."`
- [ ] Log shows `"Successfully applied ingress manifest for dashboard"`
- [ ] `https://k2s.cluster.local/dashboard/` opens and shows token login screen
- [ ] URL stays at `/dashboard/` (no rewrite loop)
- [ ] `kubectl get ingress -n dashboard` shows `dashboard-nginx-cluster-local`
- [ ] Headlamp UI renders and shows cluster resources after token login

```console
k2s addons disable dashboard -o
k2s addons disable ingress nginx -o
```

- [ ] Log shows `"Deleting nginx ingress manifest for dashboard..."`
- [ ] Namespace `dashboard` deleted cleanly

### 3.2 Traefik Ingress

```console
k2s addons enable ingress traefik -o
k2s addons enable dashboard --ingress traefik -o
```

- [ ] Log shows `"Applying traefik ingress manifest for dashboard..."` (says `traefik`, not `nginx`)
- [ ] Log shows `"Successfully applied ingress manifest for dashboard"`
- [ ] `https://k2s.cluster.local/dashboard/` opens and shows token login screen
- [ ] `kubectl get ingress -n dashboard` shows `dashboard-traefik-cluster-local`
- [ ] Headlamp UI renders after token login

```console
k2s addons disable dashboard -o
k2s addons disable ingress traefik -o
```

- [ ] Log shows `"Deleting traefik ingress manifest for dashboard..."`
- [ ] Namespace deleted cleanly

### 3.3 Nginx-GW Ingress

```console
k2s addons enable ingress nginx-gw -o
k2s addons enable dashboard --ingress nginx-gw -o
```

- [ ] Log shows `"Applying nginx ingress gateway manifest for dashboard..."`
- [ ] Log shows `"Successfully applied ingress manifest for dashboard"`
- [ ] `https://k2s.cluster.local/dashboard/` opens and shows token login screen
- [ ] `kubectl get httproute -n dashboard` shows `dashboard-nginx-gw-cluster-local`
- [ ] `kubectl get referencegrant -n nginx-gw` shows `dashboard-nginx-gw-ref-grant`
- [ ] Headlamp UI renders after token login

```console
k2s addons disable dashboard -o
k2s addons disable ingress nginx-gw -o
```

- [ ] Log shows `"Deleting gateway manifest for dashboard..."` for both standard and (if present) secure variants
- [ ] `kubectl get httproute -n dashboard` → no resources (namespace deleted)
- [ ] `kubectl get referencegrant -n nginx-gw` → `dashboard-nginx-gw-ref-grant` gone

### 3.4 Ingress Switch (Update scenario)

```console
k2s addons enable ingress nginx -o
k2s addons enable dashboard --ingress nginx -o
k2s addons disable ingress nginx -o
k2s addons enable ingress traefik -o
# The Update.ps1 is triggered; or call it manually:
&"addons\dashboard\Update.ps1" -PreferredIngress auto
```

- [ ] Old nginx ingress objects removed
- [ ] New traefik ingress objects created
- [ ] `https://k2s.cluster.local/dashboard/` reachable via traefik

---

## 4. Manual Tests — Metrics Integration

```console
k2s addons enable dashboard --enable-metrics -o
```

- [ ] Metrics addon is also enabled automatically
- [ ] Headlamp displays CPU/memory metrics for pods and nodes

```console
k2s addons enable metrics -o
k2s addons enable dashboard -o
```

- [ ] Same result — metrics visible in Headlamp

---

## 5. Manual Tests — Backup and Restore

### 5.1 Backup while enabled (with ingress)

```console
k2s addons enable ingress nginx -o
k2s addons enable dashboard --ingress nginx -o
k2s addons backup dashboard
```

- [ ] Backup succeeds (exit 0)
- [ ] Backup zip created (note the path from output)
- [ ] Extract zip and inspect `backup.json`:
  - [ ] Contains `"ingress": "nginx"` (or equivalent field)
  - [ ] Contains `"k2sVersion"` field
  - [ ] Does NOT contain old fields like `helmReleaseName`, `chart`, `kong`

### 5.2 Backup/Restore full cycle

```console
# (After 5.1 — backup zip already exists)
k2s addons disable dashboard -o
k2s addons disable ingress nginx -o
k2s addons enable ingress nginx -o
k2s addons restore dashboard -f <backup-zip-path> -o
```

- [ ] Restore re-enables dashboard (exit 0)
- [ ] Headlamp deployment becomes available
- [ ] Nginx ingress restored: `kubectl get ingress -n dashboard` shows `dashboard-nginx-cluster-local`
- [ ] `https://k2s.cluster.local/dashboard/` reachable
- [ ] `k2s addons status dashboard` shows `IsHeadlampRunning: true`

### 5.3 Backup/Restore without ingress

```console
k2s addons enable dashboard -o
k2s addons backup dashboard
k2s addons disable dashboard -o
k2s addons restore dashboard -f <backup-zip-path> -o
```

- [ ] Restore re-enables dashboard without ingress
- [ ] `kubectl get ingress -n dashboard` → no resources
- [ ] Port-forward still works: `http://localhost:4466/dashboard/`

### 5.4 Backup/Restore traefik ingress

```console
k2s addons enable ingress traefik -o
k2s addons enable dashboard --ingress traefik -o
k2s addons backup dashboard
k2s addons disable dashboard -o
k2s addons restore dashboard -f <backup-zip-path> -o
```

- [ ] Traefik ingress restored: `kubectl get ingress -n dashboard` shows `dashboard-traefik-cluster-local`
- [ ] `https://k2s.cluster.local/dashboard/` reachable via traefik

### 5.5 Backup/Restore error cases

```console
k2s addons disable dashboard -o
k2s addons backup dashboard
```
- [ ] Error: `"not enabled"` or similar (non-zero exit)

```console
k2s addons restore dashboard -f C:\nonexistent.zip
```
- [ ] Error: `"not found"` (non-zero exit)

```console
k2s addons enable dashboard -o
k2s addons restore dashboard -f <valid-zip>
```
- [ ] Error: `"disable"` — addon must be disabled before restore (non-zero exit)

---

## 6. E2E Tests (Automated — Acceptance)

> **Prerequisites:**  
> - k2s system is running  
> - All addons are disabled  
> - Run all commands from `C:\ws\K2s\k2s\` (where `go.mod` lives)

### 6.1 Main Dashboard Suite

```console
cd C:\ws\K2s\k2s
go test ./test/e2e/addons/dashboard/... -v -timeout 30000s -count=1 -tags acceptance
```

Or run per package:
```console
go test -v -timeout=30000s -count=1 . 
```
(from `C:\ws\K2s\k2s\test\e2e\addons\dashboard\`)

| Test | Expected |
|------|----------|
| `status command` — default output shows `disabled` message | Pass |
| `status command` — JSON output: `name=dashboard`, `enabled=false`, `props=null` | Pass |
| `disable` when already disabled → failure with "already disabled" | Pass |
| `enable` (no ingress) → deployment available, pod ready | Pass |
| Port-forward `svc/headlamp 4466:4466` → `GET http://localhost:4466/dashboard/` returns HTTP 200 | Pass |
| `enable` when already enabled → failure with "already enabled" | Pass |
| `status` when enabled → `IsHeadlampRunning=true`, correct message, no unmarshal error | Pass |
| `enable --ingress traefik` → `https://k2s.cluster.local/dashboard/` returns HTTP 200 | Pass |
| `enable --ingress nginx` → `https://k2s.cluster.local/dashboard/` returns HTTP 200 | Pass |
| `enable --ingress nginx-gw` → `https://k2s.cluster.local/dashboard/` returns HTTP 200 | Pass |

### 6.2 Backup/Restore E2E Suite

```console
go test ./test/e2e/addons/dashboard/backuprestore/... -v -timeout 30000s -count=1 -tags acceptance
```

| Test | Expected |
|------|----------|
| Backup while disabled → failure with "not enabled" | Pass |
| Restore with non-existent file → failure with "not found" | Pass |
| Enable → backup succeeds, zip exists on disk | Pass |
| Restore while enabled → failure with "disable" | Pass |
| Disable → restore from backup → deployment available | Pass |

### 6.3 Security Enhanced (Linkerd) E2E Suite

```console
go test ./test/e2e/addons/dashboard/securityenhanced/... -v -timeout 30000s -count=1 -tags acceptance
```

> Requires Windows build ≥ 20348 (Windows Server 2022 / Windows 11).  
> Verify: `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild`

| Test | Expected |
|------|----------|
| Security enhanced enabled first → dashboard enabled → pod shows `2/2` (Linkerd sidecar injected) | Pass |
| Linkerd labels present on pod: `linkerd.io/control-plane-ns=linkerd` | Pass |
| Dashboard enabled first → security enhanced enabled → pod shows `2/2` (auto-adapt via Update.ps1) | Pass |
| Linkerd labels present after auto-adapt | Pass |

### 6.4 Export/Import E2E Suite

```console
go test ./test/e2e/addons/dashboard/exportimport/... -v -timeout 30000s -count=1 -tags acceptance
```

> Requires internet access for OCI image verification.

| Test | Expected |
|------|----------|
| `manifests/chart/` contains exactly one `.tgz` file (`headlamp-x.y.z.tgz`) | Pass |
| `manifests/chart/values.yaml` exists (required for `helm template` image discovery) | Pass |
| Export produces a versioned OCI tar file | Pass |
| Exported OCI structure contains dashboard addon folder | Pass |
| All expected resources exported (images, packages) | Pass |
| Images available after import | Pass |
| All addon files present at correct paths after import | Pass |
| Relative path import works | Pass |

---

## 7. Manual Tests — Linkerd Service Mesh

> **Prerequisites:**  
> Windows build ≥ 20348. Check: `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild`  
> Only `--type enhanced` installs Linkerd. `--type basic` (default) does NOT.

### 7.1 Security (Linkerd) enabled BEFORE dashboard

```console
k2s addons enable security --type enhanced -o
kubectl get pods -n linkerd
k2s addons enable dashboard -o
kubectl get pods -n dashboard
kubectl get pods -n dashboard --show-labels
```

- [x] Linkerd pods running: `linkerd-destination 4/4`, `linkerd-identity 2/2`, `linkerd-proxy-injector 2/2` *(verified 2026-03-16)*
- [x] Log: `"[Dashboard] Updating Headlamp addon to be part of service mesh"` *(verified 2026-03-16)*
- [x] Log: `"deployment.apps/headlamp patched"` *(verified 2026-03-16)*
- [x] Log: `"deployment \"headlamp\" successfully rolled out"` *(verified 2026-03-16)*
- [x] `kubectl get pods -n dashboard` shows `2/2 Running` *(verified 2026-03-16)*
- [x] Pod labels include `linkerd.io/control-plane-ns=linkerd` *(verified 2026-03-16)*
- [ ] `k2s addons status dashboard` shows `IsHeadlampRunning: true`
- [ ] Port-forward still works: `http://localhost:4466/dashboard/` shows token login screen

```console
k2s addons disable dashboard -o
k2s addons disable security -o
```
- [ ] Both addons disabled cleanly

### 7.2 Dashboard enabled BEFORE security (Linkerd)

```console
k2s addons enable dashboard -o
kubectl get pods -n dashboard  # expect 1/1
k2s addons enable security --type enhanced -o
kubectl get pods -n dashboard  # expect 2/2 after security triggers Update.ps1
```

- [ ] Initially: `kubectl get pods -n dashboard` shows `1/1` (no sidecar)
- [ ] After security enable: `Update.ps1` called automatically, headlamp patched with `linkerd.io/inject: enabled`
- [ ] `kubectl get pods -n dashboard` shows `2/2 Running`
- [ ] Pod labels include `linkerd.io/control-plane-ns=linkerd`

```console
k2s addons disable dashboard -o
k2s addons disable security -o
```
- [ ] Both addons disabled cleanly

### 7.3 Linkerd annotation removal after security disable

```console
k2s addons enable security --type enhanced -o
k2s addons enable dashboard -o
# Verify 2/2 pods:
kubectl get pods -n dashboard
k2s addons disable security -o
k2s addons disable dashboard -o
k2s addons enable dashboard -o
kubectl get pods -n dashboard
```

- [ ] After re-enabling dashboard without Linkerd: `kubectl get pods -n dashboard` shows `1/1`
- [ ] Log shows `Update.ps1` removed `linkerd.io/inject` annotation (else-branch taken)
- [ ] No Linkerd labels on pod: `kubectl get pods -n dashboard --show-labels`

### 7.4 Basic security (no Linkerd) — no injection

```console
k2s addons enable security -o
k2s addons enable dashboard -o
kubectl get pods -n dashboard
kubectl get pods -n linkerd
```

- [x] No `linkerd` namespace *(verified 2026-03-16)*
- [x] `kubectl get pods -n dashboard` shows `1/1` (no sidecar injected) *(verified 2026-03-16)*
- [x] Dashboard accessible via port-forward *(verified 2026-03-16)*

```console
k2s addons disable dashboard -o
k2s addons disable security -o
```

---

## 8. Manual Tests — Security Addon with OIDC (Keycloak/Hydra)

```console
k2s addons enable ingress traefik -o
k2s addons enable security --type enhanced -o  # or whichever type enables Keycloak/Hydra
k2s addons enable dashboard --ingress traefik -o
```

- [ ] Log shows `"Applying secure traefik ingress manifest for dashboard..."` (KeyCloak/Hydra detected)
- [ ] `kubectl get ingress -n dashboard` shows traefik-secure ingress object
- [ ] `https://k2s.cluster.local/dashboard/` redirects to OIDC login page

```console
k2s addons disable dashboard -o
k2s addons disable security -o
k2s addons disable ingress traefik -o
```

- [ ] Cleanup is clean

---

## 9. Manual Tests — Namespace Sanity Check

After `k2s addons enable dashboard -o`:

```console
kubectl get all -n dashboard
helm list -n dashboard
```

- [ ] `helm list -n dashboard` shows release `headlamp`, chart `headlamp-0.40.1`, status `deployed`
- [ ] Only `headlamp` deployment, `headlamp` service, `headlamp-*` pod — no `kong`, `auth`, `api`, `web`, `metrics-scraper` resources
- [ ] Only service on port `4466` (no port `8443`, no port `8000`)
- [ ] `kubectl get clusterrolebinding headlamp-admin` → exists (from `headlamp-service-account.yaml`, applied after helm install)
- [ ] `kubectl get serviceaccount headlamp -n dashboard` → exists (created by Helm chart)
- [ ] `kubectl get namespace dashboard` → exists with label `app.kubernetes.io/name=headlamp`

---

## 10. Argo Workflow Tests — `update-addons-dashboard.yaml`

> These tests verify the Argo workflow that automatically monitors Headlamp for new versions and raises PRs.

### 10.1 Workflow Structure Validation

Inspect the workflow YAML manually:

- [ ] `metadata.name` is `update-addons-dashboard`
- [ ] `entrypoint` is `dashboard-update-pipeline`
- [ ] Arguments contain `headlamp-repo-owner: kubernetes-sigs` and `headlamp-repo-name: headlamp` (NOT `kubernetes-retired/dashboard`)
- [ ] Arguments do NOT contain `dashboard-repo-owner`, `dashboard-repo-name`, `kong-image-name` (old fields removed)
- [ ] `serviceAccountName` is `github-automation-sa`
- [ ] Pipeline has exactly **4 steps**: `get-latest-headlamp-version` → `get-current-headlamp-version` → `compare-headlamp-versions` → `create-headlamp-update-pr`
- [ ] `compare-headlamp-versions` uses `templateRef: update-common / compare-and-decide`
- [ ] `create-headlamp-update-pr` step has `when: should-update == true` condition

### 10.2 `fetch-latest-headlamp-version` template

Manually trace the script logic:

- [ ] Calls GitHub API: `https://api.github.com/repos/kubernetes-sigs/headlamp/releases?per_page=15`
- [ ] Filters tags with regex `^v[0-9]+\.[0-9]+\.[0-9]+$` (rejects `-rc`, `-beta`, `-alpha` tags)
- [ ] Probes OCI registry: `https://ghcr.io/v2/headlamp-k8s/headlamp/manifests/$TAG` with `Accept: application/vnd.oci.image.manifest.v1+json`
- [ ] HTTP 200 → tag selected; non-200 → tries next release
- [ ] Writes result to `/tmp/version.txt` as `vX.Y.Z` (with `v` prefix)
- [ ] On failure (no image found) → writes `unknown` to `/tmp/version.txt` (does NOT exit 1 — allows workflow to proceed gracefully)

### 10.3 `fetch-current-headlamp-version` template

- [ ] Reads file `addons/dashboard/manifests/headlamp/headlamp.yaml` via GitHub API (`contents` endpoint)
- [ ] Decodes base64 content with `jq -r '.content' | base64 -d`
- [ ] Extracts version from line `image: ghcr.io/headlamp-k8s/headlamp:vX.Y.Z` using `grep -oE`
- [ ] Outputs `vX.Y.Z` (with `v` prefix) — same format as `fetch-latest-headlamp-version`
- [ ] Does NOT read from `Enable.ps1`, `values.yaml`, or any chart file (only `headlamp.yaml`)

### 10.4 `create-headlamp-update-pr` template

Trace what the script does when a new version is available (e.g. current=`v0.40.1`, new=`v0.41.0`):

**headlamp.yaml updates:**
- [ ] `sed` replaces `ghcr.io/headlamp-k8s/headlamp:v0.40.1` → `ghcr.io/headlamp-k8s/headlamp:v0.41.0`
- [ ] `sed` replaces `app.kubernetes.io/version: "0.40.1"` → `app.kubernetes.io/version: "0.41.0"` (no `v` prefix in labels)
- [ ] `sed` replaces `# Based on Headlamp v0.40.1` → `# Based on Headlamp v0.41.0` (in comment)
- [ ] Verification: `grep -q "headlamp-k8s/headlamp:v0.41.0"` — exits 1 if not found

**values.yaml update:**
- [ ] `sed` replaces `tag: "v0.40.1"` → `tag: "v0.41.0"` in `manifests/chart/values.yaml`
- [ ] `values.yaml` is staged with `git add` alongside `headlamp.yaml` and chart dir
- [ ] Commit message body mentions `image.tag in manifests/chart/values.yaml`

**Helm chart .tgz:**
- [ ] Downloads from `https://headlamp-k8s.github.io/headlamp/headlamp-0.41.0.tgz`
- [ ] On HTTP 200: removes `headlamp-0.40.1.tgz` and `headlamp-0.40.1.tgz.license`
- [ ] Places `headlamp-0.41.0.tgz` in `addons/dashboard/manifests/chart/`
- [ ] Creates `headlamp-0.41.0.tgz.license` with correct SPDX header
- [ ] On non-200 (download fails): logs WARNING, continues without updating `.tgz` (does NOT fail the workflow)

**Git / PR:**
- [ ] Branch name: `autoupdate/dashboard-headlamp-v0.41.0`
- [ ] Commit title: `build(deps): addon dashboard - update Headlamp to v0.41.0`
- [ ] Commit message body lists all changes (image, labels, comment, values.yaml tag, tgz)
- [ ] PR title matches commit title
- [ ] PR body mentions: old version, new version, `kubectl apply -k`, release notes URL, `kubernetes-sigs/headlamp/releases/tag/v0.41.0`
- [ ] PR labels: `["dependencies", "automated"]`
- [ ] Uses `github-credentials-approve` secret (not `github-credentials-fetch`)

### 10.5 No-op scenario (versions already in sync)

- [ ] When `current-version == latest-version`, `compare-and-decide` returns `should-update=false`
- [ ] `create-headlamp-update-pr` step is **skipped** (Argo `when` condition not met)
- [ ] Workflow exits cleanly with no PR created

### 10.6 Version format consistency

- [ ] Both `fetch-latest-headlamp-version` and `fetch-current-headlamp-version` output version with `v` prefix (e.g. `v0.40.1`)
- [ ] `create-headlamp-update-pr` strips `v` prefix correctly for:
  - Filenames: `headlamp-0.40.1.tgz` (no `v`)
  - Labels: `app.kubernetes.io/version: "0.40.1"` (no `v`)
  - Image tag: `ghcr.io/headlamp-k8s/headlamp:v0.40.1` (with `v`)
- [ ] `compare-and-decide` common template receives consistent format from both fetch steps

### 10.7 Workflow does NOT touch old dashboard artifacts

Verify the workflow has NO references to:
- [ ] `kubernetes-retired/dashboard` — not present
- [ ] `kubernetes-dashboard-X.Y.Z.tgz` — not present
- [ ] `kong` image — not present
- [ ] `values.yaml` tag fields (`dashboard-auth`, `dashboard-api`, `dashboard-web`, `dashboard-metrics-scraper`) — not present
- [ ] `Enable.ps1` chart filename reference — not present
- [ ] `build/bom/` updates — not present (BOM not updated by this workflow)

---

## 11. File Structure Verification

Verify the following files exist with correct content:

```console
dir addons\dashboard\manifests\headlamp\
dir addons\dashboard\manifests\chart\
dir addons\dashboard\manifests\ingress-nginx\
dir addons\dashboard\manifests\ingress-nginx-gw\
dir addons\dashboard\manifests\ingress-nginx-gw-secure\
dir addons\dashboard\manifests\ingress-traefik\
dir addons\dashboard\manifests\ingress-traefik-secure\
```

| File | Check |
|------|-------|
| `manifests/headlamp/headlamp.yaml` — image `ghcr.io/headlamp-k8s/headlamp:v0.40.1` | ✓ |
| `manifests/headlamp/headlamp.yaml` — args include `-in-cluster` and `-base-url=/dashboard` | ✓ |
| `manifests/headlamp/headlamp.yaml` — containerPort `4466` | ✓ |
| `manifests/headlamp/headlamp.yaml` — `imagePullPolicy: IfNotPresent` | ✓ |
| `manifests/headlamp/kustomization.yaml` — resources: `[headlamp.yaml]` | ✓ |
| `manifests/chart/headlamp-0.40.1.tgz` — exists (used by `helm install` in Enable.ps1 and `helm template` in export) | ✓ |
| `manifests/chart/headlamp-0.40.1.tgz.license` — exists with SPDX header | ✓ |
| `manifests/chart/values.yaml` — exists with `image.tag: "v0.40.1"` (used for both `helm install` and `helm template` image discovery) | ✓ |
| `manifests/chart/values.yaml.license` — exists with SPDX header | ✓ |
| `manifests/chart/headlamp-service-account.yaml` — ClusterRoleBinding `headlamp-admin` giving `cluster-admin` to `headlamp` SA (applied separately after `helm install`) | ✓ |
| `manifests/ingress-nginx/dashboard-ingress-nginx.yaml` — path `/dashboard/`, port `4466`, no `backend-protocol: HTTPS` annotation | ✓ |
| `manifests/ingress-nginx/kustomization.yaml` | ✓ |
| `manifests/ingress-nginx-gw/dashboard-nginx-gw.yaml` — `ReferenceGrant` in `nginx-gw` namespace + `HTTPRoute` in `dashboard` namespace | ✓ |
| `manifests/ingress-nginx-gw-secure/dashboard-nginx-gw.yaml` — `sectionName: https` on parentRef | ✓ |
| `manifests/ingress-nginx-gw-secure/dashboard-linkerd-policy.yaml` — Linkerd Server + ServerAuthorization | ✓ |
| `manifests/ingress-traefik/dashboard-ingress-traefik.yaml` — `traefik.ingress.kubernetes.io/router.tls: "true"` | ✓ |
| `manifests/ingress-traefik-secure/dashboard-ingress-traefik.yaml` — secure variant | ✓ |
| `addon.manifest.yaml` — `name: dashboard`, ingress flag values: `[none, nginx, nginx-gw, traefik]` | ✓ |
| `update-addons-dashboard.yaml` — `headlamp-repo-owner: kubernetes-sigs` (not `kubernetes-retired`) | ✓ |
| `update-addons-dashboard.yaml` — updates `values.yaml` `image.tag` in addition to `headlamp.yaml` | ✓ |
| NO `kubernetes-dashboard-*.tgz` or `kong` manifest files remain | ✓ |

---

## 12. SPDX License Compliance

```console
reuse lint
```

- [ ] All files under `addons/dashboard/` carry SPDX headers
- [ ] `manifests/headlamp/headlamp.yaml` — SPDX header present
- [ ] `manifests/chart/headlamp-0.40.1.tgz.license` — SPDX sidecar present
- [ ] `manifests/chart/values.yaml.license` — SPDX sidecar present
- [ ] `update-addons-dashboard.yaml` — SPDX header present
- [ ] `TESTING-CHECKLIST.md` — SPDX comment block present
- [ ] `reuse lint` exits 0 (no violations)

---

## 13. Pre-PR Checklist

Before raising the PR, confirm:

- [ ] All **unit tests pass**: `.\test\execute_all_tests.ps1 -Tags "unit","dashboard"` → green
- [ ] All **e2e tests pass** (sections 6.1–6.4) → green
- [ ] Manual tests **2.1, 2.2** complete (core lifecycle) — including `helm list -n dashboard` verification
- [ ] Manual tests **3.1, 3.2, 3.3** complete (all three ingress types)
- [ ] Manual tests **5.1–5.5** complete (backup/restore, including error cases)
- [ ] Manual tests **7.1, 7.2** complete (Linkerd injection both orderings)
- [ ] Argo workflow checks **10.1–10.7** complete — including `values.yaml` tag update check
- [ ] File structure check **section 11** complete — including `headlamp-service-account.yaml` and `values.yaml` with `image.tag`
- [ ] `reuse lint` passes (section 12)
- [ ] No references to old `kubernetes-retired/dashboard`, `kong`, `kubernetes-dashboard-*.tgz` in any changed file
- [ ] `values.yaml` `image.tag` matches `headlamp.yaml` image tag AND `manifests/chart/headlamp-X.Y.Z.tgz` version
- [ ] README.md updated for Headlamp (no old dashboard references)
