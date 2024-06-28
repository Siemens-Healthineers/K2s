# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables Prometheus/Grafana monitoring features for the k2s cluster.

.DESCRIPTION
The "monitoring" addons enables Prometheus/Grafana monitoring features for the k2s cluster.

#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [ValidateSet('ingress-nginx', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$monitoringModule = "$PSScriptRoot\monitoring.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $monitoringModule

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'monitoring' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Name 'monitoring') -eq $true) {
    $errMsg = "Addon 'monitoring' is already enabled, nothing to do."

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

$manifestsPath = "$PSScriptRoot\manifests"

Write-Log 'Installing Kube Prometheus Stack' -Console
(Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\namespace.yaml").Output | Write-Log
(Invoke-Kubectl -Params 'create', '-f', "$manifestsPath\crds").Output | Write-Log
(Invoke-Kubectl -Params 'create', '-k', $manifestsPath).Output | Write-Log

Write-Log 'Waiting for Pods..'
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', 'monitoring', '--timeout=180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Kube Prometheus Stack could not be deployed!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', 'monitoring', '--timeout=180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Kube Prometheus Stack could not be deployed!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonsets', '-n', 'monitoring', '--timeout=180s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Kube Prometheus Stack could not be deployed!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# traefik uses crd, so we have define ingressRoute after traefik has been enabled
if (Test-TraefikIngressControllerAvailability) {
    (Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\plutono\traefik.yaml").Output | Write-Log
}
elseif (Test-NginxIngressControllerAvailability) {
    (Invoke-Kubectl -Params 'apply', '-f', "$manifestsPath\plutono\ingress.yaml").Output | Write-Log
}

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'monitoring' })

Write-Log 'Kube Prometheus Stack installed successfully'

Write-UsageForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}