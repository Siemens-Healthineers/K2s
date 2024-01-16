# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishFlannelArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish flannel artifacts"
    Copy-Item -Path "$baseDirectory\$global:WindowsNode_FlanneldExe" -Destination "$global:ExecutableFolderPath" -Force
}

function PublishCniPlugins($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish cni plugins artifacts"
    Copy-Item -Path "$baseDirectory\*.*" -Destination "$global:CniPath" -Force
}

function PublishCniFlannelArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish cni flannel artifacts"
    Copy-Item "$baseDirectory\$global:WindowsNode_Flannel64exe" "$global:CniPath\flannel.exe" -Force
}

$flannelArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_FlannelDirectory"
$cniPluginsArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_CniPluginsDirectory"
$cniFlannelArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_CniFlannelDirectory"

PublishFlannelArtifacts($flannelArtifactsDirectory)
PublishCniPlugins($cniPluginsArtifactsDirectory)
PublishCniFlannelArtifacts($cniFlannelArtifactsDirectory)





