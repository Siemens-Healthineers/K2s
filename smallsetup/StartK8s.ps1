# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
This script is only valid for the K2s Setup installed with InstallK8s.ps1
It starts the kubernetes cluster again, after is has been stopped with StopK8s.ps1

.DESCRIPTION
t.b.d.
#>

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

$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs
$kubePath = Get-KubePath

# make sure we are at the right place for executing this script
Set-Location $kubePath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Starting K2s'
}

# set ConfigKey_LoggedInRegistry empty, since not logged in into registry after restart anymore
Set-ConfigLoggedInRegistry -Value ''
    
$ProgressPreference = 'SilentlyContinue'

Write-Log 'Starting Kubernetes System'

$loopbackAdapter = Get-L2BridgeName
$dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $dnsServers = '8.8.8.8'
}

$controlPlaneStartParams = @{
    VmProcessors          = $VmProcessors
    AdditionalHooksDir    = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    SkipHeaderDisplay     = $SkipHeaderDisplay
    DnsServers            = $dnsServers
}
Start-ControlPlaneNodeOnNewVM @controlPlaneStartParams

$workerNodeStartParams = @{
    ResetHns              = $ResetHns
    AdditionalHooksDir    = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    SkipHeaderDisplay     = $SkipHeaderDisplay
    DnsServers            = $dnsServers
    WorkerNodeNumber      = '1'
}
Start-WindowsWorkerNodeOnWindowsHost @workerNodeStartParams

# Set DNS proxy for all physical network interfaces on Windows host to the DNS proxy
Set-K2sDnsProxyForActivePhysicalInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter

Invoke-AddonsHooks -HookType 'AfterStart'

Write-Log 'Script StartK8s.ps1 finished'