# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib\modules\k2s\k2s.cluster.module\k8s-api\k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'metrics', 'deployment/metrics-server').Success

$isMetricsServerRunningProp = @{Name = 'IsMetricsServerRunning'; Value = $success; Okay = $success }
if ($isMetricsServerRunningProp.Value -eq $true) {
    $isMetricsServerRunningProp.Message = 'The metrics server is working'
}
else {
    $isMetricsServerRunningProp.Message = "The metrics server is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable metrics' and 'k2s addons enable metrics'"
} 

return , @($isMetricsServerRunningProp)