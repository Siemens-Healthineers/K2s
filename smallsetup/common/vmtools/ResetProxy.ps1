# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

Write-Output "Reset proxy for current system"

# load global settings
Write-Output "Read global config values"
&$PSScriptRoot\..\GlobalVariables.ps1

Write-Output "Reset proxy"
netsh winhttp reset proxy
$RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty -Path $RegKey ProxyServer -Value '' -Verbose -ErrorAction SilentlyContinue
Set-ItemProperty -Path $RegKey ProxyEnable -Value 0 -Verbose -ErrorAction SilentlyContinue

Write-Output "Reset proxy in git"
if ( Get-Command 'git.exe' -ErrorAction SilentlyContinue ) {
    git config --global --unset https.proxy
    git config --global --unset http.proxy
} 