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
    [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
    [switch] $ResetHns = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
    [switch] $UseCachedK2sVSwitches
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

if ($HideHeaders -eq $false) {
    Write-Log 'Starting Windows worker node on Windows host'
}

$loopbackAdapter = Get-L2BridgeName
$dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $dnsServers = '8.8.8.8,8.8.4.4'
}

$hostname = $env:COMPUTERNAME
$podSubnetworkNumber = '1'
$setupConfigRoot = Get-RootConfigk2s
$templateVfpRules = $setupConfigRoot.psobject.properties['vfprules-k2s'].value | ConvertTo-Json
$vfpRoutingRules = $templateVfpRules.Replace('__SUBNETWORK_NUMBER__', $podSubnetworkNumber)

$workerNodeStartParams = @{
    Hostname = $hostname
    ResetHns = $ResetHns
    AdditionalHooksDir = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    SkipHeaderDisplay = $HideHeaders
    VfpRoutingRules = $vfpRoutingRules
    PodSubnetworkNumber = $podSubnetworkNumber
    DnsServers = $dnsServers
}
Start-WindowsWorkerNodeOnWindowsHost @workerNodeStartParams

Write-Log 'Windows worker node on Windows host started.'