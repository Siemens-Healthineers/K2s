# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1

&$global:KubectlExe wait --timeout=5s --for=condition=Available -n nginx-gateway deployment/nginx-gateway 2>&1 | Out-Null

$isGatewayControllerRunningProp = @{Name = 'isGatewayControllerRunningProp'; Value = $?; Okay = $? }
if ($isGatewayControllerRunningProp.Value -eq $true) {
    $isGatewayControllerRunningProp.Message = 'The gateway API controller is working'
}
else {
    $isGatewayControllerRunningProp.Message = "The gateway API controller is not working. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gateway-nginx' and 'k2s addons enable gateway-nginx'"
} 

$externalIp = &$global:KubectlExe get service nginx-gateway -n nginx-gateway -o jsonpath="{.spec.externalIPs[0]}"

$isExternalIPSetProp = @{Name = 'isExternalIPSetProp'; Value = ($externalIp -eq $global:IP_Master); Okay = ($externalIp -eq $global:IP_Master) }
if ($isExternalIPSetProp.Value -eq $true) {
    $isExternalIPSetProp.Message = "The external IP for gateway API service is set to $global:IP_Master"
}
else {
    $isExternalIPSetProp.Message = "The external IP for gateway API service is not set properly. Try restarting the cluster with 'k2s start' or disable and re-enable the addon with 'k2s addons disable gateway-nginx' and 'k2s addons enable gateway-nginx'"
}

return $isGatewayControllerRunningProp, $isExternalIPSetProp