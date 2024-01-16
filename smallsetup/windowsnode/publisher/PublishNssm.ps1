# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function DeployNssmArtifacts($baseDirectory) {
    if (Test-Path "$global:NssmInstallDirectory\nssm.exe") {
        Write-Log 'nssm already published.'
    }
    else {
        if (!(Test-Path "$baseDirectory")) {
            throw "Directory '$baseDirectory' does not exist"
        }

        Write-Log 'Publishing nssm ...'
        mkdir -Force $global:NssmInstallDirectory | Out-Null
        Copy-Item -Path "$baseDirectory\*" -Destination "$global:NssmInstallDirectory" -Recurse -Force

        Write-Log 'done.'
    }
}

$nssmDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_NssmDirectory"

DeployNssmArtifacts($nssmDirectory)
