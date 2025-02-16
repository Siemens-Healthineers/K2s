# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'dashboard', 'deployment/dashboard-metrics-scraper').Success

$isDashboardMetricsScaperRunningProp = @{Name = 'IsDashboardMetricsScaperRunning'; Value = $success; Okay = $success }
if ($isDashboardMetricsScaperRunningProp.Value -eq $true) {
    $isDashboardMetricsScaperRunningProp.Message = 'The metrics scraper is working'
}
else {
    $isDashboardMetricsScaperRunningProp.Message = "The metrics scraper is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dashboard' and 'k2s addons enable dashboard'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'dashboard', 'deployment/kubernetes-dashboard').Success

$isDashboardRunningProp = @{Name = 'IsDashboardRunning'; Value = $success; Okay = $success }
if ($isDashboardRunningProp.Value -eq $true) {
    $isDashboardRunningProp.Message = 'The dashboard is working'
}
else {
    $isDashboardRunningProp.Message = "The dashboard is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dashboard' and 'k2s addons enable dashboard'"
} 

return $isDashboardMetricsScaperRunningProp, $isDashboardRunningProp