# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Kubernetes version to use')]
    [string] $KubernetesVersion,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = ''
)

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1
. $PSScriptRoot\..\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

function DownloadKubetoolsArtifacts($baseDirectory) {
    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null

    if (!$KubernetesVersion.StartsWith('v')) {
        $KubernetesVersion = 'v' + $KubernetesVersion
    }

    Write-Log "Download kubelet"
    DownloadFile "$baseDirectory\$global:WindowsNode_KubeletExe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/$global:WindowsNode_KubeletExe $true $Proxy
    Write-Log "Download kubeadm"
    DownloadFile "$baseDirectory\$global:WindowsNode_KubeadmExe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/$global:WindowsNode_KubeadmExe $true $Proxy
    Write-Log "Download kubeproxy"
    DownloadFile "$baseDirectory\$global:WindowsNode_KubeproxyExe" https://dl.k8s.io/$KubernetesVersion/bin/windows/amd64/$global:WindowsNode_KubeproxyExe $true $Proxy
    Write-Log "Download kubectl"
    DownloadFile "$baseDirectory\$global:WindowsNode_KubectlExe" https://dl.k8s.io/release/$KubernetesVersion/bin/windows/amd64/$global:WindowsNode_KubectlExe $true $Proxy
}

$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$kubetoolsDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_KubetoolsDirectory"

DownloadKubetoolsArtifacts($kubetoolsDownloadsDirectory)



