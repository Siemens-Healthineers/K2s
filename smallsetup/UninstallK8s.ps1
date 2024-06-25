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
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$installationPath = Get-KubePath
Set-Location $installationPath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Uninstalling kubernetes system'
}

# stop nodes
Write-Log 'First stop complete kubernetes incl. VM'
& "$PSScriptRoot\StopK8s.ps1" -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay

Write-Log 'Uninstalling Windows worker node' -Console
Remove-WindowsWorkerNodeOnWindowsHost -SkipPurge:$SkipPurge -AdditionalHooksDir $AdditionalHooksDir -SkipHeaderDisplay:$SkipHeaderDisplay

$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
Write-Log "Uninstalling $controlPlaneVMHostName VM" -Console
Remove-ControlPlaneNodeOnNewVM -SkipPurge:$SkipPurge -AdditionalHooksDir $AdditionalHooksDir -SkipHeaderDisplay:$SkipHeaderDisplay -DeleteFilesForOfflineInstallation:$DeleteFilesForOfflineInstallation

if (!$SkipPurge) {
    Uninstall-Cluster
}

Remove-KubeNodeBaseImage -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Invoke-AddonsHooks -HookType 'AfterUninstall'

Write-Log 'Uninstalling K2s setup done.'

Save-k2sLogDirectory -RemoveVar