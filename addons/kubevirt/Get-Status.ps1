# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kubevirt', 'deployment/virt-api' | Out-Null

$isVirtApiRunningProp = @{Name = 'IsVirtApiRunning'; Value = $?; Okay = $? }
if ($isVirtApiRunningProp.Value -eq $true) {
    $isVirtApiRunningProp.Message = 'The virt-api is working'
}
else {
    $isVirtApiRunningProp.Message = "The virt-api is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kubevirt', 'deployment/virt-controller' | Out-Null

$isVirtControllerRunningProp = @{Name = 'IsVirtControllerRunning'; Value = $?; Okay = $? }
if ($isVirtControllerRunningProp.Value -eq $true) {
    $isVirtControllerRunningProp.Message = 'The virt-controller is working'
}
else {
    $isVirtControllerRunningProp.Message = "The virt-controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'kubevirt', 'deployment/virt-operator' | Out-Null

$isVirtOperatorRunningProp = @{Name = 'IsVirtOperatorRunning'; Value = $?; Okay = $? }
if ($isVirtOperatorRunningProp.Value -eq $true) {
    $isVirtOperatorRunningProp.Message = 'The virt-operator is working'
}
else {
    $isVirtOperatorRunningProp.Message = "The virt-operator is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'kubevirt', '--timeout=5s' | Out-Null

$isVirtHandlerRunningProp = @{Name = 'IsVirtHandlerRunning'; Value = $?; Okay = $? }
if ($isVirtHandlerRunningProp.Value -eq $true) {
    $isVirtHandlerRunningProp.Message = 'The virt-handler is working'
}
else {
    $isVirtHandlerRunningProp.Message = "The virt-handler is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

return $isVirtApiRunningProp, $isVirtControllerRunningProp, $isVirtOperatorRunningProp, $isVirtHandlerRunningProp