# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls Kubernetes Dashboard UI

.DESCRIPTION

.EXAMPLE
Disable Dashboard
powershell <installation folder>\addons\dashboard\Disable.ps1
#>

Param (
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

Write-Log 'Check whether dashboard addon is already disabled' -Console
if ($null -eq (kubectl get namespace kubernetes-dashboard --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling Kubernetes dashboard' -Console
$dashboardConfig = Get-DashboardConfig
$dashboardNginxIngressConfig = Get-DashboardNginxConfig
kubectl delete -f $dashboardConfig
kubectl delete -f $dashboardNginxIngressConfig --ignore-not-found
Remove-AddonFromSetupJson -Name 'dashboard'
Write-Log 'Uninstallation of Kubernetes dashboard finished' -Console