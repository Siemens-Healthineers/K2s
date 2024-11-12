# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Opens a ssh connection with WinNode VM. 

.DESCRIPTION
Opens a ssh connection with WinNode VM. It can also remotely execute commands in the WinNode VM.

.PARAMETER Command
(Optional) Command to be executed in the WinNode VM

.EXAMPLE
# Opens a ssh connection with WinNode
PS> .\sshm.ps1 

.EXAMPLE
# Runs a command in WinNode VM
PS> .\sshw.ps1 -Command "echo hello"
#>

Param(
    [Parameter(Mandatory = $false, HelpMessage = 'Command to be executed in the Kubemaster VM')]
    [string]$Command = '',
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
Import-Module $clusterModule, $infraModule, $nodeModule

Initialize-Logging

$remoteUser = Get-DefaultWinVMName
$key = Get-DefaultWinVMKey

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }
    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'MultiVMK8s' -or $setupInfo.LinuxOnly ) {
    $errMsg = 'There is no multi-vm setup with worker node installed.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $systemError -Error
    exit 1
}

if (Test-Path $key -PathType Leaf) {
    if ([string]::IsNullOrWhitespace($Command)) {
        ssh.exe -o StrictHostKeyChecking=no -i $key $remoteUser "$(($MyInvocation).UnboundArguments)"
    }
    else {
        ssh.exe -n -o StrictHostKeyChecking=no -i $key $remoteUser "$Command" | ForEach-Object { Write-Log $_ -Console -Ssh }
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}