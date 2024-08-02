<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# storage

## Introduction

The `storage smb` addon provides a Samba share in order to share files between the k2s nodes:

- smb share between k2s nodes can be either hosted by Windows or by Linux (Samba)
- smb share can be accessed by the node's OSs
- StorageClass "smb" based on this smb share for automatic storage volume provisioning

## Getting started

The storage smb addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable storage smb
```

## Shared folder

The smb share is available under the following paths.

### Windows

```
C:\k8s-smb-share
```

### Linux
```
/mnt/smb/k8s-smb-share
```
  
## Examples
- [Example Workloads](../../k2s/test/e2e/addons/storage/workloads/)
