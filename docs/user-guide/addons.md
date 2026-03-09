<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Addons

*K2s* provides a rich set of **addons** that deliver optional, pre-configured open-source components in a plugin-like manner. Addons can be enabled, disabled, exported, imported, backed up, and restored entirely through the `k2s` CLI.

## Why Use Addons?

Deploying individual workloads (e.g., manually installing an ingress controller, a monitoring stack, or a container registry) requires:

- Finding and validating compatible Helm charts or manifests for your Kubernetes version
- Configuring networking, storage, and security to match your cluster
- Managing updates and version compatibility across components
- Handling offline image pre-loading for air-gapped environments
- Writing custom backup/restore logic for each component

**K2s addons solve all of these problems out of the box.** Each addon:

- **Is pre-tested** against the shipped Kubernetes version — no compatibility guesswork
- **Integrates with the K2s cluster** networking, storage, and proxy configuration automatically
- **Supports offline usage** — addon images can be exported as OCI artifacts and imported without network access
- **Provides lifecycle management** — enable, disable, update, backup, and restore via single CLI commands
- **Is versioned with K2s** — addon updates are coordinated with cluster upgrades
- **Follows consistent patterns** — same CLI workflow for every addon, reducing operational complexity

### Comparison: Addons vs. Manual Workloads

| Aspect | K2s Addon | Manual Workload |
|--------|-----------|-----------------|
| Installation | `k2s addons enable <name>` | Find charts, write values, `helm install`, debug |
| Offline support | `k2s addons export` / `import` | Manual image pull, save, transfer, load |
| Configuration | Pre-configured for K2s | Manual adjustment for networking, storage, proxy |
| Updates | `k2s addons enable <name>` (re-enable with new version) | Manual chart/manifest version management |
| Backup & Restore | `k2s addons backup` / `restore` | Custom scripts per component |
| Status check | `k2s addons status <name>` | Manual `kubectl` queries per component |
| GitOps deployment | Rollout addon with ArgoCD or Flux CD | Set up GitOps tooling from scratch |
| Version compatibility | Tested with shipped K8s version | User must verify compatibility |

## Available Addons

| Addon | Description |
|-------|-------------|
| **autoscaling** | Horizontal workload scaling based on external events with KEDA |
| **dashboard** | Kubernetes Dashboard for cluster visualization |
| **dicom** | DICOM server based on Orthanc |
| **gpu-node** | GPU access for the control plane node |
| **ingress** | Ingress controllers (nginx, nginx-gw, traefik implementations) |
| **kubevirt** | VM workload management on Kubernetes |
| **logging** | Container log dashboard |
| **metrics** | Kubernetes metrics server for API access to service metrics |
| **monitoring** | Cluster resource monitoring and logging dashboard |
| **registry** | Private image registry on `k2s.registry.local` |
| **rollout** | GitOps deployment automation (ArgoCD or Flux CD) |
| **security** | Secure communication inside the cluster |
| **storage** | SMB-based StorageClass provisioning between K8s nodes |
| **viewer** | Clinical image viewer |

!!! tip
    Some addons have multiple **implementations**. For example, the *ingress* addon offers `nginx`, `nginx-gw`, and `traefik`. Specify the implementation when enabling: `k2s addons enable ingress nginx`.

## Addon Configuration Details

This section documents the CLI flags available for each addon. Flags without defaults are optional unless marked otherwise.

### ingress

Three mutually exclusive implementations for external access:

| Implementation | Engine | Description |
|----------------|--------|-------------|
| `nginx` | NGINX Ingress Controller | Reverse proxy based on NGINX |
| `traefik` | Traefik Proxy | Cloud-native reverse proxy |
| `nginx-gw` | NGINX Gateway Fabric | Gateway API-based NGINX controller |

```console
k2s addons enable ingress nginx
k2s addons enable ingress traefik
k2s addons enable ingress nginx-gw
```

No additional flags. Only one ingress implementation can be active at a time.

### dashboard

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | | string | `none` | Ingress controller to expose the dashboard (`none`, `nginx`, `nginx-gw`, `traefik`) |
| `--enable-metrics` | | boolean | `false` | Enable metrics display in the dashboard |

```console
k2s addons enable dashboard --ingress nginx --enable-metrics
```

### monitoring

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `none` | Ingress controller for the monitoring dashboard (`none`, `nginx`, `nginx-gw`, `traefik`) |

Includes Windows node metrics collection via `windows-exporter` alongside Linux metrics via `node-exporter`.

### logging

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | | string | `none` | Ingress controller for log dashboards (`none`, `nginx`, `nginx-gw`, `traefik`) |

### registry

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `nginx` | Ingress controller for the registry (`nginx`, `nginx-gw`, `traefik`) |

| Disable Flag | Short | Type | Default | Description |
|--------------|-------|------|---------|-------------|
| `--delete-images` | `-d` | boolean | `false` | Delete all images stored in the local registry |

