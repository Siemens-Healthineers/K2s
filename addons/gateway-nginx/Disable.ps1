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

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# load global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
Import-Module $addonsModule


Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

Write-Log "Check whether gateway-nginx addon is already disabled"

if ($null -eq (&$global:KubectlExe get namespace nginx-gateway --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling NGINX Kubernetes Gateway' -Console
&$global:KubectlExe delete -f "$global:KubernetesPath\addons\gateway-nginx\manifests\nginx-gateway-fabric-v1.1.0.yaml" | Write-Log
&$global:KubectlExe delete -f "$global:KubernetesPath\addons\gateway-nginx\manifests\crds"  | Write-Log

Write-Log 'Uninstalling Gateway API' -Console
&$global:KubectlExe delete -f "$global:KubernetesPath\addons\gateway-nginx\manifests\gateway-api-v1.0.0.yaml" | Write-Log

Remove-ScriptsFromHooksDir -ScriptNames $hookFileNames
Remove-AddonFromSetupJson -Name 'gateway-nginx'
