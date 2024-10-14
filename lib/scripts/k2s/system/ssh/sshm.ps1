# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Opens a ssh connection with Kubemaster VM. 

.DESCRIPTION
Opens a ssh connection with Kubemaster VM. It can also remotely execute commands in the Kubemaster VM.

.PARAMETER Command
(Optional) Command to be executed in the Kubemaster VM

.EXAMPLE
# Opens a ssh connection with Kubemaster
PS> .\sshm.ps1 

.EXAMPLE
# Runs a command in Kubemaster VM
PS> .\sshm.ps1 -Command "echo hello"
#>

Param(
    [Parameter(Mandatory = $false, HelpMessage = 'Command to be executed in the Kubemaster VM')]
    [string]$Command = '',
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$statusModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.cluster.module\status\status.module.psm1"
$infraModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"

Import-Module $statusModule, $infraModule, $nodeModule

Initialize-Logging

$remoteUser = Get-ControlPlaneRemoteUser
$key = Get-SSHKeyControlPlane

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

if ((Test-Path $key -PathType Leaf) -ne $true) {
    $errMsg = "Unable to find ssh directory $key"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'ssh-dir-not-found' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $systemError -Error
    exit 1
}

#Note: DO NOT ADD -n option for ssh.exe
if ([string]::IsNullOrWhitespace($Command)) {
    ssh.exe -o StrictHostKeyChecking=no -i $key $remoteUser "$(($MyInvocation).UnboundArguments)"
}
else {
    ssh.exe -n -o StrictHostKeyChecking=no -i $key $remoteUser $Command | ForEach-Object { Write-Log $_ -Console -Ssh }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}