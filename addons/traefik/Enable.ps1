# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Traefik Ingress Controller

.DESCRIPTION
NA

.EXAMPLE
# For k2sSetup.
powershell <installation folder>\addons\traefik\Enable.ps1

#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config
)

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# load global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
# load common module for installing/uninstalling traefik ingress controller
. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"

Import-Module $addonsModule


Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

if ((Test-IsAddonEnabled -Name "traefik") -eq $true) {
    Write-Log "Addon 'traefik' is already enabled, nothing to do." -Console
    exit 0
}

if ((Test-IsAddonEnabled -Name "ingress-nginx") -eq $true) {
    throw "Addon 'ingress-nginx' is enabled. Disable it first to avoid port conflicts."
}

if ((Test-IsAddonEnabled -Name "gateway-nginx") -eq $true) {
    throw "Addon 'gateway-nginx' is enabled. Disable it first to avoid port conflicts."
}

Write-Log 'Installing Traefik Ingress controller' -Console
$traefikYamlDir = Get-TraefikYamlDir
&$global:KubectlExe create namespace traefik | Write-Log
&$global:KubectlExe apply -k "$traefikYamlDir" | Write-Log
$allPodsAreUp = Wait-ForPodsReady -Selector 'app.kubernetes.io/name=traefik' -Namespace 'traefik'

Write-Log "Setting $global:IP_Master as an external IP for traefik service" -Console
$patchJson = ""
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $global:IP_Master + '"]}}'
} else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $global:IP_Master + '\"]}}'
}
&$global:KubectlExe patch svc traefik -p "$patchJson" -n traefik | Write-Log

if ($allPodsAreUp) {
    Write-Log 'All traefik pods are up and ready.' -Console

    Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'traefik' })

    Write-Log 'Installation of Traefik addon finished.' -Console
}
else {
    Write-Error 'All traefik pods could not become ready. Please use kubectl describe for more details.'
    Log-ErrorWithThrow 'Installation of traefik addon failed'
}
