# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls the updates addons (ArgoCD) in the cluster

.DESCRIPTION
The updates addons utilizes ArgoCD to provide the user with the possibility 
to automate the deployment of application based on Git repositories. The addon can 
either be used by directly accessing the argocd cli or using the exposed web interface.

.EXAMPLE
Disable updates addon in k2s
powershell <installation folder>\addons\updates\Disable.ps1
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
$updatesModule = "$PSScriptRoot\updates.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $updatesModule

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

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'updates', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'updates' })) -ne $true) {
    $errMsg = "Addon 'updates' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling updates addon' -Console
$UpdatesConfig = Get-UpdatesConfig

(Invoke-Kubectl -Params 'delete', '-n', 'updates', '-k', $UpdatesConfig).Output | Write-Log

(Invoke-Kubectl -Params 'delete', 'namespace', 'updates').Output | Write-Log

if (Test-TraefikIngressControllerAvailability) {
    $updatesDashboardTraefikIngressConfig = Get-UpdatesDashboardTraefikConfig
    (Invoke-Kubectl -Params 'delete', '-f', $updatesDashboardTraefikIngressConfig, '--ignore-not-found').Output | Write-Log
}
elseif (Test-NginxIngressControllerAvailability) {
    $updatesDashboardNginxIngressConfig = Get-UpdatesDashboardNginxConfig
    (Invoke-Kubectl -Params 'delete', '-f', $updatesDashboardNginxIngressConfig, '--ignore-not-found').Output | Write-Log
}

Remove-Item "$binPath\argocd.exe" -Force -ErrorAction SilentlyContinue

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'updates' })
Write-Log 'Uninstallation of updates addon finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}