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
    [switch] $ShowLogs = $false
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
. $PSScriptRoot\Common.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

Write-Log 'Check whether gateway-nginx addon is already disabled'

if ($null -eq (kubectl get namespace nginx-gateway --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling NGINX Kubernetes Gateway' -Console
&$global:BinPath\kubectl.exe delete -f "$global:KubernetesPath\addons\gateway-nginx\manifests\nginx-gateway-fabric-v1.1.0.yaml" | Write-Log
&$global:BinPath\kubectl.exe delete -f "$global:KubernetesPath\addons\gateway-nginx\manifests\crds" | Write-Log

Write-Log 'Uninstalling Gateway API' -Console
&$global:BinPath\kubectl.exe delete -f "$global:KubernetesPath\addons\gateway-nginx\manifests\gateway-api-v1.0.0.yaml" | Write-Log

Remove-ScriptsFromHooksDir -ScriptNames $hookFileNames
Remove-AddonFromSetupJson -Name 'gateway-nginx'
