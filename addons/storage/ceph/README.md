<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Ceph CSI Storage (CephFS)

Provides dynamic **CephFS (file) storage** for K2s. On **enable**, the addon **always provisions a
brand-new Ceph cluster** on a K2s node and wires it up through the upstream
[`ceph-csi-operator`](https://github.com/ceph/ceph-csi-operator) — no Rook required. On **disable**,
the addon can tear that cluster down again.

The cluster bootstrap node is chosen by **`clusterHost.node`** in
[`config/ceph-config.json`](config/ceph-config.json): its IP address is resolved from the K2s
cluster descriptor (`cluster.json`). When `clusterHost.node` is the K2s control plane node name
(e.g. `kubemaster`), Ceph is installed on the kubemaster; otherwise it is installed on the named
node. OSD provisioning is configured separately via `osdHosts`.

> **Only Debian 13 nodes are supported.** The addon validates the target node's OS over SSH on
> enable and refuses to continue on any other distribution.
>
> **Only Hyper-V worker nodes are supported for OSD provisioning.** `osdHosts` entries must
> resolve to `cluster.json` nodes with `NodeType` = `VM-EXISTING`.

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
   - The node must be reachable over SSH.

   > **Only Debian 13 is supported.** Debian 12 and other distributions are rejected.

2. **K8s cluster** with:
   - API server reachable from K2s nodes
   - kubelet on every node

3. **No conflicting storage implementation:**
   - SMB storage must NOT be enabled
   - Use `k2s addons disable storage smb` first if needed

## Quick Start

### 1. Configure cluster host and OSD hosts

Edit [`config/ceph-config.json`](config/ceph-config.json). Set `clusterHost.node` to the Debian 13
bootstrap node for the Ceph cluster, then list every OSD node under `osdHosts`.

- `clusterHost` controls Ceph cluster bootstrap settings only (`monCount`, `mgrCount`, `mdsCount`,
  `osdCrushChooseleafType`).
- `osdHosts` drives OSD host preparation and OSD creation.
- Each `osdHosts` entry supports `osdCount` and either:
  - `osdSizesInGb`: one size per OSD, or
  - `osdSizeInGb`: one common size for all OSDs on that host.

```json
{
  "comment": "Ceph CSI storage config. 'clusterHost.node' bootstraps only the Ceph cluster control plane and MUST be a Debian 13 K2s node listed in cluster.json (or the control plane node). OSD provisioning is driven exclusively by 'osdHosts' and supports only Hyper-V worker nodes (cluster.json NodeType 'VM-EXISTING'). Each entry in 'osdHosts' is prepared as a Ceph OSD host (via prepare-ceph-osd-host.sh) and contributes OSDs. Use 'osdSizesInGb' to set per-OSD sizes (one value per OSD) or 'osdSizeInGb' for one common size. 'windowsHosts' is a placeholder for future Windows OSD/client support and is currently NOT provisioned.",
  "cephfsFilesystem": "cephfs",
  "cephfsPool": "cephfs.cephfs.data",
  "clusterHost": {
    "node": "kubemaster",
    "os": "linux",
    "osdCrushChooseleafType": 0,
    "monCount": 1,
    "mgrCount": 1,
    "mdsCount": 1
  },
  "osdHosts": [
    {
      "node": "kubemaster",
      "os": "linux",
      "osdCount": 1,
      "osdSizesInGb": [
        10
      ]
    },
    {
      "node": "cephosdnode1",
      "os": "linux",
      "osdCount": 2,
      "osdSizesInGb": [
        5,5
      ]
    }
  ]
}
```

### 2. Enable Addon

```console
k2s addons enable storage ceph 
```

On enable the addon:
1. Reads `clusterHost.node` and resolves its IP address from `cluster.json`.
2. Validates over SSH that the node runs **Debian 13** (aborts otherwise).
3. Provisions a fresh single-node Ceph cluster on that node.
4. Reads `osdHosts`, validates Hyper-V worker node type, and provisions the requested OSDs.
5. Deploys the Ceph CSI operator and the `ceph-cephfs` StorageClass.

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

### 2. (Optional) Verify the `csi` subvolume group exists

The addon provisions every volume into a CephFS subvolume group named `csi`. This group is
**created automatically** when the Ceph cluster is provisioned during `k2s addons enable storage
ceph`, so no manual step is required. If you ever need to confirm it (replace `cephfs` with your
filesystem name):

```bash
# List existing subvolume groups (the 'csi' group should be present)
sudo cephadm shell -- ceph fs subvolumegroup ls cephfs
sudo cephadm shell -- ceph fs subvolumegroup create cephfs csi
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

Expected: `STATUS = Bound`. If it stays `Pending`

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

## Add Another OSD Host to the Ceph Cluster

By default, this addon provisions a **single-node** Ceph cluster. If you want to expand capacity or
reduce degraded single-OSD behavior, you can add another Debian host and create an OSD on that host.

### Preconditions

- The new host runs Debian 13 and is reachable over SSH.
- The new host is added to K2s as an existing Hyper-V VM (`NodeType` = `VM-EXISTING`).
- OSD disks are created automatically by the addon as `ceph-osd-*.vhdx`.

### 1. Add/verify the node in `osdHosts`

Add an entry for the node under `osdHosts` in [`config/ceph-config.json`](config/ceph-config.json),
including `osdCount` and size settings (`osdSizesInGb` or `osdSizeInGb`).

### 2. Trigger reconciliation

If the node was added using `k2s add node`, Ceph reconciliation is triggered automatically.
You can also run reconciliation manually:

```powershell
& addons\storage\ceph\Update.ps1 -ShowLogs
```

`Update.ps1` prepares the host, registers it in cephadm, labels it, creates the requested OSD disk(s),
and creates the OSD daemon(s).

### 3. Verify host and OSD state

```bash
sudo cephadm shell -- ceph -s
sudo cephadm shell -- ceph orch host ls
sudo cephadm shell -- ceph orch ps --daemon_type osd
```

## Disabling

Disabling **tears down the entire Ceph cluster** that was provisioned on the host node and removes
the addon plumbing — the `ceph-cephfs` StorageClass, the `cephfs.csi.ceph.com` CSIDriver, the
operator, the Ceph CSI custom resources/CRDs, the `ceph-csi-operator-system` namespace, the cached
CSI images and the OSD virtual disks.

- **All Ceph (CephFS) data is permanently lost when the addon is disabled.** The cluster teardown
  always runs, and the OSD virtual disks (the `ceph-osd-*.vhdx` drives created on the host VM) are
  detached and deleted along with it, so every drive backing the Ceph storage is destroyed.

### Interactive (single confirmation)

```console
k2s addons disable storage ceph
```
```
[Ceph] WARNING: Disabling storage ceph will uninstall the Ceph cluster on '<node>' (<ip>).
ALL DATA in the Ceph cluster will be permanently lost. Continue? (y/N)
```

Answer `y` to proceed (equivalent to `-f`); anything else cancels the disable. On confirmation the
PVCs/PVs bound to `ceph-cephfs` are deleted and the cluster is removed.

- **Deleting the PVCs requires the volumes to be unused.** On the confirmed/`-f` path, no pods may
  still be mounting the `ceph-cephfs` PVCs — otherwise disable aborts with
  `Pod '<name>' is still using PVC '<pvc>' ... Delete all workloads using the SC 'ceph-cephfs'
  and try again.`. Remove the workloads first, then re-run disable:

```console
kubectl delete pod <your-pods> --ignore-not-found
k2s addons disable storage ceph
```

### Force (`-f`) — no prompt, delete PVC/PV objects

```console
k2s addons disable storage ceph -f
```

Skips the confirmation, deletes the `ceph-cephfs` PVCs/PVs, and removes the cluster (data lost).


## Backup, Restore & Upgrade

Because this addon provisions a Ceph cluster on a K2s node, the only state that must be preserved to
re-enable the addon is its **configuration** (`clusterHost` + `osdHosts`, plus the `cephfsPool` /
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
  "comment": "Ceph CSI storage config. clusterHost boots the Ceph cluster; osdHosts defines Hyper-V OSD nodes.",
  "cephfsFilesystem": "cephfs",
  "cephfsPool": "cephfs.cephfs.data",
  "clusterHost": {
    "node": "kubemaster",
    "os": "linux",
    "osdCrushChooseleafType": 0,
    "monCount": 1,
    "mgrCount": 1,
    "mdsCount": 1
  },
  "osdHosts": [
    {
      "node": "kubemaster",
      "os": "linux",
      "osdCount": 2,
      "osdSizesInGb": [10, 5]
    },
    {
      "node": "worker2",
      "os": "linux",
      "osdCount": 1,
      "osdSizeInGb": 10
    }
  ],
  "windowsHosts": []
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `clusterHost.node` | Yes | Name of the K2s node (as listed in `cluster.json`) that hosts the new Ceph cluster bootstrap. Must run **Debian 13**. |
| `clusterHost.osdCrushChooseleafType` | No | Optional Ceph `osd_crush_chooseleaf_type` override. Set `0` to choose individual OSDs as the failure domain on single-host labs; leave unset to keep the Ceph default. |
| `clusterHost.monCount` | No | Optional monitor daemon count applied with `ceph orch apply mon --placement="count:N"`. |
| `clusterHost.mgrCount` | No | Optional manager daemon count applied with `ceph orch apply mgr --placement="count:N"`. |
| `clusterHost.mdsCount` | No | Optional CephFS MDS daemon count applied with `ceph orch apply mds <fs> --placement="count:N"`. |
| `osdHosts[]` | Yes | List of OSD host definitions. Each node must be Linux and must resolve to a Hyper-V worker node in `cluster.json` (`NodeType` = `VM-EXISTING`). |
| `osdHosts[].osdCount` | No | Number of OSD data disks to create on that host (default `1`). |
| `osdHosts[].osdSizesInGb` | No | Array of per-OSD sizes in GiB (one value per OSD). Example: `[10, 5]` with `osdCount: 2`. |
| `osdHosts[].osdSizeInGb` | No | Common size in GiB applied to all OSDs on that host when `osdSizesInGb` is not provided. |
| `cephfsPool` | No | CephFS **data pool** name (default `cephfs.cephfs.data`). Refreshed with the value read back from the freshly provisioned cluster. |
| `cephfsFilesystem` | No | CephFS filesystem name (default `cephfs`). |
| `windowsHosts[]` | No | Placeholder for future Windows support; currently not provisioned. |
| `comment` | No | Free-text note; ignored by the addon. |

`clusterHost.*`, `osdHosts[].osdCount`, `osdHosts[].osdSizeInGb`, and `osdHosts[].osdSizesInGb` are
**configurable** — edit them before enabling the addon to size Ceph storage to your needs. For
hardware/capacity planning guidance, see the upstream
[Ceph Hardware Recommendations](https://docs.ceph.com/en/latest/start/hardware-recommendations/).

When no config object is passed by the CLI, `enable` falls back to this file, so the
`edit ceph-config.json` → `k2s addons enable storage ceph` workflow works out of the box.

> The generated `ceph-cephfs` StorageClass uses `clusterID: storage`, which references the
> `ClientProfile/storage` resource created by the addon.

### Single-host profile vs multi-host Ceph guidance

The shipped K2s Ceph profile is tuned for a **single host** lab footprint:

- `osdHosts` contains one node (typically `kubemaster`) with desired `osdCount`/size values
- `clusterHost.osdCrushChooseleafType: 0`
- `clusterHost.monCount: 1`
- `clusterHost.mgrCount: 1`
- `clusterHost.mdsCount: 1`

`osdCrushChooseleafType: 0` means placement can choose **individual OSDs** as the leaf level,
which is practical on one host when no host-level failure domain exists yet.

For production-style resilience, Ceph is designed for **multiple hosts** with OSDs on each host.
After adding a second and third host, switch back to host-level protection and increase daemon
placement counts. In K2s config, set:

- `clusterHost.osdCrushChooseleafType: 1`
- `clusterHost.monCount`: increase from `1` toward your HA target (commonly `3` or `5`)
- `clusterHost.mgrCount`: increase from `1` toward your HA target (commonly `2` or more; some teams choose `5`)
- `clusterHost.mdsCount`: increase from `1` based on CephFS availability/performance needs

Why this matters: with host-level protection and replicas spread across hosts, a full server loss
still leaves data online from the remaining hosts.

Once new hosts and OSDs are added, run the following in cephadm shell to restore higher redundancy:

```bash
sudo cephadm shell -- ceph config set osd osd_crush_chooseleaf_type 1
sudo cephadm shell -- ceph orch apply mon --placement="count:5"
sudo cephadm shell -- ceph orch apply mgr --placement="count:5"
sudo cephadm shell -- ceph orch apply mds cephfs --placement="count:2"
sudo cephadm shell -- ceph osd pool set .mgr crush_rule replicated_rule
```

The last command reverts the `.mgr` pool to the default host-level CRUSH rule after you move from
single-host to multi-host topology.

### Why MON, MGR, and MDS are required

- **MON (monitor)**: maintains cluster maps/quorum and is required for cluster consensus.
- **MGR (manager)**: provides orchestration, metrics, and management modules used by day-2 operations.
- **MDS (metadata server)**: required for CephFS metadata operations (directory structure, inode state, locks).

Without these services in a healthy state, CephFS CSI provisioning and mount operations will fail or stall.

## Validation & Mutual Exclusion

### SMB vs Ceph

**Only ONE storage backend can be enabled at a time.**

If SMB is active and you try to enable Ceph:

```
 ERROR: Cannot enable storage ceph: smb storage is already enabled.
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
1. No conflicting storage implementation (SMB) is active
2. `clusterHost.node` is set and exists in `cluster.json` (or matches the control plane node)
3. The target node runs **Debian 13** (checked over SSH)
4. Each `osdHosts` node resolves to a Hyper-V worker (`NodeType` = `VM-EXISTING`)
5. K8s cluster is available
6. Namespaces can be created
7. Secrets can be created

## Performance Tuning

### Controller Replicas

The CephFS CSI controller (`cephfs.csi.ceph.com-ctrlplugin`) runs with **1 replica** by
default, which matches a single-schedulable-node K2s setup. On multi-node clusters you can
increase it for high availability by editing `spec.controllerPlugin.replicas` in
`addons/storage/ceph/manifests/cephfs-driver.yaml` before enabling the addon.

## References

- [Ceph CSI Documentation](https://docs.ceph.com/en/latest/cephfs/fs-volumes/)
- [CSI Specification](https://github.com/container-storage-interface/spec)
- [Ceph Documentation](https://docs.ceph.com/)
- [Storage Implementations Guide](../STORAGE_IMPLEMENTATIONS.md)