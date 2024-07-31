# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
    [switch] $CacheK2sVSwitches,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$kubePath = Get-KubePath
Set-Location $kubePath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Stopping K2s'
}

$ProgressPreference = 'SilentlyContinue'

$workerNodeStopParams = @{
    AdditionalHooksDir = $AdditionalHooksDir
    CacheK2sVSwitches  = $CacheK2sVSwitches
    SkipHeaderDisplay  = $SkipHeaderDisplay
    PodSubnetworkNumber   = '1'
}
Stop-WindowsWorkerNodeOnWindowsHost @workerNodeStopParams

$controlPlaneStopParams = @{
    AdditionalHooksDir = $AdditionalHooksDir
    CacheK2sVSwitches  = $CacheK2sVSwitches
    SkipHeaderDisplay  = $SkipHeaderDisplay
}
Stop-ControlPlaneNodeOnNewVM @controlPlaneStopParams

Reset-DnsForActivePhysicalInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter

Write-Log '...Kubernetes system stopped.'

