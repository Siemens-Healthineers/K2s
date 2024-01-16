# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1

kubectl wait --timeout=5s --for=condition=Available -n traefik deployment/traefik 2>&1 | Out-Null

$isTraefikRunningProp = @{Name = 'isTraefikRunningProp'; Value = $?; Okay = $? }
if ($isTraefikRunningProp.Value -eq $true) {
    $isTraefikRunningProp.Message = 'The traefik ingress controller is working'
}
else {
    $isTraefikRunningProp.Message = "The traefik ingress controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable traefik' and 'k2s addons enable traefik'"
} 

$externalIp = kubectl get service traefik -n traefik -o jsonpath="{.spec.externalIPs[0]}"

$isExternalIPSetProp = @{Name = 'isExternalIPSetProp'; Value = ($externalIp -eq $global:IP_Master); Okay = ($externalIp -eq $global:IP_Master) }
if ($isExternalIPSetProp.Value -eq $true) {
    $isExternalIPSetProp.Message = "The external IP for traefik service is set to $global:IP_Master"
}
else {
    $isExternalIPSetProp.Message = "The external IP for traefik service is not set properly. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable traefik' and 'k2s addons enable traefik'"
}

return $isTraefikRunningProp, $isExternalIPSetProp