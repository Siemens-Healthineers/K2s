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

This script assists in the following actions for Small K8s:
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
PS> .\lib\scripts\multivm\install\Install.ps1 -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -SkipStart -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
Install Multi-VM setup without starting the K8s cluster

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -VMStartUpMemory 3GB -VMDiskSize 40GB -VMProcessorCount 4 -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
For low end systems use less memory, disk space and processor count

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -Proxy http://your-proxy.example.com:8888 -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
With Proxy

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -Proxy http://your-proxy.example.com:8888 -DnsAddresses '8.8.8.8','8.8.4.4' -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
For specifying DNS Addresses

.EXAMPLE
PS> .\lib\scripts\multivm\install\Install.ps1 -AdditonalHooks 'C:\AdditionalHooks' -WindowsImage 'c:\temp\en_windows_10_business_editions_version_20h2_x64_dvd_4788fb7c.iso'
For specifying additional hooks to be executed.

To install Linux-only:
PS> .\lib\scripts\multivm\install\Install.ps1 -LinuxOnly
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
    [string[]]$DnsAddresses = @('8.8.8.8', '8.8.4.4'),
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


$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

$script:SetupType = 'MultiVMK8s'
$KubernetesVersion = Get-DefaultK8sVersion
$multiVMWindowsVMName = Get-ConfigVMNodeHostname # WARNING: VM name must not exceed a certain length, otherwise unattend.xml file parsing will fail!
$rootConfig = Get-RootConfigk2s
$multivmRootConfig = $rootConfig.psobject.properties['multivm'].value
$multiVMWinNodeIP = $multivmRootConfig.psobject.properties['multiVMK8sWindowsVMIP'].value

#################################################################################################
# FUNCTIONS                                                                                     #
#################################################################################################

