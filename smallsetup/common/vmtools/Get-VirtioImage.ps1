# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$Proxy = ''
)

# load global settings
&$PSScriptRoot\..\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\GlobalFunctions.ps1

Import-Module "$PSScriptRoot\..\..\ps-modules\log\log.module.psm1"

$ErrorActionPreference = 'Stop'

$urlRoot = 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/'
$urlFile = 'virtio-win.iso'

$url = "$urlRoot/$urlFile"

if (-not $OutputPath) {
    $OutputPath = Get-Item '.\'
}

$imgFile = Join-Path $OutputPath $urlFile

if ([System.IO.File]::Exists($imgFile)) {
    Write-Log "File '$imgFile' already exists. Nothing to do."
}
else {
    Write-Log "Downloading file '$imgFile'..."

    # Enables TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.WebClient

    if ($Proxy -ne '') {
        Write-Log "Using Proxy $Proxy to download $url"
        $webProxy = New-Object System.Net.WebProxy($Proxy)
        $webProxy.UseDefaultCredentials = $true
        $client.Proxy = $webProxy
    }

    $client.DownloadFile($url, $imgFile)
}

$imgFile
