# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables k2s-registry in the cluster

.DESCRIPTION
The local regsitry allows to push/pull images to/from the local volume of KubeMaster.
Each node inside the cluster can connect to the registry.

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\registry\Disable.ps1
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Delete local image storage')]
    [switch] $DeleteImages = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryFunctionsModule = "$PSScriptRoot\..\..\smallsetup\helpers\RegistryFunctions.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule, $registryFunctionsModule -DisableNameChecking

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

Write-Log "Check whether registry addon is already disabled"
if ($null -eq (&$global:KubectlExe get namespace registry --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling Kubernetes registry' -Console

&$global:KubectlExe delete -f "$global:KubernetesPath\addons\registry\manifests\k2s-registry.yaml" | Write-Log

&$global:KubectlExe delete secret k2s-registry | Write-Log
&$global:KubectlExe delete namespace registry | Write-Log

if ($DeleteImages) {
    ExecCmdMaster 'sudo rm -rf /registry'
}

#ExecCmdMaster "sudo rm -rf '/etc/containers/certs.d'"

#Remove-Item -Path "$env:programdata\docker\certs.d" -Force -Recurse -ErrorAction SilentlyContinue

Remove-AddonFromSetupJson -Name 'registry'
Remove-RegistryFromSetupJson -Name 'k2s.*' -IsRegex $true

Write-Log 'Uninstallation of Kubernetes registry finished' -Console

$loggedInRegistry = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry
if ($loggedInRegistry -match 'k2s-registry.*') {
    Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry -Value ''
}
