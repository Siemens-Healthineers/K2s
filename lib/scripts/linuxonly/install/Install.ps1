# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
    [long] $MasterVMMemory = 6GB,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
    [long] $MasterVMProcessorCount = 4,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'No proxy hosts/domains (comma-separated list or array)')]
    [string[]] $NoProxy,
    [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
    [string[]]$DnsAddresses,
    [parameter(Mandatory = $false, HelpMessage = 'Do not call the StartK8s at end')]
    [switch] $SkipStart = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Append to log file (do not start from scratch)')]
    [switch] $AppendLogFile = $false
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs
Reset-LogFile -AppendLogFile:$AppendLogFile

$ErrorActionPreference = 'Continue'

$script:SetupType = 'k2s'
Set-ConfigSetupType -Value $script:SetupType
Set-ConfigLinuxOnly -Value $true

# Initialize the proxy settings before starting installation.
New-ProxyConfig -Proxy:$Proxy -NoProxy:$NoProxy

$Proxy = Get-OrUpdateProxyServer -Proxy:$Proxy
Add-K2sHostsToNoProxyEnvVar

$dnsServers = $DnsAddresses -join ','
if ([string]::IsNullOrWhiteSpace($dnsServers)) {
    $loopbackAdapter = Get-L2BridgeName
    $dnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $loopbackAdapter
    if ([string]::IsNullOrWhiteSpace($dnsServers)) {
        $dnsServers = '8.8.8.8,8.8.4.4'
    }
}

$controlPlaneParams = @{
    MasterVMMemory                    = $MasterVMMemory
    MasterVMProcessorCount            = $MasterVMProcessorCount
    MasterDiskSize                    = $MasterDiskSize
    Proxy                             = $Proxy
    DnsAddresses                      = $dnsServers
    AdditionalHooksDir                = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation           = $ForceOnlineInstallation
    CheckOnly                         = $false
    ShowLogs                          = $ShowLogs
    WSL                               = $false
}

& "$PSScriptRoot\..\..\control-plane\Install.ps1" @controlPlaneParams

# show results
Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide

Invoke-Hook -HookName 'AfterBaseInstall' -AdditionalHooksDir $AdditionalHooksDir

if ($SkipStart) {
    Write-Log "Skipping start of K2s linux-only setup as requested"
    & "$PSScriptRoot\..\stop\Stop.ps1" -ShowLogs:$ShowLogs -HideHeaders:$true
} else {
    & "$PSScriptRoot\..\start\Start.ps1" -ShowLogs:$ShowLogs -HideHeaders:$true
}

Write-Log '---------------------------------------------------------------'
Write-Log "Linux-only setup finished.  Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

Write-RefreshEnvVariables