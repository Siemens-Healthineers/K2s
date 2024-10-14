# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&"$PSScriptRoot\..\common\GlobalVariables.ps1"

$baseImageModule = "$PSScriptRoot\BaseImage.module.psm1"
Import-Module $baseImageModule
. "$PSScriptRoot\CommonVariables.ps1"

$vmName = $VmProvisioningVmName

$vm = Get-VM | Where-Object Name -Like $vmName

Write-Log "Ensure VM $vmName is stopped" -Console
if ($null -ne $vm) {
    Stop-VirtualMachineForBaseImageProvisioning -Name $vmName
}

$inProvisioningImagePath = "$global:ProvisioningTargetDirectory\$RawBaseImageInProvisioningForKubemasterImageName"

Write-Log "Detach the image from Hyper-V" -Console
Remove-VirtualMachineForBaseImageProvisioning -VmName $vmName -VhdxFilePath $inProvisioningImagePath
Write-Log "Remove the network for provisioning the image" -Console
Remove-NetworkForProvisioning -NatName $VmProvisioningNatName -SwitchName $VmProvisioningSwitchName

if (Test-Path $global:ProvisioningTargetDirectory) {
    Write-Log "Deleting folder '$global:ProvisioningTargetDirectory'" -Console
    Remove-Item -Path $global:ProvisioningTargetDirectory -Recurse -Force
}

if (Test-Path $global:DownloadsDirectory) {
    Write-Log "Deleting folder '$global:DownloadsDirectory'" -Console
    Remove-Item -Path $global:DownloadsDirectory -Recurse -Force
}




