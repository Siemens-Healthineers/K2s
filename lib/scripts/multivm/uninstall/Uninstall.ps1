# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes the Multi-VM K8s setup.

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
Specifies whether to skipt the deletion of binaries, config files etc.

.EXAMPLE
PS> .\lib\scripts\multivm\uninstall\Uninstall.ps1
Files will be purged.

.EXAMPLE
PS> .\lib\scripts\multivm\uninstall\Uninstall.ps1 -SkipPurge
Purge is skipped.

.EXAMPLE
PS> .\lib\scripts\multivm\uninstall\Uninstall.ps1 -AdditonalHooks 'C:\AdditionalHooks'
For specifying additional hooks to be executed.
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

$ErrorActionPreference = 'Continue'

if ($(Get-ConfigLinuxOnly) -eq $true) {
    $installationType = 'Linux-only'
} else {
    $installationType = 'Multi-VM'
}

if ($HideHeaders -eq $false) {
    Write-Log "Uninstalling $installationType K2s"
}

if ($(Get-ConfigLinuxOnly) -eq $false) {
    $workerNodeParams = @{
        ShowLogs = $ShowLogs
        AdditionalHooksDir = $AdditionalHooksDir
        DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    }
    & "$PSScriptRoot\..\..\worker-node\windows\hyper-v-vm\Uninstall.ps1" @workerNodeParams
}

$controlPlaneParams = " -AdditionalHooksDir '$AdditionalHooksDir'"
if ($DeleteFilesForOfflineInstallation.IsPresent) {
    $controlPlaneParams += " -DeleteFilesForOfflineInstallation"
}
if ($ShowLogs.IsPresent) {
    $controlPlaneParams += " -ShowLogs"
}
if ($SkipPurge.IsPresent) {
    $controlPlaneParams += " -SkipPurge"
}
& powershell.exe "$PSScriptRoot\..\..\control-plane\Uninstall.ps1" $controlPlaneParams

Remove-K2sHostsFromNoProxyEnvVar

Invoke-AddonsHooks -HookType 'AfterUninstall'

if ($HideHeaders -eq $false) {
    Write-Log "K2s $installationType uninstalled."
}

Save-k2sLogDirectory -RemoveVar

