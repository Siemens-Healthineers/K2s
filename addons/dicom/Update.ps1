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

$EnancedSecurityEnabled = Test-LinkerdServiceAvailability
if ($EnancedSecurityEnabled) {
    Write-Log "Updating dicom addon to be part of service mesh"  
    $annotations1 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\",\"config.linkerd.io/opaque-ports\":\"5432\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'dicom', '-n', 'dicom', '-p', $annotations1).Output | Write-Log
    $annotations2 = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"linkerd.io/inject\":\"enabled\"}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'postgres', '-n', 'dicom', '-p', $annotations2).Output | Write-Log
} else {
    Write-Log "Updating dicom addon to not be part of service mesh"
    $annotations = '{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"config.linkerd.io/opaque-ports\":null,\"linkerd.io/inject\":null}}}}}'
    (Invoke-Kubectl -Params 'patch', 'deployment', 'dicom', '-n', 'dicom', '-p', $annotations).Output | Write-Log
    (Invoke-Kubectl -Params 'patch', 'deployment', 'postgres', '-n', 'dicom', '-p', $annotations).Output | Write-Log
}
(Invoke-Kubectl -Params 'rollout', 'status', 'deployment', '-n', 'dicom', '--timeout', '60s').Output | Write-Log


