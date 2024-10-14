# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishPuttytoolsArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish plink"
    Copy-Item -Path "$baseDirectory\$global:WindowsNode_Plink" -Destination "$global:BinPath" -Force
    Write-Log "Publish pscp"
    Copy-Item -Path "$baseDirectory\$global:WindowsNode_Pscp" -Destination "$global:BinPath" -Force
}

$puttytoolsArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_PuttytoolsDirectory"

PublishPuttytoolsArtifacts($puttytoolsArtifactsDirectory)

