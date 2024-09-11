# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Import-Module "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\k8s-api\k8s-api.module.psm1"

$deploymentAvailable = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'autoscaling', 'deployment/keda-admission').Success
$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'app=keda-operator' -Namespace 'autoscaling' -TimeoutSeconds 120)

$isKedaProp = @{Name = 'IsKedaRunning'; Value = ($deploymentAvailable -and $allPodsAreUp); Okay = ($deploymentAvailable -and $allPodsAreUp) }
if ($isKedaProp.Value -eq $true) {
    $isKedaProp.Message = 'KEDA is working'
}
else {
    $isKedaProp.Message = "KEDA is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable autoscaling' and 'k2s addons enable autoscaling'"
} 

return , @($isKedaProp)