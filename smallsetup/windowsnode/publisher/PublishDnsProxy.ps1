# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\WindowsNodeCommonVariables.ps1

$ErrorActionPreference = 'Stop'

function PublishDnsProxyArtifacts($baseDirectory) {
    if (!(Test-Path "$baseDirectory")) {
        throw "Directory '$baseDirectory' does not exist"
    }
    Write-Log "Publish dnsproxy artifacts"
    Copy-Item -Path "$baseDirectory\*" -Destination "$global:BinPath" -Recurse -Force
}


$dnsProxyDirectory = "$global:WindowsNodeArtifactsDirectory\$global:WindowsNode_DnsProxyDirectory"

PublishDnsProxyArtifacts($dnsProxyDirectory)
