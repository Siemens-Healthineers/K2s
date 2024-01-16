# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishYamlArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish yaml artifacts"
    Copy-Item -Path "$baseDirectory\*" -Destination "$global:BinPath" -Recurse -Force
}

$yamlDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_YamlDirectory"

PublishYamlArtifacts($yamlDirectory)
