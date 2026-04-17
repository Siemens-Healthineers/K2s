# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
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

# DCGM requires NVML which is unavailable via dxcore (GPU-PV). Since K2s only
# supports GPU-PV, DCGM-Exporter is no longer deployed by default. Check
# whether it exists (e.g. from an older enable) and report accordingly.
$dcgmExists = (Invoke-Kubectl -Params 'get', 'daemonset', 'dcgm-exporter', '-n', 'gpu-node', '--no-headers', '--ignore-not-found').Output
$isDCGMExporterRunningProp = @{Name = 'IsDCGMExporterRunning'; Value = $false; Okay = $true }
if ([string]::IsNullOrWhiteSpace($dcgmExists)) {
    $isDCGMExporterRunningProp.Message = 'DCGM-Exporter is not deployed (NVML is unavailable via the dxcore/D3D12 GPU-PV path). GPU workloads are not affected.'
}
else {
    $success = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'dcgm-exporter', '-n', 'gpu-node', '--timeout=5s').Success
    $isDCGMExporterRunningProp.Value = $success
    if ($success) {
        $isDCGMExporterRunningProp.Message = 'The DCGM exporter is working'
    }
    else {
        $isDCGMExporterRunningProp.Message = 'The DCGM exporter is deployed but not running. This is expected as NVML cannot access the GPU through the dxcore driver path (WSL2 and Hyper-V GPU-PV). GPU workloads are not affected. Consider disabling and re-enabling the addon to remove the unused DaemonSet.'
    }
} 

$controlPlaneNodeName = (Invoke-Kubectl -Params 'get', 'nodes', '-l', 'node-role.kubernetes.io/control-plane', '-o', 'jsonpath={.items[0].metadata.name}').Output

$nodeLabelsRaw = (Invoke-Kubectl -Params 'get', 'node', $controlPlaneNodeName, '-o', 'jsonpath={.metadata.labels}').Output
$hasGpuLabel = $nodeLabelsRaw -match '"gpu":"true"'
$hasAcceleratorLabel = $nodeLabelsRaw -match '"accelerator":"nvidia"'
$labelsOkay = $hasGpuLabel -and $hasAcceleratorLabel
$nodeLabelsMessage = if ($labelsOkay) {
    "Node '$controlPlaneNodeName' has gpu=true and accelerator=nvidia labels"
} elseif (!$hasGpuLabel -and !$hasAcceleratorLabel) {
    'Node is missing gpu=true and accelerator=nvidia labels - re-enable the addon to apply them'
} elseif (!$hasGpuLabel) {
    'Node is missing gpu=true label - re-enable the addon to apply it'
} else {
    'Node is missing accelerator=nvidia label - re-enable the addon to apply it'
}
$nodeGpuLabelsProp = @{Name = 'NodeGpuLabels'; Value = $labelsOkay; Okay = $labelsOkay; Message = $nodeLabelsMessage}

$gpuAllocatable = 0
$gpuAllocatableRaw = (Invoke-Kubectl -Params 'get', 'node', $controlPlaneNodeName, '-o', "jsonpath={.status.allocatable['nvidia\.com/gpu']}").Output
if (![string]::IsNullOrWhiteSpace($gpuAllocatableRaw) -and $gpuAllocatableRaw -match '^\d+$') {
    $gpuAllocatable = [int]$gpuAllocatableRaw
}
$slotLabel = if ($gpuAllocatable -eq 1) { 'slot' } else { 'slots' }
$gpuAllocatableProp = @{Name = 'GpuAllocatable'; Value = $gpuAllocatable -gt 0; Okay = $gpuAllocatable -gt 0 }
if ($gpuAllocatable -gt 0) {
    $gpuAllocatableProp.Message = "$gpuAllocatable GPU $slotLabel available"
}
else {
    $gpuAllocatableProp.Message = 'No GPU slots available — device plugin may not be ready yet'
}

$gpuInUse = 0
# Use field selector to limit to Running pods only — Pending/Succeeded/Failed pods do not hold GPU slots.
$gpuInUseRaw = (Invoke-Kubectl -Params 'get', 'pods', '--all-namespaces', '--field-selector=status.phase=Running', '-o', "jsonpath={range .items[*]}{range .spec.containers[*]}{.resources.limits['nvidia\.com/gpu']}{' '}{end}{end}").Output
$gpuInUseRaw -split '\s+' | ForEach-Object {
    if ($_ -match '^\d+$') { $gpuInUse += [int]$_ }
}
$inUseLabel = if ($gpuInUse -eq 1) { 'slot' } else { 'slots' }
$gpuInUseProp = @{Name = 'GpuInUse'; Value = $true; Okay = $true }
$gpuInUseProp.Message = "$gpuInUse of $gpuAllocatable GPU $inUseLabel in use"

return $isDevicePluginRunningProp, $isDCGMExporterRunningProp, $nodeGpuLabelsProp, $gpuAllocatableProp, $gpuInUseProp