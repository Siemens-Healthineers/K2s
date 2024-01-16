# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishKubetoolsArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish kubelet"
    Copy-Item -Path "$baseDirectory\$global:WindowsNode_KubeletExe" -Destination "$global:ExecutableFolderPath" -Force
    Write-Log "Publish kubeadm"
    Copy-Item -Path "$baseDirectory\$global:WindowsNode_KubeadmExe" -Destination "$global:ExecutableFolderPath" -Force
    Write-Log "Publish kubeproxy"
    Copy-Item -Path "$baseDirectory\$global:WindowsNode_KubeproxyExe" -Destination "$global:ExecutableFolderPath" -Force
    Write-Log "Publish kubectl"
    Copy-Item -Path "$baseDirectory\$global:WindowsNode_KubectlExe" -Destination "$global:ExecutableFolderPath" -Force
    # put a second copy in the bin folder, which is in the PATH
    Copy-Item -Path "$baseDirectory\$global:WindowsNode_KubectlExe" -Destination "$global:BinPath" -Force
}

$kubetoolsArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_KubetoolsDirectory"

PublishKubetoolsArtifacts($kubetoolsArtifactsDirectory)

