# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator


Param(
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
    [switch] $SkipHeaderDisplay = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Indicates this is a single node start operation')]
    [switch] $SingleNode = $false,
    [switch] $ObtainCIDR = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

# Dot-source common Linux worker node functions
$linuxWorkerCommon = "$PSScriptRoot\..\..\common\LinuxWorkerNode.Common.ps1"
. $linuxWorkerCommon

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
    ObtainCIDR = $ObtainCIDR
}
Start-LinuxWorkerNode @workerNodeStartParams

# Restore kubelet/runtime services after route setup and wait for the node to become Ready.
# Include Hyper-V diagnostics for VM-based nodes
Invoke-LinuxWorkerNodeStart -NodeName $workerNodeName -WaitForReady -IncludeHyperVDiagnostics -LogPrefix '[existing-vm]'
