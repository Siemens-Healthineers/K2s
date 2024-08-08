# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with preparing a Windows system to be used for a mixed Linux/Windows Kubernetes cluster
This script is only valid for the K2s Setup!!!

.DESCRIPTION
This script assists in the following actions for K2s:
- Downloads Kubernetes binaries (kubelet, kubeadm, flannel, nssm) at the version specified
- Registers kubelet as an nssm service. More info on nssm: https://nssm.cc/

.PARAMETER KubernetesVersion
Kubernetes version to download and use

.EXAMPLE
Without proxy
PS> .\smallsetup\InstallK8s.ps1
With proxy
PS> .\smallsetup\InstallK8s.ps1 -Proxy http://your-proxy.example.com:8888
For small systems use low memory and skip start
PS> .\smallsetup\InstallK8s.ps1 -MasterVMMemory 2GB -SkipStart
For specifying resources
PS> .\smallsetup\InstallK8s.ps1 -MasterVMMemory 8GB -MasterVMProcessorCount 6 -MasterDiskSize 80GB
For specifying DNS Addresses
PS> .\smallsetup\InstallK8s.ps1 -MasterVMMemory 8GB -MasterVMProcessorCount 6 -MasterDiskSize 80GB -DnsAddresses '8.8.8.8','8.8.4.4'
#>

Param(
    # Main parameters
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
    [long] $MasterVMMemory = 8GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
    [long] $MasterVMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'NO proxy')]
    [string[]] $NoProxy = @(),
    [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
    [string[]]$DnsAddresses,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'The path to the vhdx with Ubuntu inside.')]
    [string] $LinuxVhdxPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'The IP address of the Linux VM with Ubuntu inside.')]
    [string] $LinuxVMIP = '',
    [parameter(Mandatory = $false, HelpMessage = 'The user name to access the Linux VM with Ubuntu inside.')]
    [string] $LinuxVMUsername = '',
    [parameter(Mandatory = $false, HelpMessage = 'The password associated with the user name to access the Linux VM with Ubuntu inside.')]
    [string] $LinuxVMUserPwd = '',

    # These are specific developer options
    [parameter(Mandatory = $false, HelpMessage = 'Exit after initial checks')]
    [switch] $CheckOnly = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for VXLAN')]
    [bool] $HostGW = $true,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Restart N number of times after Install')]
    [long] $RestartAfterInstallCount = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false
)

$installationParameters = @{
    MasterVMMemory = $MasterVMMemory
    MasterVMProcessorCount = $MasterVMProcessorCount
    MasterDiskSize = $MasterDiskSize
    Proxy = $Proxy
    DnsAddresses = $DnsAddresses
    AdditionalHooksDir = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    CheckOnly = $CheckOnly
    SkipStart = $SkipStart
    ShowLogs = $ShowLogs
    RestartAfterInstallCount = $RestartAfterInstallCount
    WSL = $WSL
    AppendLogFile = $AppendLogFile
}

& "$PSScriptRoot\..\lib\scripts\k2s\install\install.ps1" @installationParameters

