# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
    [switch] $CacheK2sVSwitches,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$kubePath = Get-KubePath
Set-Location $kubePath

if ($SkipHeaderDisplay -eq $false) {
    Write-Log 'Stopping K2s'
}

# reset default namespace
$kubeToolsPath = Get-KubeToolsPath
$kubectlExe = "$kubeToolsPath\kubectl.exe"
if (Test-Path "$kubectlExe") {
    Write-Log 'Resetting default namespace for kubernetes'
    &"$kubectlExe" config set-context --current --namespace=default | Out-Null
}

$ProgressPreference = 'SilentlyContinue'

$WSL = Get-ConfigWslFlag

Write-Log 'Stopping Kubernetes services on the Windows node' -Console

Stop-ServiceAndSetToManualStart 'kubeproxy'
Stop-ServiceAndSetToManualStart 'kubelet'
Stop-ServiceAndSetToManualStart 'flanneld'
Stop-ServiceAndSetToManualStart 'windows_exporter'
Stop-ServiceAndSetToManualStart 'containerd'
Stop-ServiceAndSetToManualStart 'httpproxy'
Stop-ServiceAndSetToManualStart 'dnsproxy'

$shallRestartDocker = $false
if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
    Stop-ServiceProcess 'docker' 'dockerd'
    $shallRestartDocker = $true
}

$isReusingExistingLinuxComputer = Get-ReuseExistingLinuxComputerForMasterNodeFlag
$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$wslSwitchName = Get-WslSwitchName

if ($WSL) {
    wsl --shutdown
    Remove-NetIPAddress -IPAddress $windowsHostIpAddress -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue
    Reset-DnsServer $wslSwitchName
}
elseif ($isReusingExistingLinuxComputer) {
    $switchName = Get-NetIPAddress -IPAddress $windowsHostIpAddress | Select-Object -ExpandProperty 'InterfaceAlias'
    Reset-DnsServer $switchName
}
else {
    # stop vm
    $controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
    if ($(Get-VM | Where-Object Name -eq $controlPlaneVMHostName | Measure-Object).Count -eq 1 ) {
        Write-Log ('Stopping ' + $controlPlaneVMHostName + ' VM') -Console
        Stop-VM -Name $controlPlaneVMHostName -Force -WarningAction SilentlyContinue
    }
}

Write-Log 'Stopping K8s network' -Console
Restart-WinService 'hns'

Invoke-Hook -HookName 'BeforeStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

if (!$CacheK2sVSwitches) {
    # remove kubeswitch
    Remove-KubeSwitch

    # Remove the external switch
    Remove-ExternalSwitch
}

# remove NAT
Remove-DefaultNetNat

if ($WSL) {
    $hns = $(Get-HNSNetwork)
    $hns | Where-Object Name -Like ('*' + $wslSwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
    Restart-WinService 'WslService'
}

Write-Log 'Delete network policies'
if(!$CacheK2sVSwitches) { 
    Get-HnsPolicyList | Remove-HnsPolicyList -ErrorAction SilentlyContinue
}

if ($shallRestartDocker) {
    Start-ServiceProcess 'docker'
}

# Sometimes only removal from registry helps and reboot
if(!$CacheK2sVSwitches) { 
    Write-Log 'Cleaning up registry for NicList'
    Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\VMSMP\Parameters\NicList' | Remove-Item -ErrorAction SilentlyContinue | Out-Null
}

$ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
$setupConfigRoot = Get-RootConfigk2s
$clusterCIDRMaster = $setupConfigRoot.psobject.properties['podNetworkMasterCIDR'].value
$clusterCIDRHost = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR'].value
$clusterCIDRServices = $setupConfigRoot.psobject.properties['servicesCIDR'].value
$clusterCIDRServicesLinux = $setupConfigRoot.psobject.properties['servicesCIDRLinux'].value
$clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value

# Remove routes
Write-Log "Remove route to $ipControlPlaneCIDR"
route delete $ipControlPlaneCIDR >$null 2>&1
Write-Log "Remove route to $clusterCIDRMaster"
route delete $clusterCIDRMaster >$null 2>&1
Write-Log "Remove route to $clusterCIDRHost"
route delete $clusterCIDRHost >$null 2>&1
Write-Log "Remove route to $clusterCIDRServices"
route delete $clusterCIDRServices >$null 2>&1
route delete $clusterCIDRServicesLinux >$null 2>&1
route delete $clusterCIDRServicesWindows >$null 2>&1

Invoke-Hook -HookName 'AfterStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

Disable-LoopbackAdapter

Write-Log '...Kubernetes system stopped.'

