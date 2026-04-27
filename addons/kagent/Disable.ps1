# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls Kagent - Kubernetes-native AI agent framework
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$kagentModule = "$PSScriptRoot\kagent.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $kagentModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log '[Kagent] Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'kagent' })) -ne $true) {
    $errMsg = "Addon 'kagent' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log '[Kagent] Uninstalling Kagent' -Console

# Remove Copilot CLI BYO agent if present
Remove-CopilotCliAgent

Uninstall-KagentViaHelm

(Invoke-Kubectl -Params 'delete', 'namespace', 'kagent', '--ignore-not-found').Output | Write-Log

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'kagent' })
Write-Log '[Kagent] Uninstallation of Kagent addon finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
