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
$temporaryIsolatedCalledScriptsModule = "$PSScriptRoot\ps-modules\only-while-refactoring\installation\still-to-merge.isolatedcalledscripts.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule, $temporaryIsolatedCalledScriptsModule

Initialize-Logging -ShowLogs:$ShowLogs
Set-LoggingPreferencesIntoScriptsIsolationModule -ShowLogs:$ShowLogs -AppendLogFile:$true

# make sure we are at the right place for executing this script
$installationPath = Get-KubePath
Set-Location $installationPath
Set-InstallationPathIntoScriptsIsolationModule -Value $installationPath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Uninstalling kubernetes system'
}

# stop services
Write-Log 'First stop complete kubernetes incl. VM'
& "$PSScriptRoot\StopK8s.ps1" -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay

Write-Log 'Remove external switch'
Remove-ExternalSwitch

$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
Write-Log "Uninstalling $controlPlaneVMHostName VM" -Console

Invoke-Script_UninstallKubeMaster -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Uninstall-WinNode -ShallowUninstallation $SkipPurge

Uninstall-LoopbackAdapter

Write-Log 'Cleaning up' -Console

Write-Log 'Remove previous VM key from known_hosts file'
$ipControlPlane = Get-ConfiguredIPControlPlane
ssh-keygen.exe -R $ipControlPlane 2>&1 | % { "$_" } | Out-Null

Invoke-AddonsHooks -HookType 'AfterUninstall'

if (!$SkipPurge) {
    Uninstall-Cluster
    Remove-SshKey
}

Clear-WinNode -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Reset-EnvVars

Write-Log 'Uninstalling K2s setup done.'

Save-k2sLogDirectory -RemoveVar