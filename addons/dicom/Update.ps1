# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dicomModule = "$PSScriptRoot\dicom.module.psm1"

$dicomAddonName = 'dicom'

Import-Module $addonsModule, $dicomModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'dicom' })

$bStorageAddonEnabled = Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage' })
$dicomAttributes = Get-AddonConfig -Name $dicomAddonName
if ($dicomAttributes.StorageUsage -eq 'default' -and $bStorageAddonEnabled) {
    Write-Log '\nIn order to reuse the storage addon folders please disable and the enable again the dicom addon !' -Console
}
