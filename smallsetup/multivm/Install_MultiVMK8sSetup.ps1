# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the Multi-VM K8s setup.

.DESCRIPTION
Target setup:
+ configured Windows host (kubectl installed, etc.)
+ Linux VM on Windows host as master and worker node
+ Windows VM on Windows host as worker node

This script assists in the following actions for K2s:
- Installing the VM images
- creating a K8s cluster based on those VMs

.PARAMETER WindowsImage
Path to the Windows ISO image to use for Windows VM (mandatory)

.PARAMETER WinVMStartUpMemory
Startup Memory Size of Windows VM

.PARAMETER WinVMDiskSize
Virtual hard disk size of Windows VM

.PARAMETER WinVMProcessorCount
Number of Virtual Processors of Windows VM

.PARAMETER MasterVMMemory
Startup Memory Size of master VM (Linux)

.PARAMETER MasterDiskSize
Virtual hard disk size of master VM (Linux)

.PARAMETER MasterVMProcessorCount
Number of Virtual Processors for master VM (Linux)

.PARAMETER Proxy
Proxy to use

.PARAMETER DnsAddresses
DNS addresses

.PARAMETER SkipStart
Whether to skip starting the K8s cluster after successful installation

.PARAMETER ShowLogs
Show all logs in terminal

.PARAMETER AdditionalHooksDir
Directory containing additional hooks to be executed after local hooks are executed.

.PARAMETER Offline
Perform the installation of the Linux VM without donwloading artifacts from the internet.

.EXAMPLE
PS> .\smallsetup\multivm\InstallMultiVMK8sSetup.ps1 -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'

.EXAMPLE
PS> .\smallsetup\multivm\InstallMultiVMK8sSetup.ps1 -SkipStart -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
Install Multi-VM setup without starting the K8s cluster

.EXAMPLE
PS> .\smallsetup\multivm\InstallMultiVMK8sSetup.ps1 -VMStartUpMemory 3GB -VMDiskSize 40GB -VMProcessorCount 4 -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
For low end systems use less memory, disk space and processor count

.EXAMPLE
PS> .\smallsetup\multivm\InstallMultiVMK8sSetup.ps1 -Proxy http://your-proxy.example.com:8888 -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
With Proxy

.EXAMPLE
PS> .\smallsetup\multivm\InstallMultiVMK8sSetup.ps1 -Proxy http://your-proxy.example.com:8888 -DnsAddresses '8.8.8.8','8.8.4.4' -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
For specifying DNS Addresses

.EXAMPLE
PS> .\smallsetup\multivm\InstallMultiVMK8sSetup.ps1 -AdditonalHooks 'C:\AdditionalHooks' -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
For specifying additional hooks to be executed.

To install Linux-only:
PS> .\smallsetup\multivm\InstallMultiVMK8sSetup.ps1 -LinuxOnly
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Windows ISO image path (mandatory if not Linux-only)')]
    [string] $WindowsImage,
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Windows VM')]
    [long] $WinVMStartUpMemory = 4GB,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Windows VM')]
    [long] $WinVMDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors of Windows VM')]
    [long] $WinVMProcessorCount = 4,
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
    [long] $MasterVMMemory = 6GB,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
    [long] $MasterVMProcessorCount = 4,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
    [string[]]$DnsAddresses,
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'No Windows worker node will be set up')]
    [switch] $LinuxOnly = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false
)

$installationParameters = @{
    WindowsImage = $WindowsImage
    WinVMStartUpMemory = $WinVMStartUpMemory
    WinVMDiskSize = $WinVMDiskSize
    WinVMProcessorCount = $WinVMProcessorCount
    MasterVMMemory = $MasterVMMemory
    MasterDiskSize = $MasterDiskSize
    MasterVMProcessorCount = $MasterVMProcessorCount
    Proxy = $Proxy
    DnsAddresses = $DnsAddresses
    SkipStart = $SkipStart
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    WSL = $WSL
    LinuxOnly = $LinuxOnly
    AppendLogFile = $AppendLogFile
}

& "$PSScriptRoot\..\..\lib\scripts\multivm\install\install.ps1" @installationParameters