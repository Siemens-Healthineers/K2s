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

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"
Import-Module $addonsModule

Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

Write-Log "Check whether monitoring addon is already disabled"

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
