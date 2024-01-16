# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Docker version to use')]
    [string] $DockerVersion = '24.0.7',
    [switch] $Deploy,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy = ''
)

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1
. $PSScriptRoot\..\..\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

function DownloadDockerArtifacts($baseDirectory) {
    $compressedDockerFile = 'docker-' + $DockerVersion + '.zip'
    $compressedFile = "$baseDirectory\$compressedDockerFile"

    $url = 'https://download.docker.com/win/static/stable/x86_64/' + $compressedDockerFile

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log "Download docker"
    Write-Log "Fetching $url (approx. 130 MB)...."
    DownloadFile "$compressedFile" $url $true $Proxy
    Expand-Archive "$compressedFile" -DestinationPath "$baseDirectory" -Force
    Write-Log "  ...done"
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}

$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$downloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_DockerDirectory"

DownloadDockerArtifacts($downloadsDirectory)

if ($Deploy) {
    if (!(Test-Path($global:WindowsNodeArtifactsDirectory))) {
        mkdir $global:WindowsNodeArtifactsDirectory | Out-Null
    } else {
        $dockerArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_DockerDirectory"

        if (Test-Path("$dockerArtifactsDirectory")) {
            Remove-Item -Path "$dockerArtifactsDirectory" -Force -Recurse
        }
    }

    Copy-Item -Path "$downloadsDirectory" -Destination "$global:WindowsNodeArtifactsDirectory" -Recurse -Force
}







