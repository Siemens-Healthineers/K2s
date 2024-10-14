# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [Boolean] $DeleteFilesForOfflineInstallation = $false
)

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

if (Test-Path $global:WindowsNodeArtifactsDownloadsDirectory) {
    Write-Log "Deleting folder '$global:WindowsNodeArtifactsDownloadsDirectory'"
    Remove-Item $global:WindowsNodeArtifactsDownloadsDirectory -Recurse -Force
}

if (Test-Path $global:WindowsNodeArtifactsDirectory) {
    Write-Log "Deleting folder '$global:WindowsNodeArtifactsDirectory'"
    Remove-Item $global:WindowsNodeArtifactsDirectory -Recurse -Force
}

if ($DeleteFilesForOfflineInstallation) {
    Write-Log "Deleting file '$global:WindowsNodeArtifactsZipFilePath' if existing"
    if (Test-Path $global:WindowsNodeArtifactsZipFilePath) {
        Remove-Item $global:WindowsNodeArtifactsZipFilePath -Force
    }
}