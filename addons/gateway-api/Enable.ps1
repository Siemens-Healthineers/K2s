# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs nginx kubernetes gateway controller

.DESCRIPTION
Installs nginx kubernetes gateway controller

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
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
  if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
    return
  }

  Write-Log $systemError.Message -Error
  exit 1
}

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
  $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'gateway-api' can only be enabled for 'k2s' setup type."  
  Send-ToCli -MessageType $MessageType -Message @{Error = $err }
  return
}

if ((Test-IsAddonEnabled -Name 'gateway-api') -eq $true -or "$((Invoke-Kubectl -Params 'get', 'deployment', '-n', 'gateway-api' ,'-o', 'yaml').Output)" -match 'gateway-api') {
  $errMsg = "Addon 'gateway-api' is already enabled, nothing to do."

  if ($EncodeStructuredOutput -eq $true) {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }
    
  Write-Log $errMsg -Error
  exit 1
}

if ((Test-IsAddonEnabled -Name 'ingress') -eq $true) {
  $errMsg = "Addon 'ingress' is enabled. Disable it first to avoid port conflicts."

  if ($EncodeStructuredOutput -eq $true) {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }

  Write-Log $errMsg -Error
  exit 1
}

$manifestsPath = "$(Get-KubePath)\addons\gateway-api\manifests"

Write-Log 'Installing Gateway API' -Console
(Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\gateway-api-v1.0.0.yaml").Output | Write-Log

Write-Log 'Installing NGINX Kubernetes Gateway' -Console
(Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\crds").Output | Write-Log
(Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\nginx-gateway-fabric-v1.1.0.yaml").Output | Write-Log

$controlPlaneIp = Get-ConfiguredIPControlPlane

Write-Log "Setting $controlPlaneIp as an external IP for NGINX Kubernetes Gateway service" -Console
$patchJson = ''
if ($PSVersionTable.PSVersion.Major -gt 5) {
  $patchJson = '{"spec":{"externalIPs":["' + $controlPlaneIp + '"]}}'
}
else {
  $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $controlPlaneIp + '\"]}}'
}
$gatewayNginxSvc = 'gateway-nginx'
(Invoke-Kubectl -Params 'patch', 'svc', $gatewayNginxSvc , '-p', "$patchJson", '-n', 'gateway-api').Output | Write-Log

$kubectlCmd = (Invoke-Kubectl -Params 'wait', '--timeout=60s', '--for=condition=Available', '-n', 'gateway-api', 'deployment/nginx-gateway')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
  $errMsg = 'Not all pods could become ready. Please use kubectl describe for more details.'
  
  if ($EncodeStructuredOutput -eq $true) {
    $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
  }

  Write-Log $errMsg -Error
  exit 1
}

Write-Log 'gateway-api addon installed successfully' -Console
if ($SharedGateway) {
  Add-HostEntries -Url 'k2s-gateway.local'
  (Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\shared-gateway.yaml").Output | Write-Log

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
namespace: gateway-api
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

Copy-ScriptsToHooksDir -ScriptPaths @(Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.FullName })
Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'gateway-api' })

if ($EncodeStructuredOutput -eq $true) {
  Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}