<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Manual Test Plan: GitOps Addon Deployment on Windows
**Test Date:** February 13, 2026  
**Target:** FluxCD (rollout) + monitoring addon + GitOps addon controller  
**Architecture:** FluxCD watches the OCI registry and signals readiness (trigger only).  
The controller always pulls directly from the registry via ORAS, preserving the full multi-layer OCI manifest.  
The controller watches OCIRepository CRs — when FluxCD detects a new digest, the controller automatically re-processes the addon (no manual patch needed).  
**Environment:** Clean Windows host → fresh K2s install → full GitOps flow  
**Namespace:** rollout

## System Requirements

- **OS:** Windows Server 2022+ or Windows 11 (Hyper-V capable)
- **Permissions:** Local Administrator (elevated PowerShell throughout)
- **Hardware:** ≥ 6 CPU cores, ≥ 8 GB free RAM, ≥ 50 GB free disk
- **BIOS:** CPU virtualization (VT-x / AMD-V) enabled
- **Software:** curl.exe ≥ 7.71.0, ssh.exe ≥ 8.x, PowerShell execution policy `RemoteSigned`
- **Conflicts:** Docker Desktop must NOT be running
- **VC Runtime:** Visual C++ Redistributable 2015-2022 installed (`choco install vcredist140 -y`)

---

## Phase 0: Clean State — Uninstall and Install K2s

> **All commands in this test plan require an Administrator (elevated) PowerShell terminal.**

### 0.1 Uninstall Existing K2s (if installed)

If K2s is currently installed, remove it completely to start from a known clean state.

```powershell
# Check if K2s is installed
k2s status
```

If K2s reports a running or stopped state, uninstall:

```powershell
# Full uninstall including offline binaries and VM images
k2s uninstall -d
```

If the uninstall reports issues, force a system reset:

```powershell
# Nuclear option: reset system to pre-K2s state
k2s system reset

# If networking artifacts remain, also reset networking (requires reboot)
k2s system reset network -f
Restart-Computer -Force
```

**After uninstall, verify clean state:**
```powershell
# Should return error or "not installed"
k2s status

# Verify no leftover Hyper-V VMs
Get-VM | Where-Object { $_.Name -like "*KubeMaster*" -or $_.Name -like "*kubemaster*" }

# Verify no leftover virtual switches
Get-VMSwitch | Where-Object { $_.Name -like "*k2s*" -or $_.Name -like "*KubeSwitch*" }

# Verify PATH is clean
$env:PATH -split ";" | Where-Object { $_ -like "*k2s*" }
```

Expected: No VMs, no virtual switches, no K2s entries in PATH

### 0.2 Install K2s Fresh

```powershell
# Navigate to the workspace root
cd C:\ws

# Install K2s with recommended resources for testing
# (Linux master VM + Windows worker node, Hyper-V based)
k2s install --master-memory 8GB --master-cpus 4 --master-disk 50GB
```

> **Note:** Installation takes 10-20 minutes. It provisions a Linux control-plane VM,
> configures networking, and sets up the Windows worker node.

**If behind a proxy:**
```powershell
k2s install --master-memory 8GB --master-cpus 4 --master-disk 50GB `
  --proxy http://your-proxy:port `
  --no-proxy localhost,127.0.0.1,.local
```

### 0.3 Verify Fresh Installation
```powershell
# Check K2s status
k2s status

# Verify nodes are Ready
kubectl get nodes -o wide

# Verify system pods
kubectl get pods -A
```

Expected:
- K2s reports `running` state
- Linux master node `Ready`
- Windows worker node `Ready`
- All system pods (kube-system, flannel, etc.) running

### 0.4 Verification Checklist
- [ ] Previous K2s fully uninstalled (or was not installed)
- [ ] Fresh K2s install completed without errors
- [ ] Both nodes show `Ready` status
- [ ] System pods healthy

---

## Phase 1: Enable Registry and Configure Nodes

### 1.1 Enable Registry Addon (Required First)
The local registry (`k2s.registry.local:30500`) must be running before building/pushing any images.
```powershell
k2s addons enable registry

# Verify registry is running
kubectl get pods -n registry
kubectl get svc -n registry

# Quick connectivity test
curl -k https://k2s.registry.local:30500/v2/_catalog
```

Expected: Registry pod running, `{"repositories":[]}` returned

### 1.2 Configure Insecure Registry on Linux Node
The Linux node (using CRI-O) needs to trust the local registry as insecure.

```powershell
# SSH to Linux master node
ssh -o StrictHostKeyChecking=no -i ~\.ssh\k2s\id_rsa remote@172.19.1.100

# Add registry to insecure registries list
sudo tee -a /etc/containers/registries.conf > /dev/null <<'EOF'

[[registry]]
location = "k2s.registry.local:30500"
insecure = true
EOF

# Restart CRI-O to apply changes
sudo systemctl restart crio

# Verify registry is accessible
curl -k http://k2s.registry.local:30500/v2/_catalog

# Test manual pull (this will fail if image doesn't exist yet, but tests connectivity)
sudo crictl pull --creds="" k2s.registry.local:30500/k2s/addon-controller-linux:latest 2>&1 || echo "Expected to fail if image not built yet"

