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
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$commonModule = "$PSScriptRoot\common.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $commonModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

if ((Test-IsAddonEnabled -Name 'dashboard') -eq $true) {
    $errMsg = "Addon 'dashboard' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing Kubernetes dashboard' -Console
$dashboardConfig = Get-DashboardConfig
(Invoke-Kubectl -Params 'apply' , '-f', $dashboardConfig).Output | Write-Log

Write-Log 'Checking Dashboard status' -Console
$dashboardStatus = Wait-ForDashboardAvailable

if ($dashboardStatus -ne $true) {
    $errMsg = "All dashboard pods could not become ready. Please use kubectl describe for more details.`nInstallation of Kubernetes dashboard failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'dashboard' })

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

Write-Log 'Installation of Kubernetes dashboard finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}