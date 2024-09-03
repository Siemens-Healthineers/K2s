# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib\modules\k2s\k2s.cluster.module\k8s-api\k8s-api.module.psm1"

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'keda', 'deployment/keda-admission').Success

$isKedaProp = @{Name = 'IsKedaRunning'; Value = $success; Okay = $success }
if ($isKedaProp.Value -eq $true) {
    $isKedaProp.Message = 'The keda is working'
}
else {
    $isKedaProp.Message = "The keda is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable keda' and 'k2s addons enable keda'"
} 

return , @($isKedaProp)