# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Kubernetes Metrics Server

.DESCRIPTION
NA

.EXAMPLE
# For k2sSetup.
powershell <installation folder>\addons\metrics-server\Enable.ps1

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
# load common module for installing/uninstalling kubernetes metrics server
. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"

Import-Module $addonsModule

Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

if ((Test-IsAddonEnabled -Name "metrics-server") -eq $true) {
    Write-Log "Addon 'metrics-server' is already enabled, nothing to do." -Console
    exit 0
}

Write-Log 'Installing Kubernetes Metrics Server' -Console
$metricServerConfig = Get-MetricsServerConfig
kubectl apply -f $metricServerConfig | Write-Log

$allPodsAreUp = Wait-ForPodsReady -Selector 'k8s-app=metrics-server' -Namespace 'kube-system'

if ($allPodsAreUp) {
    Write-Log 'All metric server pods are up and ready.' -Console

    Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'metrics-server' })

    Write-Log 'Installation of Kubernetes Metrics Server finished.' -Console
}
else {
    Write-Error 'All metric server pods could not become ready. Please use kubectl describe for more details.'
    Log-ErrorWithThrow 'Installation of metrics-server failed.'
}
