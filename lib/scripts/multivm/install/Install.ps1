# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Windows ISO image path (mandatory if not Linux-only)')]
    [string] $WindowsImage,
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Windows VM')]
    [long] $WinVMStartUpMemory = 4GB,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of Windows VM')]
    [long] $WinVMDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors of Windows VM')]
    [long] $WinVMProcessorCount = 4,
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
    [long] $MasterVMMemory = 6GB,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
    [uint64] $MasterDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
    [long] $MasterVMProcessorCount = 4,
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
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
    [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
    [switch] $WSL = $false,
    [parameter(Mandatory = $false, HelpMessage = 'No Windows worker node will be set up')]
    [switch] $LinuxOnly = $false,
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

if (!$LinuxOnly -and !(Test-Path -Path $WindowsImage)) {
    throw "Windows image ISO file '$WindowsImage' not found."
}

# set defaults for unset arguments
$script:SetupType = 'MultiVMK8s'
Set-ConfigSetupType -Value $script:SetupType
Set-ConfigLinuxOnly -Value ($LinuxOnly -eq $true)

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
    MasterVMMemory = $MasterVMMemory
    MasterVMProcessorCount = $MasterVMProcessorCount
    MasterDiskSize = $MasterDiskSize
    Proxy = $Proxy
    DnsAddresses = $dnsServers
    AdditionalHooksDir = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation = $ForceOnlineInstallation
    CheckOnly = $false
    SkipStart = $SkipStart
    ShowLogs = $ShowLogs
    WSL = $WSL
}

$controlPlaneParams = " -MasterVMMemory '$MasterVMMemory'"
$controlPlaneParams += " -MasterVMProcessorCount '$MasterVMProcessorCount'"
$controlPlaneParams += " -MasterDiskSize '$MasterDiskSize'"
$controlPlaneParams += " -Proxy '$Proxy'"
$controlPlaneParams += " -DnsAddresses '$dnsServers'"
$controlPlaneParams += " -AdditionalHooksDir '$AdditionalHooksDir'"
if ($DeleteFilesForOfflineInstallation.IsPresent) {
    $controlPlaneParams += " -DeleteFilesForOfflineInstallation"
}
if ($ForceOnlineInstallation.IsPresent) {
    $controlPlaneParams += " -ForceOnlineInstallation"
}
if ($SkipStart.IsPresent) {
    $controlPlaneParams += " -SkipStart"
}
if ($ShowLogs.IsPresent) {
    $controlPlaneParams += " -ShowLogs"
}
if ($WSL.IsPresent) {
    $controlPlaneParams += " -WSL"
}
& powershell.exe "$PSScriptRoot\..\..\control-plane\Install.ps1" $controlPlaneParams
        
$installationType = 'Linux-only'

if ($(Get-ConfigLinuxOnly) -eq $false) {

    $installationType = 'Multi-VM'

    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $transparentProxy = "http://$($windowsHostIpAddress):8181"
    $dnsServersForWorkerNode = $windowsHostIpAddress

    $workerNodeParams = @{
        WindowsImage = $WindowsImage
        WinVMStartUpMemory = $WinVMStartUpMemory
        WinVMDiskSize = $WinVMDiskSize
        WinVMProcessorCount = $WinVMProcessorCount
        Proxy = $transparentProxy
        DnsAddresses = $dnsServersForWorkerNode
        SkipStart = $SkipStart
        ShowLogs = $ShowLogs
        AdditionalHooksDir = $AdditionalHooksDir
        DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
        ForceOnlineInstallation = $ForceOnlineInstallation
    }
    & "$PSScriptRoot\..\..\worker-node\windows\hyper-v-vm\Install.ps1" @workerNodeParams
}

# show results
Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide

Invoke-Hook -HookName 'AfterBaseInstall' -AdditionalHooksDir $AdditionalHooksDir



Write-Log '---------------------------------------------------------------'
Write-Log "$installationType setup finished.  Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'


