# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with creating a linux VM acting as KubeMaster (K8s master and worker)

.DESCRIPTION
This script assists in the following actions for K2s:
- Creates VM with fixed address

.EXAMPLE
PS> .\InstallKubeMaster.ps1
#>

Param(
    [long]$MemoryStartupBytes = 6GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available to be used during installation')]
    [string] $InstallationStageProxy = '',
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy to be used during operation')]
    [string] $OperationStageProxy,
    [long]$MasterVMProcessorCount = 6,
    [uint64]$MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for VXLAN')]
    [bool] $HostGW = $true,
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [Boolean] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
    [Boolean] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'The path to the vhdx with Ubuntu inside.')]
    [string] $LinuxVhdxPath = '',
    [parameter(Mandatory = $false, HelpMessage = 'The user name to access the computer with Ubuntu inside.')]
    [string] $LinuxUserName = '',
    [parameter(Mandatory = $false, HelpMessage = 'The password associated with the user name to access the computer with Ubuntu inside.')]
    [string] $LinuxUserPwd = ''
)
$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

Write-Log "InstallKubeMaster called with RAM: $MemoryStartupBytes, Diskspace: $MasterDiskSize, CPUs: $MasterVMProcessorCount, Proxy (installation stage): '$InstallationStageProxy', Proxy (operation stage): '$OperationStageProxy'"

if (-not (Test-Path env:KUBEMASTER_TYPE)) {
    $env:KUBEMASTER_TYPE = 'RawDebian'  # set env if called directly
}

# uninstall previous setup
if (($(Get-VM | Where-Object Name -eq $global:VMName | Measure-Object).Count -ge 1) -or ($(Get-VMSwitch | Where-Object Name -eq $global:SwitchName | Measure-Object).Count -ge 1 )) {
    Write-Log 'Cleaning up previous KubeMaster VM'
    &"$global:KubernetesPath\smallsetup\kubemaster\UninstallKubeMaster.ps1" -DeleteFilesForOfflineInstallation $ForceOnlineInstallation
}

$isLinuxOsDebianCloud = ((Get-LinuxOsType) -eq $global:LinuxOsType_DebianCloud)

function SetProxySettings {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [string] $ProxySettings
    )
    # put proxy in VM
    Write-Log "Set proxy: '$ProxySettings' in VM"
    ExecCmdMaster 'sudo touch /etc/apt/apt.conf.d/proxy.conf'
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        ExecCmdMaster "echo Acquire::http::Proxy \""$ProxySettings\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf"
    } else {
        ExecCmdMaster "echo Acquire::http::Proxy \\\""$ProxySettings\\\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf"
    }


    Write-Log 'Set proxy for crio'
    ExecCmdMaster 'sudo mkdir -p /etc/systemd/system/crio.service.d'
    ExecCmdMaster 'sudo touch /etc/systemd/system/crio.service.d/http-proxy.conf'
    ExecCmdMaster 'echo [Service] | sudo tee /etc/systemd/system/crio.service.d/http-proxy.conf'
    ExecCmdMaster "echo Environment=\'HTTP_PROXY=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
    ExecCmdMaster "echo Environment=\'HTTPS_PROXY=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
    ExecCmdMaster "echo Environment=\'http_proxy=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
    ExecCmdMaster "echo Environment=\'https_proxy=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
    ExecCmdMaster "echo Environment=\'no_proxy=.local\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"

    Write-Log 'Set other proxy settings'
    ExecCmdMaster 'echo [engine] | sudo tee /etc/containers/containers.conf'
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        ExecCmdmaster "echo env = [\""https_proxy=$ProxySettings\""] | sudo tee -a /etc/containers/containers.conf"
    } else {
        ExecCmdmaster "echo env = [\\\""https_proxy=$ProxySettings\\\""] | sudo tee -a /etc/containers/containers.conf"
    }
}

