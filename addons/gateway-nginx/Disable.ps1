# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls nginx kubernetes gateway

.DESCRIPTION
Uninstalls nginx kubernetes gateway
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
. $PSScriptRoot\Common.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule, $cliMessagesModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError -Error
    exit 1
}


if ($null -eq (&$global:KubectlExe get namespace nginx-gateway --ignore-not-found) -or (Test-IsAddonEnabled -Name 'gateway-nginx') -ne $true) {
    Write-Log "Addon 'gateway-nginx' is already disabled, nothing to do." -Console

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    
    exit 0
}

Write-Log 'Uninstalling NGINX Kubernetes Gateway' -Console
&$global:KubectlExe delete -f "$global:KubernetesPath\addons\gateway-nginx\manifests\nginx-gateway-fabric-v1.1.0.yaml" | Write-Log
&$global:KubectlExe delete -f "$global:KubernetesPath\addons\gateway-nginx\manifests\crds" | Write-Log

Write-Log 'Uninstalling Gateway API' -Console
&$global:KubectlExe delete -f "$global:KubernetesPath\addons\gateway-nginx\manifests\gateway-api-v1.0.0.yaml" | Write-Log

Remove-ScriptsFromHooksDir -ScriptNames $hookFileNames
Remove-AddonFromSetupJson -Name 'gateway-nginx'

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}