# Exit SSH
exit
```

Expected: CRI-O restarted successfully, registry accessible from Linux node

### 1.3 Verification Checklist
- [ ] Registry addon enabled and pods running
- [ ] Registry accessible from Windows host
- [ ] Registry accessible from Linux node
- [ ] CRI-O restarted with insecure registry config

---

## Phase 2: Build Required Images

### 2.1 Build K2s Addon Controller Images

> **Note:** The controller images must be built and pushed to the local registry **before**
> enabling the rollout addon with `-g`. The `-g` flag deploys DaemonSets that pull
> `k2s.registry.local:30500/k2s/addon-controller-linux:latest` and
> `k2s.registry.local:30500/k2s/addon-controller-windows:latest`.
>
> **Go module path:** `addons/rollout/controller/pkg/controller/`

#### Build Windows Controller Image

The Windows image follows the K2s PreCompile approach (see [Building a Container Image](docs/user-guide/building-container-image.md)):
pre-compile the Go binary on the host, then package it into a minimal `nanoserver` image via `k2s image build --windows`.

```powershell
cd C:\ws

# Step 1: Pre-compile the controller binary for Windows
Push-Location addons\rollout\controller\pkg\controller
go build -o addon-controller.exe -ldflags="-s -w" ./cmd/main.go
Pop-Location

# Step 2: Build Windows container image (copies pre-compiled binary into nanoserver)
k2s image build `
  --input-folder "addons\rollout\controller\pkg\controller" `
  --dockerfile "addons\rollout\controller\Dockerfile.windows" `
  --windows `
  --image-name k2s.registry.local:30500/k2s/addon-controller-windows `
  --image-tag latest `
  -p -o

# Step 3: Clean up the pre-compiled binary
Remove-Item addons\rollout\controller\pkg\controller\addon-controller.exe -ErrorAction SilentlyContinue
```

**Verify:**
```powershell
nerdctl --namespace k8s.io images | Select-String "addon-controller-windows"
curl -k https://k2s.registry.local:30500/v2/k2s/addon-controller-windows/tags/list
```

#### Build Linux Controller Image

```powershell
cd C:\ws

# Build Linux image using existing Dockerfile (uses buildah on the master node)
k2s image build `
  --input-folder "addons\rollout\controller\pkg\controller" `
  --dockerfile "addons\rollout\controller\Dockerfile" `
  --image-name k2s.registry.local:30500/k2s/addon-controller-linux `
  --image-tag latest `
  -p -o
```

**Verify:**
```powershell
curl -k https://k2s.registry.local:30500/v2/k2s/addon-controller-linux/tags/list
ssh -o StrictHostKeyChecking=no -i ~\.ssh\k2s\id_rsa remote@172.19.1.100 'sudo crictl images | grep addon-controller'
```

### 2.2 Verification Checklist
- [ ] Windows controller image built and pushed
- [ ] Linux controller image built and pushed
- [ ] Both images visible in local registry

**Common Issues:**
- **`go build` fails during pre-compilation**: Ensure Go is installed on the host and `go.mod` dependencies are accessible. Run `go mod download` in the module directory first.
- **`addon-controller.exe` not found during Docker build**: The pre-compiled binary must exist in the input folder (build context) before running `k2s image build --windows`.
- **`go: no modules specified`**: Build context doesn't contain go.mod. Ensure `--input-folder` points to where go.mod exists (e.g., `addons\rollout\controller\pkg\controller`)
- **Registry push fails**: Ensure registry addon is enabled first (`k2s addons enable registry`)
- **`ErrImagePull` on Linux node**: Configure the registry as insecure in CRI-O (see Phase 1.2)
- **Optimistic concurrency conflict (`the object has been modified`)**: Both Linux and Windows controllers reconcile the same K2sAddon CR simultaneously. The controller code uses `retry.RetryOnConflict` with node-aware status merging to handle this. If you see these errors after rebuilding, verify the latest controller code is deployed.

---

## Phase 3: Enable FluxCD + GitOps Controller

### 3.1 Enable FluxCD with the GitOps Addon Controller

This single command deploys FluxCD **and** the GitOps addon controller (CRD, RBAC, DaemonSets):

```powershell
k2s addons enable rollout fluxcd -g
```

> **What `-g` / `--addongitops` does:** In addition to deploying FluxCD, it applies the K2sAddon CRD,
> RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding), and Linux + Windows controller DaemonSets
> to the `k2s-system` namespace. This replaces the need to manually `kubectl apply` each manifest.

**Wait for FluxCD to be ready:**
```powershell
kubectl get pods -n rollout --watch
```

Expected FluxCD pods:
- `helm-controller-*`
- `kustomize-controller-*`
- `notification-controller-*`
- `source-controller-*`

### 3.2 Verify FluxCD Installation
```powershell
# Check all pods are running
kubectl get pods -n rollout

# Check FluxCD components
kubectl get deployments -n rollout
```

### 3.3 Verify Controller Deployment
```powershell
# Check CRD exists
kubectl get crd k2saddons.k2s.siemens-healthineers.com

# Check ServiceAccount and RBAC
kubectl get sa -n k2s-system k2s-addon-controller
kubectl get clusterrole k2s-addon-controller
kubectl get clusterrolebinding k2s-addon-controller

# Check DaemonSet status
kubectl get daemonsets -n k2s-system

# Check controller pods
kubectl get pods -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller -o wide
```

Expected: One Linux controller pod on master node, one Windows controller pod on Windows node.

### 3.4 Check Controller Logs
```powershell
# Linux controller logs
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller,app.kubernetes.io/component=linux-processor --tail=50

# Windows controller logs
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller,app.kubernetes.io/component=windows-processor --tail=50
```

Look for:
- "Starting K2s Addon Controller"
- "FluxCD OCIRepository CRD detected, watching for changes"
- "Watching for K2sAddon resources"
- No error messages

