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

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
# load common module for installing/uninstalling ingress-nginx
. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"

Import-Module $addonsModule

Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

Write-Log 'Checking if ingress nginx is already installed by us'
if ((Test-IsAddonEnabled -Name "ingress-nginx") -eq $true) {
    Write-Log "Addon 'ingress-nginx' is already enabled, nothing to do." -Console
    exit 0
}

if ((Test-IsAddonEnabled -Name "traefik") -eq $true) {
    throw "Addon 'traefik' is enabled. Disable it first to avoid port conflicts."
}

if ((Test-IsAddonEnabled -Name "gateway-nginx") -eq $true) {
    throw "Addon 'gateway-nginx' is enabled. Disable it first to avoid port conflicts."
}

$existingServices = $(&$global:KubectlExe get service -n ingress-nginx -o yaml)
if ("$existingServices" -match '.*ingress-nginx-controller.*') {
    Write-Log 'It seems as if ingress nginx is already installed in the namespace ingress-nginx. Disable it before enabling it again.' -Console
    return 0;
}

Write-Log 'Installing ingress-nginx' -Console
$ingressNginxNamespace = 'ingress-nginx'
&$global:KubectlExe create ns $ingressNginxNamespace | Write-Log

$ingressNginxConfig = Get-IngressNginxConfig
&$global:KubectlExe apply -f "$ingressNginxConfig" | Write-Log

Write-Log "Setting $global:IP_Master as an external IP for ingress-nginx-controller service" -Console
$patchJson = ""
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $global:IP_Master + '"]}}'
} else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $global:IP_Master + '\"]}}'
}
$ingressNginxSvc = 'ingress-nginx-controller'
&$global:KubectlExe patch svc $ingressNginxSvc -p "$patchJson" -n $ingressNginxNamespace | Write-Log

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
