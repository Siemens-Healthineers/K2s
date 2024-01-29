# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls ingress nginx from the cluster

.DESCRIPTION
Ingress nginx is using k8s load balancer and is bound to the IP of the master machine.
It allows applications to register their ingress resources and handles incomming HTTP/HTPPS traffic.

.EXAMPLE
powershell <installation folder>\addons\ingress-nginx\Disable.ps1
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
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

Write-Log 'Check whether ingress-nginx addon is already disabled'
if ($null -eq (kubectl get namespace ingress-nginx --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling Ingress-Nginx' -Console
$ingressNginxConfig = Get-IngressNginxConfig
&$global:BinPath\kubectl.exe delete -f "$ingressNginxConfig" | Write-Log

&$global:BinPath\kubectl.exe delete ns 'ingress-nginx' | Write-Log

Remove-AddonFromSetupJson -Name 'ingress-nginx'

Write-Log 'Uninstallation of Ingress-Nginx finished' -Console
