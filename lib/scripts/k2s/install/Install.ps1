# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    # Main parameters
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Control Plane VM (Linux)')]
    [long] $MasterVMMemory = 8GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for Control Plane VM (Linux)')]
    [long] $MasterVMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Control Plane VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'No proxy if available')]
    [string[]] $NoProxy = @(),
    [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
    [string[]]$DnsAddresses,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,

    # These are specific developer options
    [parameter(Mandatory = $false, HelpMessage = 'Exit after initial checks')]
    [switch] $CheckOnly = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Restart N number of times after Install')]
    [long] $RestartAfterInstallCount = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting Control Plane VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile:$AppendLogFile

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

# set defaults for unset arguments
$script:SetupType = 'k2s'
Set-ConfigSetupType -Value $script:SetupType

# Initialize the proxy settings before starting installation.
New-ProxyConfig -Proxy:$Proxy -NoProxy:$NoProxy

$Proxy = Get-OrUpdateProxyServer -Proxy:$Proxy

$dnsServers = $DnsAddresses -join ','
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $loopbackAdapter = Get-L2BridgeName
    $dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
    if ([string]::IsNullOrWhiteSpace($dnsServers)) {
        $dnsServers = '8.8.8.8,8.8.4.4'
    }
}

$controlPlaneNodeParams = @{
    MasterVMMemory = $MasterVMMemory
    MasterVMProcessorCount = $MasterVMProcessorCount
    MasterDiskSize = $MasterDiskSize
    Proxy = $Proxy
    DnsAddresses = $dnsServers
    AdditionalHooksDir = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    CheckOnly = $CheckOnly
    SkipStart = $SkipStart
    ShowLogs = $ShowLogs
    RestartAfterInstallCount = $RestartAfterInstallCount
    WSL = $WSL
}
& "$PSScriptRoot\..\..\control-plane\Install.ps1" @controlPlaneNodeParams

$workerNodeParams = @{
    SkipStart = $SkipStart
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    Proxy = $Proxy
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    DnsAddresses = $dnsServers
}
& "$PSScriptRoot\..\..\worker-node\windows\windows-host\Install.ps1" @workerNodeParams

# show results
Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide

Invoke-Hook -HookName 'AfterBaseInstall' -AdditionalHooksDir $AdditionalHooksDir

Write-Log '---------------------------------------------------------------'
Write-Log "K2s setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables