# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Kubernetes Dashboard UI

.DESCRIPTION
Dashboard is a web-based Kubernetes user interface. You can use Dashboard to:
- get an overview of applications running on your cluster
- deploy containerized applications to a Kubernetes cluster
- troubleshoot your containerized application

Dashboard also provides information on the state of Kubernetes resources in your cluster and on any errors that may have occurred.

.EXAMPLE
Enable Dashboard in k2s
powershell <installation folder>\addons\dashboard\Enable.ps1

Enable Dashboard in k2s with ingress-nginx addon and metrics server addon
powershell <installation folder>\addons\dashboard\Enable.ps1 -Ingress "ingress-nginx" -EnableMetricsServer
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Enable Ingress-Nginx Addon')]
    [ValidateSet('ingress-nginx', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'Enable metrics-server Addon')]
    [switch] $EnableMetricsServer = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config
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

if ((Test-IsAddonEnabled -Name "dashboard") -eq $true) {
    Write-Log "Addon 'dashboard' is already enabled, nothing to do." -Console
    exit 0
}

Write-Log 'Installing Kubernetes dashboard' -Console
$dashboardConfig = Get-DashboardConfig
kubectl apply -f $dashboardConfig

Write-Log 'Checking Dashboard status' -Console
$dashboardStatus = Wait-ForDashboardAvailable

if ($dashboardStatus) {
    Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'dashboard' })
    Write-Log 'Installation of Kubernetes dashboard finished.' -Console

    switch ($Ingress) {
        'ingress-nginx' {
            Write-Log 'Deploying ingress-nginx addon for external access to dashboard...' -Console
            Enable-IngressAddon
            break
        }
        'traefik' {
            Write-Log 'Deploying traefik addon for external access to dashboard...' -Console
            Enable-TraefikAddon
            break
        }
        'none' {
            Write-Log 'No ingress deployed...' -Console
        }
    }

    if ($EnableMetricsServer) {
        Enable-MetricsServer
    }

    Enable-ExternalAccessIfIngressControllerIsFound

    Write-UsageForUser
}
else {
    Write-Error 'All dashboard pods could not become ready. Please use kubectl describe for more details.'
    Write-Error 'Installation of Kubernetes dashboard failed.'
}
