<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Ceph Storage for Windows Workloads

Windows pods cannot use the native CephFS CSI node plugin directly. In K2s, Windows consumes CephFS through SMB.

## Scope and constraints

- This path uses the Ceph SMB provisioner `smb.csi.k8s.io` via StorageClass `ceph-smb`.
- `storage ceph` and `storage smb` cannot be enabled together.
- Disabling Ceph removes the full Ceph cluster created by the addon, including OSD resources and Ceph-backed PVs from this setup.

For mixed Linux and Windows workloads, use Ceph with `-w`: Linux workloads consume `ceph-cephfs`, while Windows workloads consume `ceph-smb`.

## Performance recommendation

For maximum Ceph performance in mixed OS environments, prefer:

- multiple OSDs with larger capacity,
- multiple dedicated OSD nodes,
- OSD placement not limited to the master/control-plane node.

## Ceph references

- [CephFS volumes and subvolumes](https://docs.ceph.com/en/latest/cephfs/fs-volumes/)
- [Ceph OSD architecture overview](https://docs.ceph.com/en/latest/architecture/#object-storage-daemon-osd)
- [Ceph hardware recommendations](https://docs.ceph.com/en/latest/start/hardware-recommendations/)

## Prerequisites

Enable Ceph with Windows SMB integration:

```console
k2s addons enable storage ceph -w
```

This creates:

- `ceph-smb` StorageClass (provisioner `smb.csi.k8s.io`)
- SMB CSI controller and node plugins in `smb.namespace` (default `storage-smb-ceph`)
- A Ceph `mgr/smb` share backed by a CephFS subvolume

The Windows SMB user is created automatically by the Ceph `mgr/smb` setup. If no custom `smb.userName` is configured in `config/ceph-config.json`, the default user name is `smbuser`. K2s then generates a random password and stores it in the Kubernetes Secret `smbcreds` in the same namespace used for the SMB CSI manifests (default `storage-smb-ceph`). The Secret contains `username` and `password`, and the `ceph-smb` StorageClass uses those credentials.

## Verify SMB path

```console
kubectl get pods -n storage-smb-ceph
kubectl get storageclass ceph-smb
```

Expected pods include `csi-smb-controller`, `csi-smb-node`, and `csi-smb-node-win`.

## Example: Windows PVC using Ceph over SMB

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ceph-smb-windows-example
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ceph-smb-windows-example
  template:
    metadata:
      labels:
        app: ceph-smb-windows-example
    spec:
      nodeSelector:
        kubernetes.io/os: windows
      containers:
      - name: app
        image: mcr.microsoft.com/windows/servercore:ltsc2022
        command:
        - powershell.exe
        - -Command
        - Start-Sleep -Seconds 3600
        volumeMounts:
        - name: data
          mountPath: C:\\data
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: ceph-smb-test-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ceph-smb-test-pvc
  namespace: default
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: ceph-smb
  resources:
    requests:
      storage: 1Gi
```

Apply and verify:

```console
kubectl apply -f ceph-smb-windows-example.yaml
kubectl get pvc ceph-smb-test-pvc
kubectl get pod ceph-smb-windows-example
```

For SMB addon-specific behavior and non-Ceph SMB examples, see the SMB addon README at `addons/storage/smb/README.md`.
