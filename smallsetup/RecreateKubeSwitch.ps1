# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

# load global settings
&$PSScriptRoot\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\common\GlobalFunctions.ps1

Write-Output "Recreate VM switch: $global:SwitchName and reassign to VMs"

# get all VMs
$vms = Get-VM
[Microsoft.HyperV.PowerShell.VirtualMachine[]]$vms_disconnected = $null
foreach ($vm in $vms) {
    $vmname = $vm.Name
    Write-Output "VM: $vmname found"

    $svm = Get-VMNetworkAdapter -VMName $vm.Name
    if ( !($svm) ) {
        Write-Output "VM adapter not found for $vmname not found, continue with next ..."
        continue
    }
    $swname = $svm.SwitchName
    Write-Output "Switch: $swname found for VM: $vmname"

    # try to remove switch
    if ( $swname.Length -gt 0 -And $swname -eq $global:SwitchName ) {
        Write-Output "Try to remove switch: $swname from VM: $vmname"
    }
    else {
        continue;
    }

    # keep in list
    $vms_disconnected = $vms_disconnected + $vm
}
# dump disconnected vms
Write-Output "All VMs: $vms_disconnected disconnected from network"

# remove switch and NAT
Write-Output "Remove NAT $global:NetNatName"
$nat = Get-NetNat -Name $global:NetNatName -ErrorAction SilentlyContinue
$IsNAT = $false
if( $nat ) {
    $IsNAT = $true
    Remove-NetNat -Name $global:NetNatName -Confirm:$False -ErrorAction SilentlyContinue
}

# remove the KubeSwitch
Remove-KubeSwitch

# create new switch and NAT
New-KubeSwitch

# add DNS proxy for cluster searches
Add-DnsServer $global:SwitchName

# recreate NAT if it was there
if( $IsNAT ) {
    Write-Output "NAT create: $global:NetNatName"
    New-NetNat -Name $global:NetNatName -InternalIPInterfaceAddressPrefix $global:IP_CIDR | Out-Null
}

# attach new switch to VMs
Write-Output "Attach already connect VMs"
foreach ($vmd in $vms_disconnected) {
    $vmdname = $vmd.Name
    Write-Output "VM: $vmdname for reconnect network"
    # connect VM to switch
    Write-Output "Connect switch: $global:SwitchName to VM: $vmdname"
    $ad = Get-VMNetworkAdapter -VMName $vmdname
    if ( !($ad) ) {
        Write-Output "Adding network adapter to VM '$vmdname' ..."
        Add-VMNetworkAdapter -VMName $vmdname -Name 'Network Adapter'
    }
    Connect-VMNetworkAdapter -VMName $vmdname -SwitchName $global:SwitchName
}

# connect kubemaster if found
Write-Output "Search for Master VM"
$vmMaster = Get-VM -Name 'KubeMaster'
if ( ($vmMaster) ) {
    $vmname = $vmMaster.Name
    Write-Output "Found VM Master: $vmname"
    $svm = Get-VMNetworkAdapter -VMName $vmname
    if ( !($svm) ) {
        # connect VM to switch
        Write-Output "Recreate adapter and connect switch: $global:SwitchName to VM: $vmname"
        Add-VMNetworkAdapter -VMName $vmname -Name $global:ControlPlaneNodeNetworkInterfaceName
        Connect-VMNetworkAdapter -VMName $vmname -SwitchName $global:SwitchName
    }
    else {
        Write-Output "Connect switch: $global:SwitchName to VM: $vmname"
        Connect-VMNetworkAdapter -VMName $vmname -SwitchName $global:SwitchName
    }
}

Write-Output "RecreateVMSwitch: $global:SwitchName finished"