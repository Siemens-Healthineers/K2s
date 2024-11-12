# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator


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
    [switch] $SkipHeaderDisplay = $false,
    [string] $NodeName = $(throw 'Argument missing: NodeName')
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$installationPath = Get-KubePath
Set-Location $installationPath

$workerNodeName = $NodeName.ToLower()

Write-Log 'Stop the control plane'
& "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay:$SkipHeaderDisplay -NodeName $workerNodeName

Write-Log "Removing worker node '$workerNodeName' from the cluster..." -Console
Remove-LinuxWorkerNodeOnNewVM -AdditionalHooksDir $AdditionalHooksDir -SkipHeaderDisplay:$SkipHeaderDisplay -DeleteFilesForOfflineInstallation:$DeleteFilesForOfflineInstallation -NodeName $workerNodeName
Write-Log '  removed.' -Console

Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log
