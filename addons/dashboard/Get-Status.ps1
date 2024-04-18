# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

Import-Module $k8sApiModule

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kubernetes-dashboard', 'deployment/dashboard-metrics-scraper' | Out-Null

$isDashboardMetricsScaperRunningProp = @{Name = 'IsDashboardMetricsScaperRunning'; Value = $?; Okay = $? }
if ($isDashboardMetricsScaperRunningProp.Value -eq $true) {
    $isDashboardMetricsScaperRunningProp.Message = 'The metrics scraper is working'
}
else {
    $isDashboardMetricsScaperRunningProp.Message = "The metrics scraper is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dashboard' and 'k2s addons enable dashboard'"
} 

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kubernetes-dashboard', 'deployment/kubernetes-dashboard' | Out-Null

$isDashboardRunningProp = @{Name = 'IsDashboardRunning'; Value = $?; Okay = $? }
if ($isDashboardRunningProp.Value -eq $true) {
    $isDashboardRunningProp.Message = 'The dashboard is working'
}
else {
    $isDashboardRunningProp.Message = "The dashboard is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dashboard' and 'k2s addons enable dashboard'"
} 

return $isDashboardMetricsScaperRunningProp, $isDashboardRunningProp