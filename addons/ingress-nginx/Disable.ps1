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

$mainStopwatch = [system.diagnostics.stopwatch]::StartNew()

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

Write-Log "Check whether ingress-nginx addon is already disabled"
if ($null -eq (&$global:KubectlExe get namespace ingress-nginx --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling Ingress-Nginx' -Console
$ingressNginxConfig = Get-IngressNginxConfig
&$global:KubectlExe delete -f "$ingressNginxConfig" | Write-Log

&$global:KubectlExe delete ns 'ingress-nginx' | Write-Log

Remove-AddonFromSetupJson -Name 'ingress-nginx'

Write-Log 'Uninstallation of Ingress-Nginx finished' -Console
