# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ImgDir,

    [Parameter(Mandatory = $true)]
    [string]$WinEdition,

    [Parameter(Mandatory = $true)]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Server2019Datacenter', 'Server2019Standard', 'Server2016Datacenter', 'Server2016Standard', 'Windows10Enterprise', 'Windows10Professional', 'Windows81Professional')]
    [string]$Version,

    [Parameter(Mandatory = $true)]
    [int64]$VMMemoryInBytes,

    [switch]$EnableDynamicMemory,

    [int64]$VMProcessorCount = 2,

    [Parameter(Mandatory = $true)]
    [uint64]$VMVHDXSizeInBytes,

    [Parameter(Mandatory = $true)]
    [string]$AdminPwd,

    [string]$VMMacAddress,

    [string]$AddVirtioDrivers,

    [string]$VMSwitchName = 'VMSwitch',

    [string]$Locale = 'en-US',

    [ValidateRange(1, 2)]
    [int16]$Generation = 2
)

$ErrorActionPreference = 'Stop'

# load global settings
&$PSScriptRoot\..\GlobalVariables.ps1

Import-Module "$PSScriptRoot\..\..\ps-modules\log\log.module.psm1"

# Requires administrative privileges for below operations (Get-CimInstance)
#Get Hyper-V Service Settings
$hyperVMSettings = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData

$vhdxPath = Join-Path $hyperVMSettings.DefaultVirtualHardDiskPath "$Name.vhdx"

# Create VHDX from ISO image
$disklayout = 'UEFI'
if ( $Generation -eq 1 ) {
    $disklayout = 'BIOS'
    $vhdxPath = Join-Path $hyperVMSettings.DefaultVirtualHardDiskPath "$Name.vhd"
}

Write-Log "Using generation $Generation with disk layout $disklayout"
&"$global:KubernetesPath\smallsetup\common\vmtools\New-VHDXFromWinImage.ps1" `
    -ImgDir $ImgDir `
    -WinEdition $WinEdition `
    -ComputerName $Name `
    -VMVHDXSizeInBytes $VMVHDXSizeInBytes `
    -VHDXPath $vhdxPath `
    -AdminPwd $AdminPwd `
    -Version $Version `
    -Locale $Locale `
    -AddVirtioDrivers $AddVirtioDrivers `
    -DiskLayout $disklayout

Write-Log "Creating VM in Hyper-V: $Name from VHDPath: $vhdxPath and attaching to switch: $VMSwitchName"
$virtualMachine = New-VM -Name $Name -Generation $Generation -MemoryStartupBytes $VMMemoryInBytes -VHDPath $vhdxPath -SwitchName $VMSwitchName

$virtualMachine | Set-VMProcessor -Count $VMProcessorCount
$virtualMachine | Set-VMMemory -DynamicMemoryEnabled:$EnableDynamicMemory.IsPresent

$virtualMachine | Get-VMIntegrationService | Where-Object { $_ -is [Microsoft.HyperV.PowerShell.GuestServiceInterfaceComponent] } | Enable-VMIntegrationService -Passthru

if ($VMMacAddress) {
    $virtualMachine | Set-VMNetworkAdapter -StaticMacAddress ($VMMacAddress -replace ':', '')
}

$command = Get-Command Set-VM
if ($command.Parameters.AutomaticCheckpointsEnabled) {
    # We need to disable automatic checkpoints
    $virtualMachine | Set-VM -AutomaticCheckpointsEnabled $false
}

#Start VM and wait for heartbeat
$virtualMachine | Start-VM

Write-Log "Waiting for VM Heartbeat..."
Wait-VM -Name $Name -For Heartbeat

Write-Log "All done in Creation of VM from Windows Image!"
