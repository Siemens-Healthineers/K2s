# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$k8sApiModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
$configModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/config/config.module.psm1"

Import-Module $k8sApiModule, $configModule

Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'nginx-gateway', 'deployment/nginx-gateway' | Out-Null

$isGatewayControllerRunningProp = @{Name = 'IsGatewayControllerRunning'; Value = $?; Okay = $? }
if ($isGatewayControllerRunningProp.Value -eq $true) {
    $isGatewayControllerRunningProp.Message = 'The gateway API controller is working'
}
else {
    $isGatewayControllerRunningProp.Message = "The gateway API controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gateway-nginx' and 'k2s addons enable gateway-nginx'"
} 

$externalIp = (Invoke-Kubectl -Params 'get', 'service', 'nginx-gateway', '-n', 'nginx-gateway', '-o', 'jsonpath="{.spec.externalIPs[0]}"').Output
$controlPlaneIp = Get-ConfiguredIPControlPlane

$isExternalIPSetProp = @{Name = 'IsExternalIPSet'; Value = ($externalIp -eq $controlPlaneIp); Okay = ($externalIp -eq $controlPlaneIp) }
if ($isExternalIPSetProp.Value -eq $true) {
    $isExternalIPSetProp.Message = "The external IP for gateway API service is set to $controlPlaneIp"
}
else {
    $isExternalIPSetProp.Message = "The external IP for gateway API service is not set properly. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gateway-nginx' and 'k2s addons enable gateway-nginx'"
}

return $isGatewayControllerRunningProp, $isExternalIPSetProp