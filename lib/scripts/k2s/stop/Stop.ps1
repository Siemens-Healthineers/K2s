# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
    [switch] $SkipHeaderDisplay = $false
)

$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$kubePath = Get-KubePath
Import-Module "$kubePath/addons/addons.module.psm1"

# make sure we are at the right place for executing this script
Set-Location $kubePath

if ($SkipHeaderDisplay -ne $true) {
    Write-Log 'Stopping K2s system'
}

# reset default namespace

$kubeToolsPath = Get-KubeToolsPath
if (Test-Path "$kubeToolsPath\kubectl.exe") {
    Write-Log 'Resetting default namespace for kubernetes'
    &"$kubeToolsPath\kubectl.exe" config set-context --current --namespace=default | Out-Null
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

$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
Write-Log "Stopping $controlPlaneVMHostName VM" -Console


if ($WSL) {
    wsl --shutdown
    Remove-NetIPAddress -IPAddress $global:IP_NextHop -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue
    Reset-DnsServer $global:WSLSwitchName
}
else {
    # stop vm
    if ($(Get-VM | Where-Object Name -eq $controlPlaneVMHostName | Measure-Object).Count -eq 1 ) {
        Write-Log ('Stopping VM: ' + $controlPlaneVMHostName)
        Stop-VM -Name $controlPlaneVMHostName -Force -WarningAction SilentlyContinue
    }
}

Write-Log 'Stopping K8s network' -Console
Restart-WinService 'hns'

Invoke-Hook -HookName 'BeforeStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

# remove switch
Remove-KubeSwitch

# remove NAT
Remove-DefaultNetNat

# Remove the external switch
Remove-ExternalSwitch

# if ($WSL) {
#     $hns | Where-Object Name -Like ('*' + $global:WSLSwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
#     Restart-WinService 'WslService'
# }

Write-Log 'Delete network policies'
Get-HnsPolicyList | Remove-HnsPolicyList -ErrorAction SilentlyContinue


Write-Log 'Removing old logfiles'
Remove-Item -Force "$(Get-SystemDriveLetter):\var\log\flanneld\flannel*.*" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
Remove-Item -Force "$(Get-SystemDriveLetter):\var\log\kubelet\*.*" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
Remove-Item -Force "$(Get-SystemDriveLetter):\var\log\kubeproxy\*.*" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

if ($shallRestartDocker) {
    Start-ServiceProcess 'docker'
}

# Sometimes only removal from registry helps and reboot
Write-Log 'Cleaning up registry for NicList'
Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\VMSMP\Parameters\NicList' | Remove-Item -ErrorAction SilentlyContinue | Out-Null

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

Write-Log 'Kubernetes system stopped.'

