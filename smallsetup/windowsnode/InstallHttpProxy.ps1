# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Proxy for Host')]
    [string]$Proxy = ''
)
Write-Log 'Registering httpproxy service'
# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
mkdir -Force "$($global:SystemDriveLetter):\var\log\httpproxy" | Out-Null
&$global:NssmInstallDirectory\nssm install httpproxy $global:BinPath\httpproxy.exe
&$global:NssmInstallDirectory\nssm set httpproxy AppDirectory $global:BinPath | Out-Null
$appParameters = "--allowed-cidr $global:ClusterCIDR --allowed-cidr $global:ClusterCIDR_Services --allowed-cidr $global:IP_CIDR --allowed-cidr $global:CIDR_LoopbackAdapter"
if ( $Proxy -ne '' ) {
    $appParameters = $appParameters + " --forwardproxy $Proxy"
}
&$global:NssmInstallDirectory\nssm set httpproxy AppParameters $appParameters | Out-Null
&$global:NssmInstallDirectory\nssm set httpproxy AppStdout "$($global:SystemDriveLetter):\var\log\httpproxy\httpproxy_stdout.log" | Out-Null
&$global:NssmInstallDirectory\nssm set httpproxy AppStderr "$($global:SystemDriveLetter):\var\log\httpproxy\httpproxy_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set httpproxy AppStdoutCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set httpproxy AppStderrCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set httpproxy AppRotateFiles 1 | Out-Null
&$global:NssmInstallDirectory\nssm set httpproxy AppRotateOnline 1 | Out-Null
&$global:NssmInstallDirectory\nssm set httpproxy AppRotateSeconds 0 | Out-Null
&$global:NssmInstallDirectory\nssm set httpproxy AppRotateBytes 500000 | Out-Null
&$global:NssmInstallDirectory\nssm set httpproxy Start SERVICE_AUTO_START | Out-Null

New-NetFirewallRule -DisplayName $global:ProxyInboundFirewallRule -Group "k2s" -Direction Inbound -LocalPort 8181 -Protocol TCP -Action Allow | Out-Null

Start-Service httpproxy