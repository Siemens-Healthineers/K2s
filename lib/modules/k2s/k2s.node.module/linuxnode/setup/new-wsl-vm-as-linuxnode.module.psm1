# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
        [Boolean] $ForceOnlineInstallation = $false
    )

    $kubebinPath = Get-KubeBinPath
    $vhdxPath = "$kubebinPath\Kubemaster-Base.vhdx"
    $rootfsPath = Get-ControlPlaneOnWslRootfsFilePath

    $isRootfsFileAlreadyAvailable = (Test-Path $rootfsPath)
    if ($ForceOnlineInstallation -and $isRootfsFileAlreadyAvailable) {
        Remove-Item -Path $rootfsPath -Force
    }

    if (!(Test-Path -Path $rootfsPath)) {
        $controlPlaneNodeCreationParams = @{
                Hostname=$Hostname
                IpAddress=$IpAddress
                GatewayIpAddress=$GatewayIpAddress
                DnsServers=$DnsServers
                VmImageOutputPath=$vhdxPath
                Proxy=$Proxy
                VMDiskSize = $VMDiskSize
                VMMemoryStartupBytes = $VMMemoryStartupBytes
                VMProcessorCount = $VMProcessorCount
                DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
                ForceOnlineInstallation = $ForceOnlineInstallation
            }
        New-VmImageForControlPlaneNode @controlPlaneNodeCreationParams

        $wslRootfsForControlPlaneNodeCreationParams = @{
                VmImageInputPath=$vhdxPath
                RootfsFileOutputPath=$rootfsPath
                Proxy=$Proxy
                VMDiskSize = $VMDiskSize
                VMMemoryStartupBytes = $VMMemoryStartupBytes
                VMProcessorCount = $VMProcessorCount
            }
        New-WslRootfsForControlPlaneNode @wslRootfsForControlPlaneNodeCreationParams

        if (!(Test-Path -Path $rootfsPath)) {
            throw "The file '$rootfsPath' is not available"
        }
    }

    Write-Log 'Remove existing KubeMaster distro if existing'
    wsl --unregister $VmName | Out-Null
    Write-Log 'Import KubeMaster distro'
    wsl --import $VmName "$env:SystemDrive\wsl" "$rootfsPath"
    Write-Log 'Set KubeMaster as default distro'
    wsl -s $VmName

    Write-Log 'Waiting for WSL distro to initialize...'
    $maxRetries = 10
    $retryDelaySeconds = 3
    $systemdReady = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        Start-Sleep -Seconds $retryDelaySeconds
        # Use -u root to avoid user session initialization issues
        $result = wsl -u root -e /bin/bash -c 'systemctl is-system-running 2>/dev/null || echo "not-ready"'
        if ($result -match 'running|degraded') {
            Write-Log "WSL systemd is ready (status: $result)"
            $systemdReady = $true
            break
        }
        Write-Log "Waiting for WSL systemd to be ready (attempt $i/$maxRetries, status: $result)..."
    }
    if (-not $systemdReady) {
        Write-Log 'Warning: WSL systemd may not be fully ready, proceeding anyway...'
    }

    Write-Log 'Update fstab'
    wsl -u root -e /bin/bash -c 'rm -f /etc/fstab'
    wsl -u root -e /bin/bash -c "echo '/dev/sdb / ext4 rw,discard,errors=remount-ro,x-systemd.growfs 0 1' | tee /etc/fstab"
    wsl --shutdown

}

function Get-ControlPlaneOnWslRootfsFilePath {
    $kubebinPath = Get-KubeBinPath
    return "$kubebinPath\$controlPlaneOnWslRootfsFileName"
}

function Get-ControlPlaneOnWslRootfsFileName {
    return $controlPlaneOnWslRootfsFileName
}


Export-ModuleMember -Function New-WslLinuxVmAsControlPlaneNode, Get-ControlPlaneOnWslRootfsFilePath, Get-ControlPlaneOnWslRootfsFileName