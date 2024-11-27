# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$viewerModule = "$PSScriptRoot\viewer.module.psm1"

Import-Module $addonsModule, $viewerModule

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'viewer' })