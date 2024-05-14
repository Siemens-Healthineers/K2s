# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'gpu-node', 'deployment/nvidia-device-plugin').Success

$isDevicePluginRunningProp = @{Name = 'IsDevicePluginRunning'; Value = $success; Okay = $success }
if ($isDevicePluginRunningProp.Value -eq $true) {
    $isDevicePluginRunningProp.Message = 'The gpu node is working'
}
else {
    $isDevicePluginRunningProp.Message = "The gpu node is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gpu-node' and 'k2s addons enable gpu-node'"
} 

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'dcgm-exporter', '-n', 'gpu-node', '--timeout=5s').Success

$isDCGMExporterRunningProp = @{Name = 'IsDCGMExporterRunning'; Value = $success; Okay = $success }
if ($isDCGMExporterRunningProp.Value -eq $true) {
    $isDCGMExporterRunningProp.Message = 'The DCGM exporter is working'
}
else {
    $isDCGMExporterRunningProp.Message = "The DCGM exporter is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gpu-node' and 'k2s addons enable gpu-node'"
} 

return $isDevicePluginRunningProp, $isDCGMExporterRunningProp