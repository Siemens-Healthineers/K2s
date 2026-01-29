# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs Kubernetes Metrics Server

.DESCRIPTION
NA

.EXAMPLE
# For k2s setup
powershell <installation folder>\addons\metrics\Enable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
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
$metricsModule = "$PSScriptRoot\metrics.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $metricsModule

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

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'metrics' })) -eq $true) {
    $errMsg = "Addon 'metrics' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing Kubernetes Metrics Server' -Console
(Invoke-Kubectl -Params 'apply', '-f', (Get-MetricsServerConfig)).Output | Write-Log

Write-Log 'Deploying Windows Exporter for Windows node metrics' -Console
$windowsExporterPath = "$PSScriptRoot\..\common\manifests\windows-exporter"
(Invoke-Kubectl -Params 'apply', '-k', $windowsExporterPath).Output | Write-Log

$allPodsAreUp = (Wait-ForPodCondition -Condition Ready -Label 'k8s-app=metrics-server' -Namespace 'metrics' -TimeoutSeconds 120)

if ($allPodsAreUp -ne $true) {
    $errMsg = "All metric server pods could not become ready. Please use kubectl describe for more details.`nInstallation of metrics-server failed."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1  
}

&"$PSScriptRoot\Update.ps1"

Write-Log 'All metric server pods are up and ready.' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'metrics' })

Write-Log 'Installation of Kubernetes Metrics Server finished.' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}