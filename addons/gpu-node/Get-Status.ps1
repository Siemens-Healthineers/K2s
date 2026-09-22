# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

$controlPlaneNodeName = (Invoke-Kubectl -Params 'get', 'nodes', '-l', 'node-role.kubernetes.io/control-plane', '-o', 'jsonpath={.items[0].metadata.name}').Output
$nodeLabelsRaw = (Invoke-Kubectl -Params 'get', 'node', $controlPlaneNodeName, '-o', 'jsonpath={.metadata.labels}').Output
$hasGpuLabel = $nodeLabelsRaw -match '"gpu":"true"'
$hasAcceleratorLabel = $nodeLabelsRaw -match '"accelerator":"nvidia"'
$isControlPlaneGpuPv = $nodeLabelsRaw -match '"k2s\.siemens-healthineers\.com/gpu-mode":"gpu-pv"'
$labelsOkay = $hasGpuLabel -and $hasAcceleratorLabel -and $isControlPlaneGpuPv
$allGpuNodesRaw = (Invoke-Kubectl -Params 'get', 'nodes', '-l', 'gpu=true,accelerator=nvidia', '-o', 'jsonpath={.items[*].metadata.name}').Output
$allGpuNodes = if ([string]::IsNullOrWhiteSpace($allGpuNodesRaw)) { @() } else { $allGpuNodesRaw -split '\s+' }
$externalGpuNodes = @($allGpuNodes | Where-Object { $_ -ne $controlPlaneNodeName })
$mode = if ($isControlPlaneGpuPv) { 'control-plane' } else { 'external-workers' }

$controlPlanePluginReady = $false
if ($isControlPlaneGpuPv) {
    $controlPlanePluginReady = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'nvidia-device-plugin', '-n', 'gpu-node', '--timeout=5s').Success
}
$nativePluginReady = $false
if ($externalGpuNodes.Count -gt 0) {
    $nativePluginReady = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'nvidia-device-plugin-native', '-n', 'gpu-node', '--timeout=5s').Success
}
$pluginReady = $controlPlanePluginReady -or $nativePluginReady
$isDevicePluginRunningProp = @{Name = 'IsDevicePluginRunning'; Value = $pluginReady; Okay = $pluginReady }
$isDevicePluginRunningProp.Message = if ($pluginReady) { 'The GPU device plugin is working' } else { "The GPU device plugin is not working. Re-enable the addon with 'k2s addons disable gpu-node' and 'k2s addons enable gpu-node'." }

$modeProp = @{Name = 'GpuMode'; Value = $mode; Okay = $true; Message = "GPU mode: $mode"}
$isDCGMExporterRunningProp = @{Name = 'IsDCGMExporterRunning'; Value = $false; Okay = $true; Message = 'DCGM-Exporter is not deployed; GPU workloads are not affected.'}
$nodeLabelsMessage = if ($labelsOkay) {
    "Node '$controlPlaneNodeName' has gpu=true and accelerator=nvidia labels"
} elseif ($mode -eq 'external-workers') {
    'Control-plane GPU labels are not required in external-workers mode'
} elseif (!$hasGpuLabel -and !$hasAcceleratorLabel) {
    'Node is missing gpu=true and accelerator=nvidia labels - re-enable the addon to apply them'
} elseif (!$hasGpuLabel) {
    'Node is missing gpu=true label - re-enable the addon to apply it'
} else {
    'Node is missing accelerator=nvidia label - re-enable the addon to apply it'
}
$nodeGpuLabelsProp = @{Name = 'NodeGpuLabels'; Value = ($labelsOkay -or $mode -eq 'external-workers'); Okay = ($labelsOkay -or $mode -eq 'external-workers'); Message = $nodeLabelsMessage}

$totalGpuAllocatable = 0
$totalGpuInUse = 0
$externalGpuWorkersProp = @{Name = 'ExternalGpuWorkers'; Value = $true; Okay = $true }
if ($externalGpuNodes.Count -gt 0) {
    $nodeListStr = $externalGpuNodes -join ', '
    $externalGpuWorkersProp.Message = "$($externalGpuNodes.Count) external GPU worker(s): $nodeListStr"
} else {
    $externalGpuWorkersProp.Message = 'No external GPU workers configured (workers with NVIDIA GPUs are automatically configured when added)'
}

foreach ($gpuNode in $allGpuNodes) {
    $gpuAllocatableRaw = (Invoke-Kubectl -Params 'get', 'node', $gpuNode, '-o', "jsonpath={.status.allocatable['nvidia\.com/gpu']}").Output
    if ($gpuAllocatableRaw -match '^\d+$') { $totalGpuAllocatable += [int]$gpuAllocatableRaw }
    $gpuInUseRaw = (Invoke-Kubectl -Params 'get', 'pods', '--all-namespaces', '--field-selector', "status.phase=Running,spec.nodeName=$gpuNode", '-o', "jsonpath={range .items[*]}{range .spec.containers[*]}{.resources.limits['nvidia\.com/gpu']}{' '}{end}{end}").Output
    $gpuInUseRaw -split '\s+' | ForEach-Object { if ($_ -match '^\d+$') { $totalGpuInUse += [int]$_ } }
}

$slotLabel = if ($totalGpuAllocatable -eq 1) { 'slot' } else { 'slots' }
$gpuAllocatableProp = @{Name = 'GpuAllocatable'; Value = $totalGpuAllocatable -gt 0; Okay = $totalGpuAllocatable -gt 0; Message = "$totalGpuAllocatable GPU $slotLabel available"}
$gpuInUseProp = @{Name = 'GpuInUse'; Value = $true; Okay = $true; Message = "$totalGpuInUse of $totalGpuAllocatable GPU $slotLabel in use"}

$resultProps = @($modeProp, $isDevicePluginRunningProp, $isDCGMExporterRunningProp, $nodeGpuLabelsProp, $gpuAllocatableProp, $gpuInUseProp, $externalGpuWorkersProp)
return $resultProps