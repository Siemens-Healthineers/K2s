<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# [EXPERIMENTAL] Extending a K2s Cluster

This guide explains how to extend a K2s cluster by adding physical hosts or virtual machines to an existing K2s setup.

## Prerequisites

1. **K2s Installed Machine**:
   - Ensure the existing machine with K2s installed is accessible.
   - Confirm that the K2s cluster is running and healthy.

2. **New Host or VM Requirements**:
    - Install a compatible operating system (Linux or Windows, based on your cluster requirements).
    - For Linux worker node onboarding, the currently supported Debian versions are `debian12` and `debian13`.
   - Install an SSH service on the new machine and ensure port 22 is enabled for connectivity.
   - Ensure network connectivity with the K2s node.
   - **IP Address Requirements**:
     - The IP address of the new machine must be in the same subnet as the K2s setup (e.g., `172.94.91.0/24`).

---

## Known Limitations

- Adding a Linux worker node is currently supported for *Debian 12* and *Debian 13*.
- The supported target can be either a physical host or a virtual machine, as long as SSH access and the OS requirements are met.
- The node IP address supplied to `k2s node add` must stay stable. Use a static IP address or a DHCP reservation.

---

## Online vs. Offline Node Add

`k2s node add` supports two installation modes for Linux worker nodes on either physical hosts or virtual machines:

- **Online mode**: the target node downloads or receives the required packages during provisioning.
- **Offline mode**: a prebuilt node package ZIP is supplied with `--node-package`, and *K2s* installs the node from the package contents instead of downloading artifacts from the internet.

Use offline mode when the new node has no internet connectivity, is behind a restricted proxy, or when you want reproducible node onboarding.

---

## Steps to Add a Physical Host or VM

### 1. Copy the public SSH Key to the new node

When K2s is installed, an SSH public key is available under the directory `%USERPROFILE%\.ssh\k2s\id_rsa.pub`.
This key must be copied to the physical host or VM to establish communication and initiate the installation.

#### Manually

Copy the file from `%USERPROFILE%\.ssh\k2s\id_rsa.pub` to any location on the machine `e.g. /tmp/ on Linux host` .

#### Using `scp` and password

##### Linux New Node

```cmd
scp -o StrictHostKeyChecking=no %USERPROFILE%\.ssh\k2s\id_rsa.pub  <usernameOfNode>@<IpAddressOfNode>:/tmp/temp_k2s.pub
```

##### Windows New Node

```cmd
scp -o StrictHostKeyChecking=no %USERPROFILE%\.ssh\k2s\id_rsa.pub  <usernameOfNode>@<IpAddressOfNode>:c:\\temp\\temp_k2s.pub
```

!!! hint "scp"
    Typically the password will be requested for the user to complete scp operation.

### 2. Add copied public SSH Key to the Authorized Users Key File of *SSH* Service

This operation ensures that the new node can be connected over SSH from K2s setup.

#### On Linux New Node

```cmd
cat /tmp/temp_k2s.pub >> ~/.ssh/authorized_keys && cat ~/.ssh/authorized_keys
```

#### On Windows New Node

```powershell
$rootPublicKey = 'c:\temp\temp_k2s.pub'
$authorizedkeypath = 'C:\ProgramData\ssh\administrators_authorized_keys'

Write-Output 'Adding public key for SSH connection'

if ((Test-Path $authorizedkeypath -PathType Leaf)) {
    Write-Output "$authorizedkeypath already exists! overwriting new key"

    Set-Content $authorizedkeypath -Value $rootPublicKey
}
else {
    New-Item $authorizedkeypath -ItemType File -Value $rootPublicKey

    $acl = Get-Acl C:\ProgramData\ssh\administrators_authorized_keys
    $acl.SetAccessRuleProtection($true, $false)
    $administratorsRule = New-Object system.security.accesscontrol.filesystemaccessrule('Administrators', 'FullControl', 'Allow')
    $systemRule = New-Object system.security.accesscontrol.filesystemaccessrule('SYSTEM', 'FullControl', 'Allow')
    $acl.SetAccessRule($administratorsRule)
    $acl.SetAccessRule($systemRule)
    $acl | Set-Acl
}
```

### 3. Add new node with K2s CLI

```cmd
k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection>
```

If the node should be installed **offline**, first create a node package and then pass it to `k2s node add`:

```console
k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection> --node-package <PathToNodePackageZip>
```

### 4. Check new node status

```cmd
k2s status -o wide
```

## Offline Installation of a Linux Worker Node

The offline workflow has two phases:

1. Build a node package on a machine that has access to the required artifacts.
2. Use that package while running `k2s node add` against the target machine.

### 1. Create the node package

Generate an OS-specific node package on the existing *K2s* host:

```console
k2s system package --node-package --os debian12 --target-dir C:\output --name debian12-node.zip
```

For Debian 13 nodes, create a Debian 13 package instead:

```console
k2s system package --node-package --os debian13 --target-dir C:\output --name debian13-node.zip
```

!!! note
    The node package contains Linux worker node artifacts such as `.deb` packages and container images needed during `k2s node add`.

!!! note
    The `--os` value must match the target node's distribution. Use the package built for the node you are adding.

!!! note
    The same workflow applies whether the target Linux node is a physical host or an existing VM.

### 2. Prepare SSH access to the target node

Follow the SSH key setup described above:

- Copy `%USERPROFILE%\.ssh\k2s\id_rsa.pub` to the target node.
- Add it to the authorized SSH keys on the target node.

This step is required in both online and offline mode because `k2s node add` still connects to the node over SSH.

### 3. Add the node using the offline package

Run `k2s node add` and point it to the node package ZIP:

```console
k2s node add --ip-addr <IPAddressOfNewNode> --username <UserNameForRemoteConnection> --node-package C:\temp\debian13-node.zip
```

### 4. Verify the node joined successfully

```console
k2s status -o wide
```

You can also use `k2s node connect` or `k2s node exec` to confirm SSH connectivity to the node after provisioning.

## When the Node IP Changes

`k2s node add` stores the node IP address for later management operations. If the node gets a different LAN IP after a reboot or network change, SSH-based operations can fail.

Recommended handling:

1. Configure a static IP address or DHCP reservation for the node.
2. If the IP already changed, remove and re-add the node with the new IP:

```console
k2s node remove --name <NodeName>
k2s node add --ip-addr <NewIpAddress> --username <UserNameForRemoteConnection> --name <NodeName>
```

If you use offline installation, include `--node-package <PathToNodePackageZip>` again during the re-add operation.
