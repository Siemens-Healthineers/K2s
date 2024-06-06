# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

param (
    [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
    [string]$UserName = $(throw 'Argument missing: UserName'),
    [string]$UserPwd = $(throw 'Argument missing: UserPwd'),
    [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
    [string] $Proxy = ''
)

&"$PSScriptRoot\..\..\common\GlobalVariables.ps1"
# dot source common functions into script scope
. "$PSScriptRoot\..\..\common\GlobalFunctions.ps1"

$validationModule = "$global:KubernetesPath\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
$baseImageModule = "$global:KubernetesPath\smallsetup\baseimage\baseimage.module.psm1"
$linuxNodeModule = "$global:KubernetesPath\smallsetup\linuxnode\linuxnode.module.psm1"
$linuxNodeUbuntuModule = "$PSScriptRoot\ubuntu.module.psm1"
Import-Module $validationModule, $baseImageModule, $linuxNodeModule, $linuxNodeUbuntuModule

$remoteUser = "$UserName@$IpAddress"
$remoteUserName = "$UserName"
$remoteUserPwd = $UserPwd

# let's check if the connection to the remote computer is possible
Write-Log "Checking if an SSH login into remote computer '$IpAddress' with user '$remoteUser' is possible"
Wait-ForSshPossible -RemoteUser "$remoteUser" -RemotePwd "$remoteUserPwd" -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'
$newUserName = $global:RemoteUserName_Master
$newUserPwd = $global:VMPwd
New-User -UserName $remoteUserName -UserPwd $remoteUserPwd -IpAddress $IpAddress -NewUserName $newUserName -NewUserPwd $newUserPwd

New-KubernetesNode -UserName $newUserName -UserPwd $newUserPwd -IpAddress $IpAddress -K8sVersion $global:KubernetesVersion -Proxy $Proxy

Install-Tools -IpAddress $IpAddress -UserName $newUserName -UserPwd $newUserPwd -Proxy $Proxy

$dnsEntries = Find-DnsIpAddress
$prefixLength = $global:IP_CIDR.Substring($global:IP_CIDR.IndexOf('/') + 1)
Add-LocalIPAddress -UserName $newUserName -UserPwd $newUserPwd -IPAddress $IpAddress -LocalIpAddress $global:IP_NextHop -PrefixLength $prefixLength
Add-RemoteIPAddress -UserName $newUserName -UserPwd $newUserPwd -IPAddress $IpAddress -RemoteIpAddress $global:IP_Master -PrefixLength $prefixLength -RemoteIpAddressGateway $global:IP_NextHop -DnsEntries $dnsEntries -NetworkInterfaceName $global:ControlPlaneNodeNetworkInterfaceName

Wait-ForSSHConnectionToLinuxVMViaPwd

Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode -IpAddress $IpAddress -UserName $newUserName -UserPwd $newUserPwd -DnsEntries $dnsEntries

$masterNodeParams = @{
    IpAddress                     = $IpAddress
    UserName                      = $newUserName
    UserPwd                       = $newUserPwd
    K8sVersion                    = $global:KubernetesVersion
    ClusterCIDR                   = $global:ClusterCIDR
    ClusterCIDR_Services          = $global:ClusterCIDR_Services
    KubeDnsServiceIP              = $global:KubeDnsServiceIP
    IP_NextHop                    = $global:IP_NextHop
    NetworkInterfaceName          = $global:ControlPlaneNodeNetworkInterfaceName
    NetworkInterfaceCni0IP_Master = $global:NetworkInterfaceCni0IP_Master
    Hook                          = {}
}
Set-UpMasterNode @masterNodeParams

Remove-SshKeyFromKnownHostsFile -IpAddress $global:IP_Master
New-SshKeyPair -PrivateKeyPath $global:LinuxVMKey
Copy-LocalPublicSshKeyToRemoteComputer -UserName $newUserName -UserPwd $newUserPwd -IpAddress $global:IP_Master -LocalPublicKeyPath "$global:LinuxVMKey.pub"

Wait-ForSSHConnectionToLinuxVMViaSshKey

Write-Log "Save the hostname of the Ubuntu computer with IP '$IpAddress'"
$hostname = ExecCmdMaster -CmdToExecute 'hostname' -NoLog
Save-ControlPlaneNodeHostname($hostname)

$rebootPendingMarkerFile = '/tmp/rebootPending'
Write-Log 'Save marker file to detect when reboot has finished'
ExecCmdMaster -CmdToExecute "echo reboot still pending | tee $rebootPendingMarkerFile"
Write-Log "Reboot the Ubuntu computer with IP '$IpAddress'"
ExecCmdMaster -CmdToExecute 'sudo reboot'
Write-Log 'Check if the reboot has been performed'
Wait-ForSshPossible -RemoteUser "$global:Remote_Master" -RemotePwd "$global:VMPwd" -SshTestCommand "cat $rebootPendingMarkerFile" -ExpectedSshTestCommandResult "cat: $rebootPendingMarkerFile`: No such file or directory"
Write-Log 'Reboot done'

Write-Log "Ubuntu computer with IP '$IpAddress' is now prepared to be used as master node"
