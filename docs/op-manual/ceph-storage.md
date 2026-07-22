<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Ceph Storage Addon (CephFS)

The **`storage ceph`** addon provides dynamic **CephFS (file) storage** for *K2s*. On enable it
**provisions a brand-new single-node Ceph cluster** on a *K2s* node using `cephadm` and wires it up
through the upstream [`ceph-csi-operator`](https://github.com/ceph/ceph-csi-operator) — no Rook
required. It registers the `ceph-cephfs` StorageClass (provisioner `cephfs.csi.ceph.com`) for
`ReadWriteMany` file volumes.

!!! warning "Experimental"
    The Ceph storage addon is **experimental**. Behavior, configuration, and defaults may change
    without notice. Do not rely on it for production data.

!!! note "Windows only"
    The addon currently **supports Windows hosts only** (Hyper-V/WSL2 *K2s* setups). The Ceph host
    node must run **Debian 13** — the addon validates the target node's OS over SSH on enable and
    refuses to continue on any other distribution.

## When to Use SMB vs Ceph

*K2s* ships two mutually exclusive storage implementations under the `storage` addon. **Only one can
be enabled at a time.** Choose the one that fits your workload:

| Use case | Recommended implementation |
|----------|----------------------------|
| Simple shared folder between K8s nodes, minimal footprint | **`smb`** |
| Windows-based file share, or a Linux SMB host | **`smb`** |
| Fastest to enable, lowest resource usage | **`smb`** |
| POSIX-like CephFS semantics with the Ceph CSI ecosystem | **`ceph`** |
| Evaluating Ceph/CephFS on *K2s* | **`ceph`** |
| A dedicated storage back-end managed by `cephadm` | **`ceph`** |

- **SMB** (`storage smb`) is the default, stable choice: it exposes an SMB share (hosted on the
  Windows host or a Linux node) as a `ReadWriteMany` StorageClass. It is lightweight and works even
  when the cluster is not running for backup purposes.
- **Ceph** (`storage ceph`) provisions a real single-node Ceph cluster and CephFS filesystem, giving
  you the Ceph CSI driver and CephFS semantics. It consumes more resources (an extra data disk and a
  running Ceph cluster) and is currently **experimental**.

!!! tip
    If SMB is already enabled, disable it before enabling Ceph:
    ```console
    k2s addons disable storage smb 
    k2s addons enable storage ceph
    ```

## Prerequisites

1. **A running *K2s* cluster** (`k2s` setup type). Check with `k2s system status`.
2. **A *K2s* node running Debian 13** to host the Ceph cluster:
   - Its name must be listed in `cluster.json` (it is part of the *K2s* cluster).
   - Use the control plane node name (e.g. `kubemaster`) to install Ceph on the kubemaster, or any
     other Debian 13 node name to install it there.
   - The node must be reachable over SSH.
3. **No conflicting storage implementation** — `storage smb` must **not** be enabled.
4. **A data disk for the Ceph OSD** (see [Minimum Node & Disk Requirements](#minimum-node--disk-requirements)).

!!! warning
    **Only Debian 13 is supported.** Debian 12 and other distributions are rejected during enable.

## Minimum Node & Disk Requirements

Ceph stores data on **OSDs**, and each OSD consumes a raw, unpartitioned block device. The addon
handles this differently depending on the node type:

| Node type | OSD disk handling |
|-----------|-------------------|
| **Hyper-V VM** (default *K2s* setup) | The addon **automatically creates** the OSD data disks as dynamic VHDX files (named `ceph-osd-*.vhdx`, default **20 GiB** each), hot-attaches them to the VM as raw SCSI disks, and lets `cephadm` provision the OSDs on them. No manual disk preparation is needed. |
| **Bare-metal node** | You must provide an **existing empty raw disk** (e.g. `/dev/sdb`); a physical disk cannot be created automatically. |

### Configurable OSD sizing

The OSD disk size and count are **not fixed** — they can be adjusted to your needs in
`addons/storage/ceph/config/ceph-config.json` before enabling the addon:

| Field | Default | Description |
|-------|---------|-------------|
| `osdsize` (alias `osdDiskSizeGB`) | `20` | Size in **GiB** of each OSD data disk created on a Hyper-V host. Set a larger value if you need more CephFS capacity. |
| `osdcount` | `2` | Number of OSD data disks to create on the host. |
| `osddevicebaremetal` | _empty_ | Comma-separated bare-metal target disks (for example `/dev/sdb, /dev/sdc`). The addon maps entry 1 to OSD #1, entry 2 to OSD #2, and so on. |

Invalid or missing values fall back to the defaults. For bare-metal hosts, provide appropriately
sized empty physical disks via `osddevicebaremetal` — `osdsize` only applies to Hyper-V-created
disks.

**Enforced before enable** (validation aborts otherwise):

- `clusterHostNode` is set and exists in `cluster.json`.
- The target node runs **Debian 13** (checked over SSH).
- No conflicting storage implementation (`smb`) is active.
- The K8s cluster is reachable and namespaces/secrets can be created.

**Recommended (not strictly enforced):**

- **Free disk space on the host** for the OSD VHDX files — at least `osdcount × osdsize` (default
  2 × 20 GiB) plus headroom for growth, since the VHDX disks are dynamic but back all CephFS data.
- **Hardware sizing (CPU, memory, disks)** — for capacity planning of the Ceph host node, follow the
  official [Ceph Hardware Recommendations](https://docs.ceph.com/en/latest/start/hardware-recommendations/){target="_blank"}.
  A single-node Ceph cluster (MON + MGR + OSD + MDS daemons) needs several GiB of RAM to run
  comfortably; provision the host VM accordingly before enabling.
- A **dedicated disk** for each OSD. On Hyper-V these are created for you; do not point an OSD at a
  disk that already holds data — `cephadm` wipes the target device.

!!! warning
    The OSD disk is consumed exclusively by Ceph. Any raw disk you hand to a bare-metal OSD host is
    **wiped**. On Hyper-V the addon only ever creates and manages its own `ceph-osd-*.vhdx` disks.

## Enabling the Addon

1. Choose the Ceph host node. Edit `addons/storage/ceph/config/ceph-config.json` and set
   `clusterHostNode` to the name of the Debian 13 *K2s* node that should host the new Ceph cluster.
   Optionally adjust `osdsize` / `osdcount` to size the CephFS capacity to your needs:

    ```json
    {
        "comment": "Ceph CSI Configuration - 'clusterHostNode' must be the name of a K2s node (as listed in cluster.json) running Debian 13.",
        "cephfsPool": "cephfs.cephfs.data",
        "cephfsFilesystem": "cephfs",
        "clusterHostNode": "kubemaster",
        "osdsize": 20,
        "osdcount": 2,
        "osddevicebaremetal": "/dev/sdb, /dev/sdc"
    }
    ```

    > `osdsize` (GiB) and `osdcount` are optional; if omitted the defaults (20 GiB, 2 disks) are used.
    > On bare-metal OSD hosts, set `osddevicebaremetal` with one disk path per OSD.

2. Enable the addon:

    ```console
    k2s addons enable storage ceph
    ```

On enable the addon:

1. Reads `clusterHostNode` and resolves its IP address from `cluster.json`.
2. Validates over SSH that the node runs **Debian 13** (aborts otherwise).
3. Creates and attaches the OSD data disks (on Hyper-V) and provisions a fresh single-node Ceph
   cluster via `cephadm`.
4. Deploys the Ceph CSI operator and the `ceph-cephfs` StorageClass, then waits for the driver pods
   to become ready.

## Verifying the Installation

All workloads run in the `ceph-csi-operator-system` namespace:

```console
kubectl get pods -n ceph-csi-operator-system
kubectl get storageclass ceph-cephfs
kubectl get csidriver cephfs.csi.ceph.com
```

Expected pods (names may vary by hash):

- `ceph-csi-operator-controller-manager` — the operator that reconciles the driver
- `cephfs.csi.ceph.com-ctrlplugin` — CephFS CSI controller (provisioner/attacher/resizer/snapshotter)
- `cephfs.csi.ceph.com-nodeplugin` — CephFS CSI node plugin (one pod per node)

You can also check status through the CLI:

```console
k2s addons status storage ceph
```

## Using the Storage

Provisioning is **dynamic** — there are no manual volume-creation steps. Any workload that creates a
`PersistentVolumeClaim` referencing `storageClassName: ceph-cephfs` gets a CephFS volume created and
mounted automatically:

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

Because CephFS supports `ReadWriteMany`, multiple pods (across nodes) can mount the same volume
concurrently.

### Testing the storage end-to-end

Validate dynamic provisioning and shared (`ReadWriteMany`) access with a throwaway PVC and pods.

#### 1. Create a PersistentVolumeClaim

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

```console
kubectl get pvc ceph-test-pvc
kubectl get pv
```

Expected: `STATUS = Bound`. If it stays `Pending`, check the CSI controller pod logs in the
`ceph-csi-operator-system` namespace.

#### 2. Write data from a pod

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

#### 3. Clean up the test resources

```console
kubectl delete pod ceph-writer --ignore-not-found
kubectl delete pvc ceph-test-pvc --ignore-not-found
```

For the full test (including a second reader pod that verifies concurrent `ReadWriteMany` access),
see the [addon README](https://github.com/Siemens-Healthineers/K2s/blob/main/addons/storage/ceph/README.md).

## Add Another OSD Host

The addon starts with a single-node Ceph cluster. To expand storage capacity, you can add another
host and provision an OSD on that host using the shipped Ceph helper scripts.

### Preconditions

- New host is reachable over SSH.
- **Bare-metal only:** pass a dedicated empty raw disk for OSD (for example `/dev/sdb`).
- **Hyper-V:** OSD disks are created automatically by the addon as `ceph-osd-*.vhdx`.
- You can run Ceph commands on the bootstrap/MGR node.

### 1. Retrieve the cephadm public key

Get it directly from the bootstrap/MGR node:

```console
sudo cat /etc/ceph/ceph.pub
```

Or use the key printed during addon enable logs:

```text
K2S_CEPH_PUB_KEY=<ssh-public-key>
```

### 2. Prepare the new host for OSD deployment

On the new host, run:

```console
./prepare-ceph-osd-host.sh "<ceph-pub-key>"
```

If the host requires proxy access for package/image download:

```console
./prepare-ceph-osd-host.sh "<ceph-pub-key>" "http://<kubeswitch-ip>:8181"
```

Expected success marker:

```text
K2S_CEPH_OSD_HOST_READY=1
```

### 3. Add the host to Ceph inventory

Add it in the Ceph UI (Dashboard -> Hosts -> Add Host), then verify:

```console
sudo cephadm shell -- ceph orch host ls
```

CLI alternative:

```console
sudo cephadm shell -- ceph orch host add <host-name> <host-ip>
```

### 4. Add host label and create OSD

Run on the bootstrap/MGR node:

```console
# labels only
./add-ceph-host-labels-and-osd.sh <host-name>

# labels + create OSD on device
./add-ceph-host-labels-and-osd.sh <host-name> /dev/sdb
```

Optional FSID parameter:

```console
FSID="$(sudo cephadm shell -- ceph fsid)"
./add-ceph-host-labels-and-osd.sh <host-name> /dev/sdb "$FSID"
```

### 5. Verify the new OSD

```console
sudo cephadm shell -- ceph -s
sudo cephadm shell -- ceph orch host ls
sudo cephadm shell -- ceph orch ps --daemon_type osd
```

!!! warning
  Use a whole, dedicated disk device for OSD creation (not a partition).

## Disabling the Addon

Disabling **tears down the entire Ceph cluster** provisioned on the host node and removes the addon
plumbing — the `ceph-cephfs` StorageClass, the `cephfs.csi.ceph.com` CSIDriver, the operator, the
Ceph CSI custom resources/CRDs, the `ceph-csi-operator-system` namespace, the cached CSI images and
the OSD virtual disks.

!!! danger "All Ceph data is permanently lost"
    Disabling **always** tears down the cluster and **deletes the OSD virtual disks** (the
    `ceph-osd-*.vhdx` drives created on the host VM), so **all CephFS data is destroyed regardless
    of the flag** you pass. The flags only control whether the Kubernetes
    `PersistentVolumeClaim`/`PersistentVolume` *objects* are deleted; kept PVs become orphaned
    because the Ceph storage behind them no longer exists.

### Interactive (single confirmation)

```console
k2s addons disable storage ceph
```

```
[Ceph] WARNING: Disabling storage ceph will uninstall the Ceph cluster on '<node>' (<ip>).
ALL DATA in the Ceph cluster will be permanently lost. Continue? (y/N)
```

Answer `y` to proceed (equivalent to `-f`); anything else cancels the disable.

### Force (`-f`) — no prompt

```console
k2s addons disable storage ceph -f
```

Skips the confirmation, deletes the `ceph-cephfs` PVCs/PVs, and removes the cluster.

!!! note
    Deleting the PVCs requires the volumes to be unused. If any pod is still mounting a
    `ceph-cephfs` PVC, disable aborts. Remove those workloads first, then re-run disable.

## Limitations & Considerations

- **Experimental** — the addon and its behavior may change without notice.
- **Windows only** — the addon is currently supported on Windows *K2s* setups.
- **Debian 13 only** — the Ceph host node must run Debian 13; other distributions are rejected.
- **Single-node Ceph cluster** — the provisioned cluster is single-node by default. Because Ceph
  pools default to a replica size of 3, a single OSD leaves the cluster in a degraded/`HEALTH_WARN`
  state until additional OSD hosts are added. This is expected for the single-node evaluation setup.
- **Mutual exclusion with SMB** — only one storage implementation can be enabled at a time.
- **Fresh cluster on every enable** — enabling always provisions a **new** cluster; existing CephFS
  data is not carried over across a disable/enable cycle.
- **CSI controller replicas** — the CephFS CSI controller runs with **1 replica** by default, which
  matches a single-schedulable-node *K2s* setup.

### Windows-related considerations

- The OSD data disks are **Hyper-V dynamic VHDX** files (`ceph-osd-*.vhdx`) created on the Windows
  host and hot-attached to the Ceph host VM. Ensure the host has enough free disk space for them.
- On disable, the OSD VHDX files are **detached and deleted** from the VM. If a guest IP cannot be
  resolved during teardown, VHDX cleanup may be skipped — verify no orphaned `ceph-osd-*.vhdx` files
  remain in the VM storage directory afterwards.
- Provision the Ceph host VM with **sufficient memory and CPU** to run the Ceph daemons alongside
  the *K2s* control plane when `clusterHostNode` is the kubemaster.

## Backup & Restore

Because the addon provisions a Ceph cluster on a *K2s* node, only the **connection configuration**
(`clusterHostNode`, `cephfsPool`, `cephfsFilesystem`) is preserved by backup/restore — no user data
is copied. Re-enabling always provisions a fresh cluster on the configured Debian 13 node. See
[Backing Up and Restoring Addons](backing-up-restoring-addons.md#storage-ceph) for details.

## References

- Addon overview: [Addons](../user-guide/addons.md#storage)
- [Ceph Hardware Recommendations](https://docs.ceph.com/en/latest/start/hardware-recommendations/){target="_blank"}
- [Ceph CSI Documentation](https://docs.ceph.com/en/latest/cephfs/fs-volumes/){target="_blank"}
- [ceph-csi-operator](https://github.com/ceph/ceph-csi-operator){target="_blank"}
- [Ceph Documentation](https://docs.ceph.com/){target="_blank"}
