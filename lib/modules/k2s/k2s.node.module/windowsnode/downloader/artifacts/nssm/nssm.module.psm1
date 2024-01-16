# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\log\log.module.psm1"
$systemModule = "$PSScriptRoot\..\..\..\system\system.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $systemModule

$kubeBinPath = Get-KubeBinPath
# nssm
$windowsNode_NssmDirectory = "nssm"
$nssmInstallDirectory = "$kubeBinPath"
$nssmInstallDirectoryLegacy = "$env:ProgramFiles\nssm"

function Invoke-DownloadNssmArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory) {
    $nssmDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_NssmDirectory"
    $compressedNssmFile = 'nssm.zip'
    $compressedFile = "$nssmDownloadsDirectory\$compressedNssmFile"

    $arch = 'win32'
    if ([Environment]::Is64BitOperatingSystem) {
        $arch = 'win64'
    }

    Write-Log "Create folder '$nssmDownloadsDirectory'"
    mkdir $nssmDownloadsDirectory | Out-Null
    Write-Log "Download nssm"
    Invoke-DownloadFile "$compressedFile" 'https://k8stestinfrabinaries.blob.core.windows.net/nssm-mirror/nssm-2.24.zip' $true $Proxy
    $ErrorActionPreference = 'SilentlyContinue'
    cmd /c tar C `"$nssmDownloadsDirectory`" -xvf `"$compressedFile`" --strip-components 2 */$arch/*.exe 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = 'Stop'
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue

    $nssmArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_NssmDirectory"

    if (Test-Path("$nssmArtifactsDirectory")) {
        Remove-Item -Path "$nssmArtifactsDirectory" -Force -Recurse
    }

    Copy-Item -Path "$nssmDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force
}

function Invoke-DeployNssmArtifacts($windowsNodeArtifactsDirectory) {
    $nssmDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_NssmDirectory"
    if (Test-Path "$nssmInstallDirectory\nssm.exe") {
        Write-Log 'nssm already published.'
    }
    else {
        if (!(Test-Path "$nssmDirectory")) {
            throw "Directory '$nssmDirectory' does not exist"
        }

        Write-Log 'Publishing nssm ...'
        mkdir -Force $nssmInstallDirectory | Out-Null
        Copy-Item -Path "$nssmDirectory\*" -Destination "$nssmInstallDirectory" -Recurse -Force

        Write-Log 'done.'
    }
}

function Remove-ServiceIfExists($serviceName) {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        $nssm = "$nssmInstallDirectory\nssm.exe"
        if (!(Test-Path $nssm)) {
            $nssm = "$nssmInstallDirectoryLegacy\nssm.exe"
        }
        Write-Log ('Removing service: ' + $serviceName)
        Stop-Service -Force -Name $serviceName | Out-Null
        &$nssm remove $serviceName confirm
    }
}

function Remove-Nssm {
    if ($global:PurgeOnUninstall) {
        Write-Log 'Remove nssm'
        Remove-Item -Path "$nssmInstallDirectory\nssm.exe" -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $nssmInstallDirectoryLegacy) {
        Remove-Item -Path $nssmInstallDirectoryLegacy -Force -Recurse -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Starts a specified service and sets it to auto-start.
.DESCRIPTION
    Starts a specified service and sets it to auto-start.
.PARAMETER Name
    Name of the service
.EXAMPLE
    Start-ServiceAndSetToAutoStart -Name 'kubelet'
.NOTES
    Does nothing if the service was not found.
#>
function Start-ServiceAndSetToAutoStart {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please provide the name of the service.')
    )

    $svc = $(Get-Service -Name $Name -ErrorAction SilentlyContinue).Status

    if ($svc) {
        $nssm = "$nssmInstallDirectory\nssm.exe"
        if (!(Test-Path $nssm)) {
            $nssm = "$nssmInstallDirectoryLegacy\nssm.exe"
        }
        Write-Log ('Changing service to auto startup and starting: ' + $Name)
        &$nssm set $Name Start SERVICE_AUTO_START | Out-Null
        Start-Service $Name -WarningAction SilentlyContinue
        Write-Log "service started: $Name"
    }
}

function Stop-ServiceAndSetToManualStart($serviceName) {
    $svc = $(Get-Service -Name $serviceName -ErrorAction SilentlyContinue).Status
    if (($svc)) {
        $nssm = "$nssmInstallDirectory\nssm.exe"
        if (!(Test-Path $nssm)) {
            $nssm = "$nssmInstallDirectoryLegacy\nssm.exe"
        }
        Write-Log ('Stopping service and set to manual startup: ' + $serviceName)
        Stop-Service $serviceName
        &$nssm set $serviceName Start SERVICE_DEMAND_START | Out-Null
    }
}

Export-ModuleMember Invoke-DownloadNssmArtifacts,
Invoke-DeployNssmArtifacts,
Remove-ServiceIfExists,
Start-ServiceAndSetToAutoStart,
Remove-Nssm,
Stop-ServiceAndSetToManualStart