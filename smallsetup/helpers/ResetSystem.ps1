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
&"$global:KubernetesPath\smallsetup\UninstallK8s.ps1" | Out-Null
&"$global:KubernetesPath\smallsetup\multivm\Uninstall_MultiVMK8sSetup.ps1" | Out-Null
&"$global:KubernetesPath\smallsetup\common\UninstallBuildOnlySetup.ps1" | Out-Null
Write-Output 'System reset successful!'
