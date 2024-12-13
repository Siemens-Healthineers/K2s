# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$dicomModule = "$PSScriptRoot\dicom.module.psm1"

Import-Module $addonsModule, $dicomModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'dicom' })