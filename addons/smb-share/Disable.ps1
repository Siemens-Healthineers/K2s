# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables the SMB share addon.
.DESCRIPTION
Disables the SMB share addon.
.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Skips user confirmation if set to true')]
    [switch] $Force = $false
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

if ($Force -ne $true) {
    $answer = Read-Host 'WARNING: This DELETES ALL DATA of the shared SMB folder. Continue? (y/N)'
    if ($answer -ne 'y') {
        Write-Log 'Disabling cancelled.' -Console
        return
    }    
}

Import-Module "$PSScriptRoot\module\Smb-share.module.psm1"

Write-Log "Disabling addon '$addonName'.."

Disable-SmbShare
