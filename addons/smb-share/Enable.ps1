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
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$smbShareModule = "$PSScriptRoot\module\Smb-share.module.psm1"
$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"

Import-Module $logModule, $cliMessagesModule, $smbShareModule

Initialize-Logging -ShowLogs:$ShowLogs

if ($Config -ne $null -and $null -ne $Config.SmbHostType) {
    Write-Log "  Using SMB host type '$($Config.SmbHostType)' from addon config." -Console
    $SmbHostType = $Config.SmbHostType
}

Write-Log "Enabling addon '$addonName' with SMB host type '$SmbHostType'.." -Console

$err = (Enable-SmbShare -SmbHostType $SmbHostType).Error

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