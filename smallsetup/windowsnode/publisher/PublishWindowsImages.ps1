# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishWindowsImages($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }

    $fileSearchPattern = "$baseDirectory\*.tar"
    $files = Get-ChildItem -Path "$fileSearchPattern"
    $amountOfFiles = $files.Count
    Write-Log "Amount of images found that matches the search pattern '$fileSearchPattern': $amountOfFiles"
    $fileIndex = 1
    foreach ($file in $files){
        $fileFullName = $file.FullName
        Write-Log "Import image from file '$fileFullName'... ($fileIndex of $amountOfFiles)"
        &$global:CtrExe -n="k8s.io" images import `"$file`"
        if (!$?) {
            throw "The file '$fileFullName' could not be imported"
        }
        Write-Log "  done"
        $fileIndex++
    }
}

$windowsImagesArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_ImagesDirectory"

PublishWindowsImages($windowsImagesArtifactsDirectory)

