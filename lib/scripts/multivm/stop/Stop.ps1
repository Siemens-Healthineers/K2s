# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Stops the K8s cluster.

.DESCRIPTION
Stops the K8s cluster and resets networking, file sharing, etc.

.PARAMETER HideHeaders
Specifies whether to hide headers console output, e.g. when script runs in the context of a parent script.

.PARAMETER ShowLogs
Show all logs in terminal

.PARAMETER AdditionalHooksDir
Directory containing additional hooks to be executed after local hooks are executed.

.EXAMPLE
PS> .\lib\scripts\multivm\stop\Stop.ps1

.EXAMPLE
PS> .\lib\scripts\multivm\stop\Stop.ps1 -HideHeaders $true
Header log entries will not be written/logged to the console.

.EXAMPLE
PS> .\lib\scripts\multivm\stop\Stop.ps1 -AdditonalHooks 'C:\AdditionalHooks'
For specifying additional hooks to be executed.
#>

param(
    [parameter(Mandatory = $false, HelpMessage = 'Set to TRUE to omit script headers.')]
    [switch] $HideHeaders = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Stop during uninstallation')]
    [switch] $StopDuringUninstall = $false
)

$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

$controlPlaneHostName = Get-ConfigControlPlaneNodeHostname
$multiVMWindowsVMName = Get-ConfigVMNodeHostname

#################################################################################################
# FUNCTIONS                                                                                     #
#################################################################################################


function Reset-K8sNamespace {
    # reset default namespace
    $kubeToolsPath = Get-KubeToolsPath
    if (Test-Path "$kubeToolsPath\kubectl.exe") {
        Write-Log 'Resetting default namespace for Kubernetes ...'
        &"$kubeToolsPath\kubectl.exe" config set-context --current --namespace=default | Out-Null
    }
}

function Start-WindowsNodeCleanup($session) {
    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true

        Stop-ServiceAndSetToManualStart 'kubeproxy'
        Stop-ServiceAndSetToManualStart 'kubelet'
        Stop-ServiceAndSetToManualStart 'flanneld'
        Stop-ServiceAndSetToManualStart 'windows_exporter'
        Stop-ServiceAndSetToManualStart 'containerd'
        Stop-ServiceAndSetToManualStart 'httpproxy'

        $shallRestartDocker = $false
        if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
            Stop-ServiceProcess 'docker' 'dockerd'
            $shallRestartDocker = $true
        }

        Remove-ExternalSwitch

        $hns = $(Get-HNSNetwork)

        # there's always at least the Default Switch network available, so we check for >= 2
        if ($($hns | Measure-Object).Count -ge 2) {
            Write-Log 'Delete bridge, clear HNSNetwork (short disconnect expected)'
            $hns | Where-Object Name -Like '*cbr0*' | Remove-HNSNetwork -ErrorAction SilentlyContinue
            $hns | Where-Object Name -Like ('*' + $cpSwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
        }

        Write-Log 'Delete network policies'
        Get-HnsPolicyList | Remove-HnsPolicyList -ErrorAction SilentlyContinue

        Write-Log 'Removing old logfiles'
        Remove-Item -Force C:\var\log\flanneld\flannel*.* -Recurse -Confirm:$False -ErrorAction SilentlyContinue
        Remove-Item -Force C:\var\log\kubelet\*.* -Recurse -Confirm:$False -ErrorAction SilentlyContinue
        Remove-Item -Force C:\var\log\kubeproxy\*.* -Recurse -Confirm:$False -ErrorAction SilentlyContinue

        if ($shallRestartDocker) {
            Start-ServiceProcess 'docker'
        }

        # Sometimes only removal from registry helps and reboot
        Write-Log 'Cleaning up registry for NicList'
        Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\VMSMP\Parameters\NicList' | Remove-Item -ErrorAction SilentlyContinue | Out-Null
    }
}

