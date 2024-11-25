# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule, $configModule

$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
$kubeSwitchIp = Get-ConfiguredKubeSwitchIP
$controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName
$ipControlPlane = Get-ConfiguredIPControlPlane
$wslSwitchName = 'WSL'

function Get-WslSwitchName {
    return $wslSwitchName
}

function Add-DnsServer($switchname) {
    # add DNS proxy for cluster searches
    $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$switchname*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    Set-DnsClientServerAddress -InterfaceIndex $ipindex -ServerAddresses $ipControlPlane | Out-Null
    Set-DnsClient -InterfaceIndex $ipindex -ConnectionSpecificSuffix 'cluster.local' -RegisterThisConnectionsAddress $false | Out-Null
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
    Get-VM | ForEach-Object { Get-VMNetworkAdapter -VMName $_.Name } | Where-Object { $_.SwitchName -eq $controlPlaneSwitchName } | Disconnect-VMNetworkAdapter

    $sw = Get-VMSwitch -Name $controlPlaneSwitchName -ErrorAction SilentlyContinue
    if ( $sw ) {
        Remove-VMSwitch -Name $controlPlaneSwitchName -Force
    }

    Remove-NetIPAddress -IPAddress $kubeSwitchIp -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue
}

function Connect-NetworkAdapterToVm() {
    param (
        [string]$VmName = $(throw 'Argument missing: VmName'),
        [string]$SwitchName = $(throw 'Argument missing: SwitchName')
    )
    Write-Log "Connect switch '$SwitchName' to VM '$VmName'"
    # connect VM to switch
    $ad = Get-VMNetworkAdapter -VMName $VmName
    if ( !($ad) ) {
        Write-Log "Adding network adapter to VM '$VmName' ..."
        Add-VMNetworkAdapter -VMName $VmName -Name 'Network Adapter'
    }
    Connect-VMNetworkAdapter -VMName $VmName -SwitchName $SwitchName
}

function Disconnect-NetworkAdapterFromVm {
    param (
        [string]$VmName = $(throw 'Argument missing: VmName')
    )
    # Remove old switch
    Write-Log "Disconnect VM '$VmName' from network adapter"
    $networkAdapter = Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue
    if ( $networkAdapter ) {
        Disconnect-VMNetworkAdapter -VmName $VmName
    }
}

function Reset-DnsServer($switchname) {
    $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*$switchname*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
    if ($ipindex) {
        Set-DnsClientServerAddress -InterfaceIndex $ipindex -ResetServerAddresses | Out-Null
        Set-DnsClient -InterfaceIndex $ipindex -ResetConnectionSpecificSuffix | Out-Null
    }
}

Export-ModuleMember Get-ControlPlaneNodeDefaultSwitchName,
Add-DnsServer, 
New-KubeSwitch, 
Connect-KubeSwitch, 
Remove-KubeSwitch, 
Get-WslSwitchName, 
Reset-DnsServer, 
Disconnect-NetworkAdapterFromVm, 
Connect-NetworkAdapterToVm