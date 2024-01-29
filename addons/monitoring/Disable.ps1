# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables Prometheus/Grafana monitoring features for the k2s cluster.

.DESCRIPTION
The "monitoring" addons enables Prometheus/Grafana monitoring features for the k2s cluster.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

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

Write-Log 'Check whether monitoring addon is already disabled'

if ($null -eq (kubectl get namespace monitoring --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling Kube Prometheus Stack' -Console
kubectl delete -k "$global:KubernetesPath\addons\monitoring\manifests"
kubectl delete -f "$global:KubernetesPath\addons\monitoring\manifests\crds"

kubectl delete -f "$global:KubernetesPath\addons\monitoring\manifests\namespace.yaml"

Remove-AddonFromSetupJson -Name 'monitoring'

Write-Log 'Kube Prometheus Stack uninstalled successfully' -Console
