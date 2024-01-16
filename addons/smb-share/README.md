<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

- [Addon 'smb-share'](#addon-smb-share)
  - [Features](#features)
  - [Examples](#examples)
  - [Contributing](#contributing)

# Addon 'smb-share'
## Features
- SMB share between K8s nodes can be either hosted by Windows or by Linux (Samba)
- SMB share can be accessed by the node's OSs
- StorageClass "smb" based on this SMB share for automatic storage volume provisioning
  
## Examples
> see [Example Workloads](../../test/e2e/addons/smb-share/workloads/)

## Contributing
See [Build Windows-based Image](./build/README.md)