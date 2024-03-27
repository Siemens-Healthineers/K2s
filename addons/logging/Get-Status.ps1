# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$global:KubectlExe wait --timeout=5s --for=condition=Available -n logging deployment/opensearch-dashboards 2>&1 | Out-Null

$areDeploymentsRunningProp = @{Name = 'areDeploymentsRunningProp'; Value = $?; Okay = $? }
if ($areDeploymentsRunningProp.Value -eq $true) {
    $areDeploymentsRunningProp.Message = 'Opensearch dashboards are working'
}
else {
    $areDeploymentsRunningProp.Message = "Opensearch dashboards are not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable logging' and 'k2s addons enable logging'"
} 

&$global:KubectlExe rollout status statefulsets -n logging --timeout=5s 2>&1 | Out-Null

$areStatefulsetsRunningProp = @{Name = 'areStatefulsetsRunningProp'; Value = $?; Okay = $? }
if ($areStatefulsetsRunningProp.Value -eq $true) {
    $areStatefulsetsRunningProp.Message = 'Opensearch is working'
}
else {
    $areStatefulsetsRunningProp.Message = "Opensearch is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable logging' and 'k2s addons enable logging'"
} 

&$global:KubectlExe rollout status daemonsets -n logging --timeout=5s 2>&1 | Out-Null

$areDaemonsetsRunningProp = @{Name = 'areDaemonsetsRunningProp'; Value = $?; Okay = $? }
if ($areDaemonsetsRunningProp.Value -eq $true) {
    $areDaemonsetsRunningProp.Message = 'Fluent-bit is working'
}
else {
    $areDaemonsetsRunningProp.Message = "Fluent-bit is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable logging' and 'k2s addons enable logging'"
} 

return $areDeploymentsRunningProp, $areStatefulsetsRunningProp, $areDaemonsetsRunningProp