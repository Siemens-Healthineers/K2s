# Ceph CSI Quick Reference

## Enable Ceph Storage

```console
k2s addons enable storage ceph \
  --monitorEndpoints "10.0.0.1:6789,10.0.0.2:6789" \
  --adminKey "AQDa1Ipn...=="
```

**What happens:**
1. ✅ Validates Ceph cluster is reachable
2. ✅ Creates namespace: `ceph-csi-cephfs`
3. ✅ Deploys CSI provisioners
4. ✅ Creates StorageClass: `ceph-cephfs`

## Verify Installation

```bash
# Check namespaces
kubectl get ns | grep ceph-csi

# Check StorageClasses
kubectl get sc | grep ceph

# Check secrets
kubectl get secrets -n ceph-csi-cephfs
```

## Create CephFS Volume

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-cephfs-volume
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ceph-cephfs
  resources:
    requests:
      storage: 20Gi
```

## Disable Ceph Storage

```console
# With prompt for data preservation
k2s addons disable storage ceph

# Delete all data
k2s addons disable storage ceph -f

# Keep all data
k2s addons disable storage ceph -k
```

## Get Ceph Status

```console
k2s addons status storage ceph
```

## Mutual Exclusion (SMB ↔ Ceph)

**You CANNOT have both enabled at the same time.**

If you try to enable Ceph while SMB is active:

```
❌ ERROR: Cannot enable storage ceph: smb storage is already enabled.
          Please disable smb storage first using:
          k2s addons disable storage smb
```

**How to switch from SMB to Ceph:**

```bash
# 1. Disable SMB
k2s addons disable storage smb -k  # Keep data

# 2. Enable Ceph
k2s addons enable storage ceph --monitorEndpoints "10.0.0.1:6789,..."
```

## Configuration

File: `addons/storage/ceph/config/ceph-config.json`

```json
{
  "monitorEndpoints": "10.0.0.1:6789,10.0.0.2:6789",
  "cephKey": "AQDa1Ipn...==",
  "cephfsPool": "cephfs_data"
}
```

## Troubleshooting

### PVC Stuck in Pending

```bash
kubectl describe pvc <pvc-name>
kubectl get events -n default --sort-by='.lastTimestamp'
```

### Check CSI Driver Logs

```bash
kubectl logs -n ceph-csi-cephfs -l component=provisioner --tail=50
```

### Verify Ceph Connection

```bash
kubectl run -it --rm debug --image=ubuntu:24.04 --restart=Never -- bash

# Inside pod:
apt-get update && apt-get install -y ceph-common
ceph -m 10.0.0.1:6789 --name client.admin --keyring /tmp/keyring status
```

## What's Created?

| Resource | Type | Namespace |
|----------|------|-----------|
| `ceph-csi-cephfs-provisioner` | StatefulSet | `ceph-csi-cephfs` |
| `ceph-csi-cephfs-nodeplugin` | DaemonSet | `ceph-csi-cephfs` |
| `ceph-secret` | Secret | `ceph-csi-cephfs` |
| `ceph-cephfs` | StorageClass | (cluster-wide) |

## Next Steps

1. ✅ Verify Ceph cluster endpoints and credentials
2. ✅ Run `k2s addons enable storage ceph --monitorEndpoints "..."`
3. ✅ Verify StorageClasses: `kubectl get sc`
4. ✅ Create test PVC
5. ✅ Mount in Pod and verify

---

[Full Documentation](./README.md) | [Implementation Details](../STORAGE_IMPLEMENTATIONS.md)
