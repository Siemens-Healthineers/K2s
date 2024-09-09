# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Copies files from and to the Kubemaster

.DESCRIPTION
Copies files from the host machine to Kubemaster and vice-versa

.PARAMETER Source
File/Folder to be copied

.PARAMETER Target
Destination where the file/folder needs to be copied to.

.PARAMETER Reverse
If set, the files are copied from the Kubemaster VM to the host machine

.EXAMPLE
# Copy files from host machine to Kubemaster VM
PS> .\scpm.ps1 -Source C:\temp.txt -Target /tmp

.EXAMPLE
# Copy files from Kubemaster VM to the host machine
PS> .\scpm.ps1 -Source /tmp/temp.txt -Target C:\temp -Reverse
#>

Param (
    [parameter(Mandatory = $true, HelpMessage = 'File/Folder to be copied')]
    [string]$Source,
    [parameter(Mandatory = $true, HelpMessage = 'Destination where the file/fodler needs to be copied to')]
    [string]$Target,
    [parameter(Mandatory = $false, HelpMessage = 'If set, the files are coped from the Kubemaster VM to the host machone')]
    [switch]$Reverse,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$statusModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.cluster.module\status\status.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.infra.module\log\log.module.psm1"
$cliMessagesModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.infra.module\cli-messages\cli-messages.module.psm1"
$errorsModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.infra.module\errors\errors.module.psm1"
$configModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.infra.module\config\config.module.psm1"
$vmModule = "$PSScriptRoot\..\..\..\..\..\lib\modules\k2s\k2s.node.module\linuxnode\vm\vm.module.psm1"

Import-Module $statusModule, $logModule, $cliMessagesModule, $errorsModule, $configModule, $vmModule

Initialize-Logging

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

try {
    if (!$Reverse) {
        Copy-ToControlPlaneViaSSHKey -Source:$Source -Target:$Target
    }
    else {
        Copy-FromControlPlaneViaSSHKey -Source:$Source -Target:$Target
    }
}
catch {
    $err = New-Error -Severity Warning -Code "scp failed" -Message $_
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}