# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls the rollout addons (ArgoCD) in the cluster

.DESCRIPTION
The rollout addons utilizes ArgoCD to provide the user with the possibility 
to automate the deployment of application based on Git repositories. The addon can 
either be used by directly accessing the argocd cli or using the exposed web interface.

.EXAMPLE
Disable rollout addon in k2s
powershell <installation folder>\addons\rollout\Disable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
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

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'rollout', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'rollout' })) -ne $true) {
    $errMsg = "Addon 'rollout' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling rollout addon' -Console
$rolloutConfig = Get-RolloutConfig

(Invoke-Kubectl -Params 'delete', '-n', 'rollout', '-k', $rolloutConfig).Output | Write-Log

(Invoke-Kubectl -Params 'delete', 'namespace', 'rollout').Output | Write-Log

$binPath = Get-KubeBinPath
Remove-Item "$binPath\argocd.exe" -Force -ErrorAction SilentlyContinue

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'rollout' })
Write-Log 'Uninstallation of rollout addon finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}