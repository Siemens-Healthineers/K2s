# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator


Param(
    [parameter(Mandatory = $false, HelpMessage = 'Number of processors for VM')]
    [string] $VmProcessors,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
    [switch] $UseCachedK2sVSwitches,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs
$kubePath = Get-KubePath

# make sure we are at the right place for executing this script
Set-Location $kubePath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Starting the control plane'
}

# set ConfigKey_LoggedInRegistry empty, since not logged in into registry after restart anymore
Set-ConfigLoggedInRegistry -Value ''
    
$ProgressPreference = 'SilentlyContinue'

$loopbackAdapter = Get-L2BridgeName
$dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $dnsServers = '8.8.8.8,8.8.4.4'
}

$controlPlaneStartParams = @{
    VmProcessors = $VmProcessors
    AdditionalHooksDir = $AdditionalHooksDir
    UseCachedK2sVSwitches = $UseCachedK2sVSwitches
    SkipHeaderDisplay = $SkipHeaderDisplay
    DnsServers = $dnsServers
}
Start-ControlPlaneNodeOnNewVM @controlPlaneStartParams

Start-WinHttpProxy
Start-WinDnsProxy

# change default policy in VM (after restart of VM always policy is changed automatically)
Write-Log 'Reconfiguring volatile settings in VM...'
(Invoke-CmdOnControlPlaneViaSSHKey 'sudo iptables --policy FORWARD ACCEPT').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey 'sudo sysctl fs.inotify.max_user_instances=8192').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey 'sudo sysctl fs.inotify.max_user_watches=524288').Output | Write-Log

# Set DNS proxy for all physical network interfaces on Windows host to the DNS proxy
Set-K2sDnsProxyForActivePhysicalInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter

Write-Log "K2s control plane node started."