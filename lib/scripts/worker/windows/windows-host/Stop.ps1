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
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
    [switch] $CacheK2sVSwitches
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$kubePath = Get-KubePath
Set-Location $kubePath

$ProgressPreference = 'SilentlyContinue'

$workerNodeStopParams = @{
    AdditionalHooksDir = $AdditionalHooksDir
    CacheK2sVSwitches  = $CacheK2sVSwitches
    SkipHeaderDisplay  = $HideHeaders
    PodSubnetworkNumber   = '1'
}
Stop-WindowsWorkerNodeOnWindowsHost @workerNodeStopParams

