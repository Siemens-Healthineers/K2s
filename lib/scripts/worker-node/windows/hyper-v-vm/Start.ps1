# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
    [string] $DnsAddresses = $(throw 'Argument missing: DnsAddresses')
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

if ($HideHeaders -eq $false) {
    Write-Log 'Starting Windows worker node on Hyper-V VM'
}

$WSL = Get-ConfigWslFlag
$switchname = ''

if ($WSL) {
    $switchname = Get-WslSwitchName
}
else {
    $switchname = Get-ControlPlaneNodeDefaultSwitchName
}

$hostname = Get-ConfigVMNodeHostname
$windowsVmName = Get-ConfigVMNodeHostname

$setupConfigRoot = Get-RootConfigk2s
$vfpRules = $setupConfigRoot.psobject.properties['vfprules-k2s'].value | ConvertTo-Json

$workerNodeStartParams = @{
    ResetHns = $false
    AdditionalHooksDir = $AdditionalHooksDir
    UseCachedK2sVSwitches = $false
    SkipHeaderDisplay = $HideHeaders
    SwitchName = $switchname
    VmName = $windowsVmName
    VfpRules = $vfpRules
    VmIpAddress = Get-WindowsVmIpAddress
    PodSubnetworkNumber = '1'
    Hostname = $hostname
    DnsServers = $DnsAddresses
}
Start-WindowsWorkerNodeOnNewVM @workerNodeStartParams

Invoke-Hook -HookName 'AfterWorkerNodeOnVMStart' -AdditionalHooksDir $AdditionalHooksDir

if ($HideHeaders -eq $false) {
    Write-Log 'Windows worker node on Hyper-V VM started'
}