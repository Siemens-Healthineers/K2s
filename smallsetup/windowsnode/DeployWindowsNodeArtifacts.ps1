# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Kubernetes version to use')]
    [string] $KubernetesVersion,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [boolean] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [boolean] $ForceOnlineInstallation = $false,
    [parameter()]
    [ValidateNotNullOrEmpty()]
    [string] $SetupType = $(throw 'K8s Setup type required')
)

&$PSScriptRoot\WindowsNodeCommonVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

function Extract-WindowsNodeArtifactsFromCompressedFile {
    if (!(Test-Path($global:WindowsNodeArtifactsZipFilePath))) {
        throw "The file '$global:WindowsNodeArtifactsZipFilePath' that shall contain the artifacts for the Windows host does not exist."
    }

    if (Test-Path($global:WindowsNodeArtifactsDirectory)) {
        Write-Log "Remove content of folder '$global:WindowsNodeArtifactsDirectory'"
        Remove-Item "$global:WindowsNodeArtifactsDirectory\*" -Recurse -Force
    } else {
        Write-Log "Create folder '$global:WindowsNodeArtifactsDirectory'"
        mkdir $global:WindowsNodeArtifactsDirectory -ErrorAction SilentlyContinue | Out-Null
    }

    Write-Log "Extract the artifacts from the file '$global:WindowsNodeArtifactsZipFilePath' to the directory '$global:WindowsNodeArtifactsDirectory'..."
    Expand-Archive -LiteralPath $global:WindowsNodeArtifactsZipFilePath -DestinationPath $global:WindowsNodeArtifactsDirectory
    Write-Log "  done"
}

$isZipFileAlreadyAvailable = Test-Path -Path "$global:WindowsNodeArtifactsZipFilePath"
$downloadArtifacts = ($ForceOnlineInstallation -or !$isZipFileAlreadyAvailable)

Write-Log "Download Windows node artifacts?: $downloadArtifacts"
Write-Log " - force online installation?: $ForceOnlineInstallation"
Write-Log " - is file '$global:WindowsNodeArtifactsZipFilePath' already available?: $isZipFileAlreadyAvailable"
Write-Log " - delete the file '$global:WindowsNodeArtifactsZipFilePath' for offline installation?: $DeleteFilesForOfflineInstallation"

if ($downloadArtifacts) {
    if ($isZipFileAlreadyAvailable) {
        Write-Log "Remove already existing file '$global:WindowsNodeArtifactsZipFilePath'"
        Remove-Item "$global:WindowsNodeArtifactsZipFilePath" -Force
    }
    Write-Log "Create folder '$global:DownloadsDirectory'"
    New-Item -Path "$global:DownloadsDirectory" -ItemType Directory -Force -ErrorAction SilentlyContinue
    &"$global:KubernetesPath\smallsetup\windowsnode\DownloadWindowsNodeArtifacts.ps1" -KubernetesVersion $KubernetesVersion -Proxy $Proxy -SetupType $SetupType
    Write-Log "Remove folder '$global:DownloadsDirectory'"
    Remove-Item -Path "$global:DownloadsDirectory" -Recurse -Force -ErrorAction SilentlyContinue
}

# expand zip file with windows node artifacts
Extract-WindowsNodeArtifactsFromCompressedFile

if ($DeleteFilesForOfflineInstallation) {
    Write-Log "Remove file '$global:WindowsNodeArtifactsZipFilePath'"
    Remove-Item "$global:WindowsNodeArtifactsZipFilePath" -Force
} else {
    Write-Log "Leave file '$global:WindowsNodeArtifactsZipFilePath' on file system for offline installation"
}