function Install-WindowsVM() {
    $switchname = ''
    if ($WSL) {
        $switchname = $global:WSLSwitchName
    }
    else {
        $controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName
        $switchname = $controlPlaneSwitchName
    }
    $kubeSwitchIp = Get-ConfiguredKubeSwitchIP

    Write-Log "Creating VM $multiVMWindowsVMName..."
    Write-Log "Using $WinVMStartUpMemory of memory for VM"
    Write-Log "Using $WinVMDiskSize of virtual disk space for VM"
    Write-Log "Using $WinVMProcessorCount of virtual processor count for VM"
    Write-Log "Using image: $WindowsImage"
    Write-Log 'Using virtio image: none'

    Initialize-WinVM `
        -Name $multiVMWindowsVMName `
        -Image $WindowsImage `
        -VMStartUpMemory $WinVMStartUpMemory `
        -VMDiskSize $WinVMDiskSize `
        -VMProcessorCount $WinVMProcessorCount `
        -Proxy $Proxy `
        -DnsAddresses $DnsAddresses `
        -SwitchName $switchname `
        -SwitchIP $kubeSwitchIp `
        -CreateSwitch $false `
        -IpAddress $multiVMWinNodeIP

    Initialize-WinVMNode -KubernetesVersion $KubernetesVersion `
        -VMName $multiVMWindowsVMName `
        -IpAddress $multiVMWinNodeIP `
        -HostGW:$true `
        -HostVM:$true `
        -Proxy:"$Proxy" `
        -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
        -ForceOnlineInstallation $ForceOnlineInstallation
}

#################################################################################################
# SCRIPT START                                                                                  #
#################################################################################################

Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile:$AppendLogFile

$ErrorActionPreference = 'Stop'

if ($Trace) {
    Set-PSDebug -Trace 1
}

Write-Log '---------------------------------------------------------------'
Write-Log 'Multi-VM Kubernetes Installation started.'
Write-Log '---------------------------------------------------------------'

# TODO: remove, when multi-vm supports offline installation ------------------|

$offlineInstallationRequested = $false

if ($ForceOnlineInstallation -ne $true) {
    $ForceOnlineInstallation = $true
    $offlineInstallationRequested = $true
}

if ($DeleteFilesForOfflineInstallation -eq $false) {
    $DeleteFilesForOfflineInstallation = $true
    $offlineInstallationRequested = $true
}

if ($offlineInstallationRequested -eq $true) {
    Write-Log "Offline installation is currently not supported for 'multi-vm', falling back to online installation."
}

# ----------------------------------------------------------------------------|

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

if ($LinuxOnly -eq $true) {
    Write-Log 'Multi-VM setup will install Linux node only'
}
else {
    if (!$WindowsImage) {
        throw 'Windows ISO image path not specified'
    }

    if ((Test-Path $WindowsImage) -ne $true) {
        throw "Windows image ISO file '$WindowsImage' not found."
    }
}

Set-EnvVars

if ($Proxy -eq "") {
    Write-Log "Determining if proxy is configured by the user in Windows Proxy settings." -Console
    $proxyEnabledStatus = Get-ProxyEnabledStatusFromWindowsSettings
    if ($proxyEnabledStatus) {
        $Proxy = Get-ProxyServerFromWindowsSettings
        Write-Log "Configured proxy server in Windows Proxy settings: $Proxy" -Console
    } else {
        Write-Log "No proxy configured in Windows Proxy Settings." -Console
    }
}

Add-k2sToDefenderExclusion
Stop-InstallIfDockerDesktopIsRunning

Set-ConfigSetupType -Value $script:SetupType
Set-ConfigWslFlag -Value $([bool]$WSL)
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LinuxOnly -Value ($LinuxOnly -eq $true)

$productVersion = Get-ProductVersion
$kubePath = Get-KubePath

Set-ConfigInstalledKubernetesVersion -Value $KubernetesVersion
Set-ConfigInstallFolder -Value $kubePath
Set-ConfigProductVersion -Value $productVersion

Enable-MissingWindowsFeatures $([bool]$WSL)

if ($WSL) {
    Write-Log 'vEthernet (WSL) switch will be reconfigured! Your existing WSL distros will not work properly until you stop the cluster.'
    Write-Log 'Configuring WSL2'
    Set-WSL
}

Test-ProxyConfiguration

$ErrorActionPreference = 'Continue'

Invoke-DowloadPuttyTools -Proxy "$Proxy"

# PREPARE LINUX VM
Initialize-LinuxNode -VMStartUpMemory $MasterVMMemory `
    -VMProcessorCount $MasterVMProcessorCount `
    -VMDiskSize $MasterDiskSize `
    -InstallationStageProxy $Proxy `
    -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
    -ForceOnlineInstallation $ForceOnlineInstallation `
    -WSL:$WSL `
    -SkipTransparentProxy:$true

$ErrorActionPreference = 'Stop'

New-DefaultNetNat

Write-Log 'Setting up WinNode worker VM' -Console

Install-WindowsVM # needs kubeswitch being already setup with Install-Kubemaster

Initialize-VMKubernetesCluster -VMName $multiVMWindowsVMName `
    -IpAddress $multiVMWinNodeIP `
    -Proxy:"$Proxy" `
    -KubernetesVersion $KubernetesVersion `
    -AdditionalHooksDir $AdditionalHooksDir

if ($global:InstallRestartRequired) {
    Write-Log 'RESTART!! Windows features are enabled. Restarting the machine is mandatory in order to start the cluster.' -Console
}
else {
    & "$PSScriptRoot\..\stop\Stop.ps1" -ShowLogs:$ShowLogs

    if (! $SkipStart) {
        Write-Log 'Starting Kubernetes system ...'
        & "$PSScriptRoot\..\start\Start.ps1" -HideHeaders -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
    }
}

Invoke-Hook -HookName 'AfterBaseInstall' -AdditionalHooksDir $AdditionalHooksDir

Write-Log '---------------------------------------------------------------'
Write-Log "Multi-VM setup finished.  Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables
