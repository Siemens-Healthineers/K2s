# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [string] $UserName = $(throw 'Argument missing: UserName'),
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [string] $NodeName,
    [string] $WindowsHostIpAddress = '',
    [string] $Proxy = '',
    [string] $NodePackagePath = '',
    [switch] $ShowLogs = $false
)

$durationStopwatch = [system.diagnostics.stopwatch]::StartNew()


$linuxWorkerCommon = "$PSScriptRoot\..\common\LinuxWorkerNode.Common.ps1"
. $linuxWorkerCommon

Initialize-LinuxWorkerScriptEnvironment -ShowLogs:$ShowLogs -IncludePuttyTools

# Import GPU worker module for GPU detection and configuration
$gpuWorkerModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\linuxnode\setup\gpu-worker.module.psm1"
Import-Module $gpuWorkerModule

$ErrorActionPreference = 'Stop'


Write-Log '[NodeAdd] Detected external node (bare-metal) - using bare-metal provisioning path' -Console
Write-Log '[NodeAdd] Performing pre-requisites check' -Console

Assert-LinuxWorkerPuttyToolsReady -LogPrefix '[NodeAdd]' -Proxy $Proxy


# Validate that the node IP is on a physical network subnet (LAN/WiFi)
$loopbackAdapter = Get-L2BridgeName
$physicalSubnets = Get-PhysicalNetworkSubnets -ExcludeNetworkInterfaceName $loopbackAdapter

Write-Log "[NodeAdd] Available physical network subnets:" -Console
foreach ($subnet in $physicalSubnets) {
    Write-Log "[NodeAdd]   - $($subnet.InterfaceName): $($subnet.CIDR) (IP: $($subnet.IPAddress))" -Console
}

if (!(Test-IpInPhysicalSubnet -IpAddress $IpAddress -ExcludeNetworkInterfaceName $loopbackAdapter)) {
    $subnetList = ($physicalSubnets | ForEach-Object { "$($_.InterfaceName): $($_.CIDR)" }) -join ', '
    throw "[NodeAdd] Precondition not met: IP address '$IpAddress' is not within any physical network subnet. Available subnets: $subnetList"
}

Write-Log "[NodeAdd] IP address '$IpAddress' validated - belongs to a physical network subnet" -Console


Assert-LinuxWorkerNodeSshConnectivity -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]' -TargetDescription 'node'
Assert-LinuxWorkerNodeAuthorizedKey -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]'

$provisioningContext = Get-LinuxWorkerNodeProvisioningContext -UserName $UserName -IpAddress $IpAddress -NodeName $NodeName -LogPrefix '[NodeAdd]' -TargetDescription 'computer'
$NodeName = $provisioningContext.ActualHostname
$k8sFormattedNodeName = $provisioningContext.KubernetesNodeName
$installedDistributionOnRemoteComputer = $provisioningContext.InstalledDistribution

Write-Log "Adding node with hostname '$k8sFormattedNodeName'"


Disable-LinuxWorkerNodeSwap -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]'

if ($WindowsHostIpAddress -eq '') {
    $loopbackAdapter = Get-L2BridgeName
    $WindowsHostIpAddress = Get-HostIpAddressForRemoteIp -RemoteIpAddress $IpAddress -ExcludeNetworkInterfaceName $loopbackAdapter
}
Write-Log "Windows Host IP address: $WindowsHostIpAddress"

# If configuration is present, retrieve proxy
if ($Proxy -eq '') {
    $proxyConfig = Get-ProxyConfig
    $Proxy = $proxyConfig.HttpProxy
}

$workerNodeParams = @{
    NodeName = $NodeName
    UserName = $UserName
    IpAddress = $IpAddress
    WindowsHostIpAddress = $WindowsHostIpAddress
    Proxy = $Proxy
    AdditionalHooksDir = $AdditionalHooksDir
    installedDistributionOnRemoteComputer = $installedDistributionOnRemoteComputer
    NodePackagePath = $NodePackagePath
    NodeType = 'HOST'
}

Add-LinuxWorkerNode @workerNodeParams

# -----------------------------------------------------------------------
# GPU Auto-Detection and Configuration
# -----------------------------------------------------------------------
Write-Log '[NodeAdd] Checking for NVIDIA GPU hardware on node...' -Console

$gpuDetection = Test-NvidiaGpuPresent -UserName $UserName -IpAddress $IpAddress
$isOfflineInstall = ![string]::IsNullOrWhiteSpace($NodePackagePath)

if ($gpuDetection.Present) {
    Write-Log "[NodeAdd] NVIDIA GPU detected: $($gpuDetection.GpuInfo)" -Console
    
    if ($isOfflineInstall) {
        # Offline installation: check if GPU packages are available in the node package
        $gpuPackages = Test-OfflineGpuPackagesAvailable -NodePackagePath $NodePackagePath
        if ($gpuPackages.Available) {
            Write-Log "[NodeAdd] Offline GPU packages found ($($gpuPackages.PackageCount) packages) - initializing GPU configuration" -Console
            Initialize-GpuWorkerNode -UserName $UserName -IpAddress $IpAddress -NodeName $NodeName -Proxy $Proxy -NodePackagePath $NodePackagePath
        } else {
            Write-Log "[NodeAdd] NVIDIA GPU detected but no GPU packages in node package." -Console
            Write-Log "[NodeAdd] To enable GPU support offline, create a node package with --include-gpu:" -Console
            Write-Log "[NodeAdd]   k2s system package --node-package --os <os> --include-gpu --target-dir <dir> --name <name>.zip" -Console
            Write-Log "[NodeAdd] Skipping GPU configuration." -Console
        }
    } else {
        # Online installation: automatically install GPU packages
        Write-Log '[NodeAdd] Online installation with NVIDIA GPU - installing GPU packages automatically' -Console
        Initialize-GpuWorkerNode -UserName $UserName -IpAddress $IpAddress -NodeName $NodeName -Proxy $Proxy -NodePackagePath ''
    }
} elseif ($gpuDetection.OtherGpu) {
    Write-Log "[NodeAdd] Non-NVIDIA GPU detected: $($gpuDetection.GpuInfo)" -Console
    Write-Log "[NodeAdd] K2s GPU support is currently available only for NVIDIA GPUs. Skipping GPU configuration." -Console
} else {
    Write-Log "[NodeAdd] No NVIDIA GPU hardware detected on node. Skipping GPU configuration." -Console
}

Write-Log 'Starting worker node' -Console
& "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $IpAddress -NodeName $NodeName -ObtainCIDR:$true

Write-Log "Current state of cluster nodes:" -Console
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log -Console

Write-Log '---------------------------------------------------------------'
Write-Log "Linux computer with IP '$IpAddress' and hostname '$NodeName' added to the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $durationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'