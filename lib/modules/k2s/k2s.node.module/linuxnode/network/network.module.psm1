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

    Write-Log "Setting DNSProxy(3) IP address '$ipControlPlane' as main DNS server for network interface '$switchname'"
    Set-DnsClientServerAddress -InterfaceIndex $ipindex -ServerAddresses $ipControlPlane | Out-Null
    Set-DnsClient -InterfaceIndex $ipindex -ResetConnectionSpecificSuffix -RegisterThisConnectionsAddress $false | Out-Null
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
    Write-Log "Index for interface $controlPlaneSwitchName : ($ipindex1) -> metric 100"
    Set-NetIPInterface -InterfaceIndex $ipindex1 -InterfaceMetric 100
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
        Write-Log "Setting DNSProxy(4) for network interface '$switchname' with reset"
        Set-DnsClientServerAddress -InterfaceIndex $ipindex -ResetServerAddresses | Out-Null
        Set-DnsClient -InterfaceIndex $ipindex -ResetConnectionSpecificSuffix | Out-Null
    }
}

function Repair-KubeSwitch {
    $WSL = Get-ConfigWslFlag
    if ($WSL) {
        Write-Log 'Repair-KubeSwitch: Using WSL2 as hosting environment for the control plane node'
        Write-Log 'Repair-KubeSwitch: No repair for WSl setup yet !'
    }
    else {
        Write-Log 'Repair-KubeSwitch: Using Hyper-V as hosting environment for the control plane node'
        # check if switch exists
        $sw = Get-VMSwitch -Name $controlPlaneSwitchName -ErrorAction SilentlyContinue
        if ( $sw ) {
            Write-Log "Repair-KubeSwitch: KubeSwitch '$controlPlaneSwitchName' already exists, check ip to repair"
            $ipindex = Get-NetIPAddress -InterfaceAlias '*$controlPlaneSwitchName*' -AddressFamily IPv4
            if ($ipindex) {
                Write-Log "Repair-KubeSwitch: KubeSwitch '$controlPlaneSwitchName' with IP '$($ipindex.IPAddress)' already exists, nothing to repair"
            } else {
                Write-Log "Repair-KubeSwitch: KubeSwitch '$controlPlaneSwitchName' exists, but has no IP, repair it"
                Remove-KubeSwitch
                New-KubeSwitch
                Connect-KubeSwitch
                Add-DnsServer $controlPlaneSwitchName
            }
        } else {
            Write-Log "Repair-KubeSwitch: KubeSwitch '$controlPlaneSwitchName' does not exist, creating it"
            New-KubeSwitch
            Connect-KubeSwitch
            Add-DnsServer $controlPlaneSwitchName
        }
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
Connect-NetworkAdapterToVm, 
Repair-KubeSwitch