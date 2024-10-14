# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Write-Log 'Registering flannel service'

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

&$global:NssmInstallDirectory\nssm install flanneld $global:ExecutableFolderPath\flanneld.exe
$adapterName = Get-L2BridgeNIC
Write-Log "Using network adapter '$adapterName'"
$ipaddresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $adapterName)
if (!$ipaddresses) {
    throw 'No IP address found on the host machine which can be used for setting up networking !'
}

$ipaddress = $ipaddresses[0] | Select -ExpandProperty IPAddress
if (!($ipaddress)) {
    $ipaddress = Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $adapterName | Select -ExpandProperty IPAddress
}

Write-Log "Using local IP $ipaddress for AppParameters of flanneld"
&$global:NssmInstallDirectory\nssm set flanneld AppParameters "--kubeconfig-file=\`"$global:KubernetesPath\config\`" --iface=$ipaddress --ip-masq=1 --kube-subnet-mgr=1" | Out-Null
$hn = ($(hostname)).ToLower()
&$global:NssmInstallDirectory\nssm set flanneld AppEnvironmentExtra NODE_NAME=$hn | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld AppDirectory "$($global:SystemDriveLetter):\" | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld AppStdout "$($global:SystemDriveLetter):\var\log\flanneld\flanneld_stdout.log" | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld AppStderr "$($global:SystemDriveLetter):\var\log\flanneld\flanneld_stderr.log" | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld AppStdoutCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld AppStderrCreationDisposition 4 | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld AppRotateFiles 1 | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld AppRotateOnline 1 | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld AppRotateSeconds 0 | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld AppRotateBytes 500000 | Out-Null
&$global:NssmInstallDirectory\nssm set flanneld Start SERVICE_AUTO_START | Out-Null