<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# controller

## Introduction

The `controller` is a component of the **rollout** addon, enabled via the `--addongitops` / `-g` flag. It runs a Kubernetes controller that watches [K2sAddon](https://k2s.siemens-healthineers.com) custom resources backed by FluxCD `OCIRepository` sources. When FluxCD detects a new addon artifact in the registry, the controller automatically pulls, extracts, and stages the addon on every node — making it available via `k2s addons enable` without manual intervention.

This brings a full GitOps workflow to K2s addons: push an OCI artifact to a registry, let FluxCD watch it, and the controller reconciles the cluster state automatically.

## Getting started

### Prerequisites

- K2s cluster running (`k2s status` shows `running`, both nodes `Ready`)
- Registry addon enabled (`k2s addons enable registry`)
- [oras](https://oras.land/) CLI installed (`winget install oras-project.oras`)

### Step 1: Enable FluxCD and the controller

```console
k2s addons enable rollout fluxcd -g
```

This enables FluxCD **and** the GitOps addon controller in a single command.

Verify everything is running:

```console
kubectl get pods -n rollout --watch           # FluxCD pods
kubectl get pods -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller -o wide   # controller pods
```

Expected: FluxCD pods in `rollout` namespace are `Running`; one controller pod on the Linux master node, one on the Windows worker node.

### Step 2: Export and push an addon artifact

Use the built-in K2s export pipeline to produce an OCI artifact from any addon and push it to a registry:

```powershell
# 1. Export the addon to an OCI Image Layout tar
k2s addons export "metrics" -d C:\Temp\metrics-export

# 2. Extract the tar (oras requires a directory, not a tar file)
$tar = (Get-ChildItem C:\Temp\metrics-export -Filter *.oci.tar)[0].FullName
New-Item -ItemType Directory -Force C:\Temp\metrics-oci | Out-Null
tar -xf $tar -C C:\Temp\metrics-oci

# 3. Push the OCI layout to a registry
$digest = (Get-Content C:\Temp\metrics-oci\artifacts\index.json | ConvertFrom-Json).manifests[0].digest
oras copy --from-oci-layout "C:\Temp\metrics-oci\artifacts@${digest}" `
  --to-plain-http k2s.registry.local:30500/k2s/addons/metrics:v1.0.0
```

> **Why extract first?** The `k2s addons export` command produces an OCI Image Layout packaged as a `.oci.tar`. The `oras copy --from-oci-layout` command only accepts a directory path, not a tar file, so the extraction step is required.

### Step 3: Create a FluxCD OCIRepository

Tell FluxCD to watch the addon artifact in the registry:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: metrics-addon
  namespace: rollout
spec:
  interval: 5m
  url: oci://k2s.registry.local:30500/k2s/addons/metrics
  ref:
    tag: v1.0.0
  insecure: true
  provider: generic
```

```console
kubectl apply -f ocirepository-metrics.yaml
```

Wait until FluxCD has fetched the artifact:

```console
kubectl get ocirepository -n rollout metrics-addon
```

The `READY` column should show `True` and the `ARTIFACT` column should display the resolved digest.

### Step 4: Create a K2sAddon resource

Point the `K2sAddon` at the FluxCD `OCIRepository` — not directly at the registry:

```yaml
apiVersion: k2s.siemens-healthineers.com/v1alpha1
kind: K2sAddon
metadata:
  name: metrics
spec:
  name: metrics
  version: "1.0.0"
  source:
    type: OCIRepository
    ociRepository:
      name: metrics-addon
      namespace: rollout
```

```console
kubectl apply -f k2saddon-metrics.yaml
```

### Step 5: Monitor and enable

```console
kubectl get k2saddon metrics --watch
```

The status progresses: `Pending` → `Pulling` → `Processing` → `Available`.

Once `Available`, the addon is delivered to every node and appears in the CLI:

```console
k2s addons ls
k2s addons enable metrics
```

## How the FluxCD integration works

```
┌─────────────┐       ┌────────────────┐       ┌──────────────────┐
│ OCI Registry│◄──────│  oras push     │       │   FluxCD         │
│ (artifact)  │       │  (one-time)    │       │  OCIRepository   │
└──────┬──────┘       └────────────────┘       │  (polls every 5m)│
       │                                       └────────┬─────────┘
       │                 digest changes                  │
       │◄────────────────────────────────────────────────┘
       │
       ▼
┌──────────────────┐     ┌──────────────────────────────────┐
│  K2sAddon CR     │────►│  Controller (DaemonSet)          │
│  source.type:    │     │  - detects digest change          │
│  OCIRepository   │     │  - pulls OCI layers               │
└──────────────────┘     │  - extracts addons to nodes       │
                         │  - imports container images        │
                         │  - sets phase: Available           │
                         └──────────────────────────────────┘
```

1. **You push** an addon OCI artifact to a registry (once, or via CI).
2. **FluxCD polls** the registry on the configured interval and tracks the digest.
3. **Controller watches** the `K2sAddon` CR, reads the linked `OCIRepository`, and reconciles when the digest changes.
4. **Addon is staged** on all nodes — the controller extracts config, manifests, scripts, container images, and packages from the 7-layer OCI artifact.
5. **You enable** the addon via `k2s addons enable <name>`.

## Updating an addon

To deliver a new version, push a new tag to the registry and update the `OCIRepository` reference:

```powershell
# Push the new version
oras copy --from-oci-layout "artifacts@${digest}" `
  --to-plain-http `
  k2s.registry.local:30500/k2s/addons/metrics:v1.1.0
```

```console
kubectl patch ocirepository metrics-addon -n rollout \
  --type merge -p '{"spec":{"ref":{"tag":"v1.1.0"}}}'
```

FluxCD detects the new digest, and the controller automatically re-processes the addon — no manual `K2sAddon` patching required.

Verify the update:

```console
kubectl get k2saddon metrics --watch
# Status: Available → Pulling → Processing → Available
```

## Using a private registry

To pull addon artifacts from a private OCI registry, configure FluxCD authentication:

### Registry credentials for FluxCD

```console
kubectl create secret docker-registry registry-credentials \
  --docker-server=private-registry.example.com \
  --docker-username=user \
  --docker-password=password \
  -n rollout
```

Reference the secret in the `OCIRepository`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: monitoring-addon
  namespace: rollout
spec:
  interval: 5m
  url: oci://private-registry.example.com/k2s/addons/monitoring
  ref:
    tag: v2.0.0
  provider: generic
  secretRef:
    name: registry-credentials
```

Then create the `K2sAddon` pointing at this `OCIRepository`:

```yaml
apiVersion: k2s.siemens-healthineers.com/v1alpha1
kind: K2sAddon
metadata:
  name: monitoring
spec:
  name: monitoring
  version: "2.0.0"
  source:
    type: OCIRepository
    ociRepository:
      name: monitoring-addon
      namespace: rollout
```

### Pull secret on the controller (direct OCI pull)

If the controller needs to pull directly (without FluxCD), create a pull secret in the controller namespace:

```console
kubectl create secret docker-registry registry-credentials \
  --docker-server=private-registry.example.com \
  --docker-username=user \
  --docker-password=password \
  -n k2s-system
```

```yaml
spec:
  source:
    type: oci
    ociRef: private-registry.example.com/k2s/addons/monitoring:v2.0.0
    pullSecretRef:
      name: registry-credentials
      namespace: k2s-system
```

## Skipping specific layers

If certain addon layers are not needed (e.g., container images are already present), they can be skipped:

```yaml
spec:
  layers:
    skipImages: true        # Skip all container images
    skipLinuxImages: true   # Skip only Linux images
    skipWindowsImages: true # Skip only Windows images
    skipPackages: true      # Skip OS packages
    skipManifests: true     # Skip Kubernetes manifests
```

## Managing multiple addons with FluxCD Kustomization

For teams managing many addons, store all `OCIRepository` and `K2sAddon` definitions in a Git repository and let FluxCD sync them via a `Kustomization`:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: k2s-addons
  namespace: rollout
spec:
  interval: 5m
  path: ./addons
  prune: true
  sourceRef:
    kind: GitRepository
    name: k2s-gitops
  healthChecks:
    - apiVersion: k2s.siemens-healthineers.com/v1alpha1
      kind: K2sAddon
      name: metrics
    - apiVersion: k2s.siemens-healthineers.com/v1alpha1
      kind: K2sAddon
      name: monitoring
  timeout: 10m
```

Your Git repo structure:

```
k2s-gitops/
└── addons/
    ├── metrics-ocirepository.yaml
    ├── metrics-k2saddon.yaml
    ├── monitoring-ocirepository.yaml
    └── monitoring-k2saddon.yaml
```

Pushing a commit to the repo automatically applies all `K2sAddon` resources — full GitOps.

## K2sAddon status reference

| Phase | Description |
|-------|-------------|
| `Pending` | Addon CR created, waiting for processing |
| `Pulling` | Downloading OCI artifact from registry (via FluxCD digest) |
| `Processing` | Extracting and installing addon layers on nodes |
| `Available` | Addon is staged and ready for `k2s addons enable` |
| `Failed` | An error occurred (see `status.errorMessage`) |

Inspect the full status:

```console
kubectl get k2saddon <name> -o yaml
```

Key status fields:

- `status.phase` — current lifecycle phase
- `status.available` — `true` when the addon is fully staged
- `status.lastPulledDigest` — the OCI digest last processed (used to detect changes)
- `status.layers` — per-layer processing status
- `status.nodeStatuses` — per-node delivery status
- `status.conditions` — standard Kubernetes conditions (`Ready`, `Progressing`, etc.)

## Troubleshooting

### OCIRepository not ready

```console
kubectl get ocirepository -n rollout <name> -o yaml
```

Check `status.conditions` for fetch errors. Common causes:

- Wrong `url` (must start with `oci://`)
- Tag does not exist in registry
- Missing `insecure: true` for plain-HTTP registries
- Missing `secretRef` for private registries

### Addon stuck in Pulling phase

The controller reads the artifact URL from the `OCIRepository` status. If FluxCD has not fetched yet, the pull cannot start.

```console
# Check FluxCD has fetched the artifact
kubectl get ocirepository -n rollout <name>

# Check controller logs
kubectl logs -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller --tail=50
```

### Addon shows Failed phase

Inspect the error message:

```console
kubectl get k2saddon <name> -o jsonpath='{.status.errorMessage}'
```

### Controller pods not starting

```console
kubectl describe pods -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller
```

### FluxCD pods not running

```console
kubectl get pods -n rollout
kubectl describe pods -n rollout
```

If FluxCD is not installed, enable it first:

```console
k2s addons enable rollout fluxcd
```

## Disable controller

```console
k2s addons disable rollout fluxcd
```

_Note:_ Disabling the rollout addon automatically removes the controller DaemonSets, RBAC, and CRD if they were deployed. Any `K2sAddon` custom resources will be deleted as part of the cleanup. FluxCD `OCIRepository` resources are removed with FluxCD.

## Developer testing

<details>
<summary>Building and testing the controller from source</summary>

### Prerequisites

- K2s cluster running with `registry` and `rollout fluxcd -g` enabled
- Go toolchain installed

### Building controller images

```powershell
cd C:\ws

# Build and push Linux controller image
k2s image build `
  --input-folder "addons\rollout\controller\pkg\controller" `
  --dockerfile "addons\rollout\controller\Dockerfile" `
  --image-name k2s.registry.local:30500/k2s/addon-controller-linux `
  --image-tag latest -p -o

# Build and push Windows controller image (PreCompile approach)
Push-Location addons\rollout\controller\pkg\controller
go build -o addon-controller.exe -ldflags="-s -w" ./cmd/
Pop-Location

k2s image build `
  --input-folder "addons\rollout\controller\pkg\controller" `
  --dockerfile "addons\rollout\controller\Dockerfile.windows" `
  --windows `
  --image-name k2s.registry.local:30500/k2s/addon-controller-windows `
  --image-tag latest -p -o

Remove-Item addons\rollout\controller\pkg\controller\addon-controller.exe -ErrorAction SilentlyContinue
```

### Restart the controller to pick up new images

```console
kubectl delete pod -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller
kubectl get pods -n k2s-system -l app.kubernetes.io/name=k2s-addon-controller --watch
```

### Configure insecure registry on Linux node

```powershell
ssh -o StrictHostKeyChecking=no -i ~\.ssh\k2s\id_rsa remote@172.19.1.100 bash -c '
cat <<EOF | sudo tee -a /etc/containers/registries.conf

[[registry]]
location = "k2s.registry.local:30500"
insecure = true
EOF
sudo systemctl restart crio
'
```

### Run unit tests

```powershell
cd C:\ws\addons\rollout\controller\pkg\controller
go test ./... -v -count=1
```

</details>

## Further reading

- [K2s Addons Export/Import](../README.md) — how OCI addon artifacts are produced
- [FluxCD OCI Repositories](https://fluxcd.io/flux/components/source/ocirepositories/) — FluxCD source for OCI artifacts
- [FluxCD Kustomizations](https://fluxcd.io/flux/components/kustomize/) — syncing resources from Git
- [OCI Artifacts](https://github.com/opencontainers/image-spec)
- [ORAS](https://oras.land/) — OCI Registry As Storage
