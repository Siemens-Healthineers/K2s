# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT


#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with preparing a Windows system to be used for a mixed Linux/Windows Kubernetes cluster
This script is only valid for the Small K8s Setup!!!

.DESCRIPTION
This script assists in the following actions for Small K8s:
- Downloads Kubernetes binaries (kubelet, kubeadm, flannel, nssm) at the version specified
- Registers kubelet as an nssm service. More info on nssm: https://nssm.cc/

.EXAMPLE
Without proxy
PS> .\smallsetup\Install.ps1
With proxy
PS> .\smallsetup\Install.ps1 -Proxy http://your-proxy.example.com:8888
For small systems use low memory and skip start
PS> .\smallsetup\Install.ps1 -MasterVMMemory 2GB -SkipStart
For specifying resources
PS> .\smallsetup\Install.ps1 -MasterVMMemory 8GB -MasterVMProcessorCount 6 -MasterDiskSize 80GB
For specifying DNS Addresses
PS> .\smallsetup\Install.ps1 -MasterVMMemory 8GB -MasterVMProcessorCount 6 -MasterDiskSize 80GB -DnsAddresses '8.8.8.8','8.8.4.4'
#>

Param(
    # Main parameters
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Control Plane VM (Linux)')]
    [long] $MasterVMMemory = 8GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for Control Plane VM (Linux)')]
    [long] $MasterVMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Control Plane VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
    [string[]]$DnsAddresses = @('8.8.8.8', '8.8.4.4'),
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
    [parameter(Mandatory = $false, HelpMessage = 'Output every line that gets executed')]
    [switch] $Trace = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for VXLAN')]
    [bool] $HostGW = $true,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Restart N number of times after Install')]
    [long] $RestartAfterInstallCount = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting Control Plane VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()



$infraModule =   "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$systemModule =  "$PSScriptRoot/../../../modules/k2s/k2s.node.module/windowsnode/system/system.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $systemModule

Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile:$AppendLogFile

$KubernetesVersion = Get-DefaultK8sVersion
$script:SetupType = 'k2s'
$ErrorActionPreference = 'Continue'

Write-Log 'Prerequisites checks before installation' -Console

Test-PathPrerequisites
Test-ControlPlanePrerequisites -MasterVMProcessorCount $MasterVMProcessorCount -MasterVMMemory $MasterVMMemory -MasterDiskSize $MasterDiskSize
Test-WindowsPrerequisites -WSL:$WSL
Stop-InstallationIfRequiredCurlVersionNotInstalled

Enable-MissingWindowsFeatures $([bool]$WSL)

Stop-InstallIfNoMandatoryServiceIsRunning

if ($CheckOnly) {
    Write-Log 'Early exit (CheckOnly)' -Console
    exit
}

Write-Log 'Starting installation...'

# Add K2s executables as part of environment variable
Set-EnvVars

# make sure we are at the right place for install
$kubePath = Get-KubePath
Set-Location $kubePath

Set-ConfigSetupType -Value $script:SetupType
Set-ConfigWslFlag -Value $([bool]$WSL)

$linuxOsType = Get-LinuxOsType $LinuxVhdxPath
Set-ConfigLinuxOsType -Value $linuxOsType

Write-Log 'Preparing Windows host as worker node' -Console

# INSTALL LOOPBACK ADPATER
New-DefaultLoopbackAdater

# PREPARE WINDOWS NODE
Initialize-WinNode -KubernetesVersion $KubernetesVersion `
    -HostGW:$HostGW `
    -Proxy:"$Proxy" `
    -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
    -ForceOnlineInstallation $ForceOnlineInstallation

Write-Log 'Preparing control plane node' -Console
# PREPARE LINUX VM
Initialize-LinuxNode -VMStartUpMemory $MasterVMMemory `
    -VMProcessorCount $MasterVMProcessorCount `
    -VMDiskSize $MasterDiskSize `
    -InstallationStageProxy $Proxy `
    -HostGW $HostGW `
    -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
    -ForceOnlineInstallation $ForceOnlineInstallation `
    -WSL:$WSL `
    -LinuxVhdxPath $LinuxVhdxPath `
    -LinuxUserName $LinuxVMUsername `
    -LinuxUserPwd $LinuxVMUserPwd

# JOIN NODES
Write-Log "Preparing Kubernetes $KubernetesVersion by joining nodes" -Console

Initialize-KubernetesCluster -AdditionalHooksDir $AdditionalHooksDir

if ($global:InstallRestartRequired) {
    Write-Log 'RESTART!! Windows features are enabled. Restarting the machine is mandatory in order to start the cluster.' -Console
}
else {
    # START CLUSTER
    if (! $SkipStart) {
        Write-Log 'Starting Kubernetes System'
        & "$PSScriptRoot\..\start\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay
    }

    if ( ($RestartAfterInstallCount -gt 0) -and (! $SkipStart) ) {
        $restartCount = 0;

        while ($true) {
            $restartCount++
            Write-Log "Restarting Kubernetes System (iteration #$restartCount):"

            & "$PSScriptRoot\..\stop\Stop.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay
            Start-Sleep 10 # Wait for renew of IP

            & "$PSScriptRoot\..\start\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay
            Start-Sleep -s 5

            if ($restartCount -eq $RestartAfterInstallCount) {
                Write-Log 'Restarting Kubernetes System Completed'
                break;
            }
        }
    }
}

Invoke-Hook -HookName 'AfterBaseInstall' -AdditionalHooksDir $AdditionalHooksDir

# CURRENT STATE OF CLUSTER
Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide

Write-Log '---------------------------------------------------------------'
Write-Log "K2s setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables