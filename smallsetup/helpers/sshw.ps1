# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

Param(
    [Parameter(Mandatory = $false)]
    [string]$Command = '',
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\common\GlobalVariables.ps1

$clusterModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"

Import-Module $clusterModule, $infraModule

Initialize-Logging

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
if ($setupInfo.Name -ne $global:SetupType_MultiVMK8s -or $setupInfo.LinuxOnly ) {
    $errMsg = 'There is no multi-vm setup with worker node installed.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $systemError -Error
    exit 1
}

if (Test-Path $global:WindowsVMKey -PathType Leaf) {
    if ([string]::IsNullOrWhitespace($Command)) {
        ssh.exe -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode "$(($MyInvocation).UnboundArguments)"
    }
    else {
        ssh.exe -n -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode "$Command" | ForEach-Object { Write-Output $_ }
    }
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}