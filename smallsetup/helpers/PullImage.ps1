# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

<#
.Description
Pull container images in K2s
#>

Param (
    [parameter(Mandatory = $true, HelpMessage = 'Name of the image to be pulled.')]
    [string] $ImageName,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, the image will be pulled for windows 10 node.')]
    [switch] $Windows,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$clusterModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $clusterModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

if (!$Windows) {
    ExecCmdMaster "sudo buildah pull $ImageName 2>&1" -Retries 5 -NoLog

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    return
}

$setupInfo = Get-SetupInfo

if ($setupInfo.Name -eq "$global:SetupType_MultiVMK8s") {
    if ($setupInfo.LinuxOnly -eq $true) {
        $errMsg = 'Windows image pull option is not possible for a Linux-only setup.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }

    $retries = 5
    $success = $false
    while ($retries -gt 0) {
        $retries--
        ssh.exe -o StrictHostKeyChecking=no -i $global:WindowsVMKey $global:Admin_WinNode crictl pull $ImageName

        if ($?) {
            $success = $true
            break
        }
        Start-Sleep 1
    }

    if (!$success) {
        $errMsg = "Error pulling image '$ImageName'"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-pull-failed' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    return
}

$retries = 5
$success = $false

while ($retries -gt 0) {
    $retries--
    &$global:BinPath\crictl pull $ImageName

    if ($?) {
        $success = $true
        break
    }
    Start-Sleep 1
}

if (!$success) {
    $errMsg = "Error pulling image '$ImageName'"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-pull-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
