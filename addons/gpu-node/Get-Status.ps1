# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$global:KubectlExe wait --timeout=5s --for=condition=Available -n gpu-node deployment/nvidia-device-plugin 2>&1 | Out-Null
$isDevicePluginRunningProp = @{Name = 'isDevicePluginRunning'; Value = $?; Okay = $? }
if ($isDevicePluginRunningProp.Value -eq $true) {
    $isDevicePluginRunningProp.Message = 'The gpu node is working'
}
else {
    $isDevicePluginRunningProp.Message = "The gpu node is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gpu-node' and 'k2s addons enable gpu-node'"
} 

&$global:KubectlExe rollout status daemonset dcgm-exporter -n gpu-node --timeout=5s 2>&1 | Out-Null
$isDCGMExporterRunningProp = @{Name = 'isDCGMExporterRunning'; Value = $?; Okay = $? }
if ($isDCGMExporterRunningProp.Value -eq $true) {
    $isDCGMExporterRunningProp.Message = 'The DCGM exporter is working'
}
else {
    $isDCGMExporterRunningProp.Message = "The DCGM exporter is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gpu-node' and 'k2s addons enable gpu-node'"
} 

return $isDevicePluginRunningProp, $isDCGMExporterRunningProp