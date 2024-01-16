# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1

kubectl wait --timeout=5s --for=condition=Available -n ingress-nginx deployment/ingress-nginx-controller 2>&1 | Out-Null

$isIngressNginxRunningProp = @{Name = 'isIngressNginxRunningProp'; Value = $?; Okay = $? }
if ($isIngressNginxRunningProp.Value -eq $true) {
    $isIngressNginxRunningProp.Message = 'The ingress-nginx ingress controller is working'
}
else {
    $isIngressNginxRunningProp.Message = "The ingress-nginx ingress controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable ingress-nginx' and 'k2s addons enable ingress-nginx'"
} 

$externalIp = kubectl get service ingress-nginx-controller -n ingress-nginx -o jsonpath="{.spec.externalIPs[0]}"

$isExternalIPSetProp = @{Name = 'isExternalIPSetProp'; Value = ($externalIp -eq $global:IP_Master); Okay = ($externalIp -eq $global:IP_Master) }
if ($isExternalIPSetProp.Value -eq $true) {
    $isExternalIPSetProp.Message = "The external IP for ingress-nginx service is set to $global:IP_Master"
}
else {
    $isExternalIPSetProp.Message = "The external IP for ingress-nginx service is not set properly. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable ingress-nginx' and 'k2s addons enable ingress-nginx'"
}

return $isIngressNginxRunningProp, $isExternalIPSetProp