### 3.5 Verify ADDONS_PATH

> **⚠️ CRITICAL:** The Windows controller DaemonSet must have `ADDONS_PATH` matching your K2s install
> directory + `\addons`. The controller writes addon files to this path, and `k2s addons ls` scans
> `<InstallDir>\addons\`. If they don't match, GitOps-imported addons won't appear in `k2s addons ls`.

```powershell
kubectl get daemonset k2s-addon-controller-windows -n k2s-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADDONS_PATH")].value}'

$installDir = Split-Path (Get-Command k2s -ErrorAction SilentlyContinue).Source -ErrorAction SilentlyContinue
if ($installDir) {
    Write-Host "K2s install directory: $installDir"
    Write-Host "Expected ADDONS_PATH:  $installDir\addons"
}
```

### 3.6 Verification Checklist
- [ ] FluxCD pods all running
- [ ] No CrashLoopBackOff errors
- [ ] FluxCD CRDs installed
- [ ] K2sAddon CRD installed
- [ ] RBAC resources created
- [ ] Linux controller pod running
- [ ] Windows controller pod running
- [ ] ADDONS_PATH matches K2s install directory
- [ ] No errors in controller logs

---

## Phase 4: Export Monitoring Addon

### 4.1 Export Monitoring Addon to OCI Format
```powershell
cd C:\ws

# Create export directory
New-Item -ItemType Directory -Force -Path "C:\Temp\monitoring-export" 

# Export monitoring addon
k2s addons export "monitoring" -d C:\Temp\monitoring-export
```

Expected output:
- OCI Image Layout tar file: `C:\Temp\monitoring-export\K2s-<version>-addons-monitoring.oci.tar`

> **Note:** The monitoring addon (Prometheus + Grafana + Alertmanager + kube-state-metrics + exporters)
> is significantly larger than simpler addons. Export may take several minutes.

### 4.2 Push Exported Addon OCI Artifact to Registry

`Export.ps1` produces an **OCI Image Layout** `.oci.tar` (not a Docker image).
Use `oras` to push it to the local registry.

```powershell
# Find the exported tar (resolve the wildcard to actual filename)
$tarFile = (Get-ChildItem "C:\Temp\monitoring-export" -Filter "K2s-*-addons-monitoring.oci.tar")[0].FullName
Write-Host "Exported artifact: $tarFile"

# Extract the OCI tar to a temp directory
$extractDir = "C:\Temp\monitoring-export\oci-extracted"
Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

# Note: tar.exe doesn't support PowerShell wildcards, use resolved path
tar -xf $tarFile -C $extractDir

# The tar extracts into an "artifacts/" subdirectory containing the OCI layout
$ociDir = "$extractDir\artifacts"
Test-Path "$ociDir\oci-layout"   # must be True
Test-Path "$ociDir\index.json"   # must be True

# Verify OCI layout structure
Get-Content "$ociDir\oci-layout"       # should show imageLayoutVersion 1.0.0
Get-Content "$ociDir\index.json" | ConvertFrom-Json | ConvertTo-Json -Depth 5

# Verify multi-layer manifest
$indexJson = Get-Content "$ociDir\index.json" | ConvertFrom-Json
$manifestDigest = $indexJson.manifests[0].digest
$manifestFile = "$ociDir\blobs\sha256\$($manifestDigest -replace 'sha256:','')"
$manifest = Get-Content $manifestFile | ConvertFrom-Json
Write-Host "Layers in OCI manifest: $($manifest.layers.Count)"
$manifest.layers | ForEach-Object { Write-Host "  - $($_.mediaType)  ($([math]::Round($_.size/1024,1)) KB)" }

# Push to registry using oras (install: winget install oras-project.oras)
$index = Get-Content "$ociDir\index.json" | ConvertFrom-Json
$digest = $index.manifests[0].digest
Write-Host "Pushing manifest digest: $digest"

Push-Location $extractDir
oras copy --from-oci-layout "artifacts@${digest}" `
  --to-plain-http `
  k2s.registry.local:30500/k2s/addons/monitoring:v1.0.0
Pop-Location

# Verify successful push
Write-Host "Verifying pushed artifact..."
oras manifest fetch k2s.registry.local:30500/k2s/addons/monitoring:v1.0.0 --plain-http
```

### 4.3 Verify Addon in Registry
```powershell
curl -k https://k2s.registry.local:30500/v2/k2s/addons/monitoring/tags/list
```

Expected: `{"name":"k2s/addons/monitoring","tags":["v1.0.0"]}`

### 4.4 Remove Local Monitoring Addon (CRITICAL for Test Validity)

> **⚠️ This step is essential.** Without it, `k2s addons ls` shows monitoring because the addon
> already exists in the source tree at `C:\ws\addons\monitoring\`. Removing it proves that the
> controller actually delivered the addon files via GitOps.

```powershell
# Back up the local monitoring addon (we'll restore it during cleanup)
Remove-Item -Path "C:\ws\addons\monitoring" -Force
Rename-Item -Path "C:\ws\addons\monitoring" -NewName "monitoring.gitops-backup" -Force

# Verify it's gone
Test-Path "C:\ws\addons\monitoring"  # must be False

