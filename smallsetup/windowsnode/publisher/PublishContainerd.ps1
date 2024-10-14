# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishContainerdArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    $containerdTargetDirectory = "$global:KubernetesPath\bin\containerd"
    if (!(Test-Path "$containerdTargetDirectory")) {
        Write-Log "Create folder '$containerdTargetDirectory'"
        mkdir $containerdTargetDirectory | Out-Null
    }

    $containerdSourceDirectory = "$baseDirectory\bin"
    if (!(Test-Path "$containerdSourceDirectory")) {
        throw "The expected directory '$containerdSourceDirectory' does not exist"
    }
    Write-Log "Publish containerd artifacts"
    Copy-Item -Path "$containerdSourceDirectory\*.*" -Destination "$containerdTargetDirectory"
}

function PublishCrictlArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish crictl artifacts"
    Copy-Item -Path "$baseDirectory\crictl.exe" -Destination "$global:BinPath" -Force
}

function PublishNerdctlArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish nerdctl artifacts"
    Copy-Item -Path "$baseDirectory\nerdctl.exe" -Destination "$global:BinPath" -Force
}

$containerdArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_ContainerdDirectory"
$crictlArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_CrictlDirectory"
$nerdctlArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_NerdctlDirectory"

PublishContainerdArtifacts($containerdArtifactsDirectory)
PublishCrictlArtifacts($crictlArtifactsDirectory)
PublishNerdctlArtifacts($nerdctlArtifactsDirectory)







