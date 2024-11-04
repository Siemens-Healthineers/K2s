# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls Kubernetes Dashboard UI

.DESCRIPTION

.EXAMPLE
Disable Dashboard
powershell <installation folder>\addons\dashboard\Disable.ps1
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

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'dashboard', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'dashboard' })) -ne $true) {
    $errMsg = "Addon 'dashboard' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling Kubernetes dashboard' -Console
Remove-IngressForTraefik -Addon ([pscustomobject] @{Name = 'dashboard' })
Remove-IngressForNginx -Addon ([pscustomobject] @{Name = 'dashboard' })
$dashboardConfig = Get-DashboardConfig
(Invoke-Kubectl -Params 'delete', '-k', $dashboardConfig).Output | Write-Log

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'dashboard' })
Write-Log 'Uninstallation of Kubernetes dashboard finished' -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}