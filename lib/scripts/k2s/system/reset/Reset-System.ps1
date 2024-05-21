# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Resets system to the state before K2s installation

.DESCRIPTION
Resets system to the state before K2s installation

#>

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
Import-Module $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Output "Reset system"
& $PSScriptRoot\..\..\uninstall\Uninstall.ps1 | Out-Null
Write-Output "System reset successful!"