# Verify k2s CLI no longer lists monitoring
k2s addons ls 
# Expected: monitoring should NOT appear
```

### 4.5 Verification Checklist
- [ ] Monitoring addon exported successfully
- [ ] OCI tar file created (K2s-*-addons-monitoring.oci.tar)
- [ ] OCI artifact pushed to local registry via oras
- [ ] Artifact visible in registry (`/v2/.../tags/list`)
- [ ] Local `C:\ws\addons\monitoring` renamed to `monitoring.gitops-backup`
- [ ] `k2s addons ls` no longer shows monitoring addon

---

## Phase 5: Create FluxCD Resources for Monitoring Addon

> **Architecture Note:** FluxCD's OCIRepository acts as a **trigger/notifier**. The source-controller
> watches the OCI registry, downloads the artifact for integrity checking, and reports readiness via
> `status.conditions`. The K2s addon controller **watches OCIRepository CRs** — when FluxCD updates
> `status.artifact.digest` (new tag detected), the controller automatically re-reconciles the
> referencing K2sAddon CRs. It reads `spec.url` + `spec.ref.tag` from the OCIRepository CR, then
> pulls the artifact **directly from the registry** via ORAS. This preserves the full multi-layer
> OCI manifest with all media types intact.

### 5.1 Create OCIRepository for Monitoring Addon
```powershell
# Create OCIRepository CR
@"
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: monitoring-addon
  namespace: rollout
spec:
  interval: 5m
  url: oci://k2s.registry.local:30500/k2s/addons/monitoring
  ref:
    tag: v1.0.0
  insecure: true
  provider: generic
"@ | kubectl apply -f -
```

### 5.2 Verify OCIRepository
```powershell
# Check OCIRepository status
Start-Sleep -Seconds 10
kubectl get ocirepository -n rollout monitoring-addon

# Get detailed status
kubectl describe ocirepository -n rollout monitoring-addon

# Check for Ready condition
kubectl get ocirepository -n rollout monitoring-addon -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

Expected: Status should be "Ready" with "True"

### 5.3 Check FluxCD Logs
```powershell
# Source controller should show artifact fetched
kubectl logs -n rollout deployment/source-controller --tail=100 | Select-String "monitoring-addon"
```

### 5.4 Verification Checklist
- [ ] OCIRepository created
- [ ] OCIRepository status is Ready
- [ ] No errors in source-controller logs
- [ ] Artifact downloaded by FluxCD

---

## Phase 6: Deploy K2sAddon CR

### 6.0 Pre-Check: Verify Clean State
```powershell
# CRITICAL: Confirm the local monitoring addon was removed in Phase 4.4
# If this returns True, the test is invalid — go back to Phase 4.4
Test-Path "C:\ws\addons\monitoring\addon.manifest.yaml"
# Expected: False

# Confirm the backup exists
Test-Path "C:\ws\addons\monitoring.gitops-backup"
# Expected: True

# Confirm the target directory is empty/absent for controller to write to
Test-Path "C:\ws\addons\monitoring"
# Expected: False
```

### 6.1 Create K2sAddon Resource

```powershell
@"
apiVersion: k2s.siemens-healthineers.com/v1alpha1
kind: K2sAddon
metadata:
  name: monitoring
spec:
  name: monitoring
  version: "1.0.0"
  source:
    type: OCIRepository
    ociRepository:
      name: monitoring-addon
      namespace: rollout
"@ | kubectl apply -f -
```

**Note:** K2sAddon is **cluster-scoped** (no namespace needed in metadata).

### 6.2 Monitor K2sAddon Processing
```powershell
# Watch K2sAddon status
kubectl get k2saddon monitoring --watch

# Detailed status
kubectl describe k2saddon monitoring

# Check phase and conditions
kubectl get k2saddon monitoring -o yaml
```

Expected phases progression:
1. `Pending` - Initial state
2. `Pulling` - Downloading OCI artifact
3. `Processing` - Extracting layers
4. `Available` - Ready to enable

### 6.3 Monitor Controller Logs (CRITICAL)
```powershell
# Follow Linux controller logs
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller,app.kubernetes.io/component=linux-processor -f

# In separate terminal, follow Windows controller logs
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller,app.kubernetes.io/component=windows-processor -f
```

Look for (structured JSON logs):
- `"msg":"Processing addon"` with `"name":"monitoring"` — reconciliation started
- `"msg":"Resolving FluxCD OCIRepository"` with `"name":"monitoring-addon"` — looking up the OCIRepository CR
- `"msg":"FluxCD OCIRepository is Ready — pulling directly from OCI registry"` with `"ref":"k2s.registry.local:30500/k2s/addons/monitoring:v1.0.0"`
- `"msg":"Pulling from OCI registry"` — ORAS pull initiated
- `"msg":"Pulled OCI artifact"` with `"digest":"sha256:..."` — manifest digest captured
- `"msg":"Processing layer"` with `"mediaType":"application/vnd.k2s.addon.configfiles.v1.tar+gzip"`
- `"msg":"Processing layer"` with `"mediaType":"application/vnd.k2s.addon.manifests.v1.tar+gzip"`
- `"msg":"Processing layer"` with `"mediaType":"application/vnd.k2s.addon.scripts.v1.tar+gzip"`
- `"msg":"Processing layer"` with `"mediaType":"application/vnd.oci.image.layer.v1.tar"` (Linux images)
- `"msg":"Processing layer"` with `"mediaType":"application/vnd.oci.image.layer.v1.tar+windows"` (Windows images)
- `"msg":"K2sAddon processed successfully"` with `"name":"monitoring"` — processing complete

> **Note:** Each controller only imports images for its own node type. The Linux controller
> skips Windows image layers (and vice versa). Occasional `"Reconciler error"` messages about
> `"the object has been modified"` are **expected** — this is the optimistic concurrency conflict
> when both controllers try to update the same K2sAddon CR simultaneously. The controller
> automatically retries via `retry.RetryOnConflict`.

