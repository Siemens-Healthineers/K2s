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

    # Configure systemd to work with cgroups v1 before starting user sessions (required for newer systemd on WSL2)
    Write-Log 'Configuring systemd for cgroups v1 compatibility...'
    $null = wsl --exec /bin/bash -c 'mkdir -p /etc/systemd/system/user@.service.d && echo -e "[Service]\nDelegate=yes" > /etc/systemd/system/user@.service.d/delegate.conf' 2>&1
    $null = wsl --exec /bin/bash -c 'mkdir -p /etc/systemd/logind.conf.d && echo -e "[Login]\nKillUserProcesses=no" > /etc/systemd/logind.conf.d/nokill.conf' 2>&1
    # Shutdown WSL to apply the systemd configuration
    wsl --shutdown
    Start-Sleep -Seconds 2

    Write-Log 'Waiting for WSL distro to initialize...'
    $maxRetries = 15
    $retryDelaySeconds = 2
    $systemdReady = $false
    for ($i = 1; $i -le $maxRetries; $i++) {
        Start-Sleep -Seconds $retryDelaySeconds
        # Use --exec to bypass shell and session setup, redirect all output
        try {
            $result = wsl --exec /bin/bash -c 'systemctl is-system-running 2>/dev/null; exit 0' 2>&1
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
        Write-Log 'Warning: WSL systemd may not be fully ready, proceeding anyway...'
    }

    Write-Log 'Update fstab'
    $null = wsl --exec /bin/bash -c 'rm -f /etc/fstab' 2>&1
    $null = wsl --exec /bin/bash -c "echo '/dev/sdb / ext4 rw,discard,errors=remount-ro,x-systemd.growfs 0 1' > /etc/fstab" 2>&1
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