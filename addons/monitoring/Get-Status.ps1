# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$global:KubectlExe wait --timeout=5s --for=condition=Available -n monitoring deployment/kube-prometheus-stack-kube-state-metrics 2>&1 | Out-Null

$isKubeStateMetricsRunningProp = @{Name = 'isKubeStateMetricsRunningProp'; Value = $?; Okay = $? }
if ($isKubeStateMetricsRunningProp.Value -eq $true) {
    $isKubeStateMetricsRunningProp.Message = 'The Kube State Metrics Deployment is working'
}
else {
    $isKubeStateMetricsRunningProp.Message = "The Kube State Metrics Deployment is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

&$global:KubectlExe wait --timeout=5s --for=condition=Available -n monitoring deployment/kube-prometheus-stack-operator 2>&1 | Out-Null

$isPrometheusOperatorRunningProp = @{Name = 'isPrometheusOperatorRunningProp'; Value = $?; Okay = $? }
if ($isPrometheusOperatorRunningProp.Value -eq $true) {
    $isPrometheusOperatorRunningProp.Message = 'The Prometheus Operator is working'
}
else {
    $isPrometheusOperatorRunningProp.Message = "The Prometheus Operator is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

&$global:KubectlExe wait --timeout=5s --for=condition=Available -n monitoring deployment/kube-prometheus-stack-plutono 2>&1 | Out-Null

$isPlutonoRunningProp = @{Name = 'isPlutonoRunningProp'; Value = $?; Okay = $? }
if ($isPlutonoRunningProp.Value -eq $true) {
    $isPlutonoRunningProp.Message = 'The Plutono Dashboard is working'
}
else {
    $isPlutonoRunningProp.Message = "The Plutono Dashboard is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

&$global:KubectlExe rollout status statefulsets -n monitoring --timeout=5s 2>&1 | Out-Null

$areStatefulsetsRunningProp = @{Name = 'areStatefulsetsRunningProp'; Value = $?; Okay = $? }
if ($areStatefulsetsRunningProp.Value -eq $true) {
    $areStatefulsetsRunningProp.Message = 'Prometheus and Alertmanager are working'
}
else {
    $areStatefulsetsRunningProp.Message = "Prometheus and Alertmanager are not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

&$global:KubectlExe rollout status daemonsets -n monitoring --timeout=5s 2>&1 | Out-Null

$areDaemonsetsRunningProp = @{Name = 'areDaemonsetsRunningProp'; Value = $?; Okay = $? }
if ($areDaemonsetsRunningProp.Value -eq $true) {
    $areDaemonsetsRunningProp.Message = 'Node Exporter is working'
}
else {
    $areDaemonsetsRunningProp.Message = "Node Exporter is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable monitoring' and 'k2s addons enable monitoring'"
} 

return $isKubeStateMetricsRunningProp, $isPrometheusOperatorRunningProp, $isPlutonoRunningProp, $areStatefulsetsRunningProp, $areDaemonsetsRunningProp