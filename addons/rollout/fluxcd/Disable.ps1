# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes the rollout addon (Flux CD) from the cluster

.DESCRIPTION
Uninstalls Flux CD controllers and removes the rollout namespace

.EXAMPLE
Disable rollout with Flux
powershell <installation folder>\addons\rollout\fluxcd\Disable.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\addons.module.psm1"
$rolloutModule = "$PSScriptRoot\rollout.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $rolloutModule

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

if (-not (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd'}))) {
    $errMsg = 'Addon rollout with Flux implementation is already disabled, nothing to do.'

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling Flux addon' -Console

# Remove optional ingress manifests (silently skips if not present)
Remove-IngressForTraefik -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })
Remove-IngressForNginx -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })

Write-Log 'Uninstalling Flux resources...' -Console
$kustomizationDir = Get-FluxConfig
(Invoke-Kubectl -Params 'delete', '-k', $kustomizationDir).Output | Write-Log

Write-Log 'Deleting rollout namespace...' -Console
(Invoke-Kubectl -Params 'delete', 'namespace', 'rollout','--timeout', '60s').Output | Write-Log

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'rollout'; Implementation = 'fluxcd' })
Write-Log 'Uninstallation of rollout addon with Flux finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}
