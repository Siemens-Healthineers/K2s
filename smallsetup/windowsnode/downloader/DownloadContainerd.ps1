# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [switch] $Deploy,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = ''
)

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1
. $PSScriptRoot\..\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

function DownloadContainerdArtifacts($baseDirectory) {
    $compressedContainerdFile = 'containerd-1.7.17-windows-amd64.tar.gz'
    $compressedFile = "$baseDirectory\$compressedContainerdFile"

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log 'Download containerd'
    DownloadFile "$compressedFile" https://github.com/containerd/containerd/releases/download/v1.7.17/$compressedContainerdFile $true $Proxy
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    cmd /c tar xf `"$compressedFile`" -C `"$baseDirectory`"
    Write-Log '  ...done'
    if (!$?) { throw "unable to extract '$compressedFile'" }
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}

function DownloadCrictlArtifacts($baseDirectory) {
    $compressedCrictlFile = 'crictl-v1.28.0-windows-amd64.tar.gz'
    $compressedFile = "$baseDirectory\$compressedCrictlFile"

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log 'Download crictl'
    DownloadFile "$compressedFile" https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.28.0/$compressedCrictlFile $true $Proxy
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    cmd /c tar xf `"$compressedFile`" -C `"$baseDirectory`"
    Write-Log '  ...done'
    if (!$?) { throw "unable to extract '$compressedFile'" }
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}

function DownloadNerdctlArtifacts($baseDirectory) {
    $compressedNerdFile = 'nerdctl-1.7.2-windows-amd64.tar.gz'
    $compressedFile = "$baseDirectory\$compressedNerdFile"

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log 'Download nerdctl'
    DownloadFile "$compressedFile" https://github.com/containerd/nerdctl/releases/download/v1.7.2/$compressedNerdFile $true $Proxy
    Write-Log '  ...done'
    Write-Log "Extract downloaded file '$compressedFile'"
    cmd /c tar xf `"$compressedFile`" -C `"$baseDirectory`"
    Write-Log '  ...done'
    if (!$?) { throw "unable to extract $compressedNerdFile" }
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}

$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$containerdDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_ContainerdDirectory"
$crictlDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_CrictlDirectory"
$nerdctlDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_NerdctlDirectory"

DownloadContainerdArtifacts($containerdDownloadsDirectory)
DownloadCrictlArtifacts($crictlDownloadsDirectory)
DownloadNerdctlArtifacts($nerdctlDownloadsDirectory)

if ($Deploy) {
    if (!(Test-Path($global:WindowsNodeArtifactsDirectory))) {
        mkdir $global:WindowsNodeArtifactsDirectory | Out-Null
    }
    else {
        $containerdArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_ContainerdDirectory"
        $crictlArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_CrictlDirectory"
        $nerdctlArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_NerdctlDirectory"

        if (Test-Path("$containerdArtifactsDirectory")) {
            Remove-Item -Path "$containerdArtifactsDirectory" -Force -Recurse
        }
        if (Test-Path("$crictlArtifactsDirectory")) {
            Remove-Item -Path "$crictlArtifactsDirectory" -Force -Recurse
        }
        if (Test-Path("$nerdctlArtifactsDirectory")) {
            Remove-Item -Path "$nerdctlArtifactsDirectory" -Force -Recurse
        }
    }

    Copy-Item -Path "$containerdDownloadsDirectory" -Destination "$global:WindowsNodeArtifactsDirectory" -Recurse -Force
    Copy-Item -Path "$crictlDownloadsDirectory" -Destination "$global:WindowsNodeArtifactsDirectory" -Recurse -Force
    Copy-Item -Path "$nerdctlDownloadsDirectory" -Destination "$global:WindowsNodeArtifactsDirectory" -Recurse -Force
}







