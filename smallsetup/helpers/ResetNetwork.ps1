# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Force deleting network settings')]
    [switch] $Force = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

&$PSScriptRoot\..\common\GlobalVariables.ps1

$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $logModule, $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

if ($Force -ne $true) {
    $answer = Read-Host 'WARNING: THIS DELETES ALL NETWORK SETTINGS. Continue? (y/N)'
    if ($answer -ne 'y') {
        $errMsg = 'Network reset cancelled.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeUserCancellation) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }    
}

Write-Log 'Removing HNS Network' 
Import-Module "$global:KubernetesPath\smallsetup\LoopbackAdapter.psm1" -Force
Get-NetAdapter | Where-Object InterfaceDescription -like 'Microsoft KM-TEST Loopback Adapter*' | ForEach-Object { Remove-LoopbackAdapter -Name $_.Name -DevConExe $global:DevconExe }

Get-HnsNetwork | Remove-HnsNetwork
Write-Log 'Delete Network Configuration'
netcfg -d

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}

Write-Log 'Restart computer now?' -Console
Restart-Computer -Confirm