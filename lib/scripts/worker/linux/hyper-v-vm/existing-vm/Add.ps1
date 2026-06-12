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


$linuxWorkerCommon = "$PSScriptRoot\..\..\common\LinuxWorkerNode.Common.ps1"
. $linuxWorkerCommon

Initialize-LinuxWorkerScriptEnvironment -ShowLogs:$ShowLogs -IncludePuttyTools

# Import GPU worker module for GPU detection and configuration
$gpuWorkerModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.node.module\linuxnode\setup\gpu-worker.module.psm1"
Import-Module $gpuWorkerModule

$ErrorActionPreference = 'Stop'


Write-Log '[NodeAdd] Detected local Hyper-V VM on KubeSwitch - using existing-vm provisioning path'
Write-Log '[NodeAdd] Performing pre-requisites check' -Console

Assert-LinuxWorkerPuttyToolsReady -LogPrefix '[NodeAdd]' -Proxy $Proxy


# Find the VM by matching IP address to MAC address via ARP table
$kubeSwitchName = Get-ControlPlaneNodeDefaultSwitchName
Write-Log "[NodeAdd] Looking for VM with IP '$IpAddress' on switch '$kubeSwitchName'" 

# Ping the IP to populate ARP cache
Write-Log "[NodeAdd] Pinging '$IpAddress' to populate ARP cache..." 
$pingResult = Test-Connection -ComputerName $IpAddress -Count 2 -Quiet -ErrorAction SilentlyContinue
if (-not $pingResult) {
    throw "Precondition not met: IP address '$IpAddress' is not reachable"
}

# Get MAC address from ARP table
$arpEntry = Get-NetNeighbor -IPAddress $IpAddress -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Unreachable' }
if ($null -eq $arpEntry) {
    throw "Precondition not met: Could not find MAC address for IP '$IpAddress' in ARP table"
}
$targetMac = $arpEntry.LinkLayerAddress -replace '-', ''
Write-Log "[NodeAdd] Found MAC address '$targetMac' for IP '$IpAddress'" 

# Find VM on KubeSwitch with matching MAC address
$vmsOnKubeSwitch = Get-VM | Where-Object {
    $adapters = Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue
    $adapters | Where-Object { $_.SwitchName -eq $kubeSwitchName }
}

if ($vmsOnKubeSwitch.Count -eq 0) {
    throw "Precondition not met: No VMs found attached to switch '$kubeSwitchName'"
}

$targetVm = $null
foreach ($vm in $vmsOnKubeSwitch) {
    $adapters = Get-VMNetworkAdapter -VMName $vm.Name -ErrorAction SilentlyContinue
    foreach ($adapter in $adapters) {
        $vmMac = $adapter.MacAddress -replace '-', ''
        if ($vmMac -eq $targetMac) {
            $targetVm = $vm
            break
        }
    }
    if ($null -ne $targetVm) { break }
}

if ($null -eq $targetVm) {
    $vmNames = ($vmsOnKubeSwitch | ForEach-Object { $_.Name }) -join ', '
    throw "Precondition not met: No VM with MAC '$targetMac' found on switch '$kubeSwitchName'. VMs on switch: $vmNames"
}

$VmName = $targetVm.Name
Write-Log "[NodeAdd] Found VM '$VmName' with IP '$IpAddress' (MAC: $targetMac) on switch '$kubeSwitchName'"

if ($targetVm.State -ne [Microsoft.HyperV.PowerShell.VMState]::Running) {
    throw "Precondition not met: VM '$VmName' must be in 'Running' state, but is '$($targetVm.State)'"
}

# Check KubeSwitch firewall posture is acceptable: hidden, or Private as fallback
$kubeSwitchProfile = Test-KubeSwitchPrivateProfile
if (-not $kubeSwitchProfile.IsAcceptable) {
    $category = $kubeSwitchProfile.CurrentCategory
    $interfaceAlias = $kubeSwitchProfile.InterfaceAlias
    
    $errorMsg = @"
Precondition not met: KubeSwitch firewall posture is not acceptable. Current category: '$category', hidden: '$($kubeSwitchProfile.IsHidden)'.

To fix this, run the following command in an elevated PowerShell:
    & "$(Get-KubeBinPath)\SetNcfHidden.exe" ALIAS '$interfaceAlias' true 1

If SetNcfHidden.exe is unavailable, use the fallback:
    Set-NetConnectionProfile -InterfaceAlias '$interfaceAlias' -NetworkCategory Private
"@
    throw $errorMsg
}
Write-Log "[NodeAdd] KubeSwitch firewall posture check passed (category: $($kubeSwitchProfile.CurrentCategory), hidden: $($kubeSwitchProfile.IsHidden))"

Assert-LinuxWorkerNodeSshConnectivity -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]' -TargetDescription 'node'
Assert-LinuxWorkerNodeAuthorizedKey -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]'

$provisioningContext = Get-LinuxWorkerNodeProvisioningContext -UserName $UserName -IpAddress $IpAddress -NodeName $NodeName -LogPrefix '[NodeAdd]' -TargetDescription 'computer'
$NodeName = $provisioningContext.ActualHostname
$k8sFormattedNodeName = $provisioningContext.KubernetesNodeName
$installedDistributionOnRemoteComputer = $provisioningContext.InstalledDistribution

Write-Log "Adding node with hostname '$k8sFormattedNodeName'"

Disable-LinuxWorkerNodeSwap -UserName $UserName -IpAddress $IpAddress -LogPrefix '[NodeAdd]'

# For local VMs on KubeSwitch, always use the transparent proxy through the Windows host.
# The corporate proxy is not reachable from the isolated KubeSwitch network.
$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$transparentProxy = "http://$($windowsHostIpAddress):8181"
Write-Log "[LocalVM] Using transparent proxy: $transparentProxy (local VM cannot reach corporate proxy)"

Write-Log "Windows Host IP address: $WindowsHostIpAddress"

$workerNodeParams = @{
    NodeName = $NodeName
    UserName = $UserName
    IpAddress = $IpAddress
    WindowsHostIpAddress = $WindowsHostIpAddress
    Proxy = $transparentProxy
    AdditionalHooksDir = $AdditionalHooksDir
    installedDistributionOnRemoteComputer = $installedDistributionOnRemoteComputer
    NodePackagePath = $NodePackagePath
    NodeType = 'VM-EXISTING'
    VmName = $VmName  # Hyper-V VM name (detected earlier via MAC address)
}
Add-LinuxWorkerNode @workerNodeParams

Write-Log 'Starting worker node' -Console
& "$PSScriptRoot\..\..\bare-metal\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $IpAddress -NodeName $NodeName -ObtainCIDR:$true

Write-Log "Current state of cluster nodes:" -Console
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log

Write-Log '---------------------------------------------------------------'
Write-Log "Linux Hyper-V VM with IP  '$IpAddress' and hostname '$NodeName' added to the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $durationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'