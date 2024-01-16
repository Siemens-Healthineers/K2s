# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = ''
)

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1
. $PSScriptRoot\..\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

function DownloadFlannelArtifacts($baseDirectory) {
    $file = "$baseDirectory\$global:WindowsNode_FlanneldExe"

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log "Download flannel"
    DownloadFile "$file" https://github.com/coreos/flannel/releases/download/$global:FlannelVersion/$global:WindowsNode_FlanneldExe $true $Proxy
}

function DownloadCniPlugins($baseDirectory) {
    $cniPlugins = "cni-plugins-windows-amd64-$global:CNIPluginVersion.tgz"
    $compressedFile = "$baseDirectory\$cniPlugins"

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log "Download cni plugins"
    DownloadFile "$compressedFile" https://github.com/containernetworking/plugins/releases/download/$global:CNIPluginVersion/$cniPlugins $true $Proxy
    Write-Log "  ...done"
    Write-Log "Extract downloaded file '$compressedFile'"
    $ErrorActionPreference = 'Continue'
    tar.exe xvf `"$compressedFile`" -C `"$baseDirectory`" 2>&1 | %{ "$_" }
    $ErrorActionPreference = 'Stop'
    Write-Log "  ...done"
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}

function DownloadCniFlannelArtifacts($baseDirectory) {
    $file = "$baseDirectory\$global:WindowsNode_Flannel64exe"

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log "Download cni flannel"
    DownloadFile "$file" https://github.com/flannel-io/cni-plugin/releases/download/$global:CNIFlannelVersion/$global:WindowsNode_Flannel64exe $true $Proxy
    Write-Log "  ...done"
}

$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$flannelDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_FlannelDirectory"
$cniPluginsDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_CniPluginsDirectory"
$cniFlannelDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_CniFlannelDirectory"

DownloadFlannelArtifacts($flannelDownloadsDirectory)
DownloadCniPlugins($cniPluginsDownloadsDirectory)
DownloadCniFlannelArtifacts($cniFlannelDownloadsDirectory)