function New-SshKey() {
    # remove previous VM key from known hosts
    $file = $global:SshConfigDir + '\known_hosts'
    if (Test-Path $file) {
        Write-Log 'Remove previous VM key from known_hosts file'
        ssh-keygen.exe -R $global:IP_Master 2>&1 | % { "$_" }
    }

    # Create SSH keypair, if not yet available
    $sshDir = Split-Path -parent $global:LinuxVMKey
    if (!(Test-Path $sshDir)) {
        mkdir $sshDir | Out-Null
    }
    if (!(Test-Path $global:LinuxVMKey)) {
        Write-Log "creating SSH key $global:LinuxVMKey"
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $global:LinuxVMKey -N ''
        } else {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $global:LinuxVMKey -N '""'  # strange powershell syntax for empty passphrase...
        }
    }
    if (!(Test-Path $global:LinuxVMKey)) {
        throw "unable to generate SSH keys ($global:LinuxVMKey)"
    }
}

function CopyBaseImageTo($TargetPath) {
    $kubemasterBaseVhdxPath = Get-KubemasterBaseImagePath
    $isBaseImageAlreadyAvailable = (Test-Path $kubemasterBaseVhdxPath)

    Write-Log "Provisioned base image already available? $isBaseImageAlreadyAvailable"
    Write-Log "Force the build and provisioning of the base image (i.e. online installation)? $ForceOnlineInstallation"
    Write-Log "Delete the provisioned base image for offline installation? $DeleteFilesForOfflineInstallation"

    $isOfflineInstallation = ($isBaseImageAlreadyAvailable -and !$ForceOnlineInstallation)

    if ($isLinuxOsDebianCloud) {
        $kubemasterRootfsPath = Get-KubemasterRootfsPath
        $isRootfsAlreadyAvailable = (Test-Path $kubemasterRootfsPath)
        Write-Log "Provisioned base image rootfs for WSL2 already available? $isRootfsAlreadyAvailable"

        $isOfflineInstallation = ($isOfflineInstallation -and $isRootfsAlreadyAvailable)
    }

    if ($isOfflineInstallation) {
        Write-Log "Using already existing base image '$kubemasterBaseVhdxPath'"
    }
    else {
        Write-Log 'Create and provision the base image'
        $validationModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
        Import-Module $validationModule
	    &"$global:KubernetesPath\smallsetup\baseimage\BuildAndProvisionKubemasterBaseImage.ps1" -Proxy $InstallationStageProxy -OutputPath $kubemasterBaseVhdxPath -VMMemoryStartupBytes $MemoryStartupBytes -VMProcessorCount $MasterVMProcessorCount -VMDiskSize $MasterDiskSize
        if (!(Test-Path $kubemasterBaseVhdxPath)) {
            throw "The provisioned base image is not available as $kubemasterBaseVhdxPath"
        }
        Write-Log "Provisioned base image available as $kubemasterBaseVhdxPath"
    }

    Write-Log "Removing '$TargetPath' if existing"
    if (Test-Path $TargetPath) {
        Remove-Item $TargetPath -Force
    }

    Write-Log "Copy '$kubemasterBaseVhdxPath' to '$TargetPath'"
    Copy-Item $kubemasterBaseVhdxPath $TargetPath
}

# Get default VHD path (requires administrative privileges)
$vmmsSettings = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
$vhdxPath = Join-Path $vmmsSettings.DefaultVirtualHardDiskPath "$global:VMName.vhdx"

CopyBaseImageTo($vhdxPath)

# restart httpproxy if service exists in order to listen also on new switch
Restart-Service httpproxy -ErrorAction SilentlyContinue

New-SshKey

