# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$kubePath = Get-KubePath
Import-Module "$kubePath/addons/addons.module.psm1"

Write-Log 'Uninstalling small kubernetes'

if (! $SkipPurge) {
    # this negative logic is important to have the right defaults:
    # if UninstallK8s is called directly, the default is to purge
    # if UninstallK8s is called from InstallK8s, the default is not to purge
    $global:PurgeOnUninstall = $true
}

# make sure we are at the right place for executing this script
Set-Location $kubePath

if ($SkipHeaderDisplay -ne $true) {
    Write-Log 'Uninstalling kubernetes system'
}

# stop services
Write-Log 'First stop complete kubernetes incl. VM'
& $PSScriptRoot\..\stop\Stop.ps1 -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay

Uninstall-LinuxNode -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Uninstall-WinNode

Uninstall-LoopbackAdapter

Uninstall-Cluster

Clear-WinNode -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Remove-K2sHostsFromNoProxyEnvVar
Reset-EnvVars

Write-Log 'Uninstalling K2s setup done.'

Save-k2sLogDirectory -RemoveVar