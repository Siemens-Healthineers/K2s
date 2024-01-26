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

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# load global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
# load common module for installing/uninstalling kubernetes dashboard
. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"
Import-Module $addonsModule

Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

Write-Log "Check whether dashboard addon is already disabled" -Console
if ($null -eq (&$global:KubectlExe get namespace kubernetes-dashboard --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling Kubernetes dashboard' -Console
$dashboardConfig = Get-DashboardConfig
$dashboardNginxIngressConfig = Get-DashboardNginxConfig
&$global:KubectlExe delete -f $dashboardConfig
&$global:KubectlExe delete -f $dashboardNginxIngressConfig --ignore-not-found
Remove-AddonFromSetupJson -Name 'dashboard'
Write-Log 'Uninstallation of Kubernetes dashboard finished' -Console