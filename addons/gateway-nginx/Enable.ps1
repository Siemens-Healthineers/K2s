# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs nginx kubernetes gateway

.DESCRIPTION
Installs nginx kubernetes gateway

#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use shared gateway')]
    [switch] $SharedGateway = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config
)

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# load global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
Import-Module $addonsModule

Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

if ((Test-IsAddonEnabled -Name "gateway-nginx") -eq $true) {
    Write-Log "Addon 'gateway-nginx' is already enabled, nothing to do." -Console
    exit 0
}

$existingServices = $(&$global:KubectlExe get deployment -n nginx-gateway -o yaml)
if ("$existingServices" -match 'nginx-gateway') {
    Write-Log 'gateway-nginx addon is already enabled.' -Console
    exit 0;
}

if ((Test-IsAddonEnabled -Name "ingress-nginx") -eq $true) {
    Log-ErrorWithThrow "Addon 'ingress-nginx' is enabled. Disable it first to avoid port conflicts."
}

if ((Test-IsAddonEnabled -Name "traefik") -eq $true) {
    Log-ErrorWithThrow "Addon 'traefik' is enabled. Disable it first to avoid port conflicts."
}

Write-Log 'Installing Gateway API' -Console
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\gateway-nginx\manifests\gateway-api-v1.0.0.yaml" | Write-Log

Write-Log 'Installing NGINX Kubernetes Gateway' -Console
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\gateway-nginx\manifests\crds" | Write-Log
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\gateway-nginx\manifests\nginx-gateway-fabric-v1.1.0.yaml" | Write-Log

# Access via 172.19.1.100
Write-Log "Setting $global:IP_Master as an external IP for NGINX Kubernetes Gateway service" -Console
$patchJson = ""
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $global:IP_Master + '"]}}'
} else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $global:IP_Master + '\"]}}'
}
$gatewayNginxSvc = 'nginx-gateway'
&$global:KubectlExe patch svc $gatewayNginxSvc -p "$patchJson" -n nginx-gateway | Write-Log

&$global:KubectlExe wait --timeout=60s --for=condition=Available -n nginx-gateway deployment/nginx-gateway
if (!$?) {
    Write-Error 'Not all pods could become ready. Please use kubectl describe for more details.'
    Log-ErrorWithThrow 'Installation of gateway-nginx addon failed.'
    exit 1
}

Write-Log 'gateway-nginx addon installed successfully' -Console
if ($SharedGateway) {
    &$global:KubectlExe apply -f "$global:KubernetesPath\addons\gateway-nginx\manifests\shared-gateway.yaml" | Write-Log

@"
                                        USAGE NOTES

 Gateway created: 'shared-gateway'

 Example HTTPRoute manifest:

 apiVersion: gateway.networking.k8s.io/v1beta1
 kind: HTTPRoute
 metadata:
   name: example-route
 spec:
   parentRefs:
   - name: shared-gateway
     namespace: nginx-gateway
   rules:
   - matches:
     - path:
         type: PathPrefix
         value: /example
     backendRefs:
     - name: example-service
       port: 80
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}
else {
@"
                                        USAGE NOTES

 Use 'gatewayClassName: nginx' to connect to nginx gateway controller
 
 Example Gateway manifest:

 apiVersion: gateway.networking.k8s.io/v1beta1
 kind: Gateway
 metadata:
   name: example-gateway
 spec:
   gatewayClassName: nginx
   listeners:
   - name: http
     protocol: HTTP
     port: 80
"@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

Copy-ScriptsToHooksDir -ScriptPaths $hookFilePaths
Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'gateway-nginx' })
