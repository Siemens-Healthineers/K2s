# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with preparing a Windows VM to setup K8s networking

.DESCRIPTION

.EXAMPLE
PS> .\SetupNetworking.ps1 -MinSetup $true -HostGW $true

#>

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Min setup as host only: true, false for normal node in medium/high kubernetes cluster')]
    [bool] $MinSetup,
    [parameter(Mandatory = $true, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for vxlan')]
    [bool] $HostGW
)

# load global settings
&$PSScriptRoot\common\GlobalVariables.ps1

# import global functions
. $PSScriptRoot\common\GlobalFunctions.ps1

$ErrorActionPreference = 'Stop'

$r = Get-NetFirewallRule -DisplayName 'kubelet' 2> $null;
if ( $r ) {
    Remove-NetFirewallRule -DisplayName 'kubelet'
}

if ($MinSetup) {
    $r = Get-NetFirewallRule -DisplayName $global:LegacyVMFirewallRuleName -ErrorAction SilentlyContinue
    if ( $r ) {
        Remove-NetFirewallRule -DisplayName $global:LegacyVMFirewallRuleName -ErrorAction SilentlyContinue
    }

    $r = Get-NetFirewallRule -DisplayName $global:KubeVMFirewallRuleName -ErrorAction SilentlyContinue
    if ( $r ) {
        Remove-NetFirewallRule -DisplayName $global:KubeVMFirewallRuleName -ErrorAction SilentlyContinue
    }
    New-NetFirewallRule -DisplayName $global:KubeVMFirewallRuleName -Group "k2s" -Description 'Allow inbound traffic from the Linux VM on ports above 8000' -RemoteAddress $global:IP_Master -RemotePort '8000-32000' -Enabled True -Direction Inbound -Protocol TCP -Action Allow | Out-Null
}

$adapterName = Get-L2BridgeNIC
Write-Log "Using network adapter '$adapterName'"
$ipaddresses = @(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias $adapterName)
if (!$ipaddresses) {
    throw 'No IP address found which can be used for setting up Small K8s Setup !'
}
$ipaddress = $ipaddresses[0] | Select -ExpandProperty IPAddress
Write-Log "Using local IP $ipaddress for setup of CNI"

$NetworkAddress = "  ""Network"": ""$global:ClusterCIDR_Host"","

$targetFilePath = "$($global:SystemDriveLetter):\etc\kube-flannel\net-conf.json"
if ( $HostGW) {
    Write-Log "Writing $targetFilePath for HostGW mode"
    Copy-Item -force "$global:KubernetesPath\cfg\cni\net-conf.json.template" $targetFilePath

    $lineNetworkAddress = Get-Content $targetFilePath | Select-String NETWORK.ADDRESS | Select-Object -ExpandProperty Line
    if ( $lineNetworkAddress ) {
        $content = Get-Content $targetFilePath
        $content | ForEach-Object { $_ -replace $lineNetworkAddress, $NetworkAddress } | Set-Content $targetFilePath
    }
}
else {
    Write-Log "Writing $targetFilePath for VXLAN mode"
    Copy-Item -force "$global:KubernetesPath\cfg\cni\net-conf-vxlan.json.template" $targetFilePath

    $lineNetworkAddress = Get-Content $targetFilePath | Select-String NETWORK.ADDRESS | Select-Object -ExpandProperty Line
    if ( $lineNetworkAddress ) {
        $content = Get-Content $targetFilePath
        $content | ForEach-Object { $_ -replace $lineNetworkAddress, $NetworkAddress } | Set-Content $targetFilePath
    }
}

$svc = $(Get-Service -Name flanneld -ErrorAction SilentlyContinue).Status
if ($svc) {
    # startup params for flanneld must be adapted
    &$global:NssmInstallDirectory\nssm set flanneld AppParameters "--kubeconfig-file=\`"$global:KubernetesPath\config\`" --iface=$ipaddress --ip-masq=1 --kube-subnet-mgr=1" | Out-Null
}

Copy-Item -force "$global:KubernetesPath\smallsetup\kubeadm-flags.env" $global:KubeletConfigDir

if ($MinSetup) {
    # save the current IP address to make a later check possible
    Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_HostGw -Value $HostGW
    Write-Log "Saved IP address and hostGW to $global:SetupJsonFile"
}

