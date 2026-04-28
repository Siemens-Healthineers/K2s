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

$ErrorActionPreference = 'Stop'


Write-Log '[NodeAdd] Detected local Hyper-V VM on KubeSwitch - using existing-vm provisioning path' -Console
Write-Log '[NodeAdd] Performing pre-requisites check' -Console

Assert-LinuxWorkerPuttyToolsReady -LogPrefix '[NodeAdd]' -Proxy $Proxy


# Find the VM attached to KubeSwitch with the given IP address
$kubeSwitchName = Get-ControlPlaneNodeDefaultSwitchName
Write-Log "[NodeAdd] Looking for VM with IP '$IpAddress' attached to switch '$kubeSwitchName'" -Console

$vmsOnKubeSwitch = Get-VM | Where-Object {
    $adapters = Get-VMNetworkAdapter -VMName $_.Name -ErrorAction SilentlyContinue
    $adapters | Where-Object { $_.SwitchName -eq $kubeSwitchName }
}

if ($vmsOnKubeSwitch.Count -eq 0) {
    throw "Precondition not met: No VMs found attached to switch '$kubeSwitchName'"
}

# Find the VM that has our target IP address
$targetVm = $null
foreach ($vm in $vmsOnKubeSwitch) {
    $vmIPs = (Get-VMNetworkAdapter -VMName $vm.Name).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
    if ($vmIPs -contains $IpAddress) {
        $targetVm = $vm
        break
    }
}

if ($null -eq $targetVm) {
    $vmNames = ($vmsOnKubeSwitch | ForEach-Object { $_.Name }) -join ', '
    throw "Precondition not met: No VM with IP '$IpAddress' found on switch '$kubeSwitchName'. VMs on switch: $vmNames"
}

$VmName = $targetVm.Name
Write-Log "[NodeAdd] Found VM '$VmName' with IP '$IpAddress' on switch '$kubeSwitchName'" -Console

if ($targetVm.State -ne [Microsoft.HyperV.PowerShell.VMState]::Running) {
    throw "Precondition not met: VM '$VmName' must be in 'Running' state, but is '$($targetVm.State)'"
}

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
    Proxy = $Proxy
    AdditionalHooksDir = $AdditionalHooksDir
    installedDistributionOnRemoteComputer = $installedDistributionOnRemoteComputer
    NodePackagePath = $NodePackagePath
}
Add-LinuxWorkerNode @workerNodeParams

Write-Log "Current state of cluster nodes:" -Console
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log

Write-Log '---------------------------------------------------------------'
Write-Log "Linux Hyper-V VM with IP  '$IpAddress' and hostname '$NodeName' added to the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $durationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

