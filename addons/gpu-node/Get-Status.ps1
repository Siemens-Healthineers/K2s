# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'nvidia-device-plugin', '-n', 'gpu-node', '--timeout=5s').Success

$isDevicePluginRunningProp = @{Name = 'IsDevicePluginRunning'; Value = $success; Okay = $success }
if ($isDevicePluginRunningProp.Value -eq $true) {
    $isDevicePluginRunningProp.Message = 'The gpu node is working'
}
else {
    $isDevicePluginRunningProp.Message = "The gpu node is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gpu-node' and 'k2s addons enable gpu-node'"
} 

$success = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'dcgm-exporter', '-n', 'gpu-node', '--timeout=5s').Success

# Both WSL2 and Hyper-V GPU-PV access the GPU via dxcore/D3D12, not NVML.
# DCGM requires NVML to discover the GPU, so it cannot work on either path.
# DCGM failure is therefore non-fatal on both modes — GPU workloads are unaffected.
$isDCGMExporterRunningProp = @{Name = 'IsDCGMExporterRunning'; Value = $success; Okay = $true }
if ($success) {
    $isDCGMExporterRunningProp.Message = 'The DCGM exporter is working'
}
else {
    $isDCGMExporterRunningProp.Message = 'The DCGM exporter is not running. This is expected as NVML cannot access the GPU through the dxcore driver path (WSL2 and Hyper-V GPU-PV). GPU workloads are not affected.'
} 

return $isDevicePluginRunningProp, $isDCGMExporterRunningProp