The registry is exposed on `k2s.registry.local`.

### security

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `nginx` | Ingress controller (`nginx`, `traefik`, `nginx-gw`) |
| `--type` | `-t` | string | `basic` | Security level: `basic` (cert-manager only) or `enhanced` (zero trust with Linkerd + OAuth2) |
| `--omitHydra` | | boolean | `false` | Skip Ory Hydra and Windows login integration |
| `--omitKeycloak` | | boolean | `false` | Skip Keycloak — use an external OAuth2 provider instead |
| `--omitOAuth2Proxy` | | boolean | `false` | Skip OAuth2 Proxy deployment |

```console
# Basic: cert-manager only
k2s addons enable security

# Enhanced: zero trust with full authentication stack
k2s addons enable security --type enhanced --ingress nginx

# Enhanced with external IdP (no Keycloak)
k2s addons enable security --type enhanced --omitKeycloak
```

See [Security Features](../security/security-features.md) for details on the zero-trust architecture.

### rollout

Two mutually exclusive GitOps implementations:

**ArgoCD:**

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `none` | Ingress controller for the ArgoCD dashboard (`none`, `nginx`, `nginx-gw`, `traefik`) |

**Flux CD:**

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `none` | Ingress controller for the webhook receiver (`none`, `nginx`, `nginx-gw`, `traefik`) |

When you enable `rollout fluxcd`, *K2s* installs the host Flux CLI at `bin\\flux.exe`. In offline environments the CLI zip is bundled in the addon export and extracted on import.

```console
k2s addons enable rollout argocd --ingress nginx
k2s addons enable rollout fluxcd --ingress traefik
```

### storage

Implementation: `smb` (SMB file sharing between K8s nodes).

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--smbHostType` | `-t` | string | `windows` | SMB host type: `windows` or `linux` |

| Disable Flag | Short | Type | Default | Description |
|--------------|-------|------|---------|-------------|
| `--force` | `-f` | boolean | `false` | Disable and **delete all data** without confirmation |
| `--keep` | `-k` | boolean | `false` | Disable and **keep all data** without confirmation |

!!! warning
    `--force` and `--keep` are mutually exclusive.

```console
k2s addons enable storage smb --smbHostType linux
k2s addons disable storage smb --keep
```

### dicom

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | | string | `none` | Ingress controller (`none`, `nginx`, `nginx-gw`, `traefik`) |
| `--storage` | | string | `none` | Storage addon for persistent DICOM data (`none`, `smb`) |
| `--storagedir` | | string | `none` | Path to SMB storage directory (e.g. `/mnt/k8s-smb-share`) |

| Disable Flag | Short | Type | Default | Description |
|--------------|-------|------|---------|-------------|
| `--force` | `-f` | boolean | `false` | Disable and **delete all data** without confirmation |

```console
k2s addons enable dicom --ingress nginx --storage smb --storagedir /mnt/k8s-smb-share
```

### viewer

| Enable Flag | Short | Type | Default | Description |
|-------------|-------|------|---------|-------------|
| `--ingress` | `-i` | string | `nginx` | Ingress controller (`nginx`, `nginx-gw`, `traefik`) |
| `--nodeport` | `-n` | integer | `0` | NodePort for direct viewer access (range: 30000–32767, `0` = disabled) |

```console
k2s addons enable viewer --ingress traefik --nodeport 31000
```

### kubevirt

No CLI flags. Enables VM workload management on Kubernetes.

When used offline, the addon installs QEMU, libvirt, and `virtctl` on the Linux VM, and `virt-viewer` MSI plus `virtctl` on the Windows host.

Additional helper scripts:

- `BuildKubevirtImage.ps1` — build VM disk images for KubeVirt
- `UploadImage.ps1` — upload disk images to a running KubeVirt instance

### gpu-node

No CLI flags. Configures the Linux control-plane node to use NVIDIA GPUs.

Installs the NVIDIA container toolkit on the Linux VM. For WSL 2 setups, a custom kernel image (`microsoft-standard-wsl2`) is used to enable GPU passthrough.

### autoscaling

No CLI flags. Installs [KEDA](https://keda.sh){target="_blank"} (Kubernetes Event-Driven Autoscaling) for horizontally scaling workloads based on external events or triggers.

### metrics

No CLI flags. Installs the Kubernetes **metrics server**, enabling `kubectl top nodes`, `kubectl top pods`, and Horizontal Pod Autoscaler (HPA) support.

## Managing Addons

### Listing Addons

```console
k2s addons ls
```

### Enabling an Addon

```console
# Enable an addon (single implementation)
k2s addons enable dashboard

# Enable an addon with a specific implementation
k2s addons enable ingress nginx

