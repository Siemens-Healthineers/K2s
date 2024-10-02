# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the rollout addons (ArgoCD) in the cluster

.DESCRIPTION
The rollout addons utilizes ArgoCD to provide the user with the possibility 
to automate the deployment of application based on Git repositories. The addon can 
either be used by directly accessing the argocd cli or using the exposed web interface.

.EXAMPLE
Enable rollout in k2s
powershell <installation folder>\addons\rollout\Enable.ps1

Enable rollout addon in k2s with ingress nginx addon
powershell <installation folder>\addons\rollout\Enable.ps1 -Ingress "nginx"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Enable Ingress-Nginx Addon')]
    [ValidateSet('nginx', 'traefik', 'none')]
    [string] $Ingress = 'none',
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
$addonsIngressModule = "$PSScriptRoot\..\addons.ingress.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $addonsIngressModule, $nodeModule, $rolloutModule

Initialize-Logging -ShowLogs:$ShowLogs

$Proxy = Get-OrUpdateProxyServer -Proxy:$Proxy

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
    $err = New-Error -Severity Warning -Code (Get-ErrCodeWrongSetupType) -Message "Addon 'rollout' can only be enabled for 'k2s' setup type."  
    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
    return
}

if ((Test-IsAddonEnabled -Addon ([PSCustomObject]@{Name = 'rollout'})) -eq $true) {
    $errMsg = "Addon 'rollout' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

$rolloutNamespace = 'rollout'

$VERSION_ARGOCD = 'v2.12.1'

Write-Log 'Creating rollout namespace'
(Invoke-Kubectl -Params 'create', 'namespace', $rolloutNamespace).Output | Write-Log

Write-Log 'Installing rollout addon' -Console
$rolloutConfig = Get-RolloutConfig
(Invoke-Kubectl -Params 'apply' , '-n', $rolloutNamespace, '-k', $rolloutConfig).Output | Write-Log

Update-IngressForAddon -Addon ([pscustomobject] @{Name = 'rollout' })

Write-Log 'Waiting for pods being ready...' -Console

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'deployments', '-n', $rolloutNamespace, '--timeout=300s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'rollout addon could not be deployed successfully!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'statefulsets', '-n', $rolloutNamespace, '--timeout=300s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'rollout addon (ArgoCD application controller) could not be deployed successfully'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

(Invoke-Kubectl -Params 'delete', 'secret', 'argocd-initial-secret', '-n', $rolloutNamespace).Output | Write-Log

Write-Log 'Installation of rollout addon finished.' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'rollout' })

Write-UsageForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}