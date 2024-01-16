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

function DownloadWindowsExporterArtifacts($baseDirectory) {
    $file = "$baseDirectory\$global:WindowsNode_WindowsExporterExe"

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log "Download windows exporter"
    DownloadFile "$file" https://github.com/prometheus-community/windows_exporter/releases/download/v0.22.0/windows_exporter-0.22.0-amd64.exe $true $Proxy
}

$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$windowsExporterDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_WindowsExporterDirectory"

DownloadWindowsExporterArtifacts($windowsExporterDownloadsDirectory)

