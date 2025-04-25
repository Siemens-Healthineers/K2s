# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Resets system to the state before K2s installation

.DESCRIPTION
Resets system to the state before K2s installation

#>
Param(

)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1


Write-Output 'Reset system'
&"$global:KubernetesPath\lib\scripts\k2s\uninstall\uninstall.ps1" | Out-Null
&"$global:KubernetesPath\lib\scripts\linuxonly\uninstall\uninstall.ps1" | Out-Null
&"$global:KubernetesPath\lib\scripts\buildonly\uninstall\uninstall.ps1" | Out-Null
Write-Output 'System reset successful!'
