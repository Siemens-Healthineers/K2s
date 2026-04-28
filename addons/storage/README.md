<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# storage

## Introduction

The `storage` addon provides persistent storage solutions for the K2s cluster. It currently offers one implementation:

- **[smb](./smb/README.md)** — StorageClass provisioning based on SMB share between K8s nodes (Windows/Linux)

## Getting started

Enable the storage addon using the k2s CLI:

```console
k2s addons enable storage smb
```

## Disable storage

```console
k2s addons disable storage smb
```
