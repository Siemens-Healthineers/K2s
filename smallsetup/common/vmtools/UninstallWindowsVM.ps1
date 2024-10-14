# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Remove windows VM  

.DESCRIPTION
This script assists in the following actions:
- Removes windows VM

.EXAMPLE
PS> .\UninstallWindowsVM.ps1 -Name TestVM
#>


Param(
    [parameter(Mandatory = $true, HelpMessage = 'Windows VM Name to use')]
    [string] $Name
)

$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

# load global settings
&$PSScriptRoot\..\GlobalVariables.ps1 

# remove old switch
$svm = Get-VMNetworkAdapter -VMName $Name -ErrorAction SilentlyContinue
if ( ($svm) ) {
    Write-Output "VM with name: $Name found"

    # Disconect adapter from switch
    Write-Output "Disconnect current network adapter from VM: $Name"
    Disconnect-VMNetworkAdapter -VMName $Name
}

# stop VM and remove VM
if ($(Get-VM | Where-Object Name -eq $Name | Measure-Object).Count -eq 1 ) {
    Write-Output ("Stopping VM: " + $Name)
    Stop-VM -Name $Name -TurnOff -WarningAction SilentlyContinue
}
if ($(Get-VM | Where-Object Name -eq $Name | Measure-Object).Count -eq 1 ) {
    # not needed, done in StopK8s.ps1:  Stop-VM -Name $global:VMName -Force -WarningAction SilentlyContinue
    Write-Output ("Remove VM: " + $Name)
    Remove-VM -Name $Name -Force
}
else {
    Write-Output ("VM '" + $Name + "' not found, nothing to do")
}

# Get default VHD path (requires administrative privileges)
$vmms = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementService
$vmmsSettings = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
$vhdxPath = Join-Path $vmmsSettings.DefaultVirtualHardDiskPath "$Name.vhdx"
Write-Output ("Remove vhdx from: $vhdxPath")
if (Test-Path $vhdxPath) {
    Remove-Item -Path $vhdxPath -Force -ErrorAction SilentlyContinue
}
$vhdPath = Join-Path $vmmsSettings.DefaultVirtualHardDiskPath "$Name.vhd"
Write-Output ("Remove vhd from: $vhdPath")
if (Test-Path $vhdPath) {
    Remove-Item -Path $vhdPath -Force -ErrorAction SilentlyContinue
}

Write-Output ("VM $Name removed !")