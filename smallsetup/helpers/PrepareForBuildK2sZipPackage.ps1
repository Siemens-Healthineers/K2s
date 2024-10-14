# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$ErrorActionPreference = 'Stop'
if ($Trace) {
    Set-PSDebug -Trace 1
}


# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

Import-Module "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "Clean up all related to the building and provisioning of the base image." -Console
& "$global:KubernetesPath\smallsetup\baseimage\Cleaner.ps1"

