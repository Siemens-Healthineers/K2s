# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'monitoring', 'deployment/kube-prometheus-stack-kube-state-metrics').Success

$isKubeStateMetricsRunningProp = @{Name = 'IsKubeStateMetricsRunning'; Value = $success; Okay = $success }
if ($isKubeStateMetricsRunningProp.Value -eq $true) {
    $isKubeStateMetricsRunningProp.Message = 'The Kube State Metrics Deployment is working'
}
else {
    $isKubeStateMetricsRunningProp.Message = "The Kube State Metrics Deployment is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'monitoring', 'deployment/kube-prometheus-stack-operator').Success

$isPrometheusOperatorRunningProp = @{Name = 'IsPrometheusOperatorRunning'; Value = $success; Okay = $success }
if ($isPrometheusOperatorRunningProp.Value -eq $true) {
    $isPrometheusOperatorRunningProp.Message = 'The Prometheus Operator is working'
}
else {
    $isPrometheusOperatorRunningProp.Message = "The Prometheus Operator is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'monitoring', 'deployment/kube-prometheus-stack-grafana').Success

$isGrafanaRunningProp = @{Name = 'IsGrafanaRunning'; Value = $success; Okay = $success }
if ($isGrafanaRunningProp.Value -eq $true) {
    $isGrafanaRunningProp.Message = 'The Grafana Dashboard is working'
}
else {
    $isGrafanaRunningProp.Message = "The Grafana Dashboard is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
}

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'monitoring', '--timeout=5s').Success

$areStatefulsetsRunningProp = @{Name = 'AreStatefulsetsRunning'; Value = $success; Okay = $success }
if ($areStatefulsetsRunningProp.Value -eq $true) {
    $areStatefulsetsRunningProp.Message = 'Prometheus and Alertmanager are working'
}
else {
    $areStatefulsetsRunningProp.Message = "Prometheus and Alertmanager are not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'monitoring', '--timeout=5s').Success

$areDaemonsetsRunningProp = @{Name = 'AreDaemonsetsRunning'; Value = $success; Okay = $success }
if ($areDaemonsetsRunningProp.Value -eq $true) {
    $areDaemonsetsRunningProp.Message = 'Node Exporter is working'
}
else {
    $areDaemonsetsRunningProp.Message = "Node Exporter is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

return $isKubeStateMetricsRunningProp, $isPrometheusOperatorRunningProp, $isGrafanaRunningProp, $areStatefulsetsRunningProp, $areDaemonsetsRunningProp