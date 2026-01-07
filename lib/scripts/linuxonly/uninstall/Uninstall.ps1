# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes the Linux-only K2s setup.

.DESCRIPTION
This script assists in the following actions for K2s:
- Removal of
-- VMs
-- virtual disks
-- virtual switches
-- config files
-- config entries
-- etc.

.PARAMETER SkipPurge
Specifies whether to skip the deletion of binaries, config files etc.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
    [switch] $SkipPurge = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false
)

$infraModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\addons\addons.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

if ($HideHeaders -eq $false) {
    Write-Log 'Uninstalling Linux-only K2s'
}

Invoke-AddonsHooks -HookType 'BeforeUninstall'

$ErrorActionPreference = 'Continue'

$controlPlaneParams = " -AdditionalHooksDir '$AdditionalHooksDir'"
if ($DeleteFilesForOfflineInstallation.IsPresent) {
    $controlPlaneParams += ' -DeleteFilesForOfflineInstallation'
}
if ($ShowLogs.IsPresent) {
    $controlPlaneParams += ' -ShowLogs'
}
if ($SkipPurge.IsPresent) {
    $controlPlaneParams += ' -SkipPurge'
}
& powershell.exe "$PSScriptRoot\..\..\control-plane\Uninstall.ps1" $controlPlaneParams

Remove-K2sHostsFromNoProxyEnvVar

Invoke-AddonsHooks -HookType 'AfterUninstall'

if ($HideHeaders -eq $false) {
    Write-Log 'K2s Linux-only uninstalled.'
}

# Refresh PATH for current session to avoid stale k2s entries
$env:PATH =
[Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [Environment]::GetEnvironmentVariable("Path", "User")

Save-k2sLogDirectory -RemoveVar

