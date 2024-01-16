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

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# load global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1
# load common module for installing/uninstalling kubernetes dashboard
. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"
Import-Module $addonsModule


Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

Write-Log "Check whether traefik addon is already disabled"
if ($null -eq (kubectl get namespace traefik --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling Traefik addon' -Console
$traefikYamlDir = Get-TraefikYamlDir
&$global:BinPath\kubectl.exe delete -k "$traefikYamlDir" | Write-Log
&$global:BinPath\kubectl.exe delete namespace traefik | Write-Log
Remove-AddonFromSetupJson -Name 'traefik'
Write-Log 'Uninstallation of Traefik addon finished' -Console
