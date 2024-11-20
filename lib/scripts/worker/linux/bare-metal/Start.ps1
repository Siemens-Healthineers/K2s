# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator


Param(
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [switch] $ShowLogs = $false,
    [string] $AdditionalHooksDir = '',
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs
$kubePath = Get-KubePath

# make sure we are at the right place for executing this script
Set-Location $kubePath

$ProgressPreference = 'SilentlyContinue'

$workerNodeName = $NodeName.ToLower()

$workerNodeStartParams = @{
    AdditionalHooksDir = $AdditionalHooksDir
    SkipHeaderDisplay = $SkipHeaderDisplay
    IpAddress = $IpAddress
    NodeName = $workerNodeName
}
Start-LinuxWorkerNodeOnUbuntuBareMetal @workerNodeStartParams
