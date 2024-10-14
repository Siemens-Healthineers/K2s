# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator
Param(
    [parameter(Mandatory = $false, HelpMessage = 'DNS Server for dnsproxy upstream')]
    [string] $dnsServer = '8.8.8.8'
)
# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

Write-Log 'Registering dnsproxy service'
mkdir -Force "$($global:SystemDriveLetter):\var\log\dnsproxy" | Out-Null
&$global:NssmInstallDirectory\nssm install dnsproxy $global:BinPath\dnsproxy.exe
&$global:NssmInstallDirectory\nssm set dnsproxy AppDirectory $global:BinPath | Out-Null

Write-Log "Creating dnsproxy.yaml (config for dnsproxy.exe)"

$configContent = @'
# To use it within dnsproxy specify the --config-path=/<path-to-config.yaml>
# option.  Any other command-line options specified will override the values
# from the config file.
---
listen-addrs:
'@

$configContent += "`n"
$configContent += "  - ""$global:ClusterCIDR_NextHop"" `n"
$configContent += "  - ""$global:IP_NextHop"" `n"
$configContent += "upstream: `n"
$configContent += "  - ""[/local/]$global:IP_Master"" `n"
$configContent += "  - ""$dnsServer"""

$configContent | Set-Content "$global:KubernetesPath\bin\dnsproxy.yaml" -Force

&$global:NssmInstallDirectory\nssm set dnsproxy AppParameters " --config-path=\`"$global:KubernetesPath\bin\dnsproxy.yaml\`" " | Out-Null
&$global:NssmInstallDirectory\nssm set dnsproxy AppStdout "$($global:SystemDriveLetter):\var\log\dnsproxy\dnsproxy_stdout.log" | Out-Null
&$global:NssmInstallDirectory\nssm set dnsproxy AppStderr "$($global:SystemDriveLetter):\var\log\dnsproxy\dnsproxy_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set dnsproxy AppStdoutCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set dnsproxy AppStderrCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set dnsproxy AppRotateFiles 1 | Out-Null
&$global:NssmInstallDirectory\nssm set dnsproxy AppRotateOnline 1 | Out-Null
&$global:NssmInstallDirectory\nssm set dnsproxy AppRotateSeconds 0 | Out-Null
&$global:NssmInstallDirectory\nssm set dnsproxy AppRotateBytes 500000 | Out-Null
&$global:NssmInstallDirectory\nssm set dnsproxy Start SERVICE_AUTO_START | Out-Null

