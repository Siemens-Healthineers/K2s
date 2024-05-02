# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls security

.DESCRIPTION

.EXAMPLE
Disable security addon
powershell <installation folder>\addons\security\Disable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$securityModule = "$PSScriptRoot\security.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $securityModule

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

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'cert-manager', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Name 'security') -ne $true) {
    $errMsg = "Addon 'security' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling security' -Console
$certManagerConfig = Get-CertManagerConfig
$caIssuerConfig = Get-CAIssuerConfig

(Invoke-Kubectl -Params 'delete', '-f', $caIssuerConfig).Output | Write-Log
(Invoke-Kubectl -Params 'delete', '-f', $certManagerConfig).Output | Write-Log

Remove-Cmctl
Remove-AddonFromSetupJson -Name 'security'

Write-Log 'Uninstallation of security finished' -Console

Write-WarningForUser

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}