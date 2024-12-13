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
   - Install an SSH service on the new machine and ensure port 22 is enabled for connectivity.
   - Ensure network connectivity with the K2s node.
   - **IP Address Requirements**:
     - The IP address of the new machine must be in the same subnet as the K2s setup (e.g., `172.94.91.0/24`).

---

## Known Limitations

- Adding a new node works only if there is an internet connection on the new node. *(Offline support is in progress.)*
- Adding a new physical host is currently supported only on **Debian** and **Ubuntu** Linux distributions.

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

### 4. Check new node status

```cmd
k2s status -o wide
```
