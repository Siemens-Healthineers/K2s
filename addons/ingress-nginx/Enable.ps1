# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables ingress nginx in the cluster to the ingress-nginx namespace

.DESCRIPTION
Ingress nginx is using k8s load balancer and is bound to the IP of the master machine.
It allows applications to register their ingress resources and handles incoming HTTP/HTPPS traffic.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\ingress-nginx\Enable.ps1
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
. $PSScriptRoot\Common.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

Write-Log 'Checking if ingress nginx is already installed by us'
if ((Test-IsAddonEnabled -Name 'ingress-nginx') -eq $true) {
    Write-Log "Addon 'ingress-nginx' is already enabled, nothing to do." -Console
    exit 0
}

if ((Test-IsAddonEnabled -Name 'traefik') -eq $true) {
    throw "Addon 'traefik' is enabled. Disable it first to avoid port conflicts."
}

if ((Test-IsAddonEnabled -Name 'gateway-nginx') -eq $true) {
    throw "Addon 'gateway-nginx' is enabled. Disable it first to avoid port conflicts."
}

$existingServices = $(&$global:BinPath\kubectl.exe get service -n ingress-nginx -o yaml)
if ("$existingServices" -match '.*ingress-nginx-controller.*') {
    Write-Log 'It seems as if ingress nginx is already installed in the namespace ingress-nginx. Disable it before enabling it again.' -Console
    return 0;
}

Write-Log 'Installing ingress-nginx' -Console
$ingressNginxNamespace = 'ingress-nginx'
&$global:BinPath\kubectl.exe create ns $ingressNginxNamespace | Write-Log

$ingressNginxConfig = Get-IngressNginxConfig
&$global:BinPath\kubectl.exe apply -f "$ingressNginxConfig" | Write-Log

Write-Log "Setting $global:IP_Master as an external IP for ingress-nginx-controller service" -Console
$patchJson = ''
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $global:IP_Master + '"]}}'
}
else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $global:IP_Master + '\"]}}'
}
$ingressNginxSvc = 'ingress-nginx-controller'
&$global:BinPath\kubectl.exe patch svc $ingressNginxSvc -p "$patchJson" -n $ingressNginxNamespace | Write-Log

$allPodsAreUp = Wait-ForPodsReady -Selector 'app.kubernetes.io/name=ingress-nginx' -Namespace 'ingress-nginx'

if ($allPodsAreUp) {
    Write-Log 'All ingress-nginx pods are up and ready.'

    Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'ingress-nginx' })

    Write-Log 'ingress-nginx installed successfully' -Console
}
else {
    Write-Error 'All ingress-nginx pods could not become ready. Please use kubectl describe for more details.'
    Log-ErrorWithThrow 'Installation of ingress-nginx failed.'
}
