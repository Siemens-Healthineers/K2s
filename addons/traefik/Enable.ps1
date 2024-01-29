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

if ((Test-IsAddonEnabled -Name 'traefik') -eq $true) {
    Write-Log "Addon 'traefik' is already enabled, nothing to do." -Console
    exit 0
}

if ((Test-IsAddonEnabled -Name 'ingress-nginx') -eq $true) {
    throw "Addon 'ingress-nginx' is enabled. Disable it first to avoid port conflicts."
}

if ((Test-IsAddonEnabled -Name 'gateway-nginx') -eq $true) {
    throw "Addon 'gateway-nginx' is enabled. Disable it first to avoid port conflicts."
}

Write-Log 'Installing Traefik Ingress controller' -Console
$traefikYamlDir = Get-TraefikYamlDir
&$global:BinPath\kubectl.exe create namespace traefik | Write-Log
&$global:BinPath\kubectl.exe apply -k "$traefikYamlDir" | Write-Log
$allPodsAreUp = Wait-ForPodsReady -Selector 'app.kubernetes.io/name=traefik' -Namespace 'traefik'

Write-Log "Setting $global:IP_Master as an external IP for traefik service" -Console
$patchJson = ''
if ($PSVersionTable.PSVersion.Major -gt 5) {
    $patchJson = '{"spec":{"externalIPs":["' + $global:IP_Master + '"]}}'
}
else {
    $patchJson = '{\"spec\":{\"externalIPs\":[\"' + $global:IP_Master + '\"]}}'
}
&$global:BinPath\kubectl.exe patch svc traefik -p "$patchJson" -n traefik | Write-Log

if ($allPodsAreUp) {
    Write-Log 'All traefik pods are up and ready.' -Console

    Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'traefik' })

    Write-Log 'Installation of Traefik addon finished.' -Console
}
else {
    Write-Error 'All traefik pods could not become ready. Please use kubectl describe for more details.'
    Log-ErrorWithThrow 'Installation of traefik addon failed'
}