function Remove-ObsoleteNetworkAdapterProfiles($session) {
    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Initialize-Logging -Nested:$true

        $devices = @(Get-PnpDevice -class net | Where-Object Status -eq Unknown | Select-Object FriendlyName, InstanceId)

        ForEach ($device in $devices) {
            Write-Output "Removing device '$($device.FriendlyName)'"

            $RemoveKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)"

            Get-Item $RemoveKey | Select-Object -ExpandProperty Property | ForEach-Object { Remove-ItemProperty -Path $RemoveKey -Name $_ -Force }
        }
    }
}

#################################################################################################
# SCRIPT START                                                                                  #
#################################################################################################

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

if ($Trace) {
    Set-PSDebug -Trace 1
}

if ($HideHeaders -ne $true) {
    Write-Log '---------------------------------------------------------------'
    Write-Log 'Multi-VM Kubernetes stopping ...'
    Write-Log '---------------------------------------------------------------'
}

Reset-K8sNamespace


Write-Log "Stopping $controlPlaneHostName VM" -Console

Stop-VirtualMachine -VmName $controlPlaneHostName

$ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
$ipNextHop = Get-ConfiguredKubeSwitchIP
$setupConfigRoot = Get-RootConfigk2s
$clusterCIDRMaster = $setupConfigRoot.psobject.properties['podNetworkMasterCIDR'].value
$clusterCIDRWorker = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR'].value
$clusterCIDRServicesLinux = $setupConfigRoot.psobject.properties['servicesCIDRLinux'].value
$clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value

if ((Get-VM -Name $multiVMWindowsVMName) -and !$StopDuringUninstall) {
    Get-VMNetworkAdapter -VMName $multiVMWindowsVMName | Disconnect-VMNetworkAdapter

    $cpSwitchName = Get-ControlPlaneNodeDefaultSwitchName
    $sw = Get-VMSwitch -Name $cpSwitchName -ErrorAction SilentlyContinue
    if ( $sw ) {
        Remove-VMSwitch -Name $cpSwitchName -Force
    }

    New-VMSwitch -Name $cpSwitchName -SwitchType Internal -MinimumBandwidthMode Weight | Out-Null
    New-NetIPAddress -IPAddress $ipNextHop -PrefixLength 24 -InterfaceAlias "vEthernet ($cpSwitchName)" | Out-Null
    Add-DnsServer $cpSwitchName

    $nad = Get-VMNetworkAdapter -VMName $multiVMWindowsVMName
    if ( !($nad) ) {
        Write-Log "Adding network adapter to VM '$multiVMWindowsVMName' ..."
        Add-VMNetworkAdapter -VMName $multiVMWindowsVMName -Name 'Network Adapter'
    }

    Connect-VMNetworkAdapter -VMName $multiVMWindowsVMName -SwitchName $cpSwitchName
    # make sure Windows node is online to perform cleanup tasks first
    Start-VirtualMachine -VmName $multiVMWindowsVMName -Wait

    Wait-ForSSHConnectionToWindowsVMViaSshKey

    $session = Open-DefaultWinVMRemoteSessionViaSSHKey

    Write-Log "Stopping K8s services on $multiVMWindowsVMName VM" -Console

    Start-WindowsNodeCleanup $session
}

Write-Log 'Stopping K8s network' -Console

Invoke-Hook -HookName 'BeforeStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

if (!$StopDuringUninstall) {
    Remove-ObsoleteNetworkAdapterProfiles $session
    Get-PSSession | Remove-PSSession
}

Write-Log "Stopping $multiVMWindowsVMName VM" -Console
Stop-VirtualMachine -VmName $multiVMWindowsVMName

route delete $clusterCIDRServicesLinux >$null 2>&1 | Out-Null
route delete $clusterCIDRServicesWindows >$null 2>&1 | Out-Null
route delete $ipControlPlaneCIDR >$null 2>&1 | Out-Null
route delete $clusterCIDRWorker >$null 2>&1 | Out-Null
route delete $clusterCIDRMaster >$null 2>&1 | Out-Null

Invoke-Hook -HookName 'AfterStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

if ($HideHeaders -ne $true) {
    Write-Log '---------------------------------------------------------------'
    Write-Log 'Multi-VM Kubernetes stopped.'
    Write-Log '---------------------------------------------------------------'
}


