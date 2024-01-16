# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(ParameterSetName = 'PROXY', Mandatory = $True)]
    [string] $Proxy
)

$ErrorActionPreference = 'Stop'

Write-Output "Set proxy $proxy for current system"

# load global settings
Write-Output "Read global config values"
&$PSScriptRoot\..\GlobalVariables.ps1

$pr = ''
if ( $Proxy ) { $pr = $Proxy.Replace('http://', '') }
$NoProxy = "localhost,$global:IP_Master,10.81.0.0/16,$global:ClusterCIDR,$global:ClusterCIDR_Services,$global:IP_CIDR,svc.cluster.local"

Write-Output "Simple proxy: $pr"
netsh winhttp set proxy proxy-server=$pr bypass-list="<local>"
$RegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Set-ItemProperty -Path $RegKey ProxyEnable -Value 1 -Verbose -ErrorAction Stop
Set-ItemProperty -Path $RegKey ProxyServer -Value $Proxy -verbose -ErrorAction Stop