### 6.4 Verify Digest Tracking
```powershell
# Verify the controller stored the FluxCD artifact digest
kubectl get k2saddon monitoring -o jsonpath='{.status.lastPulledDigest}'
# Expected: a sha256 digest string (e.g., sha256:abc123...)
```

### 6.5 Check for Errors
```powershell
# Check K2sAddon status for errors
kubectl get k2saddon monitoring -o jsonpath='{.status.errorMessage}'

# Check events
kubectl get events --sort-by='.lastTimestamp' | Select-String "monitoring"
```

### 6.6 Verification Checklist
- [ ] K2sAddon resource created
- [ ] Status progresses through phases
- [ ] Reaches `Available` phase
- [ ] No error messages in status
- [ ] Controller logs show successful processing
- [ ] lastPulledDigest is set
- [ ] No errors in events

---

## Phase 7: Verify Addon Files on Host

### 7.1 Check Linux Node (Master)
```powershell
# SSH to Linux node
ssh -o StrictHostKeyChecking=no -i ~\.ssh\k2s\id_rsa remote@172.19.1.100

# Check addon directory created
ls -la /addons/monitoring/

# Check for addon files
ls -la /addons/monitoring/addon.manifest.yaml
ls -la /addons/monitoring/Enable.ps1
ls -la /addons/monitoring/Disable.ps1
ls -la /addons/monitoring/monitoring.module.psm1
ls -la /addons/monitoring/manifests/

# Exit SSH
exit
```

### 7.2 Check Windows Node (Local Host)

> **Note:** The controller writes files to the path configured in `ADDONS_PATH`.
> Since we renamed the local monitoring addon in Phase 4.4, the only way these files
> can exist is if the controller delivered them via GitOps.

```powershell
# Check addon directory on Windows (path matches ADDONS_PATH in DaemonSet)
Get-ChildItem C:\ws\addons\monitoring\ -Recurse | Select-Object FullName

# Verify key files exist — these were delivered by the controller, NOT from source tree
Test-Path C:\ws\addons\monitoring\addon.manifest.yaml
Test-Path C:\ws\addons\monitoring\Enable.ps1
Test-Path C:\ws\addons\monitoring\Disable.ps1
Test-Path C:\ws\addons\monitoring\monitoring.module.psm1
Test-Path C:\ws\addons\monitoring\manifests

# Check manifest content
Get-Content C:\ws\addons\monitoring\addon.manifest.yaml

# CRITICAL CHECK: Verify this is NOT the backed-up original
# The gitops-backup should still exist
Test-Path C:\ws\addons\monitoring.gitops-backup  # must be True (our backup)
```

### 7.3 Verification Checklist
- [ ] Addon directory created on Linux node
- [ ] Addon directory created on Windows node
- [ ] addon.manifest.yaml present
- [ ] Enable.ps1 script present
- [ ] Disable.ps1 script present
- [ ] monitoring.module.psm1 present
- [ ] manifests directory present with monitoring subdirectories

---

## Phase 8: Verify Images Imported

### 8.1 Check Linux Node Images
```powershell
# SSH to Linux node
ssh -o StrictHostKeyChecking=no -i ~\.ssh\k2s\id_rsa remote@172.19.1.100

# List imported monitoring images
sudo crictl images | grep -E 'prometheus|grafana|alertmanager|kube-state|node-exporter|config-reloader'

# Exit
exit
```

Expected Linux images:
- `quay.io/prometheus/prometheus`
- `docker.io/grafana/grafana`
- `quay.io/prometheus/alertmanager`
- `registry.k8s.io/kube-state-metrics/kube-state-metrics`
- `quay.io/prometheus/node-exporter`
- `quay.io/prometheus-operator/prometheus-operator`
- `quay.io/prometheus-operator/prometheus-config-reloader`

### 8.2 Check Windows Node Images
```powershell
# Check Windows images
nerdctl --namespace k8s.io images | Select-String "windows-exporter"
```

Expected:
- `ghcr.io/prometheus-community/windows-exporter`

### 8.3 Verification Checklist
- [ ] Linux monitoring images imported (Prometheus, Grafana, Alertmanager, etc.)
- [ ] Windows exporter image imported
- [ ] Images match versions in addon manifest

---

## Phase 9: Enable Monitoring Addon via k2s CLI

### 9.1 List Available Addons
```powershell
# List addons (should now show monitoring)
k2s addons ls

# Check if monitoring shows as available
k2s addons ls | Select-String "monitoring"
```

Expected: Monitoring addon should appear in the list (delivered via GitOps)

### 9.2 Enable Monitoring Addon
```powershell
# Enable monitoring addon
k2s addons enable monitoring
```

### 9.3 Verify Monitoring Deployment
```powershell
# Check monitoring namespace
kubectl get ns monitoring

# Check monitoring pods
kubectl get pods -n monitoring -o wide

# Wait for key pods to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus -n monitoring --timeout=300s
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s

# Check Windows exporter on Windows node
kubectl get pods -n monitoring -l app.kubernetes.io/name=windows-exporter -o wide

# Check all deployments and statefulsets
kubectl get deployments -n monitoring
kubectl get statefulsets -n monitoring
```

### 9.4 Test Monitoring Functionality
```powershell
# Test metrics API (relies on monitoring stack)
kubectl top nodes
kubectl top pods -A
```

Expected: Metrics should be returned without errors

