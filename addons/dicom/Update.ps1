# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dicomModule = "$PSScriptRoot\dicom.module.psm1"
Import-Module $addonsModule, $dicomModule

$addonName = Get-AddonNameFromFolderPath -BaseFolderPath $PSScriptRoot

Update-IngressForAddon -Addon ([pscustomobject] @{Name = $addonName })

$bStorageAddonEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage' })
$dicomAttributes = Get-AddonConfig -Name $addonName
Write-Log "Storage usage: $($dicomAttributes.StorageUsage) and storage addon enabled: $bStorageAddonEnabled" 
if ($dicomAttributes.StorageUsage -ne 'storage' -and $bStorageAddonEnabled) {
    Write-Log ' ' -Console
    Write-Log '!!!! DICOM addon is enabled. Please disable and enable DICOM addon again for a change in storage !!!!' -Console
    Write-Log ' ' -Console
}

