# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of worker VM (Linux)')]
    [long] $VMMemory = 8GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for worker VM (Linux)')]
    [long] $VMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of worker VM (Linux)')]
    [uint64] $VMDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(HelpMessage = 'DNS Addresses')]
    [string[]]$DnsAddresses,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

$Proxy = Get-OrUpdateProxyServer -Proxy:$Proxy

$dnsServers = $DnsAddresses -join ','
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $loopbackAdapter = Get-L2BridgeName
    $dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
    if ([string]::IsNullOrWhiteSpace($dnsServers)) {
        $dnsServers = '8.8.8.8,8.8.4.4'
    }
}

$workerNodeName = $NodeName.ToLower()

Write-Log "Adding node '$workerNodeName' to the cluster as worker..." -Console

$workerNodeParams = @{
    WorkerNodeName = $workerNodeName
    IpAddress = $IpAddress
    MasterVMMemory = $VMMemory
    MasterVMProcessorCount = $VMProcessorCount
    MasterDiskSize = $VMDiskSize
    Proxy = $Proxy
    DnsServers = $dnsServers
    AdditionalHooksDir = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
}
Add-LinuxWorkerNodeOnNewVM @workerNodeParams

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$transparentProxy = "http://$($windowsHostIpAddress):8181"
$workerNodeUserName = Get-DefaultUserNameWorkerNode
Set-ProxySettingsOnKubenode -ProxySettings $transparentProxy -UserName $workerNodeUserName -IpAddress $IpAddress

if (! $SkipStart) {
    Write-Log 'Starting worker node'
    & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $IpAddress -NodeName $workerNodeName

    if ($RestartAfterInstallCount -gt 0) {
        $restartCount = 0;
    
        while ($true) {
            $restartCount++
            Write-Log "Restarting worker (iteration #$restartCount):"
    
            & "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -NodeName $workerNodeName
            Start-Sleep 10
    
            & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $IpAddress -NodeName $workerNodeName
            Start-Sleep -s 5
    
            if ($restartCount -eq $RestartAfterInstallCount) {
                Write-Log 'Restarting worker node completed'
                break;
            }
        }
    }
} 

Write-Log '  added.' -Console

Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log

Write-Log '---------------------------------------------------------------'
Write-Log "K2s Linux worker node '$workerNodeName' on Hyper-V VM setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

