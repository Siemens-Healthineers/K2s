# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Uninstalls Kubernetes Metrics Server

.DESCRIPTION
NA

.EXAMPLE
# For k2sSetup.
powershell <installation folder>\addons\metrics-server\Disable.ps1
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
. $PSScriptRoot\Common.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

Write-Log "Check whether traefik addon is already disabled"
if ($null -eq (&$global:KubectlExe get namespace traefik --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling Traefik addon' -Console
$traefikYamlDir = Get-TraefikYamlDir
&$global:KubectlExe delete -k "$traefikYamlDir" | Write-Log
&$global:KubectlExe delete namespace traefik | Write-Log
Remove-AddonFromSetupJson -Name 'traefik'
Write-Log 'Uninstallation of Traefik addon finished' -Console
