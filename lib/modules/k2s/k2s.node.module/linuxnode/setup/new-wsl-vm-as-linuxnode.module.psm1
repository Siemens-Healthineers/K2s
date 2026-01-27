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

    # CRITICAL: Fix fstab IMMEDIATELY after import, before systemd starts
    # The rootfs was built from Hyper-V and has PARTUUID entries that don't exist in WSL
    # This causes systemd to hang waiting for non-existent devices
    Write-Log 'Fixing fstab for WSL compatibility (removing PARTUUID entries)...'
    $wslRootPath = "$env:SystemDrive\wsl"
    $wslFstabPath = Join-Path $wslRootPath 'etc\fstab'
    if (Test-Path $wslFstabPath) {
        # Replace fstab with WSL-compatible version
        Set-Content -Path $wslFstabPath -Value '/dev/sdb / ext4 rw,discard,errors=remount-ro 0 1' -Force
        Write-Log 'Updated fstab to use /dev/sdb instead of PARTUUID'
    }

    # Configure systemd to work with cgroups v1 (required for newer systemd on WSL2)
    Write-Log 'Configuring systemd for cgroups v1 compatibility...'
    # Enable cgroup delegation for user sessions
    $userServiceDir = Join-Path $wslRootPath 'etc\systemd\system\user@.service.d'
    if (-not (Test-Path $userServiceDir)) { New-Item -ItemType Directory -Path $userServiceDir -Force | Out-Null }
    Set-Content -Path (Join-Path $userServiceDir 'delegate.conf') -Value "[Service]`nDelegate=yes" -Force

    # Prevent killing user processes
    $logindConfDir = Join-Path $wslRootPath 'etc\systemd\logind.conf.d'
    if (-not (Test-Path $logindConfDir)) { New-Item -ItemType Directory -Path $logindConfDir -Force | Out-Null }
    Set-Content -Path (Join-Path $logindConfDir 'wsl.conf') -Value "[Login]`nKillUserProcesses=no" -Force

    # Mask the boot-efi.mount that doesn't exist in WSL
    $systemdSystemDir = Join-Path $wslRootPath 'etc\systemd\system'
    $null = New-Item -ItemType SymbolicLink -Path (Join-Path $systemdSystemDir 'boot-efi.mount') -Target '/dev/null' -Force -ErrorAction SilentlyContinue

    Write-Log 'Starting WSL distro...'
    # Start WSL - now systemd should boot properly
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