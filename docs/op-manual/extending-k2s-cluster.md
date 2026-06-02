<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Extending a K2s Cluster

This guide explains how to extend a K2s cluster by adding additional nodes. At the moment, the documented and supported workflow covers Linux worker nodes on physical hosts or existing virtual machines. Support for Windows worker nodes will follow.

## Prerequisites

1. **K2s Installed Machine**:
   - Ensure the existing machine with K2s installed is accessible.
   - Confirm that the K2s cluster is running and healthy.

2. **New Host or VM Requirements**:
     - Install a supported Debian Linux operating system. The currently supported Linux node versions are `debian12` and `debian13`.
     - Install an SSH service on the new machine and ensure port 22 is enabled for connectivity.
     - Ensure network connectivity with the K2s node.
     - **IP Address Requirements**:
         - The IP address of the new machine must be in the same subnet as the K2s setup (e.g., `172.94.91.0/24`).
         - **Bare-metal target**: IP must be in a physical network subnet (LAN/WiFi/Ethernet) of the Windows host.
         - **Existing Hyper-V VM target**: VM must be attached to KubeSwitch and have an IP in the KubeSwitch CIDR (for example `172.19.1.x`).

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

## Steps to Add a Supported Node

Before running `k2s node add`, make sure your target matches one of the supported types:

- **Bare-metal host**: reachable over SSH and IP belongs to a physical host subnet.
- **Existing Hyper-V VM**: reachable over SSH, connected to KubeSwitch, and currently running.

### 1. Copy the public SSH Key to the new node

When K2s is installed, an SSH public key is available under the directory `%USERPROFILE%\.ssh\k2s\id_rsa.pub`.
This key must be copied to the Linux physical host or VM to establish communication and initiate the installation.

#### Manually

Copy the file from `%USERPROFILE%\.ssh\k2s\id_rsa.pub` to any location on the machine `e.g. /tmp/ on Linux host` .

#### Using `scp` and password

##### Target Linux Node

```cmd
scp -o StrictHostKeyChecking=no %USERPROFILE%\.ssh\k2s\id_rsa.pub  <usernameOfNode>@<IpAddressOfNode>:/tmp/temp_k2s.pub
```

!!! hint "scp"
    Typically the password will be requested for the user to complete scp operation.

### 2. Add copied public SSH Key to the Authorized Users Key File of *SSH* Service

This operation ensures that the new node can be connected over SSH from K2s setup.

#### On Target Linux Node

```cmd
cat /tmp/temp_k2s.pub >> ~/.ssh/authorized_keys && cat ~/.ssh/authorized_keys
```

### 3. Add the new node with K2s CLI

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

Generate an OS-specific node package. This step requires an installed *K2s* cluster on the machine where you run the command, and it must use the local cluster proxy `http://172.19.1.1:8181`.

Example using `k2s.exe` directly from a local directory:

```console
.\k2s.exe system package --node-package --os debian12 --target-dir "D:\Linuxpackagetest" --name "debian12.zip" --proxy http://172.19.1.1:8181
```

You can also generate the package on an existing *K2s* host:

```console
k2s system package --node-package --os debian12 --target-dir "C:\out" --name "debian12-node.zip" -p http://172.19.1.1:8181
```

For Debian 13 nodes, create a Debian 13 package instead:

```console
k2s system package --node-package --os debian13 --target-dir "C:\out" --name "debian13-node.zip" -p http://172.19.1.1:8181
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
