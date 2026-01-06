# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$k8sApiModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k8s-api/k8s-api.module.psm1"
$configModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/config/config.module.psm1"

Import-Module $k8sApiModule, $configModule

$success = (Invoke-Kubectl -Params 'wait', '--timeout=5s', '--for=condition=Available', '-n', 'nginx-gw', 'deployment/nginx-gw').Success

$isIngressNginxGatewayRunningProp = @{Name = 'IsIngressNginxGatewayFabricRunning'; Value = $success; Okay = $success }
if ($isIngressNginxGatewayRunningProp.Value -eq $true) {
    $isIngressNginxGatewayRunningProp.Message = 'The nginx ingress gateway api controller is working'
}
else {
    $isIngressNginxGatewayRunningProp.Message = "The nginx ingress gateway api controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable ingress nginx-gw' and 'k2s addons enable ingress nginx-gw'"
} 

$externalIp = (Invoke-Kubectl -Params 'get', 'service', 'nginx-gw-controller', '-n', 'nginx-gw', '-o', 'jsonpath="{.spec.externalIPs[0]}"').Output
$controlPlaneIp = Get-ConfiguredIPControlPlane

$isExternalIPSetProp = @{Name = 'IsExternalIPSet'; Value = ($externalIp -eq $controlPlaneIp); Okay = ($externalIp -eq $controlPlaneIp) }
if ($isExternalIPSetProp.Value -eq $true) {
    $isExternalIPSetProp.Message = "The external IP for nginx-gw-controller service is set to $controlPlaneIp"
}
else {
    $isExternalIPSetProp.Message = "The external IP for nginx-gw-controller service is not set properly. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable ingress nginx-gw' and 'k2s addons enable ingress nginx-gw'"
}

return $isIngressNginxGatewayRunningProp, $isExternalIPSetProp