# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishDockerArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish docker artifacts"
    Copy-Item -Path "$baseDirectory\" -Destination "$global:KubernetesPath\bin" -Force -Recurse
}

$dockerDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_DockerDirectory\docker"

PublishDockerArtifacts($dockerDirectory)
