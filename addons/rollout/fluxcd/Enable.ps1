# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs the rollout addon (Flux CD) in the cluster

.DESCRIPTION
The rollout addon utilizes Flux CD to provide GitOps continuous delivery for Kubernetes.
Flux automatically syncs applications from Git repositories to the cluster.

.EXAMPLE
Enable rollout with Flux in k2s
powershell <installation folder>\addons\rollout\fluxcd\Enable.ps1

Enable rollout addon with Flux and ingress nginx
powershell <installation folder>\addons\rollout\fluxcd\Enable.ps1 -Ingress "nginx"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Enable Ingress-Nginx Addon')]
    [ValidateSet('nginx', 'nginx-gw', 'traefik', 'none')]
    [string] $Ingress = 'none',
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override parameters')]
    [pscustomobject] $Config,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$nodeModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $nodeModule, $rolloutModule

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

Write-Log 'Check if Flux is already enabled'
if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd'})) -eq $true) {
    $errMsg = 'Addon rollout with Flux implementation is already enabled, nothing to do.'

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'argocd' })) -eq $true) {
    $errMsg = "Addon 'rollout argocd' is enabled. Disable it first to avoid conflicts."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Creating rollout namespace' -Console
(Invoke-Kubectl -Params 'create', 'namespace', 'rollout').Output | Write-Log

Write-Log 'Installing Flux addon' -Console
$kustomizationDir = Get-FluxConfig
(Invoke-Kubectl -Params 'apply', '-k', $kustomizationDir).Output | Write-Log

Write-Log 'Waiting for Flux controllers to be ready...' -Console
(Invoke-Kubectl -Params 'wait', '--for=condition=available', '--timeout=180s', 'deployment', '--all', '-n', 'rollout').Output | Write-Log

if ($Ingress -ne 'none') {
    Enable-IngressAddon -Ingress:$Ingress
}

&"$PSScriptRoot\Update.ps1"

Write-Log 'Installation of rollout addon with Flux finished.' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })

Write-Log 'Flux CD is now installed in the rollout namespace' -Console
Write-Log 'To use Flux, configure GitRepository and Kustomization CRDs' -Console
Write-Log 'Example: kubectl apply -f <your-flux-resources>.yaml' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
