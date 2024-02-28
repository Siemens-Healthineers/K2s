# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Gathers status information.

.DESCRIPTION
Gathers addon status information and outputs the data either as structured, compressed data or as is.

.PARAMETER Name
Name of the addon

.PARAMETER Directory
Directory path of the addon

.PARAMETER EncodeStructuredOutput
If set to true, will encode and send result as structured data to the CLI.

.PARAMETER MessageType
Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true

.EXAMPLE
# Outputs the addon status to default output stream as is
PS> .\Get-Status.ps1 -Name dashboard -Directory c:\k\addons\dashboard

.EXAMPLE
# Sends the addon status as structured, compressed data with a message type label to default output stream
PS> .\Get-Status.ps1 -Name dashboard -Directory c:\k\addons\dashboard -EncodeStructuredOutput -MessageType my-status
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Name of the addon')]
    [string] $Name = $(throw 'Name not specified'),
    [parameter(Mandatory = $false, HelpMessage = 'Directory path of the addon')]
    [string] $Directory = $(throw 'Directory not specified'),
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$cliMessagesModule = "$PSScriptRoot/../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"
$addonsModule = "$PSScriptRoot\addons.module.psm1"
$logModule = "$PSScriptRoot/../smallsetup/ps-modules/log/log.module.psm1"

Import-Module $addonsModule, $logModule, $cliMessagesModule

Initialize-Logging 

$script = $MyInvocation.MyCommand.Name

Write-Log "[$script] started with EncodeStructuredOutput='$EncodeStructuredOutput' and MessageType='$MessageType'"

try {
    $status = Get-AddonStatus -Name $Name -Directory $Directory

    Write-Log "[$script] Status determined: $status"

    if ($EncodeStructuredOutput -eq $true) {
        Write-Log "[$script] Sending status to CLI.."

        Send-ToCli -MessageType $MessageType -Message $status
    }
    else {
        $status
    }

    Write-Log "[$script] finished"
}
catch {
    Write-Log "[$script] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}