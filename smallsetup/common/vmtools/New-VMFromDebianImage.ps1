# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$VhdxPath,

    [uint64]$VHDXSizeBytes,

    [int64]$MemoryStartupBytes = 1GB,

    [int64]$ProcessorCount = 2,

    [string]$SwitchName = 'SWITCH',

    [switch]$UseGeneration1
)

$ErrorActionPreference = 'Stop'

# load global settings
&$PSScriptRoot\..\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\GlobalFunctions.ps1

Import-Module "$PSScriptRoot\..\..\ps-modules\log\log.module.psm1"

if ($VHDXSizeBytes) {
    Resize-VHD -Path $VhdxPath -SizeBytes $VHDXSizeBytes
}

# Create VM
$generation = 2
if ($UseGeneration1) {
    $generation = 1
}
Write-Log "Creating VM: $VMName"
Write-Log "             - Vhdx: $VhdxPath"
Write-Log "             - MemoryStartupBytes: $MemoryStartupBytes"
Write-Log "             - SwitchName: $SwitchName"
Write-Log "             - VM Generation: $generation"
$vm = New-VM -Name $VMName -Generation $generation -MemoryStartupBytes $MemoryStartupBytes -VHDPath $VhdxPath -SwitchName $SwitchName
$vm | Set-VMProcessor -Count $ProcessorCount

<#
Avoid using VM Service name as it is not culture neutral, use the ID instead.
Name: Guest Service Interface; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\6C09BB55-D683-4DA0-8931-C9BF705F6480
Name: Heartbeat; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47
Name: Key-Value Pair Exchange; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\2A34B1C2-FD73-4043-8A5B-DD2159BC743F
Name: Shutdown; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\9F8233AC-BE49-4C79-8EE3-E7E1985B2077
Name: Time Synchronization; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\2497F4DE-E9FA-4204-80E4-4B75C46419C0
Name: VSS; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\5CED1297-4598-4915-A5FC-AD21BB4D02A4
#>

$GuestServiceInterfaceID = '6C09BB55-D683-4DA0-8931-C9BF705F6480'
Get-VMIntegrationService -VM $vm |  Where-Object {$_.Id -match $GuestServiceInterfaceID} | Enable-VMIntegrationService
$vm | Set-VMMemory -DynamicMemoryEnabled $false

# Sets Secure Boot Template.
#   Set-VMFirmware -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' doesn't work anymore (!?).
if ( $generation -eq 2 ) {
    $vm | Set-VMFirmware -SecureBootTemplateId ([guid]'272e7447-90a4-4563-a4b9-8e4ab00526ce')
}

# Enable nested virtualization (if processor supports it)
$virt = Get-CimInstance Win32_Processor | Where-Object { ($_.Name -like 'Intel*') }
if ( $virt ) {
    Write-Log "Enable nested virtualization"
    $vm | Set-VMProcessor -ExposeVirtualizationExtensions $true
}

# Disable Automatic Checkpoints. Check if command is available since it doesn't exist in Server 2016.
$command = Get-Command Set-VM
if ($command.Parameters.AutomaticCheckpointsEnabled) {
    $vm | Set-VM -AutomaticCheckpointsEnabled $false
}

Write-Log "Starting VM $VMName"
$i = 0;
$RetryCount = 3;
while ($true) {
    $i++
    if ($i -gt $RetryCount) {
        throw "           Failure starting $VMName VM"
    }
    Write-Log "VM Start Handling loop (iteration #$i):"
    Start-VM -Name $VMName -ErrorAction Continue
    if ($?) {
        Write-Log "           Start success $VMName VM"
        break;
    }
    Start-Sleep -s 5
}

# Wait for VM
Write-Log "Waiting for VM to send heartbeat..."
Wait-VM -Name $VMName -For Heartbeat

Write-Log "VM started ok"