### 9.5 Verification Checklist
- [ ] Monitoring addon appears in `k2s addons ls`
- [ ] Enable command succeeds
- [ ] Prometheus pods running
- [ ] Grafana pods running
- [ ] Windows exporter running on Windows node
- [ ] `kubectl top nodes` works
- [ ] `kubectl top pods` works

---

## Phase 10: Test Update Workflow

> **Goal:** Verify the controller **automatically** re-processes an addon when the OCI tag changes.
> With the OCIRepository watch and digest-based change detection, no manual K2sAddon spec patch
> is required. The flow is: push new artifact → update OCIRepository tag → FluxCD detects →
> FluxCD updates OCIRepository status.artifact.digest → controller watch triggers reconcile →
> controller compares digests → automatic re-pull and re-processing.

### 10.1 Record Current Digest
```powershell
# Record the current digest before the update
$oldDigest = kubectl get k2saddon monitoring -o jsonpath='{.status.lastPulledDigest}'
$oldTime = kubectl get k2saddon monitoring -o jsonpath='{.status.lastProcessedTime}'
Write-Host "Current digest: $oldDigest"
Write-Host "Current time: $oldTime"
```

### 10.2 Create Modified Addon and Push with New Tag

> **Critical:** To test automatic re-processing, we need **different content** (different digest).
> Modify the addon manifest version, re-export, and push as v1.0.1.

```powershell
# Temporarily restore the backup to modify it
if (-not (Test-Path "C:\ws\addons\monitoring.gitops-backup")) {
    Write-Host "ERROR: Backup not found. Cannot proceed with update test."
    exit 1
}

# Modify the addon manifest version to create different content
$manifestPath = "C:\ws\addons\monitoring.gitops-backup\addon.manifest.yaml"
(Get-Content $manifestPath) -replace 'version:\s*["\x27]?1\.0\.0["\x27]?', 'version: "1.0.1"' | Set-Content $manifestPath

# Re-export the modified addon
New-Item -ItemType Directory -Force -Path "C:\Temp\monitoring-export-v2" | Out-Null
k2s addons export "monitoring.gitops-backup" -d C:\Temp\monitoring-export-v2

# Extract the new OCI tar
$tarFile = (Get-ChildItem "C:\Temp\monitoring-export-v2" -Filter "K2s-*-addons-*.oci.tar")[0].FullName
$extractDir = "C:\Temp\monitoring-export-v2\oci-extracted"
Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
tar -xf $tarFile -C $extractDir

# Get the NEW digest (will be different from v1.0.0)
$ociDir = "$extractDir\artifacts"
$index = Get-Content "$ociDir\index.json" | ConvertFrom-Json
$newDigest = $index.manifests[0].digest
Write-Host "v1.0.0 digest: $oldDigest"
Write-Host "v1.0.1 digest: $newDigest (modified content)"

# Push the modified artifact as v1.0.1
Push-Location $extractDir
oras copy --from-oci-layout "artifacts@${newDigest}" `
  --to-plain-http `
  k2s.registry.local:30500/k2s/addons/monitoring:v1.0.1
Pop-Location

# Verify both tags exist
curl -k https://k2s.registry.local:30500/v2/k2s/addons/monitoring/tags/list

# Revert the manifest change in backup (keep original clean)
(Get-Content $manifestPath) -replace 'version:\s*["\x27]?1\.0\.1["\x27]?', 'version: "1.0.0"' | Set-Content $manifestPath
```

Expected: `{"name":"k2s/addons/monitoring","tags":["v1.0.0","v1.0.1"]}` with **different digests**

### 10.3 Update OCIRepository Tag
```powershell
# Patch the OCIRepository to point to the new tag
kubectl patch ocirepository monitoring-addon -n rollout --type merge -p '{\"spec\":{\"ref\":{\"tag\":\"v1.0.1\"}}}'

# Wait for FluxCD to reconcile the new tag
kubectl get ocirepository -n rollout monitoring-addon --watch
```

Expected: OCIRepository shows `Ready=True` with the new artifact digest.

### 10.4 Monitor Automatic Re-Processing (No Manual Patch!)

> **Key difference from previous design:** The controller now watches OCIRepository CRs.
> When FluxCD updates the OCIRepository status (new artifact digest), the controller
> receives an event, compares `status.artifact.digest` against `status.lastPulledDigest`,
> and automatically re-processes the addon.

```powershell
# Watch status — should cycle through Pulling → Processing → Available WITHOUT manual patch
kubectl get k2saddon monitoring --watch

# Check controller logs for automatic re-processing
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller --tail=50
```

Look for:
- `"msg":"Enqueuing K2sAddon for OCIRepository change"` — the watch triggered
- `"msg":"OCIRepository artifact digest changed"` — digest comparison detected change
- `"msg":"FluxCD OCIRepository is Ready — pulling directly from OCI registry"` — re-pull initiated
- `"msg":"K2sAddon processed successfully"` — re-processing completed

### 10.5 Verify Digest Updated
```powershell
# Check that lastPulledDigest changed
$newDigest = kubectl get k2saddon monitoring -o jsonpath='{.status.lastPulledDigest}'
$newTime = kubectl get k2saddon monitoring -o jsonpath='{.status.lastProcessedTime}'
Write-Host "Previous digest: $oldDigest"
Write-Host "New digest:     $newDigest"
Write-Host "Digests match:  $($oldDigest -eq $newDigest)"
Write-Host ""
Write-Host "Previous time: $oldTime"
Write-Host "New time:      $newTime"

# CRITICAL: Digests MUST be different for the test to be valid
if ($oldDigest -eq $newDigest) {
    Write-Host "ERROR: Digests are the same! Controller correctly skipped re-processing."
    Write-Host "This means v1.0.1 has the same content as v1.0.0 (test setup issue)."
} else {
    Write-Host "SUCCESS: Different digest detected, controller re-processed the addon."
}
```

