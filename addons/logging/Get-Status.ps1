# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib\modules\k2s\k2s.cluster.module\k8s-api\k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'logging', 'deployment/opensearch-dashboards').Success

$areDeploymentsRunningProp = @{Name = 'AreDeploymentsRunning'; Value = $success; Okay = $success }
if ($areDeploymentsRunningProp.Value -eq $true) {
    $areDeploymentsRunningProp.Message = 'Opensearch dashboards are working'
}
else {
    $areDeploymentsRunningProp.Message = "Opensearch dashboards are not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable logging' and 'k2s addons enable logging'"
} 

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'logging', '--timeout=5s').Success

$areStatefulsetsRunningProp = @{Name = 'AreStatefulsetsRunning'; Value = $success; Okay = $success }
if ($areStatefulsetsRunningProp.Value -eq $true) {
    $areStatefulsetsRunningProp.Message = 'Opensearch is working'
}
else {
    $areStatefulsetsRunningProp.Message = "Opensearch is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable logging' and 'k2s addons enable logging'"
} 

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'logging', '--timeout=5s').Success

$areDaemonsetsRunningProp = @{Name = 'AreDaemonsetsRunning'; Value = $success; Okay = $success }
if ($areDaemonsetsRunningProp.Value -eq $true) {
    $areDaemonsetsRunningProp.Message = 'Fluent-bit is working'
}
else {
    $areDaemonsetsRunningProp.Message = "Fluent-bit is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable logging' and 'k2s addons enable logging'"
} 

return $areDeploymentsRunningProp, $areStatefulsetsRunningProp, $areDaemonsetsRunningProp