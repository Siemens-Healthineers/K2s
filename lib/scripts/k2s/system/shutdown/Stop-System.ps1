# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"

Import-Module $infraModule, $nodeModule
Initialize-Logging

$logUseCase = 'Stop-System'
try {
    Write-Log "[$logUseCase] started"
    Write-Log "[$logUseCase] removing external switch with l2 bridge network"
    # remove L2 bridge switch
    Write-Log "[$logUseCase] start hns in case it is not running"
    Start-Service -Name 'hns' -ErrorAction SilentlyContinue
    Write-Log "[$logUseCase] retrieving HNS networks"
    $hns = Get-HNSNetwork
    $hnsNames = $hns | Select-Object -ExpandProperty Name
    $logText = "[$logUseCase] HNS networks available: " + $hnsNames
    Write-Log $logText
    try {
        $hnsToRemove = $hns | Where-Object Name -Like '*cbr0*'
        if ($hnsToRemove) {
            Write-Log "[$logUseCase] removing *cbr0* networks"
            $hnsToRemove | Remove-HNSNetwork -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "[$logUseCase] removing *cbr0* networks failed: $($_.Exception.Message) - $($_.ScriptStackTrace)"
    }
    Write-Log "[$logUseCase] cbr0 network removed"
    # show the still existing HNS networks
    $hns = Get-HNSNetwork
    $hnsNames = $hns | Select-Object -ExpandProperty Name
    $logText = "[$logUseCase] HNS networks available: " + $hnsNames
    Write-Log $logText
    Write-Log "[$logUseCase] finished"
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
}
catch {
    Write-Log "[$logUseCase] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}