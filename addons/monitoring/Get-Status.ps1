# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'monitoring', 'deployment/kube-prometheus-stack-kube-state-metrics' | Out-Null

$isKubeStateMetricsRunningProp = @{Name = 'IsKubeStateMetricsRunning'; Value = $?; Okay = $? }
if ($isKubeStateMetricsRunningProp.Value -eq $true) {
    $isKubeStateMetricsRunningProp.Message = 'The Kube State Metrics Deployment is working'
}
else {
    $isKubeStateMetricsRunningProp.Message = "The Kube State Metrics Deployment is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'monitoring', 'deployment/kube-prometheus-stack-operator' | Out-Null

$isPrometheusOperatorRunningProp = @{Name = 'IsPrometheusOperatorRunning'; Value = $?; Okay = $? }
if ($isPrometheusOperatorRunningProp.Value -eq $true) {
    $isPrometheusOperatorRunningProp.Message = 'The Prometheus Operator is working'
}
else {
    $isPrometheusOperatorRunningProp.Message = "The Prometheus Operator is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'monitoring', 'deployment/kube-prometheus-stack-plutono' | Out-Null

$isPlutonoRunningProp = @{Name = 'IsPlutonoRunning'; Value = $?; Okay = $? }
if ($isPlutonoRunningProp.Value -eq $true) {
    $isPlutonoRunningProp.Message = 'The Plutono Dashboard is working'
}
else {
    $isPlutonoRunningProp.Message = "The Plutono Dashboard is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'monitoring', '--timeout=5s' | Out-Null

$areStatefulsetsRunningProp = @{Name = 'AreStatefulsetsRunning'; Value = $?; Okay = $? }
if ($areStatefulsetsRunningProp.Value -eq $true) {
    $areStatefulsetsRunningProp.Message = 'Prometheus and Alertmanager are working'
}
else {
    $areStatefulsetsRunningProp.Message = "Prometheus and Alertmanager are not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'monitoring', '--timeout=5s' | Out-Null

$areDaemonsetsRunningProp = @{Name = 'AreDaemonsetsRunning'; Value = $?; Okay = $? }
if ($areDaemonsetsRunningProp.Value -eq $true) {
    $areDaemonsetsRunningProp.Message = 'Node Exporter is working'
}
else {
    $areDaemonsetsRunningProp.Message = "Node Exporter is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

return $isKubeStateMetricsRunningProp, $isPrometheusOperatorRunningProp, $isPlutonoRunningProp, $areStatefulsetsRunningProp, $areDaemonsetsRunningProp