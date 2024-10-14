# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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

function DownloadDnsProxyArtifacts($baseDirectory) {
    $compressedFile = "$baseDirectory\dnsproxy.zip"

    Write-Log "Create folder '$baseDirectory'"
    mkdir $baseDirectory | Out-Null
    Write-Log "Download dnsproxy"
    DownloadFile "$compressedFile" https://github.com/AdguardTeam/dnsproxy/releases/download/v0.43.1/dnsproxy-windows-amd64-v0.43.1.zip $true $Proxy
    Write-Log "  ...done"
    Write-Log "Extract downloaded file '$compressedFile'"
    $ErrorActionPreference = 'SilentlyContinue'
    tar C `"$baseDirectory`" -xvf `"$compressedFile`" --strip-components 1 windows-amd64/*.exe 2>&1 | % { "$_" }
    $ErrorActionPreference = 'Stop'
    Write-Log "  ...done"
    Remove-Item -Path "$compressedFile" -Force -ErrorAction SilentlyContinue
}


$downloadsBaseDirectory = "$global:WindowsNodeArtifactsDownloadsDirectory"
if (!(Test-Path $downloadsBaseDirectory)) {
    Write-Log "Create folder '$downloadsBaseDirectory'"
    New-Item -Force -Path $downloadsBaseDirectory -ItemType Directory
}

$dnsproxyDownloadsDirectory = "$downloadsBaseDirectory\$global:WindowsNode_DnsProxyDirectory"

DownloadDnsProxyArtifacts($dnsproxyDownloadsDirectory)

