# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

kubectl wait --timeout=5s --for=condition=Available -n kubevirt deployment/virt-api 2>&1 | Out-Null

$isVirtApiRunningProp = @{Name = 'isVirtApiRunningProp'; Value = $?; Okay = $? }
if ($isVirtApiRunningProp.Value -eq $true) {
    $isVirtApiRunningProp.Message = 'The virt-api is working'
}
else {
    $isVirtApiRunningProp.Message = "The virt-api is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

kubectl wait --timeout=5s --for=condition=Available -n kubevirt deployment/virt-controller 2>&1 | Out-Null

$isVirtControllerRunningProp = @{Name = 'isVirtControllerRunningProp'; Value = $?; Okay = $? }
if ($isVirtControllerRunningProp.Value -eq $true) {
    $isVirtControllerRunningProp.Message = 'The virt-controller is working'
}
else {
    $isVirtControllerRunningProp.Message = "The virt-controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

kubectl wait --timeout=5s --for=condition=Available -n kubevirt deployment/virt-operator 2>&1 | Out-Null

$isVirtOperatorRunningProp = @{Name = 'isVirtOperatorRunningProp'; Value = $?; Okay = $? }
if ($isVirtOperatorRunningProp.Value -eq $true) {
    $isVirtOperatorRunningProp.Message = 'The virt-operator is working'
}
else {
    $isVirtOperatorRunningProp.Message = "The virt-operator is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

kubectl rollout status daemonsets -n kubevirt --timeout=5s 2>&1 | Out-Null

$isVirtHandlerRunningProp = @{Name = 'isVirtHandlerRunningProp'; Value = $?; Okay = $? }
if ($isVirtHandlerRunningProp.Value -eq $true) {
    $isVirtHandlerRunningProp.Message = 'The virt-handler is working'
}
else {
    $isVirtHandlerRunningProp.Message = "The virt-handler is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable kubevirt' and 'k2s addons enable kubevirt'"
} 

return $isVirtApiRunningProp, $isVirtControllerRunningProp, $isVirtOperatorRunningProp, $isVirtHandlerRunningProp