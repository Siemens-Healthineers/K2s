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
    [switch] $Force = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"
$smbShareModule = "$PSScriptRoot\module\Smb-share.module.psm1"

Import-Module $logModule, $cliMessagesModule, $smbShareModule

Initialize-Logging -ShowLogs:$ShowLogs

if ($Force -ne $true) {
    $answer = Read-Host 'WARNING: This DELETES ALL DATA of the shared SMB folder. Continue? (y/N)'
    if ($answer -ne 'y') {
        Write-Log 'Disabling cancelled.' -Console
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $null }
        }
        return
    }    
}

Write-Log "Disabling addon '$addonName'.."

$result = Disable-SmbShare

if ($result.Error) {
    if ($result.Error -eq 'already-disabled') {
        if ($EncodeStructuredOutput -eq $true) {
            Send-ToCli -MessageType $MessageType -Message @{Error = $null }
        }
        return
    }

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $result.Error }
        return
    }

    Write-Log $result.Error -Error
    exit 1
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}