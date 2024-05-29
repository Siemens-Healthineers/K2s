<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
SPDX-License-Identifier: MIT
-->

# Installation
## Prerequisites
- The *Windows* host must match one of the [Supported OS Versions](os-support.md)
- Local admin permissions are currently needed in order to be able to create virtual switches, VMs, etc.
- Please try to install from an folder which is available on `C:\` drive, since most open-source components assume this. We are testing the solution also on other drives, but cannot guarantee that the cluster will work fully.
- Hardware: The system should offer at least 4G RAM free, as well as 50GB disk space free. Recommended are at least 6 CPU cores, but less are possible.
- CPU virtualization must be enabled in the BIOS. To verify, open the *Task Manager* and check the *Virtualization* property on the *Performance* tab:<br/>
 ![Check Virtualization](assets/check_virtualization.png)
 <br/>If you run the setup inside a VM, enable nested virtualization (e.g. when using *Hyper-V*:<br/>
 ```powershell
 Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true
 ```
 , see [Configure Nested Virtualization](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/enable-nested-virtualization#configure-nested-virtualization){target="_blank"} for details).
- *Docker* (Desktop) must not be running. Either stop *Docker* and set it to start manually or uninstall it completely
- *PowerShell* execution policy must be **RemoteSigned** or less restrictive. To set the policy, run:
  ```powershell 
  Set-ExecutionPolicy RemoteSigned -Force
  ```
- *curl.exe*: the installed version in the *Windows* host must be at least **7.71.0** (to check it call `curl.exe --version` from the command shell).
- *Optional:* Enable required *Windows Features* beforehand (they will get enabled during the installation anyways, but would require a system restart and installation re-run):
  - *Windows 10/11*
    ```powershell
    Enable-WindowsOptionalFeature -Online -FeatureName $('Microsoft-Hyper-V-All', 'Microsoft-Hyper-V', 'Microsoft-Hyper-V-Tools-All', 'Microsoft-Hyper-V-Management-PowerShell', 'Microsoft-Hyper-V-Hypervisor', 'Microsoft-Hyper-V-Services', 'Microsoft-Hyper-V-Management-Clients', 'Containers', 'VirtualMachinePlatform') -All -NoRestart
    ``` 
  - *Windows Server* OSs
    ```powershell 
    Enable-WindowsOptionalFeature -Online -FeatureName $('Microsoft-Hyper-V', 'Microsoft-Hyper-V-Management-PowerShell', 'Containers', 'VirtualMachinePlatform') -All -NoRestart
    ``` 

!!! tip
    For installing in *WSL* mode, add the `Microsoft-Windows-Subsystem-Linux` feature to the prior command.