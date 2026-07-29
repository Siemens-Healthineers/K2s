<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# storage

## Introduction

The `storage` addon provides persistent storage solutions for the K2s cluster. It offers two **mutually exclusive** implementations:

- **[smb](./smb/README.md)** — StorageClass provisioning based on SMB share between K8s nodes (Windows/Linux)
- **[ceph](./ceph/README.md)** — Ceph CSI operator for CephFS (file) storage provisioning

**Important:** Only ONE storage implementation can be enabled at a time. Enabling one automatically disables any active alternative.

## Quick Start

### Enable SMB Storage

```console
k2s addons enable storage smb
```

### Enable Ceph CSI Storage

```console
k2s addons enable storage ceph \
  --monitorEndpoints "10.0.0.1:6789,10.0.0.2:6789" \
  --adminKey "AQDa1Ipn...=="
```

### Disable Storage

```console
# Disable with data preservation prompt
k2s addons disable storage smb
k2s addons disable storage ceph

# Force delete all data
k2s addons disable storage smb -f
k2s addons disable storage ceph -f

# Keep all data
k2s addons disable storage smb -k
k2s addons disable storage ceph -k
```

## Choosing a Storage Backend

| Requirement | SMB | Ceph |
|-------------|-----|------|
| Simple local/network share | ✅ Yes | ❌ No |
| External Ceph cluster | ❌ No | ✅ Required |
| High availability | ⚠️ Limited | ✅ Full |
| Shared file storage | ✅ Yes | ✅ Yes (CephFS) |
| Enterprise workloads | ⚠️ Basic | ✅ Yes |

## Mutual Exclusion

**Only ONE storage backend can be active.**

**Attempting to enable Ceph while SMB is active:**

```console
❌ ERROR: Cannot enable storage ceph: smb storage is already enabled.
          Please disable smb storage first using:
          k2s addons disable storage smb
```

**How to switch storage backends:**

```bash
# 1. Disable current backend
k2s addons disable storage smb -k  # Keep data if needed

# 2. Enable new backend
k2s addons enable storage ceph --monitorEndpoints "..." --adminKey "..."
```

## Implementation Details

- **[SMB Implementation](./smb/README.md)** — Windows/Linux SMB-based storage
- **[Ceph CSI Implementation](./ceph/README.md)** — External Ceph cluster integration
- **[Storage Implementations Guide](./STORAGE_IMPLEMENTATIONS.md)** — Architecture and validation details

## Status & Monitoring

Check which storage backend is active:

```bash
# Check enabled StorageClasses
kubectl get storageclass

# For SMB
kubectl get ns | grep smb

# For Ceph
kubectl get ns | grep ceph-csi

# Addon status
k2s addons status storage smb
k2s addons status storage ceph
```

## Troubleshooting

### Error: "Cannot enable storage..."

**Cause:** Another storage implementation is already enabled.

**Solution:**
```bash
k2s addons disable storage <other-impl>
k2s addons enable storage <requested-impl>
```

### PersistentVolumeClaim Stuck in Pending

Check the provisioner logs and describe the PVC:

```bash
kubectl describe pvc <pvc-name>
kubectl get events --sort-by='.lastTimestamp'
```

### Check Current Backend Status

```bash
# See what's active
kubectl get storageclass -o wide

# Check namespace
kubectl get namespace
```

## References

- [SMB Storage Documentation](./smb/README.md)
- [Ceph CSI Documentation](./ceph/README.md)
- [Ceph CSI Quick Start](./ceph/QUICKSTART.md)
- [Storage Implementations Architecture](./STORAGE_IMPLEMENTATIONS.md)
