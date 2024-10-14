# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishWindowsExporterArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish windows exporter artifacts"
    Copy-Item -Path "$baseDirectory\$global:WindowsNode_WindowsExporterExe" -Destination "$global:ExecutableFolderPath" -Force
}

$windowsExporterArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_WindowsExporterDirectory"

PublishWindowsExporterArtifacts($windowsExporterArtifactsDirectory)

