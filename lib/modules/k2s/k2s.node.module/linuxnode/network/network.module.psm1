# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule, $configModule

$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
$kubeSwitchIp = Get-ConfiguredKubeSwitchIP
$controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName
$ipControlPlane = Get-ConfiguredIPControlPlane
$controlePlaneNetworkInterfaceName = 'eth0'
$workerNodeNetworkInterfaceName = 'eth0'
$wslSwitchName = 'WSL'

function Get-ControlPlaneNodeNetworkInterfaceName {
    return $controlePlaneNetworkInterfaceName
}

function Get-WorkerNodeNetworkInterfaceName {
    return $workerNodeNetworkInterfaceName
}

function Get-WslSwitchName {
    return $wslSwitchName
}

function Add-DnsServer($switchname) {
    # add DNS proxy for cluster searches
    $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$switchname*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    Set-DnsClientServerAddress -InterfaceIndex $ipindex -ServerAddresses $ipControlPlane | Out-Null
    Set-DnsClient -InterfaceIndex $ipindex -ConnectionSpecificSuffix 'cluster.local' | Out-Null
}

<#
.SYNOPSIS
    Create switch to KubeMaster VM.
.DESCRIPTION
    Create switch to KubeMaster VM.
#>
function New-KubeSwitch() {
    # create new switch for debian VM
    Write-Log "Create internal switch $controlPlaneSwitchName"
    New-VMSwitch -Name $controlPlaneSwitchName -SwitchType Internal -MinimumBandwidthMode Weight | Out-Null
    New-NetIPAddress -IPAddress $kubeSwitchIp -PrefixLength 24 -InterfaceAlias "vEthernet ($controlPlaneSwitchName)" | Out-Null
    # set connection to private because of firewall rules
    Set-NetConnectionProfile -InterfaceAlias "vEthernet ($controlPlaneSwitchName)" -NetworkCategory Private -ErrorAction SilentlyContinue
    # enable forwarding
    netsh int ipv4 set int "vEthernet ($controlPlaneSwitchName)" forwarding=enabled | Out-Null
    # change index in order to have the Ethernet card as first card (also for much better DNS queries)
    $ipindex1 = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*$controlPlaneSwitchName*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
    Write-Log "Index for interface $controlPlaneSwitchName : ($ipindex1) -> metric 25"
    Set-NetIPInterface -InterfaceIndex $ipindex1 -InterfaceMetric 25
}

<#
.SYNOPSIS
    Connect switch to control plane VM.
.DESCRIPTION
    Connect switch to control plane VM.
#>
function Connect-KubeSwitch() {
    Write-Log 'Connect KubeSwitch to VM'
    # connect VM to switch
    $ad = Get-VMNetworkAdapter -VMName $controlPlaneVMHostName
    if ( !($ad) ) {
        Write-Log "Adding network adapter to VM '$controlPlaneVMHostName' ..."
        Add-VMNetworkAdapter -VMName $controlPlaneVMHostName -Name 'Network Adapter'
    }
    Connect-VMNetworkAdapter -VMName $controlPlaneVMHostName -SwitchName $controlPlaneSwitchName
}

<#
.SYNOPSIS
    Remove switch to control plane VM.
.DESCRIPTION
    Remove switch to control plane VM.
#>
function Remove-KubeSwitch() {
    # Remove old switch
    Write-Log 'Remove KubeSwitch'
    $vm = Get-VMNetworkAdapter -VMName $controlPlaneVMHostName -ErrorAction SilentlyContinue
    if ( $vm ) {
        $vm | Disconnect-VMNetworkAdapter
    }
    $sw = Get-VMSwitch -Name $controlPlaneSwitchName -ErrorAction SilentlyContinue
    if ( $sw ) {
        Remove-VMSwitch -Name $controlPlaneSwitchName -Force
    }

    Remove-NetIPAddress -IPAddress $kubeSwitchIp -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Create switch to Control Plane VM.
.DESCRIPTION
    Create switch to Control Plane VM.
#>
function New-DefaultControlPlaneSwitch {
    # create new switch for debian VM
    Write-Log "Create internal switch $controlPlaneSwitchName"
    New-VMSwitch -Name $controlPlaneSwitchName -SwitchType Internal -MinimumBandwidthMode Weight | Out-Null
    New-NetIPAddress -IPAddress $kubeSwitchIp -PrefixLength 24 -InterfaceAlias "vEthernet ($controlPlaneSwitchName)" | Out-Null
    # set connection to private because of firewall rules
    Set-NetConnectionProfile -InterfaceAlias "vEthernet ($controlPlaneSwitchName)" -NetworkCategory Private -ErrorAction SilentlyContinue
    # enable forwarding
    netsh int ipv4 set int "vEthernet ($controlPlaneSwitchName)" forwarding=enabled | Out-Null
    # change index in order to have the Ethernet card as first card (also for much better DNS queries)
    $ipindex1 = Get-NetIPInterface | ? InterfaceAlias -Like "*$controlPlaneSwitchName*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    Write-Log "Index for interface $controlPlaneSwitchName : ($ipindex1) -> metric 25"
    Set-NetIPInterface -InterfaceIndex $ipindex1 -InterfaceMetric 25
}

function Reset-DnsServer($switchname) {
    $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$switchname*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    if ($ipindex) {
        Set-DnsClientServerAddress -InterfaceIndex $ipindex -ResetServerAddresses | Out-Null
        Set-DnsClient -InterfaceIndex $ipindex -ResetConnectionSpecificSuffix | Out-Null
    }
}

Export-ModuleMember New-DefaultControlPlaneSwitch,
Get-ControlPlaneNodeDefaultSwitchName,
Get-ControlPlaneNodeNetworkInterfaceName,
Get-WorkerNodeNetworkInterfaceName,
Add-DnsServer, New-KubeSwitch, Connect-KubeSwitch, Remove-KubeSwitch, Get-WslSwitchName, Reset-DnsServer