# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Copies files from and to the WinNode

.DESCRIPTION
Copies files from the host machine to WinNode and vice-versa

.PARAMETER Source
File/Folder to be copied

.PARAMETER Target
Destination where the file/folder needs to be copied to.

.PARAMETER Reverse
If set, the files are copied from the WinNode VM to the host machine

.EXAMPLE
# Copy files from host machine to WinNode VM
PS> .\scpw.ps1 -Source C:\temp.txt -Target /tmp

.EXAMPLE
# Copy files from WinNode VM to the host machine
PS> .\scpm.ps1 -Source /tmp/temp.txt -Target C:\temp -Reverse
#>

Param(
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

$session = Open-RemoteSessionViaSSHKey $remoteUser $key

if (!$Reverse) {
    Copy-Item "$Source" -Destination "$Target" -Recurse -ToSession $session -Force
}
else {
    Copy-Item "$Source" -Destination "$Target" -Recurse -FromSession $session -Force
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}