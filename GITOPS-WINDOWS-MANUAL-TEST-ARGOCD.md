<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Manual Test Plan: GitOps Addon Deployment on Windows (ArgoCD)
**Test Date:** February 16, 2026  
**Target:** ArgoCD (rollout) + monitoring addon + GitOps addon controller  
**Architecture:** ArgoCD provides declarative GitOps continuous delivery.  
The controller pulls addon OCI artifacts directly from the registry via ORAS using the `source.type: oci` mode.  
Unlike the FluxCD variant, there is no OCIRepository CR — the K2sAddon CR's `spec.source.ociRef` points directly at the registry.  
Update detection requires a spec change (new tag) on the K2sAddon CR, which bumps the CR generation.  
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

## Phase 3: Enable ArgoCD + GitOps Controller

### 3.1 Enable ArgoCD with the GitOps Addon Controller

This single command deploys ArgoCD **and** the GitOps addon controller (CRD, RBAC, DaemonSets):

```powershell
k2s addons enable rollout argocd -g
```

> **What `-g` / `--addongitops` does:** In addition to deploying ArgoCD, it applies the K2sAddon CRD,
> RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding), and Linux + Windows controller DaemonSets
> to the `k2s-system` namespace. This replaces the need to manually `kubectl apply` each manifest.

**Wait for ArgoCD to be ready:**
```powershell
kubectl get pods -n rollout --watch
```

Expected ArgoCD pods:
- `argocd-applicationset-controller-*`
- `argocd-dex-server-*`
- `argocd-notifications-controller-*`
- `argocd-redis-*`
- `argocd-repo-server-*`
- `argocd-server-*`
- `argocd-application-controller-*` (StatefulSet)

