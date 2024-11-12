# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Number of processors for VM')]
    [string] $VmProcessors,
    [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
    [switch] $ResetHns = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
    [switch] $UseCachedK2sVSwitches,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs
$kubePath = Get-KubePath

# make sure we are at the right place for executing this script
Set-Location $kubePath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Starting K2s'
}
    
$ProgressPreference = 'SilentlyContinue'

Write-Log 'Starting Kubernetes System'

$loopbackAdapter = Get-L2BridgeName
$dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $dnsServers = '8.8.8.8,8.8.4.4'
}

$controlPlaneParams = @{
    VmProcessors = $VmProcessors
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    SkipHeaderDisplay = $SkipHeaderDisplay
    DnsAddresses = $dnsServers
}
& "$PSScriptRoot\..\..\control-plane\Start.ps1" @controlPlaneParams

$workerNodeParams = @{
    HideHeaders = $SkipHeaderDisplay
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    ResetHns = $ResetHns
    DnsAddresses = $dnsServers
}
& "$PSScriptRoot\..\..\worker-node\windows\windows-host\Start.ps1" @workerNodeParams

Invoke-AddonsHooks -HookType 'AfterStart'

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'K2s started.'
}