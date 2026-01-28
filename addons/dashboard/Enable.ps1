# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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

Enable Dashboard in k2s with nginx addon and metrics server addon
powershell <installation folder>\addons\dashboard\Enable.ps1 -Ingress "nginx" -EnableMetricsServer
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Enable ingress addon')]
    [ValidateSet('nginx', 'nginx-gw', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'Enable metrics addon')]
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
$dashboardModule = "$PSScriptRoot\dashboard.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $dashboardModule

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

$setupInfo = Get-SetupInfo
if ($setupInfo.Name -ne 'k2s') {
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'dashboard' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'dashboard' })) -eq $true) {
    $errMsg = "Addon 'dashboard' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

if ($EnableMetricsServer) {
    Enable-MetricsServer
}

Write-Log 'Installing dashboard from helm chart' -Console
$dashboardChartDirectory = Get-DashboardChartDirectory
# create the namespace dashboard
(Invoke-Kubectl -Params 'create', 'namespace', 'dashboard').Output | Write-Log

# apply the chart
$dashboardChart = "$dashboardChartDirectory/kubernetes-dashboard-7.14.0.tgz"
$dashboardValues = "$dashboardChartDirectory/values.yaml"
(Invoke-Helm -Params 'install', 'kubernetes-dashboard', $dashboardChart, '--namespace', 'dashboard', '-f', $dashboardValues).Output | Write-Log 

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

# create the service account
$dashboardServiceAccount = "$dashboardChartDirectory/dashboard-service-account.yaml"
(Invoke-Kubectl -Params 'apply' , '-f', $dashboardServiceAccount).Output | Write-Log

# If nginx-gw ingress is being used, create the kong CA certificate ConfigMap for BackendTLSPolicy
if ($Ingress -eq 'nginx-gw') {
    Write-Log 'Configuring BackendTLSPolicy certificate validation for nginx-gw' -Console
    New-KongCACertConfigMap
}

&"$PSScriptRoot\Update.ps1"

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'dashboard' })

Write-DashboardUsageForUser
Write-BrowserWarningForUser

Write-Log 'Installation of Kubernetes dashboard finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}