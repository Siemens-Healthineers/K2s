# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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

function DownloadNssmArtifacts($baseDirectory) {
    $compressedNssmFile = 'nssm.zip'
    $compressedFile = "$baseDirectory\$compressedNssmFile"

    $arch = 'win32'
    if ([Environment]::Is64BitOperatingSystem) {
        $arch = 'win64'
    }

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log "Download nssm"
    DownloadFile "$compressedFile" 'https://k8stestinfrabinaries.blob.core.windows.net/nssm-mirror/nssm-2.24.zip' $true $Proxy
    $ErrorActionPreference = 'SilentlyContinue'
    cmd /c tar C `"$baseDirectory`" -xvf `"$compressedFile`" --strip-components 2 */$arch/*.exe 2>&1 | ForEach-Object { "$_" }
    $ErrorActionPreference = 'Stop'
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}

$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$downloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_NssmDirectory"

DownloadNssmArtifacts($downloadsDirectory)

if ($Deploy) {
    if (!(Test-Path($global:WindowsNodeArtifactsDirectory))) {
        mkdir $global:WindowsNodeArtifactsDirectory | Out-Null
    } else {
        $nssmArtifactsDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_NssmDirectory"

        if (Test-Path("$nssmArtifactsDirectory")) {
            Remove-Item -Path "$nssmArtifactsDirectory" -Force -Recurse
        }
    }

    Copy-Item -Path "$downloadsDirectory" -Destination "$global:WindowsNodeArtifactsDirectory" -Recurse -Force
}








