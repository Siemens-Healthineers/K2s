# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator


Param(
    # Main parameters
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
    [long] $MasterVMMemory = 8GB,
    [parameter(Mandatory = $false, HelpMessage = 'Minimum Memory for Dynamic Memory (Linux Control Plane VM)')]
    [long] $MasterVMMemoryMin = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Maximum Memory for Dynamic Memory (Linux Control Plane VM)')]
    [long] $MasterVMMemoryMax = 0,
    [parameter(Mandatory = $false, HelpMessage = 'Enable Hyper-V Dynamic Memory for Control Plane VM')]
    [switch] $EnableDynamicMemory = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
    [long] $MasterVMProcessorCount = 6,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(HelpMessage = 'DNS Addresses')]
    [string]$DnsAddresses = $(throw 'Argument missing: DnsAddresses'),
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    
    # These are specific developer options
    [parameter(Mandatory = $false, HelpMessage = 'Exit after initial checks')]
    [switch] $CheckOnly = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

$productVersion = Get-ProductVersion
Set-ConfigProductVersion -Value $productVersion
Set-ConfigInstallFolder -Value $installationPath

# set defaults for unset arguments
$KubernetesVersion = Get-DefaultK8sVersion

Invoke-DeployWinArtifacts -KubernetesVersion $KubernetesVersion -Proxy $Proxy -ForceOnlineInstallation:$ForceOnlineInstallation
Install-PuttyTools

$controlPlaneNodeParams = @{
    MasterVMMemory = $MasterVMMemory
    MasterVMMemoryMin = $MasterVMMemoryMin
    MasterVMMemoryMax = $MasterVMMemoryMax
    EnableDynamicMemory = $EnableDynamicMemory
    MasterVMProcessorCount = $MasterVMProcessorCount
    MasterDiskSize = $MasterDiskSize
    Proxy = $Proxy
    AdditionalHooksDir = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    CheckOnly = $CheckOnly
    WSL = $WSL
    DnsServers = $DnsAddresses
}
New-ControlPlaneNodeOnNewVM @controlPlaneNodeParams

# add transparent proxy to Windows host
$proxyConfig = Get-ProxyConfig
$proxyOverrides = if ($proxyConfig.NoProxy.Count -gt 0) { $proxyConfig.NoProxy } else { @() }

Install-WinHttpProxy -Proxy $Proxy -ProxyOverrides $proxyOverrides
$controlPlaneIpAddress = Get-ConfiguredIPControlPlane
$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$transparentProxy = "http://$($windowsHostIpAddress):8181"
$controlPlaneUserName = Get-DefaultUserNameControlPlane
Set-ProxySettingsOnKubenode -ProxySettings $transparentProxy -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress

$windowsArtifactsDirectory = Get-WindowsArtifactsDirectory
Invoke-DeployDnsProxyArtifacts $windowsArtifactsDirectory
Install-WinDnsProxy -ListenIpAddresses @($windowsHostIpAddress) -UpstreamIpAddressForCluster $controlPlaneIpAddress -UpstreamIpAddressesForNonCluster $($DnsAddresses -split ',')


Write-Log '---------------------------------------------------------------'
Write-Log "K2s control plane node setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