### 10.6 Verification Checklist
- [ ] Modified addon exported (version 1.0.1 in manifest)
- [ ] v1.0.1 tag pushed to registry with **different digest**
- [ ] OCIRepository updated and re-reconciled by FluxCD
- [ ] Controller **automatically** detected the digest change (no K2sAddon spec patch needed)
- [ ] Controller re-processes the addon (Pulling → Processing → Available)
- [ ] `lastPulledDigest` updated to new digest
- [ ] `lastProcessedTime` updated
- [ ] Status returns to `Available`
- [ ] No errors during update

---

## Phase 11: Test Cleanup

### 11.1 Disable Monitoring Addon
```powershell
# Disable via k2s CLI
k2s addons disable monitoring

# Verify resources removed
kubectl get pods -n monitoring
kubectl get ns monitoring
```

### 11.2 Delete K2sAddon CR and FluxCD Resources
```powershell
# Delete K2sAddon CR (triggers finalizer cleanup on controller)
kubectl delete k2saddon monitoring

# Delete OCIRepository
kubectl delete ocirepository monitoring-addon -n rollout --ignore-not-found

# Verify CR deleted
kubectl get k2saddon
kubectl get ocirepository -n rollout
```

### 11.3 Restore Local Monitoring Addon
```powershell
# Remove controller-delivered files (if any remain after finalizer cleanup)
if (Test-Path "C:\ws\addons\monitoring") {
    Remove-Item -Path "C:\ws\addons\monitoring" -Recurse -Force
}

# Restore the original monitoring addon from backup
if (Test-Path "C:\ws\addons\monitoring.gitops-backup") {
    Rename-Item -Path "C:\ws\addons\monitoring.gitops-backup" -NewName "monitoring" -Force
    Write-Host "Restored original monitoring addon from backup"
} else {
    Write-Host "WARNING: No backup found at C:\ws\addons\monitoring.gitops-backup"
}

# Verify restoration
Test-Path "C:\ws\addons\monitoring\addon.manifest.yaml"  # must be True
k2s addons ls | Select-String "monitoring"                 # should appear again
```

### 11.4 Cleanup Export Artifacts
```powershell
# Remove temp export directories
Remove-Item -Path "C:\Temp\monitoring-export" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\Temp\monitoring-export-v2" -Recurse -Force -ErrorAction SilentlyContinue
```

### 11.5 Verification Checklist
- [ ] Addon disabled successfully
- [ ] Kubernetes resources cleaned up
- [ ] K2sAddon CR deleted
- [ ] OCIRepository deleted
- [ ] Original monitoring addon restored from backup
- [ ] `k2s addons ls` shows monitoring again
- [ ] Export temp files cleaned up

---

## Phase 12: Test Error Scenarios

### 12.1 Test Invalid OCI Reference
```powershell
# Create K2sAddon with non-existent image
@"
apiVersion: k2s.siemens-healthineers.com/v1alpha1
kind: K2sAddon
metadata:
  name: test-invalid
spec:
  name: invalid
  version: "1.0.0"
  source:
    type: oci
    ociRef: k2s.registry.local:30500/k2s/addons/nonexistent:v1.0.0
    insecure: true
"@ | kubectl apply -f -

# Check status shows error
kubectl get k2saddon test-invalid -o yaml
```

Expected: Status should show error message about missing image

### 12.2 Test Missing OCIRepository
```powershell
# Create K2sAddon referencing non-existent OCIRepository
@"
apiVersion: k2s.siemens-healthineers.com/v1alpha1
kind: K2sAddon
metadata:
  name: test-missing-repo
spec:
  name: missing
  version: "1.0.0"
  source:
    type: OCIRepository
    ociRepository:
      name: does-not-exist
      namespace: rollout
"@ | kubectl apply -f -

# Check status
kubectl describe k2saddon test-missing-repo
```

Expected: Error indicating OCIRepository not found

### 12.3 Cleanup Test Resources
```powershell
kubectl delete k2saddon test-invalid test-missing-repo --ignore-not-found
```

### 12.4 Verification Checklist
- [ ] Invalid references handled gracefully
- [ ] Error messages clear and helpful
- [ ] Controller doesn't crash on errors

---

## Test Summary Checklist

### Clean State & Install
- [ ] Previous K2s fully uninstalled (or was not installed)
- [ ] Fresh K2s install completed
- [ ] Both nodes Ready

### Registry & Node Config
- [ ] Registry addon enabled
- [ ] Insecure registry configured on Linux node

### Build Phase
- [ ] Windows controller image built
- [ ] Linux controller image built
- [ ] Images pushed to registry

### FluxCD + Controller (via `-g` flag)
- [ ] `k2s addons enable rollout fluxcd -g` succeeds
- [ ] FluxCD pods running
- [ ] Controller pods running (Linux + Windows)
- [ ] ADDONS_PATH matches K2s install directory

### Addon Export & Local Removal
- [ ] Monitoring addon exported to OCI tar
- [ ] OCI artifact pushed to registry
- [ ] Local monitoring addon renamed to `monitoring.gitops-backup`
- [ ] `k2s addons ls` no longer shows monitoring

### FluxCD Integration
- [ ] OCIRepository created
- [ ] OCIRepository Ready

