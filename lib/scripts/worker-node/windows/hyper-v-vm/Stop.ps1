# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

param(
    [parameter(Mandatory = $false, HelpMessage = 'Set to TRUE to omit script headers.')]
    [switch] $HideHeaders = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = ''
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$kubePath = Get-KubePath
Set-Location $kubePath

$ErrorActionPreference = 'Continue'

if ($HideHeaders -eq $false) {
    Write-Log 'Stopping Windows worker node on Hyper-V VM'
}

$WSL = Get-ConfigWslFlag
$switchname = ''

if ($WSL) {
    $switchname = Get-WslSwitchName
}
else {
    $switchname = Get-ControlPlaneNodeDefaultSwitchName
}

$workerNodeStopParams = @{
    AdditionalHooksDir = $AdditionalHooksDir
    CacheK2sVSwitches = $false
    SkipHeaderDisplay = $HideHeaders
    PodSubnetworkNumber = '1'
    SwitchName = $switchname
}
Stop-WindowsWorkerNodeOnNewVM @workerNodeStopParams

Invoke-Hook -HookName 'AfterWorkerNodeOnVMStop' -AdditionalHooksDir $AdditionalHooksDir

if ($HideHeaders -eq $false) {
    Write-Log 'Windows worker node on Hyper-V VM stopped.'
}