# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'viewer', 'deployment/viewerwebapp').Success

$isViewerRunningProp = @{Name = 'IsViewerRunning'; Value = $success; Okay = $success }
if ($isViewerRunningProp.Value -eq $true) {
    $isViewerRunningProp.Message = 'The viewer is working'
}
else {
    $isViewerRunningProp.Message = "The viewer is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable viewer' and 'k2s addons enable viewer'"
} 
return $isViewerRunningProp,$isViewerRunningProp