# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

Param(
    [parameter(Mandatory = $false)]
    [string] $Source,
    [parameter(Mandatory = $false)]
    [string] $Target,
    [parameter(Mandatory = $false)]
    [switch] $Reverse,
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

$systemError = Test-SystemAvailability
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }
    Write-Log $systemError -Error
    exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne $global:SetupType_MultiVMK8s -or $setupInfo.LinuxOnly ) {
    $errMsg = 'There is no multi-vm setup with worker node installed.'
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        return
    }
    Write-Log $systemError -Error
    exit 1
}

if ((Test-Path $global:WindowsVMKey -PathType Leaf) -ne $true) {
    $errMsg = "Unable to find ssh directory $global:WindowsVMKey"
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        return
    }
    Write-Log $systemError -Error
    exit 1
}

if (!$Reverse) {
    $source = $Source
    $target = $global:Admin_WinNode + ':' + $Target
}
else {
    $source = $global:Admin_WinNode + ':' + $Source
    $target = $Target
}

scp.exe -r -q -o StrictHostKeyChecking=no -i $global:WindowsVMKey $source $target

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}