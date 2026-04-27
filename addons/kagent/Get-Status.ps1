# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

$controllerAvailable = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kagent', 'deployment/kagent-controller').Success
$uiAvailable = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kagent', 'deployment/kagent-ui').Success

$isRunning = $controllerAvailable -and $uiAvailable

$isKagentProp = @{Name = 'IsKagentRunning'; Value = $isRunning; Okay = $isRunning }
if ($isKagentProp.Value -eq $true) {
    $isKagentProp.Message = 'Kagent is working'
}
else {
    $isKagentProp.Message = "Kagent is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kagent' and 'k2s addons enable kagent'"
}

return , @($isKagentProp)
