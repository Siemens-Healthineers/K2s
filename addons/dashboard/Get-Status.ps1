# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

kubectl wait --timeout=5s --for=condition=Available -n kubernetes-dashboard deployment/dashboard-metrics-scraper 2>&1 | Out-Null

$isDashboardMetricsScaperRunningProp = @{Name = 'isDashboardMetricsScaperRunningProp'; Value = $?; Okay = $? }
if ($isDashboardMetricsScaperRunningProp.Value -eq $true) {
    $isDashboardMetricsScaperRunningProp.Message = 'The metrics scraper is working'
}
else {
    $isDashboardMetricsScaperRunningProp.Message = "The metrics scraper is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dashboard' and 'k2s addons enable dashboard'"
} 

kubectl wait --timeout=5s --for=condition=Available -n kubernetes-dashboard deployment/kubernetes-dashboard 2>&1 | Out-Null

$isDashboardRunningProp = @{Name = 'isDashboardRunningProp'; Value = $?; Okay = $? }
if ($isDashboardRunningProp.Value -eq $true) {
    $isDashboardRunningProp.Message = 'The dashboard is working'
}
else {
    $isDashboardRunningProp.Message = "The dashboard is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable dashboard' and 'k2s addons enable dashboard'"
} 

return $isDashboardMetricsScaperRunningProp, $isDashboardRunningProp