<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Ceph CSI Storage (CephFS)

Provides dynamic **CephFS (file) storage** for K2s. On **enable**, the addon **always provisions a
brand-new Ceph cluster** on a K2s node and wires it up through the upstream
[`ceph-csi-operator`](https://github.com/ceph/ceph-csi-operator) — no Rook required. On **disable**,
the addon can tear that cluster down again.

The target node is chosen by the **`clusterHostNode`** value in
[`config/ceph-config.json`](config/ceph-config.json): its IP address is resolved from the K2s
cluster descriptor (`cluster.json`). When `clusterHostNode` is the K2s control plane node name
(e.g. `kubemaster`), Ceph is installed on the kubemaster; otherwise it is installed on the named
node.

> **Only Debian 13 nodes are supported.** The addon validates the target node's OS over SSH on
> enable and refuses to continue on any other distribution.

After the cluster is provisioned, the addon deploys the `ceph-csi-operator` and a small set of
custom resources. The operator then reconciles those resources and creates/maintains the CephFS CSI
controller and node plugins for you.

This implementation provides:
- **A freshly provisioned single-node Ceph cluster** on the selected Debian 13 node
- **ceph-csi-operator** that manages the CephFS CSI controller and node plugins
- **Custom resources** (`Driver`, `CephConnection`, `ClientProfile`) that describe the driver and Ceph connection
- **RBAC & permissions** (ServiceAccounts, ClusterRoles, ClusterRoleBindings)
- **StorageClass** `ceph-cephfs` for `ReadWriteMany` file storage
- **Ceph cluster connection** via a Kubernetes secret (`ceph-secret`)
- **Mutual exclusion** with SMB storage (only one storage implementation can be enabled at a time)

> All addon resources are deployed into the **`ceph-csi-operator-system`** namespace.

## Prerequisites

1. **A K2s node running Debian 13** to host the Ceph cluster:
   - Its name must be listed in `cluster.json` (it is part of the K2s cluster).
   - Use the K2s control plane node name (e.g. `kubemaster`) to install Ceph on the kubemaster,
     or any other Debian 13 node name to install it there.
   - The node must be reachable over SSH and expose a blank data disk for the Ceph OSD.

   > **Only Debian 13 is supported.** Debian 12 and other distributions are rejected.

2. **K8s cluster** with:
   - API server reachable from K2s nodes
   - kubelet on every node

3. **No conflicting storage implementation:**
   - SMB storage must NOT be enabled
   - Use `k2s addons disable storage smb` first if needed

## Quick Start

### 1. Choose the Ceph host node

Edit [`config/ceph-config.json`](config/ceph-config.json) and set `clusterHostNode` to the name
of the Debian 13 K2s node that should host the new Ceph cluster (as listed in `cluster.json`). Use
the K2s control plane node name (e.g. `kubemaster`) to install Ceph on the kubemaster, or any other
Debian 13 node name to install it there:

```json
{
    "comment": "Ceph CSI Configuration - 'clusterHostNode' must be the name of a K2s node (as listed in cluster.json) running Debian 13.",
    "cephfsPool": "cephfs.cephfs.data",
    "cephfsFilesystem": "cephfs",
    "clusterHostNode": "kubemaster"
}
```

### 2. Enable Addon

```console
k2s addons enable storage ceph 
```

On enable the addon:
1. Reads `clusterHostNode` and resolves its IP address from `cluster.json`.
2. Validates over SSH that the node runs **Debian 13** (aborts otherwise).
3. Provisions a fresh single-node Ceph cluster on that node.
4. Deploys the Ceph CSI operator and the `ceph-cephfs` StorageClass.

### 3. Verify Installation

All workloads run in the `ceph-csi-operator-system` namespace:

```bash
kubectl get pods -n ceph-csi-operator-system
kubectl get storageclass | Select-String ceph
```

Expected pods (names may vary by hash):

- `ceph-csi-operator-controller-manager` — the operator that reconciles the driver
- `cephfs.csi.ceph.com-ctrlplugin` — CephFS CSI controller (provisioner/attacher/resizer/snapshotter)
- `cephfs.csi.ceph.com-nodeplugin` — CephFS CSI node plugin (one pod per node)

The `enable` command already waits for these to become ready before reporting success.

### 4. Use the Storage

There are **no manual volume-creation steps**. Enabling the addon registers the
`ceph-cephfs` StorageClass and the CSI driver, and provisioning is **dynamic**: any workload
that creates a `PersistentVolumeClaim` referencing `storageClassName: ceph-cephfs` gets a
CephFS volume created and mounted automatically — you never pre-create volumes by hand.

Simply reference the StorageClass from your application's PVC:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-app-data
spec:
  accessModes: [ "ReadWriteMany" ]
  storageClassName: ceph-cephfs
  resources:
    requests:
      storage: 10Gi
```

To validate the setup end-to-end with a throwaway PVC and pod, see
[Testing CephFS File Storage](#testing-cephfs-file-storage) below.

## Deployment Options

### Enable CephFS

```console
k2s addons enable storage ceph 
```

Only CephFS file storage is supported by this addon implementation.

### Creating an Offline Ceph Node Package

To add worker nodes that can run the CephFS CSI plugin in air-gapped environments:

```console
# Create a node package with Ceph support (use --include-ceph to include the Ceph CSI images)
k2s system package --node-package --os debian13 --include-ceph --target-dir C:\packages --name debian13-node-ceph.zip

# Transfer the package to the air-gapped environment and use it when adding the node
k2s node add --ip-addr 192.168.1.50 --username admin --node-package C:\packages\debian13-node-ceph.zip
```

The package bundles the Ceph CSI container images (`ceph-csi-operator`, `cephcsi`, and the
`sig-storage` CSI sidecars) so the addon's ceph implementation can run without pulling images from
the internet.

## Storage Classes

### CephFS (File Storage)

```yaml
StorageClass: ceph-cephfs
Provisioner: cephfs.csi.ceph.com
AccessModes: ReadWriteMany (multiple nodes)
Usage: Shared files, multi-pod access, NFS-like behavior
```

## Testing CephFS File Storage

After enabling the addon, verify that dynamic provisioning and shared (`ReadWriteMany`)
access work end-to-end against your Ceph cluster.

### 1. Confirm the driver is ready

```bash
kubectl get pods -n ceph-csi-operator-system
kubectl get storageclass ceph-cephfs
kubectl get csidriver cephfs.csi.ceph.com
```

All pods should be `Running`/`Ready`, the `ceph-cephfs` StorageClass should exist, and the
`cephfs.csi.ceph.com` CSIDriver should be registered.

### 2. Ensure the `csi` subvolume group exists

The addon provisions every volume into a CephFS subvolume group named `csi`. If it is
missing, PVCs stay `Pending` with `subvolume group 'csi' does not exist`. Check whether it
already exists on the Ceph cluster and create it if needed (replace `cephfs` with your
filesystem name):

```bash
# List existing subvolume groups
sudo cephadm shell ceph fs subvolumegroup ls cephfs

# Create it only if 'csi' is not already listed
sudo cephadm shell ceph fs subvolumegroup create cephfs csi
```

### 3. Create a PersistentVolumeClaim

```powershell
kubectl delete pvc ceph-test-pvc --ignore-not-found
@'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-test-pvc
spec:
  accessModes: [ "ReadWriteMany" ]
  storageClassName: ceph-cephfs
  resources:
    requests:
      storage: 1Gi
'@ | kubectl apply -f -
```

Wait for it to bind (a `PersistentVolume` is created automatically by the CSI controller):

```bash
kubectl get pvc ceph-test-pvc
kubectl get pv
```

Expected: `STATUS = Bound`. If it stays `Pending`, see [Troubleshooting](#troubleshooting).

### 4. Write data from a pod

```powershell
@'
apiVersion: v1
kind: Pod
metadata:
  name: ceph-writer
spec:
  containers:
  - name: writer
    image: busybox:latest
    command: ['sh', '-c', 'echo "hello from k2s ceph" > /mnt/data/hello.txt && sleep 3600']
    volumeMounts:
    - name: data
      mountPath: /mnt/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ceph-test-pvc
'@ | kubectl apply -f -

kubectl wait --for=condition=Ready pod/ceph-writer --timeout=120s
kubectl exec ceph-writer -- cat /mnt/data/hello.txt
```

Expected output: `hello from k2s ceph`.

### 5. Verify shared (ReadWriteMany) access

Because CephFS supports `ReadWriteMany`, a second pod can read the same file concurrently:

```powershell
@'
apiVersion: v1
kind: Pod
metadata:
  name: ceph-reader
spec:
  containers:
  - name: reader
    image: busybox:latest
    command: ['sh', '-c', 'sleep 3600']
    volumeMounts:
    - name: data
      mountPath: /mnt/data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ceph-test-pvc
'@ | kubectl apply -f -

kubectl wait --for=condition=Ready pod/ceph-reader --timeout=120s
kubectl exec ceph-reader -- cat /mnt/data/hello.txt
```

The reader pod sees the same `hello from k2s ceph` content written by the writer pod,
confirming shared volume access.

### 6. Clean up the test resources

```bash
kubectl delete pod ceph-writer ceph-reader --ignore-not-found
kubectl delete pvc ceph-test-pvc --ignore-not-found
```

**What actually gets deleted at each level:**

| Action | Kubernetes objects | Ceph data (`hello.txt`) | Confirmation prompt |
|--------|--------------------|--------------------------|---------------------|
| Delete the **pod** | PVC and PV are kept | **Kept** — still on Ceph | No |
| Delete the **PVC** | Bound PV is removed | **Deleted** — subvolume removed from Ceph | No (immediate) |
| Disable the **addon** | Driver/StorageClass/operator removed | Depends on flag (see [Disabling](#disabling)) | Only without `-f`/`-k` |

- Deleting a **pod** only frees the compute; the PVC, PV, and the CephFS subvolume survive.
  That is why the `ceph-reader` pod in step 5 still sees the file written by `ceph-writer`.
- Deleting the **PVC** triggers the reclaim policy. Because the `ceph-cephfs` StorageClass uses
  `reclaimPolicy: Delete`, the CSI controller calls `DeleteVolume` and the underlying CephFS
  subvolume (and its data) is **permanently removed from the Ceph cluster**. There is no
  confirmation — `kubectl delete pvc` deletes immediately, so only run it when you are sure.

> To keep data even after the PVC is deleted, use a StorageClass with `reclaimPolicy: Retain`
> instead; the PV/subvolume then remains and must be deleted manually.

## Disabling

Disabling removes the addon plumbing — the `ceph-cephfs` StorageClass, the
`cephfs.csi.ceph.com` CSIDriver, the operator, the Ceph CSI custom resources/CRDs, and the
`ceph-csi-operator-system` namespace. What happens to your PersistentVolumes (and the CephFS
data behind them) depends on which flag you pass.

### Prompt for Data Preservation

```console
k2s addons disable storage ceph
```

Without `-f`/`-k`, the command runs interactively and prompts:

```
Do you want to DELETE ALL DATA on the Ceph (CephFS) volumes? Otherwise, all data will be kept. (y/N)
```

Answer `y` to delete all PersistentVolumes (and their CephFS data); anything else keeps them.

> **Delete requires the volumes to be unused.** When you choose to delete data (prompt `y` or
> `-f`), no pods may still be mounting the `ceph-cephfs` PVCs — otherwise disable aborts with
> `Pod '<name>' is still using PVC '<pvc>' ... Delete all workloads using the SC 'ceph-cephfs'
> and try again.`. Remove the workloads first, then re-run disable:
>
> ```console
> kubectl delete pod <your-pods> --ignore-not-found
> k2s addons disable storage ceph
> ```
>
> Choosing to keep data (`N` or `-k`) has no such requirement.

### Force Delete All Data

```console
k2s addons disable storage ceph -f
```

Deletes all PersistentVolumes **without confirmation** (data loss).

### Keep All Data

```console
k2s addons disable storage ceph -k
```

Keeps all PersistentVolumes **without confirmation** (data preserved).

> **How deletion is handled safely.** When you choose to delete (prompt `y` or `-f`), the addon
> deletes the PVCs bound to the `ceph-cephfs` StorageClass **while the CSI driver is still
> running**, so `reclaimPolicy: Delete` frees the underlying CephFS subvolumes on the Ceph
> cluster before the driver and operator are removed. When you keep data (prompt `N` or `-k`),
> the PVCs/PVs are left intact.
>
> If PVs were kept and you later want to reclaim that space on the Ceph cluster, remove the
> leftover subvolumes manually:
> `sudo cephadm shell ceph fs subvolume rm cephfs <subvolume-name> csi`.

## Backup, Restore & Upgrade

Because this addon provisions a Ceph cluster on a K2s node, the only state that must be preserved to
re-enable the addon is its **configuration** (`clusterHostNode`, plus the `cephfsPool` /
`cephfsFilesystem` names). This configuration is persisted to `config/ceph-config.json` when the
addon is enabled and is what the backup/restore/upgrade flows capture. Re-enabling always
provisions a fresh Ceph cluster on the configured Debian 13 node.

### Addon backup and restore

```console
k2s addons backup storage ceph
k2s addons restore storage ceph
```

`backup` snapshots the ceph connection configuration into a zip archive. `restore` re-applies the
snapshot and re-enables the addon using the restored configuration. No user data is copied, since it
resides on the external Ceph cluster.

### System backup, restore and upgrade

`k2s system backup`, `k2s system restore`, and `k2s system upgrade` automatically preserve the ceph
connection configuration through backup/restore hooks that are registered while the addon is
enabled. During an upgrade the addon install folder is replaced (resetting `ceph-config.json` to the
shipped defaults); the restore hook writes the backed-up configuration back before the addon is
re-enabled, so the connection to the external Ceph cluster is retained without manual reconfiguration.

## Architecture

### Components Deployed

Applied by the addon (`enable`):

| Component | Type | Namespace |
|-----------|------|-----------|
| `ceph-csi-operator-controller-manager` | Deployment | `ceph-csi-operator-system` |
| `ceph-secret` | Secret | `ceph-csi-operator-system` |
| `ceph-cephfs` | StorageClass | cluster-scoped |
| `CephConnection/ceph-connection` | Custom resource | `ceph-csi-operator-system` |
| `Driver/cephfs.csi.ceph.com` | Custom resource | `ceph-csi-operator-system` |
| `ClientProfile/storage` | Custom resource | `ceph-csi-operator-system` |
| `*.csi.ceph.io` CRDs | CustomResourceDefinition | cluster-scoped |

Created and managed by the operator (from the `Driver` resource):

| Component | Type | Namespace |
|-----------|------|-----------|
| `cephfs.csi.ceph.com-ctrlplugin` | Deployment | `ceph-csi-operator-system` |
| `cephfs.csi.ceph.com-nodeplugin` | DaemonSet | `ceph-csi-operator-system` |
| `cephfs.csi.ceph.com` | CSIDriver | cluster-scoped |

### Data Flow

```
k2s addons enable storage ceph
    ↓ (applies operator + CephConnection/Driver/ClientProfile)
ceph-csi-operator reconciles the Driver resource
    ↓ (creates ctrlplugin Deployment + nodeplugin DaemonSet + CSIDriver)
Pod requests PVC (storageClassName: ceph-cephfs)
    ↓
CephFS CSI controller (ctrlplugin)
    ↓ (CreateVolume → uses ceph-secret + CephConnection monitors)
Provisioned Ceph cluster creates a CephFS subvolume
    ↓
PersistentVolume created and bound
    ↓
CephFS CSI node plugin (nodeplugin) stages/publishes the volume
    ↓
Volume mounted into the Pod (ReadWriteMany)
```

## Configuration

File: `addons/storage/ceph/config/ceph-config.json`

```json
{
  "comment": "Ceph CSI Configuration - 'clusterHostNode' must be the name of a K2s node (as listed in cluster.json) running Debian 13.",
  "cephfsPool": "cephfs.cephfs.data",
  "cephfsFilesystem": "cephfs",
  "clusterHostNode": "kubemaster"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `clusterHostNode` | Yes | Name of the K2s node (as listed in `cluster.json`) that hosts the new Ceph cluster. Must run **Debian 13**. Use the control plane node name (e.g. `kubemaster`) for the kubemaster, or another Debian 13 node name. |
| `cephfsPool` | No | CephFS **data pool** name (default `cephfs.cephfs.data`). Refreshed with the value read back from the freshly provisioned cluster. |
| `cephfsFilesystem` | No | CephFS filesystem name (default `cephfs`). |
| `comment` | No | Free-text note; ignored by the addon. |

When no config object is passed by the CLI, `enable` falls back to this file, so the
`edit ceph-config.json` → `k2s addons enable storage ceph` workflow works out of the box.

> The generated `ceph-cephfs` StorageClass uses `clusterID: storage`, which references the
> `ClientProfile/storage` resource created by the addon.

## Validation & Mutual Exclusion

### SMB vs Ceph

**Only ONE storage backend can be enabled at a time.**

If SMB is active and you try to enable Ceph:

```
❌ ERROR: Cannot enable storage ceph: smb storage is already enabled.
          Please disable smb storage first using:
          k2s addons disable storage smb
```

**How to switch:**

```bash
# 1. Disable SMB
k2s addons disable storage smb -k

# 2. Enable Ceph
k2s addons enable storage ceph
```

### Validation Checks

Enable command validates:
1. ✅ No conflicting storage implementation (SMB) is active
2. ✅ `clusterHostNode` is set and exists in `cluster.json`
3. ✅ The target node runs **Debian 13** (checked over SSH)
4. ✅ K8s cluster is available
5. ✅ Namespaces can be created
6. ✅ Secrets can be created

## Troubleshooting

### 1. CSI Pods Not Starting

```console
kubectl get pods -n ceph-csi-operator-system
kubectl logs -n ceph-csi-operator-system -l control-plane=ceph-csi-op-controller-manager --tail=50
kubectl logs -n ceph-csi-operator-system -l app.kubernetes.io/component=cephfs-controller,app.kubernetes.io/part-of=k2s-ceph-csi --tail=50
```

**Common causes:**
- Invalid monitor endpoints (typo or unreachable)
- Invalid keyring
- Missing Ceph pools
- Operator has not finished reconciling the `Driver` resource yet

### 2. PVC Stuck in Pending

```console
kubectl describe pvc <pvc-name>
```

**Check CSI controller events and logs:**

```console
kubectl get events --sort-by='.lastTimestamp'
kubectl logs -n ceph-csi-operator-system deployment/cephfs.csi.ceph.com-ctrlplugin --tail=50
```

**`subvolume group 'csi' does not exist`** — the CephFS subvolume group referenced by the
addon (`ClientProfile/storage` → `spec.cephFs.subVolumeGroup: csi`) is missing on the Ceph
cluster. Create it once (replace `cephfs` with your filesystem name), then the PVC provisions
on the next retry:

```bash
sudo cephadm shell ceph fs subvolumegroup create cephfs csi
sudo cephadm shell ceph fs subvolumegroup ls cephfs
```

**`invalid pool layout '<name>'--need a valid data pool`** — the `cephfsPool` in the config
is set to the *filesystem name* instead of an actual CephFS **data pool**. Find the real data
pool and set `cephfsPool` to it, then re-enable the addon (the StorageClass `pool` parameter is
immutable, so it must be recreated):

```bash
sudo cephadm shell ceph fs ls
# name: cephfs, metadata pool: ..., data pools: [cephfs_data]   <-- use the data pool
```

```console
k2s addons disable storage ceph -k
k2s addons enable storage ceph
```

### 3. Verify Ceph Connectivity

```bash
# Run debug pod
kubectl run -it --rm debug --image=ubuntu:24.04 --restart=Never -- bash

# Inside pod:
apt-get update && apt-get install -y ceph-common
ceph -m 10.0.0.1:6789 --name client.admin --keyring /etc/ceph/ceph.client.admin.keyring status
```

### 4. Check Secret Configuration

```bash
# View secret (redacted)
kubectl get secret ceph-secret -n ceph-csi-operator-system -o yaml
```

### 5. Inspect Operator Custom Resources

```bash
kubectl get drivers,cephconnections,clientprofiles -n ceph-csi-operator-system
kubectl describe driver cephfs.csi.ceph.com -n ceph-csi-operator-system
```

## Security Notes

- **Keyring management** — Store Ceph keys securely, never commit to git
- **RBAC** — The operator and CSI plugins run under dedicated ServiceAccounts
- **Network policies** — Consider restricting CSI driver communication
- **TLS** — Use TLS for Ceph connections in production
- **Quotas** — Set resource requests/limits on CSI pods

## Performance Tuning

### Controller Replicas

The CephFS CSI controller (`cephfs.csi.ceph.com-ctrlplugin`) runs with **1 replica** by
default, which matches a single-schedulable-node K2s setup. On multi-node clusters you can
increase it for high availability by editing `spec.controllerPlugin.replicas` in
`addons/storage/ceph/manifests/cephfs-driver.yaml` before enabling the addon.

### CephFS Mounter

Use the kernel mounter for better throughput than FUSE:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-cephfs-kernel
provisioner: cephfs.csi.ceph.com
parameters:
  clusterID: storage
  mounter: kernel  # Faster than fuse
```

## Limits

- **Max volumes per node** — Depends on Ceph cluster and CephFS client limits
- **Volume size** — Limited by Ceph cluster capacity
- **Network** — Bandwidth limited by network MTU and cluster capacity

## References

- [Ceph CSI Documentation](https://docs.ceph.com/en/latest/cephfs/fs-volumes/)
- [CSI Specification](https://github.com/container-storage-interface/spec)
- [Ceph Documentation](https://docs.ceph.com/)
- [Storage Implementations Guide](../STORAGE_IMPLEMENTATIONS.md)

## Support

For issues:
1. Check logs: `kubectl logs -n ceph-csi-operator-system ...`
2. Verify Ceph cluster: `ceph status`
3. Review configuration: `addons/storage/ceph/config/ceph-config.json` (`clusterHostNode` must be a Debian 13 node in `cluster.json`)
4. Check mutual exclusion: `k2s addons status storage smb`
