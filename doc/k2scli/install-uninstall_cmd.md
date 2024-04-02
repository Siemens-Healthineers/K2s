<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

[Home](../../README.md)

- [Installing](#installing)
  - [Prerequisites](#prerequisites)
  - [Introduction](#introduction)
  - [Variant 1: Installing Small K8s Setup with Defaults (aka. Host Variant)](#variant-1-installing-small-k8s-setup-with-defaults-aka-host-variant)
    - [Offline](#offline)
    - [Online](#online)
  - [Variant 2: Installing Small K8s Setup in multiple VMs on your machine](#variant-2-installing-small-k8s-setup-in-multiple-vms-on-your-machine)
  - [Variant 3: Build Only Setup](#variant-3-build-only-setup)
  - [Installing Using Config Files](#installing-using-config-files)
- [Assignment of cluster IP addresses for Services:](#assignment-of-cluster-ip-addresses-for-services)
- [Uninstalling](#uninstalling)

---

# Installing
## Prerequisites
- Windows host must match one of the [Supported OS Versions](../../README.md#supported-os-versions)
- Local admin permissions are currently needed in order to be able to create virtual switches, VMs, etc.
- Please try to install from an folder which is available on C: drive, since most open source components assume this. We are testing the solution also on other drives, but cannot any garanties that the cluster will work fully.
- Hardware: The system should offer at least 4G RAM free, as well as 50GB disk space free. Recommended are at least 6 CPU cores, but less are possible.
- CPU virtualization must be enabled in the BIOS. To verify, open the Task Manager and check the *Virtualization* property on the *Performance* tab:<br/>
 ![Check Virtualization](img/check_virtualization.png)
 <br/>If you run the setup inside a VM, enable nested virtualization (e.g. when using Hyper-V: `PS> Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true`; see [Configure Nested Virtualization](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/enable-nested-virtualization#configure-nested-virtualization) for details).
- Docker (Desktop) must not be running. Either stop Docker and set it to start manually or uninstall it completely
- PowerShell execution policy must be **RemoteSigned** or less restrictive. To set the policy, e.g. run:
  ```powershell 
  Set-ExecutionPolicy RemoteSigned -Force
  ```
- curl.exe: the installed version in the Windows host must be at least 7.71.0 (to check it call 'curl.exe --version' from the command shell).
- *Required:* Enable required Windows Features beforehand (they will get enabled during the installation anyways, but would require a system restart and installation re-run):
  - Windows 10/11
    ```powershell
    Enable-WindowsOptionalFeature -Online -FeatureName $('Microsoft-Hyper-V-All', 'Microsoft-Hyper-V', 'Microsoft-Hyper-V-Tools-All', 'Microsoft-Hyper-V-Management-PowerShell', 'Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Services', 'Microsoft-Hyper-V-Management-Clients', 'Containers', 'VirtualMachinePlatform') -All -NoRestart
    ``` 
  - Windows Server OSs
    ```powershell 
    Enable-WindowsOptionalFeature -Online -FeatureName $('Microsoft-Hyper-V', 'Microsoft-Hyper-V-Management-PowerShell', 'Microsoft-Hyper-V-Management-Clients', 'Containers', 'VirtualMachinePlatform') -All -NoRestart
    ``` 

  <span style="color:orange;font-size:medium">**⚠**</span> For installing in *WSL* mode, add the **Microsoft-Windows-Subsystem-Linux** feature to the prior command.

## Introduction
The K2s setup provides a variety of options, depending on the way K2s was acquired (online/offline, see [Get K2s](../K8s_Get-k2s.md)) and the desired setup type (see [K2s Variants](../../README.md)).

The *k2s* CLI tool provides an extensive help for all available commands and parameters/flags:
```
<installation folder>\k2s.exe -h
```

To specifically check the install options, run:
```
<installation folder>\k2s.exe install -h
```

 <span style="color:orange;font-size:medium">**⚠**</span> By default, the installation assumes 6 CPU cores to be available on the host system. If less cores are available, reduce the number of virtual cores used by K2s according to the actual amount, e.g. when 4 cores are available, assign max. 4 virtual cores to K2s:
  ```shell 
  <installation folder>\k2s.exe install --master-cpus 4
  ```

> More information regarding *online/offline installation* can be found [here](../offlineinstallation/KubemasterOfflineInstallation.png).

Instead of assembling many command line parameters/flags to customize the installation, you can also use YAML files to configure the desired state (see [Installing Using Config Files](#installing-using-config-files)).

## Variant 1: Installing Small K8s Setup with Defaults (aka. Host Variant)
### Offline
```shell
<installation folder>\k2s.exe install
```
### Online
```shell
<installation folder>\k2s.exe install [-d] [-f]
```
The option `-d` deletes the files needed for an offline installation on the disk drive after the installation is done, otherwise they are kept.

The option `-f` forces the online installation. This option has to be used if the needed files for an offline installation are already on the disk drive
(by default the files for an offline installation are always kept).

Use the following flag in order to use WSL2 for hosting of KubeMaster Linux node instead of Hyper-V:

```shell
<installation folder>\k2s.exe install --wsl
```

## Variant 2: Installing Small K8s Setup in multiple VMs on your machine
To use a dedicated Windows VM as worker node instead of the Windows host, the following command would install effectively two VMs in Hyper-V (Windows worker node and Linux control-plane/worker node).

```
<installation folder>\k2s install -t multi-vm
```

Use the following flag in order to use WSL2 for hosting of KubeMaster Linux node instead of Hyper-V:

```shell
<installation folder>\k2s install -t multi-vm --wsl
```

## Variant 3: Build Only Setup 
To build and test containers without a K8s cluster, see [Build Only Setup](../K8s_BuildOnly.md).

> This variant is available both online or offline (see [Variant 1](#variant-1-installing-small-k8s-setup-with-defaults-aka-host-variant)).

## Installing Using Config Files
The `k2s install` command accepts a config file parameter pointing to a YAML config file containing all install parameters like node resource parameters like (e.g. CPU, RAM or HDD size).

**Default config files** as base for user-defined configurations for all setup flavors can be found [here](../../k2s/cmd/k2s/cmd/install/config/embed/)

**Syntax**:
k2s install (-c|--config) \<path-to-config-file\>

Example:
```sh
<installation folder>\k2s.exe install -c c:\temp\my_config.yaml
```

# Assignment of cluster IP addresses for Services:
 
In case of services on Linux side please use the subnet 172.21.0.0/24 starting from 172.21.0.50 (k2s reserves addresses up to 172.21.0.49):
```
clusterIP: 172.21.0.x
```

In case of services on Windows side please use the subnet 172.21.1.0/24 starting from 172.21.1.50 (k2s reserves addresses up to 172.21.1.49):
```
clusterIP: 172.21.1.x
```

# Uninstalling

```
<installation folder>\k2s uninstall [-d]
```
The option `-d` makes possible to delete the files needed for an offline installation on the disk drive, otherwise they are kept.

&larr;&nbsp;[Get K2s](../K8s_Get-k2s.md)&nbsp;&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;&nbsp;[Start/Stop K2s](./start-stop_cmd.md)&nbsp;&rarr;