### 3.2 Verify ArgoCD Installation
```powershell
# Check all pods are running
kubectl get pods -n rollout

# Check ArgoCD components
kubectl get deployments -n rollout
kubectl get statefulsets -n rollout
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
- "FluxCD OCIRepository CRD not found, skipping watch (direct OCI mode only)"
- "Watching for K2sAddon resources"
- No error messages about `OCIRepository`

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

### 3.6 Verify ArgoCD Admin Password (Optional)
```powershell
# Retrieve ArgoCD initial admin password
kubectl -n rollout get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | 
  ForEach-Object { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

### 3.7 Verification Checklist
- [ ] ArgoCD pods all running
- [ ] ArgoCD StatefulSet (application-controller) running
- [ ] No CrashLoopBackOff errors
- [ ] ArgoCD CRDs installed
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

## Phase 5: Deploy K2sAddon CR (Direct OCI)

> **Architecture Note (ArgoCD vs FluxCD):** With ArgoCD, the K2sAddon CR uses `source.type: oci`
> with a direct `ociRef` pointing at the registry. There is **no** FluxCD OCIRepository CR involved.
> The controller pulls the artifact directly from the registry via ORAS using the reference in
> `spec.source.ociRef`. ArgoCD itself is not involved in the OCI artifact pull — it serves as the
> GitOps platform for application deployment while the K2s addon controller handles addon lifecycle.
>
> **Key difference from FluxCD variant:** Update detection requires changing the K2sAddon spec
> (e.g., updating the tag in `ociRef`), which bumps the CR generation. The controller compares
> `status.observedGeneration` vs `metadata.generation` to detect changes.

### 5.0 Pre-Check: Verify Clean State
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

### 5.1 Create K2sAddon Resource (Direct OCI Source)

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
    type: oci
    ociRef: k2s.registry.local:30500/k2s/addons/monitoring:v1.0.0
    insecure: true
"@ | kubectl apply -f -
```

**Note:** K2sAddon is **cluster-scoped** (no namespace needed in metadata).
The `source.type: oci` tells the controller to pull directly from the registry via ORAS — no FluxCD dependency.

### 5.2 Monitor K2sAddon Processing
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
2. `Pulling` - Downloading OCI artifact directly from registry
3. `Processing` - Extracting layers
4. `Available` - Ready to enable

### 5.3 Monitor Controller Logs (CRITICAL)
```powershell
# Follow Linux controller logs
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller,app.kubernetes.io/component=linux-processor -f

# In separate terminal, follow Windows controller logs
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller,app.kubernetes.io/component=windows-processor -f
```

Look for (structured JSON logs):
- `"msg":"Processing addon"` with `"name":"monitoring"` — reconciliation started
- `"msg":"Pulling from OCI registry"` with `"ref":"k2s.registry.local:30500/k2s/addons/monitoring:v1.0.0"` — ORAS pull initiated
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

### 5.4 Verify Digest Tracking
```powershell
# Verify the controller stored the artifact digest
kubectl get k2saddon monitoring -o jsonpath='{.status.lastPulledDigest}'
# Expected: a sha256 digest string (e.g., sha256:abc123...)
```

### 5.5 Check for Errors
```powershell
# Check K2sAddon status for errors
kubectl get k2saddon monitoring -o jsonpath='{.status.errorMessage}'

# Check events
kubectl get events --sort-by='.lastTimestamp' | Select-String "monitoring"
```

### 5.6 Verification Checklist
- [ ] K2sAddon resource created with `source.type: oci`
- [ ] Status progresses through phases
- [ ] Reaches `Available` phase
- [ ] No error messages in status
- [ ] Controller logs show successful processing (direct OCI pull, no FluxCD)
- [ ] lastPulledDigest is set
- [ ] No errors in events

---

## Phase 6: Verify Addon Files on Host

### 6.1 Check Linux Node (Master)
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

### 6.2 Check Windows Node (Local Host)

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

### 6.3 Verification Checklist
- [ ] Addon directory created on Linux node
- [ ] Addon directory created on Windows node
- [ ] addon.manifest.yaml present
- [ ] Enable.ps1 script present
- [ ] Disable.ps1 script present
- [ ] monitoring.module.psm1 present
- [ ] manifests directory present with monitoring subdirectories

---

## Phase 7: Verify Images Imported

### 7.1 Check Linux Node Images
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

### 7.2 Check Windows Node Images
```powershell
# Check Windows images
nerdctl --namespace k8s.io images | Select-String "windows-exporter"
```

Expected:
- `ghcr.io/prometheus-community/windows-exporter`

### 7.3 Verification Checklist
- [ ] Linux monitoring images imported (Prometheus, Grafana, Alertmanager, etc.)
- [ ] Windows exporter image imported
- [ ] Images match versions in addon manifest

---

## Phase 8: Enable Monitoring Addon via k2s CLI

### 8.1 List Available Addons
```powershell
# List addons (should now show monitoring)
k2s addons ls

# Check if monitoring shows as available
k2s addons ls | Select-String "monitoring"
```

Expected: Monitoring addon should appear in the list (delivered via GitOps)

### 8.2 Enable Monitoring Addon
```powershell
# Enable monitoring addon
k2s addons enable monitoring
```

### 8.3 Verify Monitoring Deployment
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

### 8.4 Test Monitoring Functionality
```powershell
# Test metrics API (relies on monitoring stack)
kubectl top nodes
kubectl top pods -A
```

Expected: Metrics should be returned without errors

### 8.5 Verification Checklist
- [ ] Monitoring addon appears in `k2s addons ls`
- [ ] Enable command succeeds
- [ ] Prometheus pods running
- [ ] Grafana pods running
- [ ] Windows exporter running on Windows node
- [ ] `kubectl top nodes` works
- [ ] `kubectl top pods` works

---

## Phase 9: Test Update Workflow

> **Goal:** Verify the controller re-processes an addon when the K2sAddon spec changes.
> With the direct OCI source type (`source.type: oci`), there is no FluxCD OCIRepository watch.
> Instead, updating the `spec.source.ociRef` tag bumps the CR generation, and the controller
> detects `status.observedGeneration != metadata.generation` → triggers re-processing.
>
> **Flow:** push artifact with new tag → patch K2sAddon `ociRef` to new tag → controller
> detects generation change → re-pull and re-processing.

### 9.1 Record Current State
```powershell
# Record the current state before the update
$oldDigest = kubectl get k2saddon monitoring -o jsonpath='{.status.lastPulledDigest}'
$oldTime = kubectl get k2saddon monitoring -o jsonpath='{.status.lastProcessedTime}'
$oldGen = kubectl get k2saddon monitoring -o jsonpath='{.metadata.generation}'
Write-Host "Current digest: $oldDigest"
Write-Host "Current time: $oldTime"
Write-Host "Current generation: $oldGen"
```

### 9.2 Push Same Artifact with New Tag
```powershell
# Re-use the already-extracted OCI layout from Phase 4.2
$extractDir = "C:\Temp\monitoring-export\oci-extracted"
$ociDir = "$extractDir\artifacts"
$index = Get-Content "$ociDir\index.json" | ConvertFrom-Json
$digest = $index.manifests[0].digest

Push-Location $extractDir
oras copy --from-oci-layout "artifacts@${digest}" `
  --to-plain-http `
  k2s.registry.local:30500/k2s/addons/monitoring:v1.0.1
Pop-Location

# Verify both tags exist
curl -k https://k2s.registry.local:30500/v2/k2s/addons/monitoring/tags/list
```

Expected: `{"name":"k2s/addons/monitoring","tags":["v1.0.0","v1.0.1"]}`

### 9.3 Update K2sAddon OCI Reference

> **Key difference from FluxCD variant:** With direct OCI mode, you update the K2sAddon CR
> spec directly. This bumps `metadata.generation`, and the controller detects the change.

```powershell
# Patch the K2sAddon to point to the new tag
kubectl patch k2saddon monitoring --type merge -p '{"spec":{"source":{"ociRef":"k2s.registry.local:30500/k2s/addons/monitoring:v1.0.1"}}}'

# Watch status — should cycle through Pulling → Processing → Available
kubectl get k2saddon monitoring --watch
```

### 9.4 Monitor Re-Processing
```powershell
# Check controller logs for re-processing
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller --tail=50
```

Look for:
- `"msg":"Processing addon"` with `"name":"monitoring"` — generation change detected
- `"msg":"Pulling from OCI registry"` with `"ref":"k2s.registry.local:30500/k2s/addons/monitoring:v1.0.1"`
- `"msg":"Pulled OCI artifact"` with `"digest":"sha256:..."`
- `"msg":"K2sAddon processed successfully"` — re-processing completed

### 9.5 Verify State Updated
```powershell
# Check that state changed
$newDigest = kubectl get k2saddon monitoring -o jsonpath='{.status.lastPulledDigest}'
$newTime = kubectl get k2saddon monitoring -o jsonpath='{.status.lastProcessedTime}'
$newGen = kubectl get k2saddon monitoring -o jsonpath='{.status.observedGeneration}'
Write-Host "Previous digest: $oldDigest"
Write-Host "New digest: $newDigest"
Write-Host "Previous time: $oldTime"
Write-Host "New time: $newTime"
Write-Host "Observed generation: $newGen (should match current metadata.generation)"
```

### 9.6 Verification Checklist
- [ ] v1.0.1 tag pushed to registry
- [ ] K2sAddon `ociRef` patched to v1.0.1
- [ ] Controller detected generation change and re-processed
- [ ] Status cycles through Pulling → Processing → Available
- [ ] Status returns to `Available`
- [ ] `lastProcessedTime` is updated
- [ ] `observedGeneration` matches current `metadata.generation`
- [ ] No errors during update

---

## Phase 10: Test Cleanup

### 10.1 Disable Monitoring Addon
```powershell
# Disable via k2s CLI
k2s addons disable monitoring

# Verify resources removed
kubectl get pods -n monitoring
kubectl get ns monitoring
```

### 10.2 Delete K2sAddon CR
```powershell
# Delete K2sAddon CR (triggers finalizer cleanup on controller)
kubectl delete k2saddon monitoring

# Verify CR deleted
kubectl get k2saddon
```

### 10.3 Restore Local Monitoring Addon
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

### 10.4 Cleanup Export Artifacts
```powershell
# Remove temp export directory
Remove-Item -Path "C:\Temp\monitoring-export" -Recurse -Force -ErrorAction SilentlyContinue
```

### 10.5 Verification Checklist
- [ ] Addon disabled successfully
- [ ] Kubernetes resources cleaned up
- [ ] K2sAddon CR deleted
- [ ] Original monitoring addon restored from backup
- [ ] `k2s addons ls` shows monitoring again
- [ ] Export temp files cleaned up

---

## Phase 11: Test Error Scenarios

### 11.1 Test Invalid OCI Reference
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
Start-Sleep -Seconds 15
kubectl get k2saddon test-invalid -o yaml
```

Expected: Status should show `phase: Failed` with an error message about missing image

### 11.2 Test Invalid Tag
```powershell
# Create K2sAddon with valid repo but non-existent tag
@"
apiVersion: k2s.siemens-healthineers.com/v1alpha1
kind: K2sAddon
metadata:
  name: test-bad-tag
spec:
  name: badtag
  version: "1.0.0"
  source:
    type: oci
    ociRef: k2s.registry.local:30500/k2s/addons/monitoring:v99.99.99
    insecure: true
"@ | kubectl apply -f -

# Check status shows error
Start-Sleep -Seconds 15
kubectl describe k2saddon test-bad-tag
```

Expected: Error indicating tag not found

### 11.3 Cleanup Test Resources
```powershell
kubectl delete k2saddon test-invalid test-bad-tag --ignore-not-found
```

### 11.4 Verification Checklist
- [ ] Invalid references handled gracefully
- [ ] Non-existent tags handled gracefully
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

### ArgoCD + Controller (via `-g` flag)
- [ ] `k2s addons enable rollout argocd -g` succeeds
- [ ] ArgoCD pods running (deployments + statefulset)
- [ ] Controller pods running (Linux + Windows)
- [ ] ADDONS_PATH matches K2s install directory

### Addon Export & Local Removal
- [ ] Monitoring addon exported to OCI tar
- [ ] OCI artifact pushed to registry
- [ ] Local monitoring addon renamed to `monitoring.gitops-backup`
- [ ] `k2s addons ls` no longer shows monitoring

### GitOps Flow — Direct OCI (PROVES GITOPS WORKS)
- [ ] Pre-check: local monitoring addon absent
- [ ] K2sAddon CR created with `source.type: oci`
- [ ] Controller pulls addon directly from registry (no FluxCD dependency)
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
- [ ] K2sAddon `ociRef` patched to new tag (generation bump)
- [ ] Controller re-processes addon (detects generation change)
- [ ] lastPulledDigest updated in status

### Cleanup
- [ ] Addon can be disabled
- [ ] K2sAddon CR deleted
- [ ] Original monitoring addon restored from backup
- [ ] `k2s addons ls` shows monitoring again
- [ ] Export temp files cleaned up

---

## Differences from FluxCD Variant

| Aspect | FluxCD Variant | ArgoCD Variant (this doc) |
|--------|---------------|--------------------------|
| **GitOps Platform** | FluxCD | ArgoCD |
| **Enable Command** | `k2s addons enable rollout fluxcd -g` | `k2s addons enable rollout argocd -g` |
| **K2sAddon Source Type** | `OCIRepository` | `oci` |
| **OCI Pull Mechanism** | Controller reads `spec.url` + `spec.ref.tag` from FluxCD OCIRepository CR, then pulls via ORAS | Controller reads `spec.source.ociRef` directly, pulls via ORAS |
| **FluxCD Dependency** | OCIRepository CR required (FluxCD watches registry, controller watches OCIRepository) | No FluxCD dependency for OCI pull |
| **Update Detection** | Automatic — FluxCD detects new digest → controller watches OCIRepository status changes | Manual — patch K2sAddon `ociRef` to new tag → generation bump triggers re-processing |
| **Update Trigger** | No K2sAddon spec change needed | K2sAddon spec change required (`ociRef` tag update) |
| **Expected Pods (rollout ns)** | source-controller, helm-controller, kustomize-controller, notification-controller | argocd-server, argocd-repo-server, argocd-redis, argocd-dex-server, argocd-applicationset-controller, argocd-notifications-controller, argocd-application-controller |
| **Phase Count** | 13 phases (0-12) | 12 phases (0-11) — no separate OCIRepository phase |

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

### ArgoCD Issues
```powershell
# Check ArgoCD pods
kubectl get pods -n rollout

# Check ArgoCD deployments and statefulsets
kubectl get deployments -n rollout
kubectl get statefulsets -n rollout

# ArgoCD server logs
kubectl logs -n rollout deployment/argocd-server --tail=100

# ArgoCD application controller logs
kubectl logs -n rollout statefulset/argocd-application-controller --tail=100

# ArgoCD repo server logs
kubectl logs -n rollout deployment/argocd-repo-server --tail=100

# Retrieve ArgoCD admin password
kubectl -n rollout get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | 
  ForEach-Object { [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

### Controller Not Starting After `-g` Flag
```powershell
kubectl get ds -n k2s-system
kubectl get events -n k2s-system --sort-by='.lastTimestamp'
curl -k https://k2s.registry.local:30500/v2/k2s/addon-controller-linux/tags/list
curl -k https://k2s.registry.local:30500/v2/k2s/addon-controller-windows/tags/list
```

### K2sAddon Stuck in Pulling Phase
```powershell
# Check controller logs for errors
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller --all-containers --tail=100

# Check if lastPulledDigest is being persisted (mergeStatus bug was fixed)
kubectl get k2saddon monitoring -o jsonpath='{.status.lastPulledDigest}'

# If empty after multiple reconciles, controller images may not include the mergeStatus fix.
# Rebuild images (Phase 2) and restart:
kubectl rollout restart daemonset/k2s-addon-controller-linux -n k2s-system
kubectl rollout restart daemonset/k2s-addon-controller-windows -n k2s-system
```

### ADDONS_PATH Mismatch
```powershell
# Check what ADDONS_PATH the Windows controller is using
kubectl get daemonset k2s-addon-controller-windows -n k2s-system -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ADDONS_PATH")].value}'

# Check where K2s is installed
Split-Path (Get-Command k2s -ErrorAction SilentlyContinue).Source

# If mismatched, the Install-AddonGitOpsController function should have patched it.
# Verify by checking controller logs for "addonsPath" in the startup config.
kubectl logs -n k2s-system -l app.kubernetes.io/component=windows-processor --tail=10 | Select-String "addonsPath"
```

---

## Success Criteria

The test is considered **PASSED** if:

1. ✅ K2s installs cleanly from scratch (both nodes Ready)
2. ✅ Registry addon works and is accessible from both nodes
3. ✅ All controller images build successfully
4. ✅ `k2s addons enable rollout argocd -g` deploys ArgoCD + controller in one command
5. ✅ ArgoCD pods all running (deployments + statefulset)
6. ✅ Controller DaemonSets run on both nodes (ADDONS_PATH configured correctly)
7. ✅ Monitoring addon exports to multi-layer OCI format and pushes to registry
8. ✅ Local monitoring addon removed — proving GitOps is the only delivery path
9. ✅ K2sAddon CR with `source.type: oci` is processed — controller pulls directly from registry
10. ✅ Addon files appear on host filesystem (both Windows and Linux)
11. ✅ Container images are imported correctly (Prometheus, Grafana, etc. on Linux; Windows exporter on Windows)
12. ✅ Addon appears in `k2s addons ls` (via controller-delivered files, NOT source tree)
13. ✅ Addon can be enabled via `k2s addons enable monitoring`
14. ✅ Monitoring stack functional (Prometheus scraping, Grafana accessible)
15. ✅ Update workflow works (new tag → patch K2sAddon ociRef → controller re-processes)
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
- **ArgoCD vs FluxCD**: Both implementations share the same controller (same DaemonSet images). The difference is in the K2sAddon CR `source.type` — `oci` (direct) vs `OCIRepository` (FluxCD-managed). You can even mix both on the same cluster for different addons.
- **Conflict Guard**: The ArgoCD enable script checks if FluxCD is already enabled and rejects the operation. Disable FluxCD first if switching implementations.

---

## Test Execution Log

Date: _______________  
Tester: _______________  

| Phase | Status | Notes | Time |
|-------|--------|-------|------|
| 0. Uninstall & Install K2s | ☐ | | |
| 1. Registry & Node Config | ☐ | | |
| 2. Build Controller Images | ☐ | | |
| 3. Enable ArgoCD + Controller (`-g`) | ☐ | ADDONS_PATH= | |
| 4. Export + Push + Remove Local | ☐ | | |
| 5. Deploy K2sAddon (Direct OCI) | ☐ | Pre-check passed? | |
| 6. Verify Host Files | ☐ | Controller-delivered? | |
| 7. Verify Images | ☐ | | |
| 8. Enable Monitoring Addon | ☐ | All pods running? | |
| 9. Test Update | ☐ | Generation bump? | |
| 10. Test Cleanup | ☐ | Backup restored? | |
| 11. Error Scenarios | ☐ | | |

**Overall Result:** ☐ PASS  ☐ FAIL

**Issues Encountered:**
_______________________________________________________________________________
_______________________________________________________________________________
_______________________________________________________________________________
