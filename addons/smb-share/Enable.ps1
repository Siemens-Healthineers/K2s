# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables the SMB share addon.
.DESCRIPTION
Enables the SMB share addon.
.PARAMETER ShowLogs
If log output shall be streamed also to CLI output.
.PARAMETER SmbHostType
Controls which host will expose the ContextFolder SMB share. Default: "windows".
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Controls which host will expose the ContextFolder SMB share. Default: "windows".')]
    [ValidateSet('windows', 'linux')]
    [string]$SmbHostType = 'windows',
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
Import-Module "$PSScriptRoot\module\Smb-share.module.psm1"

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

if ($Config -ne $null -and $null -ne $Config.SmbHostType) {
    Write-Log "  Using SMB host type '$($Config.SmbHostType)' from addon config." -Console
    $SmbHostType = $Config.SmbHostType
}

Write-Log "Enabling addon '$addonName' with SMB host type '$SmbHostType'.." -Console

Enable-SmbShare -SmbHostType $SmbHostType