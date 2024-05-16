# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot\..\..\..\k2s.infra.module\k2s.infra.module.psm1"
$commonDistroModule = "$PSScriptRoot\..\distros\common-setup.module.psm1"
Import-Module $infraModule, $commonDistroModule

$debianDistroModule = "$PSScriptRoot\..\distros\debian\debian.module.psm1"
Import-SpecificDistroSettingsModule -ModulePath $debianDistroModule

$controlPlaneOnWslRootfsFileName = 'Kubemaster-Base.rootfs.tar.gz'

function New-WslLinuxVmAsControlPlaneNode {
    param (
        [string]$Hostname,
        [string]$IpAddress,
        [string]$GatewayIpAddress,
        [string]$DnsServers,
        [string]$VmName,
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes = 8GB,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount = 4,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize = 50GB,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
        [Boolean] $ForceOnlineInstallation = $false
    )

    $kubebinPath = Get-KubeBinPath
    $vhdxPath = "$kubebinPath\Kubemaster-Base-for-WSL.vhdx"
    $rootfsPath = Get-ControlPlaneOnWslRootfsFilePath

    $isRootfsFileAlreadyAvailable = (Test-Path $rootfsPath)
    $isOnlineInstallation = (!$isRootfsFileAlreadyAvailable -or $ForceOnlineInstallation)

    if ($isOnlineInstallation -and $isRootfsFileAlreadyAvailable) {
        Remove-Item -Path $rootfsPath -Force
    }
    if (Test-Path -Path $vhdxPath) {
        Remove-Item -Path $vhdxPath -Force
    }

    if (!(Test-Path -Path $rootfsPath)) {
        $controlPlaneNodeCreationParams = @{
                Hostname=$Hostname
                IpAddress=$IpAddress
                GatewayIpAddress=$GatewayIpAddress
                DnsServers=$DnsServers
                VmImageOutputPath=$vhdxPath
                Proxy=$Proxy
            }
        New-VmImageForControlPlaneNode @controlPlaneNodeCreationParams

        New-WslRootfsForControlPlaneNode -VmImageInputPath $vhdxPath -RootfsFileOutputPath $rootfsPath -Proxy $Proxy

        if (Test-Path -Path $vhdxPath) {
            Remove-Item -Path $vhdxPath -Force
        }
    }
}

function Get-ControlPlaneOnWslRootfsFilePath {
    $kubebinPath = Get-KubeBinPath
    return "$kubebinPath\$controlPlaneOnWslRootfsFileName"
}

function Get-ControlPlaneOnWslRootfsFileName {
    return $controlPlaneOnWslRootfsFileName
}

function Remove-WslLinuxVmAsControlPlaneNode {
    param (
        [string]$VmName,
        [string]$SwitchName
    )
    wsl --shutdown | Out-Null
    wsl --unregister $VmName | Out-Null
    #Reset-DnsServer $SwitchName
}


Export-ModuleMember -Function New-WslLinuxVmAsControlPlaneNode, Get-ControlPlaneOnWslRootfsFilePath, Remove-WslLinuxVmAsControlPlaneNode, Get-ControlPlaneOnWslRootfsFileName