# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Target machine IP address')]
    [string] $IpAddress,  # Add this parameter
    [parameter(Mandatory = $true, HelpMessage = 'IP address of the Windows host for routing to control plane')]
    [string] $HostIpAddress,
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
    [string] $K8sBinsPath = ''
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

# Replace the Write-Log line (around line 32) with this:
Write-Log "InstallNode.ps1 started. IPAddress: $IpAddress ShowLogs: $ShowLogs"

# Read join command from file
$joinCommandFile = "C:\Temp\join-command.txt"
if (Test-Path $joinCommandFile) {
    $JoinCommand = Get-Content -Path $joinCommandFile -Raw -Encoding UTF8
    $JoinCommand = $JoinCommand.Trim()
    Write-Log "Join command read from file: $joinCommandFile"
} else {
    Write-Log "Join command file not found at: $joinCommandFile. Will generate new join command." -Console
    $JoinCommand = $null
}

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

Write-Log "Setting up Windows worker node"

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$transparentProxy = "http://$($windowsHostIpAddress):8181"
#$joinCommand = New-JoinCommand

$workerNodeParams = @{
    Proxy                             = $transparentProxy
    AdditionalHooksDir                = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation           = $ForceOnlineInstallation
    PodSubnetworkNumber               = '2'
    JoinCommand                       = $JoinCommand
    K8sBinsPath                       = $K8sBinsPath
    IpAddress                         = $IpAddress
    IsLoopBackAdapterRequired         = $false
}

# Ensure kubeconfig is present for kubectl before any kubectl usage
$kubeConfigSource = 'C:\k2s\config'
$kubeConfigTargetDir = Join-Path $env:USERPROFILE '.kube'
$kubeConfigTarget = Join-Path $kubeConfigTargetDir 'config'
if (!(Test-Path $kubeConfigTargetDir)) {
    Write-Log "Creating .kube directory at $kubeConfigTargetDir"
    New-Item -ItemType Directory -Path $kubeConfigTargetDir -Force | Out-Null
}
Copy-Item -Path $kubeConfigSource -Destination $kubeConfigTarget -Force
Write-Log "Kubeconfig copied to $kubeConfigTarget. kubectl will use this config."

# For Node join to work, the Windows worker node needs to have a route to the control plane CIDR via the Windows host. 
# This is needed for the kubelet on the Windows worker node to be able to reach the API server on the control plane.
$ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
# # Use the passed HostIpAddress as the next hop
$nextHop = $HostIpAddress
route delete $ipControlPlaneCIDR >$null 2>&1
Write-Log "[Route] Adding persistent route to $ipControlPlaneCIDR via $nextHop"
route -p add $ipControlPlaneCIDR $nextHop METRIC 3 | Out-Null

# Add persistent route to pod network CIDR
$podNetworkCIDR = Get-ConfiguredClusterCIDR
route delete $podNetworkCIDR >$null 2>&1
Write-Log "[Route] Adding persistent route to $podNetworkCIDR via $nextHop"
route -p add $podNetworkCIDR $nextHop METRIC 3 | Out-Null

Add-WindowsWorkerNodeOnWindowsHost @workerNodeParams

Write-Log "Starting Windows worker node on Windows host"
$dnsServers = '8.8.8.8,8.8.4.4'  # Use default DNS servers
$startWorkerParams = @{
    PodSubnetworkNumber = '2'
    DnsServers          = $dnsServers
    AdditionalHooksDir  = $AdditionalHooksDir
    SkipHeaderDisplay   = $true
    IpAddress           = $IpAddress
}
Start-RemoteWindowsWorkerNode @startWorkerParams

Write-Log "Join Command after installation:" -Console
if ([string]::IsNullOrWhiteSpace($JoinCommand)) {
    $JoinCommand = New-JoinCommand
    Write-Log "Generated new join command: $JoinCommand" -Console
} else {
    Write-Log "Using provided join command: $JoinCommand" -Console
}


Write-Log '---------------------------------------------------------------'
Write-Log "K2s Windows worker node on Windows host setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-Log "[Debug] InstallNode.ps1 completed, exiting" -Console
exit 0


