# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with uninstalling a Windows system to be used for a mixed Linux/Windows Kubernetes cluster
This script is only valid for the K2s Setup !!!
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
    [switch] $SkipPurge = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$installationPath = Get-KubePath
Set-Location $installationPath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Uninstalling K2s'
}

Invoke-AddonsHooks -HookType 'BeforeUninstall'

$workerNodeParams = @{
    SkipPurge          = $SkipPurge
    ShowLogs           = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    SkipHeaderDisplay  = $SkipHeaderDisplay
}
& "$PSScriptRoot\..\..\worker\windows\windows-host\Uninstall.ps1" @workerNodeParams

$controlPlaneParams = @{
    SkipPurge                         = $SkipPurge
    ShowLogs                          = $ShowLogs
    AdditionalHooksDir                = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    SkipHeaderDisplay                 = $SkipHeaderDisplay
}
& "$PSScriptRoot\..\..\control-plane\Uninstall.ps1" @controlPlaneParams

if (!$SkipPurge) {
    Uninstall-Cluster
}

Remove-K2sHostsFromNoProxyEnvVar

Invoke-AddonsHooks -HookType 'AfterUninstall'

Write-Log 'K2s uninstalled.'

# Refresh PATH for current session to avoid stale k2s entries
$env:PATH =
[Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [Environment]::GetEnvironmentVariable("Path", "User")

Write-Log 'PATH refreshed for current PowerShell session after uninstall.'

Save-k2sLogDirectory -RemoveVar

