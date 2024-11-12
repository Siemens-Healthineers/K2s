# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator


Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false
)


$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\addons\addons.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$kubePath = Get-KubePath
Set-Location $kubePath

$ErrorActionPreference = 'Continue'

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Uninstalling Windows worker node on Hyper-V VM'
}

$WSL = Get-ConfigWslFlag
$switchname = ''

if ($WSL) {
    $switchname = Get-WslSwitchName
}
else {
    $switchname = Get-ControlPlaneNodeDefaultSwitchName
}

Write-Log 'Stop the Windows worker node on Hyper-V VM'
&"$PSScriptRoot\Stop.ps1" -HideHeaders:$false -ShowLogs:$ShowLogs -AdditionalHooksDir:$AdditionalHooksDir

$vmName = $(Get-ConfigVMNodeHostname)
$podSubnetworkNumber = '1'
Write-Log 'Remove the worker node on Hyper-V VM'
Remove-WindowsWorkerNodeOnNewVM -VmName $vmName -AdditionalHooksDir $AdditionalHooksDir -SkipHeaderDisplay:$SkipHeaderDisplay -PodSubnetworkNumber $podSubnetworkNumber -SwitchName $switchname -DeleteFilesForOfflineInstallation:$DeleteFilesForOfflineInstallation

Invoke-AddonsHooks -HookType 'AfterUninstall'

Invoke-Hook -HookName 'AfterWorkerNodeOnVMUninstall' -AdditionalHooksDir $AdditionalHooksDir

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Windows worker node on Hyper-V VM uninstalled.'
}