### GitOps Flow (PROVES GITOPS WORKS)
- [ ] Pre-check: local monitoring addon absent
- [ ] K2sAddon CR created
- [ ] Controller processes addon (pulls from OCI/FluxCD)
- [ ] Files extracted to host by controller
- [ ] Images imported by controller
- [ ] Status shows Available

### k2s CLI Integration
- [ ] Addon appears in `k2s addons ls` (via controller-delivered files)
- [ ] Addon can be enabled
- [ ] Monitoring stack deploys successfully
- [ ] Prometheus, Grafana, exporters all running

### Update Workflow
- [ ] New tag pushed to registry
- [ ] OCIRepository updated
- [ ] Controller automatically re-processes addon (no K2sAddon patch needed)
- [ ] lastPulledDigest updated in status

### Cleanup
- [ ] Addon can be disabled
- [ ] K2sAddon and OCIRepository deleted
- [ ] Original monitoring addon restored from backup
- [ ] `k2s addons ls` shows monitoring again
- [ ] Export temp files cleaned up

---

## Troubleshooting Commands

### General Debugging
```powershell
# Get all resources in k2s-system
kubectl get all -n k2s-system

# Get all K2sAddons
kubectl get k2saddon -A

# Check CRD details
kubectl get crd k2saddons.k2s.siemens-healthineers.com -o yaml

# Check all controller logs
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller --all-containers --tail=200
```

### Registry Issues
```powershell
# Test registry connectivity
curl -k https://k2s.registry.local:30500/v2/_catalog

# Check registry pods
kubectl get pods -n registry
```

### FluxCD Issues
```powershell
# Check FluxCD reconciliation
kubectl get kustomizations -n rollout
kubectl get gitrepositories -n rollout
kubectl get ocirepositories -n rollout

# FluxCD controller logs
kubectl logs -n rollout deployment/source-controller --tail=100
kubectl logs -n rollout deployment/kustomize-controller --tail=100

# Verify OCIRepository watch is working (controller should log events)
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller --tail=100 | Select-String "Enqueuing K2sAddon for OCIRepository"
```

### Controller Not Starting After `-g` Flag
```powershell
kubectl get ds -n k2s-system
kubectl get events -n k2s-system --sort-by='.lastTimestamp'
curl -k https://k2s.registry.local:30500/v2/k2s/addon-controller-linux/tags/list
curl -k https://k2s.registry.local:30500/v2/k2s/addon-controller-windows/tags/list
```

---

## Success Criteria

The test is considered **PASSED** if:

1. ✅ K2s installs cleanly from scratch (both nodes Ready)
2. ✅ Registry addon works and is accessible from both nodes
3. ✅ All controller images build successfully
4. ✅ `k2s addons enable rollout fluxcd -g` deploys FluxCD + controller in one command
5. ✅ Controller DaemonSets run on both nodes (ADDONS_PATH configured correctly)
6. ✅ Monitoring addon exports to multi-layer OCI format and pushes to registry
7. ✅ Local monitoring addon removed — proving GitOps is the only delivery path
8. ✅ FluxCD OCIRepository detects the artifact and reports Ready (trigger role)
9. ✅ K2sAddon CR is processed — controller pulls directly from registry
10. ✅ Addon files appear on host filesystem (both Windows and Linux)
11. ✅ Container images are imported correctly (Prometheus, Grafana, etc. on Linux; Windows exporter on Windows)
12. ✅ Addon appears in `k2s addons ls` (via controller-delivered files, NOT source tree)
13. ✅ Addon can be enabled via `k2s addons enable monitoring`
14. ✅ Monitoring stack functional (Prometheus scraping, Grafana accessible)
15. ✅ Update workflow works (new tag → FluxCD detects → controller **automatically** re-processes, no manual patch)
16. ✅ Cleanup works (disable/delete/restore)

---

## Notes

- **Install Time**: Fresh K2s install takes 10-20 minutes (VM provisioning, network setup)
- **Uninstall Time**: `k2s uninstall -d` takes 2-5 minutes; system reset may require a reboot
- **Build Time**: Controller image builds may take 5-10 minutes
- **Pull Time**: OCI artifact pulls depend on size and network
- **Processing Time**: Large addons with many images may take several minutes
- **Windows HostProcess**: Windows controller requires HostProcess support (Windows Server 2022+)
- **Registry**: Ensure local registry is accessible from both nodes
- **Proxy**: If behind a corporate proxy, pass `--proxy` and `--no-proxy` flags to `k2s install`

---

## Test Execution Log

Date: _______________  
Tester: _______________  

| Phase | Status | Notes | Time |
|-------|--------|-------|------|
| 0. Uninstall & Install K2s | ☐ | | |
| 1. Registry & Node Config | ☐ | | |
| 2. Build Controller Images | ☐ | | |
| 3. Enable FluxCD + Controller (`-g`) | ☐ | ADDONS_PATH= | |
| 4. Export + Push + Remove Local | ☐ | | |
| 5. Create OCIRepository | ☐ | | |
| 6. Deploy K2sAddon | ☐ | Pre-check passed? | |
| 7. Verify Host Files | ☐ | Controller-delivered? | |
| 8. Verify Images | ☐ | | |
| 9. Enable Monitoring Addon | ☐ | All pods running? | |
| 10. Test Update | ☐ | Auto-detect? | |
| 11. Test Cleanup | ☐ | Backup restored? | |
| 12. Error Scenarios | ☐ | | |

**Overall Result:** ☐ PASS  ☐ FAIL

**Issues Encountered:**
_______________________________________________________________________________
_______________________________________________________________________________
_______________________________________________________________________________
