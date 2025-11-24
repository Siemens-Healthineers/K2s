# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule, $configModule, $pathModule

$kubePath = Get-KubePath
$kubeBinPath = Get-KubeBinPath

$windowsNode_GpgDirectory = 'gpg'

function Invoke-DownloadAndInstallGpgArtifacts($downloadsBaseDirectory, $Proxy, $windowsNodeArtifactsDirectory, $gpgVersion = '2.4.8_20250514') {
    $gpgDownloadsDirectory = "$downloadsBaseDirectory\$windowsNode_GpgDirectory"
    $gpgArtifactsDirectory = "$windowsNodeArtifactsDirectory\$windowsNode_GpgDirectory"
    $installerFile = "gnupg-w32-${gpgVersion}.exe"
    $installerPath = "$gpgDownloadsDirectory\$installerFile"
    $url = "https://gnupg.org/ftp/gcrypt/binary/$installerFile"

    Write-Log "[Gpg] Create folder '$gpgDownloadsDirectory'"
    mkdir $gpgDownloadsDirectory | Out-Null

    Write-Log "[Gpg] Downloading $url"
    Invoke-DownloadFile "$installerPath" $url $true $Proxy

    Write-Log "[Gpg] Downloaded installer at $installerPath"

    if (Test-Path("$gpgArtifactsDirectory")) {
        Remove-Item -Path "$gpgArtifactsDirectory" -Force -Recurse
    }
    Copy-Item -Path "$gpgDownloadsDirectory" -Destination "$windowsNodeArtifactsDirectory" -Recurse -Force

    Write-Log "[Gpg] Performing silent install of GnuPG"
    Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
    Write-Log "[Gpg] Silent install completed"
}

# PowerShell

# PowerShell

function Invoke-DeployGpgArtifacts($windowsNodeArtifactsDirectory, $gpgVersion = '2.4.8_20250514') {
    $gpgInstallDir = "$env:ProgramFiles\GnuPG"
    if (!(Test-Path $gpgInstallDir)) {
        $gpgInstallDir = "${env:ProgramFiles(x86)}\GnuPG"
    }
    if (!(Test-Path $gpgInstallDir)) {
        throw "GnuPG install directory not found after installation."
    }

    $gpgTargetDir = Join-Path (Get-KubeBinPath) "gpg"
    Write-Log "[Gpg] Copying GnuPG directory '$gpgInstallDir' to '$gpgTargetDir'"
    if (!(Test-Path $gpgTargetDir)) {
        mkdir $gpgTargetDir | Out-Null
    }
    Copy-Item -Path "$gpgInstallDir\*" -Destination $gpgTargetDir -Recurse -Force
}



Export-ModuleMember Invoke-DownloadAndInstallGpgArtifacts, Invoke-DeployGpgArtifacts
