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
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$smbShareModule = "$PSScriptRoot\module\Smb-share.module.psm1"

Import-Module $infraModule, $smbShareModule

Initialize-Logging -ShowLogs:$ShowLogs

if ($Force -ne $true) {
    $answer = Read-Host 'WARNING: This DELETES ALL DATA of the shared SMB folder. Continue? (y/N)'
    if ($answer -ne 'y') {
        $errMsg = 'Disable storage cancelled.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeUserCancellation) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }    
}

Write-Log "Disabling addon '$addonName'.."

$err = (Disable-SmbShare).Error

if ($err) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $err.Message -Error
    exit 1
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}