# Enable with flags
k2s addons enable dashboard --ingress
```

### Disabling an Addon

```console
k2s addons disable dashboard
k2s addons disable ingress nginx
```

### Checking Addon Status

```console
k2s addons status dashboard
k2s addons status ingress nginx

# JSON output
k2s addons status registry -o json
```

## Offline Usage: OCI Export & Import

One of the most powerful addon features is the ability to **export addons as OCI-compliant artifacts** and **import them on air-gapped systems**. This enables fully offline addon deployment without any network access.

### How It Works

When you export an addon, K2s packages everything needed into a single OCI-compliant tar archive:

- Container images (Linux and Windows)
- Kubernetes manifests
- Helm charts
- Configuration files
- Enable/Disable scripts

The resulting `.oci.tar` file follows the [OCI Image Layout Specification](https://github.com/opencontainers/image-spec/blob/main/image-layout.md){target="_blank"}, making it compatible with standard container tooling.

### Exporting Addons

```console
# Export all addons
k2s addons export -d C:\export

# Export a specific addon
k2s addons export registry -d C:\export

# Export a specific implementation
k2s addons export "ingress nginx" -d C:\export
```

The export produces a file like `addons.oci.tar` containing all requested addon artifacts.

### Importing Addons

On the target system (which may be offline), import the previously exported archive:

```console
# Import all addons from archive
k2s addons import -z C:\transfer\addons.oci.tar

# Import a specific addon
k2s addons import registry -z C:\transfer\addons.oci.tar

# Import a specific implementation
k2s addons import "ingress nginx" -z C:\transfer\addons.oci.tar
```

After import, the addon images are loaded into the cluster's container runtime and the addon can be enabled normally.

### Typical Offline Workflow

1. **On an online machine** with K2s installed, export the addons you need:
   ```console
   k2s addons export "ingress nginx" registry monitoring -d C:\export
   ```
2. **Transfer** the `addons.oci.tar` file to the air-gapped environment (USB drive, secure file transfer, etc.)
3. **On the offline machine**, import and enable:
   ```console
   k2s addons import -z D:\transfer\addons.oci.tar
   k2s addons enable ingress nginx
   k2s addons enable registry
   k2s addons enable monitoring
   ```

## Backup & Restore

Addons support data backup and restore for disaster recovery or migration scenarios.

### Backing Up Addon Data

```console
# Backup to a specific file
k2s addons backup registry -f C:\backups\registry-backup.zip

# Backup to default location (C:\Temp\k2s\Addons)
k2s addons backup registry
```

### Restoring Addon Data

```console
# Restore from a specific file
k2s addons restore registry -f C:\backups\registry-backup.zip

# Restore newest backup from default location
k2s addons restore registry
```

## GitOps with the Rollout Addon

The **rollout** addon provides GitOps-based continuous deployment using either **ArgoCD** or **Flux CD**. This is especially powerful when combined with addon OCI export/import for offline environments.

### Why GitOps?

- **Declarative deployments** — desired state is defined in Git, not applied manually
- **Audit trail** — every change is a Git commit
- **Automated reconciliation** — drift from desired state is automatically corrected
- **Reproducible environments** — same Git repo produces identical deployments

### ArgoCD Implementation

```console
k2s addons enable rollout argocd
```

ArgoCD provides a web dashboard at `https://k2s.cluster.local/rollout` (when ingress is configured) for visual deployment management. It supports:

- Application deployment from Git repositories
- Sync status visualization
- Rollback capabilities
- Multi-application management

Optional ingress integration:
```console
k2s addons enable rollout argocd --ingress nginx
```

### Flux CD Implementation

```console
k2s addons enable rollout fluxcd
```

Flux CD provides a CLI/YAML-only GitOps experience with:

- `GitRepository`, `Kustomization`, `HelmRepository`, `HelmRelease` CRDs
- Automatic polling of Git repositories (default: every 1 minute)
- Optional webhook ingress for push-based notifications

Optional ingress integration:
```console
k2s addons enable rollout fluxcd --ingress traefik
```

### Offline GitOps Workflow

Combining OCI export/import with the rollout addon enables GitOps in air-gapped environments:

1. **Export** the rollout addon (and any other addons your applications depend on):
   ```console
   k2s addons export rollout "ingress nginx" registry -d C:\export
   ```
2. **Transfer** and **import** on the offline cluster:
   ```console
   k2s addons import -z D:\transfer\addons.oci.tar
   k2s addons enable rollout argocd --ingress nginx
   ```
3. **Configure ArgoCD/Flux** to point to a local Git server (also deployed in the cluster or available on the local network) containing your application manifests.

!!! note
    Only one rollout implementation can be active at a time — ArgoCD and Flux CD are mutually exclusive.

## See Also

- [Creating Offline Package](../op-manual/creating-offline-package.md) — includes addon packaging in the K2s offline package
- [Upgrading K2s](../op-manual/upgrading-k2s.md) — addon behavior during cluster upgrades
