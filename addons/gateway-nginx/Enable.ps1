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
  [pscustomobject] $Config,
  [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
  [switch] $EncodeStructuredOutput,
  [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
  [string] $MessageType
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
. $PSScriptRoot\Common.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule, $cliMessagesModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability
if ($systemError) {
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
    return
  }

  Write-Log $systemError -Error
  exit 1
}

if ((Test-IsAddonEnabled -Name 'gateway-nginx') -eq $true -or "$(&$global:KubectlExe get deployment -n nginx-gateway -o yaml)" -match 'nginx-gateway') {
  Write-Log "Addon 'gateway-nginx' is already enabled, nothing to do." -Console

  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
  }
  
  exit 0
}

if ((Test-IsAddonEnabled -Name 'ingress-nginx') -eq $true) {
  $errMsg = "Addon 'ingress-nginx' is enabled. Disable it first to avoid port conflicts."

  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
    return
  }

  Write-Log $errMsg -Error
  exit 1
}

if ((Test-IsAddonEnabled -Name 'traefik') -eq $true) {
  $errMsg = "Addon 'traefik' is enabled. Disable it first to avoid port conflicts."
  
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
    return
  }

  Write-Log $errMsg -Error
  exit 1
}

Write-Log 'Installing Gateway API' -Console
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\gateway-nginx\manifests\gateway-api-v1.0.0.yaml" | Write-Log

Write-Log 'Installing NGINX Kubernetes Gateway' -Console
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\gateway-nginx\manifests\crds" | Write-Log
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\gateway-nginx\manifests\nginx-gateway-fabric-v1.1.0.yaml" | Write-Log

# Access via 172.19.1.100
Write-Log "Setting $global:IP_Master as an external IP for NGINX Kubernetes Gateway service" -Console
$patchJson = ''
if ($PSVersionTable.PSVersion.Major -gt 5) {
  $patchJson = '{"spec":{"externalIPs":["' + $global:IP_Master + '"]}}'
}
else {
  $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $global:IP_Master + '\"]}}'
}
$gatewayNginxSvc = 'nginx-gateway'
&$global:KubectlExe patch svc $gatewayNginxSvc -p "$patchJson" -n nginx-gateway | Write-Log

&$global:KubectlExe wait --timeout=60s --for=condition=Available -n nginx-gateway deployment/nginx-gateway
if (!$?) {
  $errMsg = 'Not all pods could become ready. Please use kubectl describe for more details.'
  
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
    return
  }

  Write-Log $errMsg -Error
  exit 1
}

Write-Log 'gateway-nginx addon installed successfully' -Console
if ($SharedGateway) {
  &$global:KubectlExe apply -f "$global:KubernetesPath\addons\gateway-nginx\manifests\shared-gateway.yaml" | Write-Log

  @'
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
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}
else {
  @'
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
'@ -split "`r`n" | ForEach-Object { Write-Log $_ -Console }
}

Copy-ScriptsToHooksDir -ScriptPaths $hookFilePaths
Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'gateway-nginx' })

if ($EncodeStructuredOutput -eq $true) {
  Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}