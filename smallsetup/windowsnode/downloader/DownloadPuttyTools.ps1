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

function DownloadPuttyArtifacts($baseDirectory) {
    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null

    Write-Log "Download plink"
    DownloadFile "$baseDirectory\$global:WindowsNode_Plink" https://the.earth.li/~sgtatham/putty/0.76/w64/$global:WindowsNode_Plink $true $Proxy
    Write-Log "Download pscp"
    DownloadFile "$baseDirectory\$global:WindowsNode_Pscp" https://the.earth.li/~sgtatham/putty/0.76/w64//$global:WindowsNode_Pscp $true $Proxy
}

$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$puttytoolsDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_PuttytoolsDirectory"

DownloadPuttyArtifacts($puttytoolsDownloadsDirectory)


