<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Ceph CSI Operator

Deploy Ceph storage with CSI drivers directly via YAML manifests without Rook operator.

This implementation provides:
- **Ceph CSI operator** deployment for CephFS (file) provisioner
- **RBAC & permissions** (ServiceAccounts, ClusterRoles, ClusterRoleBindings)
- **StorageClass** definitions for file storage
- **Ceph cluster connection** via Kubernetes secrets
- **Fine-grained control** — no Rook abstraction layer
- **Mutual exclusion** with SMB storage (only one can be enabled at a time)

## Prerequisites

1. **Existing Ceph cluster** with:
   - Monitor endpoints (e.g., `10.0.0.1:6789,10.0.0.2:6789`)
   - Admin keyring or read-only key
  - Existing CephFS data pool (e.g., `cephfs_data`)
   - CephFS filesystem configured (if using CephFS)

2. **K8s cluster** with:
   - API server reachable from K2s nodes
   - kubelet on every node

3. **No conflicting storage implementation:**
   - SMB storage must NOT be enabled
   - Use `k2s addons disable storage smb` first if needed

## Quick Start

### 1. Prepare Ceph Details

Gather from your Ceph cluster:
- Monitor endpoints: `10.0.0.1:6789,10.0.0.2:6789,10.0.0.3:6789`
- Admin keyring: `AQDa1Ipn...==` (base64-encoded)
- CephFS pool: `cephfs_data` (or custom name)

### 2. Enable Addon

```console
k2s addons enable storage ceph \
  --monitorEndpoints "10.0.0.1:6789,10.0.0.2:6789,10.0.0.3:6789" \
  --adminKey "AQDa1Ipnwxxxxxxxxxxxxxxxxxxxxxxxxxxx=="
```

### 3. Verify Installation

```bash
kubectl get pods -n ceph-csi-cephfs
kubectl get storageclass | grep ceph
```

### 4. Create Volume

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-cephfs
spec:
  accessModes: [ "ReadWriteMany" ]
  storageClassName: ceph-cephfs
  resources:
    requests:
      storage: 10Gi
EOF
```

### 5. Mount in Pod

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
spec:
  containers:
  - name: app
    image: busybox:latest
    command: ['sh', '-c', 'echo hello > /mnt/data/test.txt && sleep 3600']
    volumeMounts:
    - name: storage
      mountPath: /mnt/data
  volumes:
  - name: storage
    persistentVolumeClaim:
      claimName: test-cephfs
EOF
```

## Deployment Options

### Enable CephFS

```console
k2s addons enable storage ceph \
  --monitorEndpoints "10.0.0.1:6789,10.0.0.2:6789" \
  --adminKey "..." \
  --cephfsPool "cephfs_data"
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

## Disabling

### Prompt for Data Preservation

```console
k2s addons disable storage ceph
```

### Force Delete All Data

```console
k2s addons disable storage ceph -f
```

### Keep All Data

```console
k2s addons disable storage ceph -k
```

## Architecture

### Components Deployed

| Component | Type | Namespace |
|-----------|------|-----------|
| `ceph-csi-cephfs-provisioner` | StatefulSet (2) | `ceph-csi-cephfs` |
| `ceph-csi-cephfs-nodeplugin` | DaemonSet | `ceph-csi-cephfs` |

### Data Flow

```
Pod requests PVC
    ↓
CSI Provisioner (StatefulSet)
    ↓ (CreateVolume call)
CSI CephFS Plugin
    ↓ (Ceph API call)
External Ceph Cluster
    ↓ (Creates CephFS subvolume)
PersistentVolume created
    ↓
Node Plugin (DaemonSet)
    ↓ (Stage/Publish volume)
Mount to Pod
    ↓
Application uses volume
```

## Configuration

File: `addons/storage/ceph/config/ceph-config.json`

```json
{
  "monitorEndpoints": "10.0.0.1:6789,10.0.0.2:6789",
  "cephUser": "client.admin",
  "cephKey": "AQDa1Ipn...==",
  "cephfsPool": "cephfs_data",
  "cephfsFilesystem": "cephfs"
}
```

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
k2s addons enable storage ceph --monitorEndpoints "..." --adminKey "..."
```

### Validation Checks

Enable command validates:
1. ✅ No conflicting storage implementation (SMB) is active
2. ✅ Monitor endpoints provided
3. ✅ Admin keyring provided
4. ✅ K8s cluster is available
5. ✅ Namespaces can be created
6. ✅ Secrets can be created

## Troubleshooting

### 1. Provisioner Pods Not Starting

```console
kubectl logs -n ceph-csi-cephfs -l app=ceph-csi-cephfs --tail=50
```

**Common causes:**
- Invalid monitor endpoints (typo or unreachable)
- Invalid keyring
- Missing Ceph pools

### 2. PVC Stuck in Pending

```console
kubectl describe pvc <pvc-name>
```

**Check provisioner events:**

```console
kubectl get events -n default --sort-by='.lastTimestamp'
```

**Check provisioner logs:**

```console
kubectl logs -n ceph-csi-cephfs deployment/ceph-csi-cephfs-provisioner --tail=50
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
kubectl get secret ceph-secret -n ceph-csi-cephfs -o yaml

# Verify keyring is readable
kubectl exec -it <provisioner-pod> -n ceph-csi-cephfs -- cat /etc/ceph/ceph.client.admin.keyring
```

## Security Notes

- **Keyring management** — Store Ceph keys securely, never commit to git
- **RBAC** — Each provisioner runs under dedicated ServiceAccounts
- **Network policies** — Consider restricting CSI driver communication
- **TLS** — Use TLS for Ceph connections in production
- **Quotas** — Set resource requests/limits on CSI pods

## Performance Tuning

### Replica Count

Higher replicas = better HA, more resources:

```yaml
spec:
  replicas: 3  # Default 2
```

### Resource Limits

Adjust for your workload:

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "200m"
  limits:
    memory: "1Gi"
    cpu: "1000m"
```

## Advanced Usage

### CephFS with Kernel Mount

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-cephfs-kernel
provisioner: cephfs.csi.ceph.com
parameters:
  mounter: kernel  # Faster than fuse
```

### Volume Snapshots

Requires external-snapshotter with a CephFS-compatible snapshot class.

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
1. Check logs: `kubectl logs -n ceph-csi-cephfs ...`
2. Verify Ceph cluster: `ceph status`
3. Review configuration: `addons/storage/ceph/config/ceph-config.json`
4. Check mutual exclusion: `k2s addons status storage smb`
