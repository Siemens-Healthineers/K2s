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

    # The rootfs has been pre-configured during creation with:
    # - Fixed fstab (no PARTUUID entries)
    # - Masked boot-efi.mount
    # - Systemd cgroups v1 compatibility settings

    Write-Log 'Starting WSL distro...'
    $null = wsl --exec /bin/true 2>&1

    Write-Log 'Waiting for WSL distro to initialize...'
    $maxRetries = 20
    $retryDelaySeconds = 3
    $systemdReady = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        Start-Sleep -Seconds $retryDelaySeconds
        try {
            $result = wsl --exec /bin/bash -c 'systemctl is-system-running 2>/dev/null || echo "unknown"; exit 0' 2>&1
            $resultStr = ($result | Out-String).Trim()
            if ($resultStr -match 'running|degraded') {
                Write-Log "WSL systemd is ready (status: $resultStr)"
                $systemdReady = $true
                break
            }
            Write-Log "Waiting for WSL systemd to be ready (attempt $i/$maxRetries, status: $resultStr)..."
        }
        catch {
            Write-Log "Waiting for WSL systemd to be ready (attempt $i/$maxRetries, exception: $($_.Exception.Message))..."
        }
    }
    if (-not $systemdReady) {
        Write-Log 'Warning: WSL systemd may not be fully ready, attempting to start sshd directly...'
        $null = wsl --exec /bin/bash -c 'systemctl start ssh 2>/dev/null || /usr/sbin/sshd 2>/dev/null; exit 0' 2>&1
    }

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