if ($WSL) {
    $kubemasterRootfsPath = Get-KubemasterRootfsPath
    $isRootfsAlreadyAvailable = (Test-Path $kubemasterRootfsPath)
    if (!$isRootfsAlreadyAvailable) {
        throw "$kubemasterRootfsPath not available!"
    }

    Write-Log 'Remove existing KubeMaster distro if existing'
    wsl --unregister $global:VMName | Out-Null
    Write-Log 'Import KubeMaster distro'
    wsl --import $global:VMName "$env:SystemDrive\wsl" "$kubemasterRootfsPath"
    Write-Log 'Set KubeMaster as default distro'
    wsl -s $global:VMName

    Write-Log 'Update fstab'
    wsl /bin/bash -c 'sudo rm /etc/fstab'
    wsl /bin/bash -c "echo '/dev/sdb / ext4 rw,discard,errors=remount-ro,x-systemd.growfs 0 1' | sudo tee /etc/fstab"
    wsl --shutdown

    Start-WSL

    Set-WSLSwitch

    Wait-ForSSHConnectionToLinuxVMViaPwd
}
else {
    # prepare switch for master VM
    New-KubeSwitch

    &$PSScriptRoot\..\common\vmtools\New-VMFromDebianImage.ps1 -VMName $global:VMName -VhdxPath $vhdxPath -SwitchName $global:SwitchName -VHDXSizeBytes $MasterDiskSize -MemoryStartupBytes $MemoryStartupBytes -ProcessorCount $MasterVMProcessorCount -UseGeneration1

    Wait-ForSSHConnectionToLinuxVMViaPwd
}

$kubemasterBaseImagePath = Get-KubemasterBaseImagePath
$kubemasterRootfsPath = Get-KubemasterRootfsPath
if ($DeleteFilesForOfflineInstallation) {
    Write-Log "Remove '$kubemasterBaseImagePath'"
    Remove-Item $kubemasterBaseImagePath -Force
    Write-Log "Remove '$kubemasterRootfsPath'"
    Remove-Item $kubemasterRootfsPath -Force
}
else {
    Write-Log "Leave file '$kubemasterBaseImagePath' on file system for offline installation"
    Write-Log "Leave file '$kubemasterRootfsPath' on file system for offline installation"
}

# copy public key into VM and add it to authorized_keys file for the remote user
$localSourcePath = "$global:LinuxVMKey.pub"
$targetPath = "/tmp/$global:keyFileName.pub"
$remoteTargetPath = "$global:Remote_Master" + ":$targetPath"
Copy-FromToMaster -Source $localSourcePath -Target $remoteTargetPath -UsePwd
ExecCmdMaster "sudo mkdir -p /home/remote/.ssh" -UsePwd
ExecCmdMaster "sudo cat $targetPath | sudo tee /home/remote/.ssh/authorized_keys" -UsePwd

# for the next steps we need ssh access, so let's wait for ssh
Wait-ForSSHConnectionToLinuxVMViaSshKey

# remove password for remote user and disable password login
ExecCmdMaster "sudo passwd -d remote"

ExecCmdMaster "sudo sed -i 's/.*NAutoVTs.*/NAutoVTs=0/' /etc/systemd/logind.conf"
ExecCmdMaster "sudo sed -i 's/.*ReserveVT.*/ReserveVT=0/' /etc/systemd/logind.conf"
ExecCmdMaster "sudo systemctl disable getty@tty1.service 2>&1"
ExecCmdMaster 'sudo systemctl stop "getty@tty*.service"'
ExecCmdMaster "sudo systemctl restart systemd-logind.service"
ExecCmdMaster "echo Include /etc/ssh/sshd_config.d/*.conf | sudo tee -a /etc/ssh/sshd_config"
ExecCmdMaster "sudo touch /etc/ssh/sshd_config.d/disable_pwd_login.conf"
ExecCmdMaster "echo ChallengeResponseAuthentication no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf"
ExecCmdMaster "echo PasswordAuthentication no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf"
ExecCmdMaster "echo UsePAM no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf"
ExecCmdMaster "echo PermitRootLogin no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf"
ExecCmdMaster "sudo systemctl reload ssh"

if ($isLinuxOsDebianCloud) {
    SaveCloudInitFiles
}

if (![string]::IsNullOrWhiteSpace($OperationStageProxy)) {
    SetProxySettings -ProxySettings $OperationStageProxy
}

# dump vm properties
#Get-Vm -Name $global:VMName


$hostname = ExecCmdMaster "hostname" -NoLog
Save-ControlPlaneNodeHostname($hostname)

Write-Log "All steps done, VM $global:VMName now available !"