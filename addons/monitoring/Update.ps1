# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$monitoringModule = "$PSScriptRoot\monitoring.module.psm1"

Import-Module $addonsModule, $monitoringModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'monitoring' })