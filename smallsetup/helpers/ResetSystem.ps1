# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Resets system to the state before k2s installation

.DESCRIPTION
Resets system to the state before k2s installation

#>
Param(

)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1


Write-Output "Resetting system"
&"$global:KubernetesPath\smallsetup\UninstallK8s.ps1" | Out-Null
&"$global:KubernetesPath\smallsetup\multivm\Uninstall_MultiVMK8sSetup.ps1" | Out-Null
&"$global:KubernetesPath\smallsetup\common\UninstallBuildOnlySetup.ps1" | Out-Null
Write-Output "System reseted successfully!"
