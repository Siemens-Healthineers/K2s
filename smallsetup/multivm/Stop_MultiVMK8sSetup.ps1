# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
PS> Stop_MultiVMK8sSetup.ps1

.EXAMPLE
PS> Stop_MultiVMK8sSetup.ps1 -HideHeaders $true
Header log entries will not be written/logged to the console.

.EXAMPLE
PS> Stop_MultiVMK8sSetup.ps1 -AdditonalHooks 'C:\AdditionalHooks'
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

#################################################################################################
# FUNCTIONS                                                                                     #
#################################################################################################

function Reset-K8sNamespace {
    # reset default namespace
    if (Test-Path $global:KubectlExe) {
        Write-Log 'Resetting default namespace for Kubernetes ...'
        &$global:KubectlExe config set-context --current --namespace=default | Out-Null
    }

}

function Invoke-BeforeVMNetworkingRemovalHook([string]$AdditionalHooksDir) {
    Invoke-Hook -HookName 'BeforeStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir
}

function Invoke-AfterVMNetworkingRemovalHook([string]$AdditionalHooksDir) {
    Invoke-Hook -HookName 'AfterStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir
}

function Start-WindowsNodeCleanup($session) {
    Invoke-Command -Session $session {
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        # load global settings
        &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1

        # import global functions
        . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1
        Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
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

        RemoveExternalSwitch

        $hns = $(Get-HNSNetwork)

        # there's always at least the Default Switch network available, so we check for >= 2
        if ($($hns | Measure-Object).Count -ge 2) {
            Write-Log 'Delete bridge, clear HNSNetwork (short disconnect expected)'
            $hns | Where-Object Name -Like '*cbr0*' | Remove-HNSNetwork -ErrorAction SilentlyContinue
            $hns | Where-Object Name -Like ('*' + $global:SwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
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
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop
        Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
        Initialize-Logging -Nested:$true

        $devices = @(Get-PnpDevice -class net | Where-Object Status -eq Unknown | Select-Object FriendlyName, InstanceId)

        ForEach ($device in $devices) {
            Write-Log "Removing device '$($device.FriendlyName)'"

            $RemoveKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($device.InstanceId)"

            Get-Item $RemoveKey | Select-Object -ExpandProperty Property | ForEach-Object { Remove-ItemProperty -Path $RemoveKey -Name $_ -Force }
        }
    }
}

#################################################################################################
# SCRIPT START                                                                                  #
#################################################################################################

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1

# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/../ps-modules/log/log.module.psm1"
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

$WSL = Get-WSLFromConfig
$linuxOnly = Get-LinuxOnlyFromConfig

Write-Log "Stopping $global:VMName VM" -Console

# no further steps on Linux node
if ($WSL) {
    wsl --shutdown
    Remove-NetIPAddress -IPAddress $global:IP_NextHop -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue
    Reset-DnsServer $global:WSLSwitchName

    Restart-WinService 'hns'
    Get-HNSNetwork | Where-Object Name -Like ('*' + $global:WSLSwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
    Restart-WinService 'WslService'
}
else {
    Stop-VirtualMachine -VmName $global:VMName
}

if ($linuxOnly -ne $true) {
    if ((Get-VM -Name $global:MultiVMWindowsVMName -ErrorAction SilentlyContinue) -and !$StopDuringUninstall) {
        Get-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName | Disconnect-VMNetworkAdapter

        $sw = Get-VMSwitch -Name $global:SwitchName -ErrorAction SilentlyContinue
        if ( $sw ) {
            Remove-VMSwitch -Name $global:SwitchName -Force
        }

        New-VMSwitch -Name $global:SwitchName -SwitchType Internal -MinimumBandwidthMode Weight | Out-Null
        New-NetIPAddress -IPAddress $global:IP_NextHop -PrefixLength 24 -InterfaceAlias "vEthernet ($global:SwitchName)" | Out-Null
        Add-DnsServer $global:SwitchName

        $nad = Get-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName
        if ( !($nad) ) {
            Write-Log "Adding network adapter to VM '$global:MultiVMWindowsVMName' ..."
            Add-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName -Name 'Network Adapter'
        }

        Connect-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName -SwitchName $global:SwitchName
        # make sure Windows node is online to perform cleanup tasks first
        Start-VirtualMachine -VmName $global:MultiVMWindowsVMName -Wait

        Wait-ForSSHConnectionToWindowsVMViaSshKey

        $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

        Write-Log "Stopping K8s services on $global:MultiVMWindowsVMName VM" -Console

        Start-WindowsNodeCleanup $session
    }
}


Write-Log 'Stopping K8s network' -Console

Invoke-BeforeVMNetworkingRemovalHook -AdditionalHooksDir $AdditionalHooksDir

if ($linuxOnly -ne $true) {
    if (!$StopDuringUninstall) {
        Remove-ObsoleteNetworkAdapterProfiles $session
        Get-PSSession | Remove-PSSession
    }

    Write-Log "Stopping $global:MultiVMWindowsVMName VM" -Console
    Stop-VirtualMachine -VmName $global:MultiVMWindowsVMName
}

route delete $global:ClusterCIDR_ServicesLinux >$null 2>&1 | Out-Null
route delete $global:ClusterCIDR_ServicesWindows >$null 2>&1 | Out-Null
route delete $global:IP_CIDR >$null 2>&1 | Out-Null
route delete $global:ClusterCIDR_Host >$null 2>&1 | Out-Null
route delete $global:ClusterCIDR_Master >$null 2>&1 | Out-Null

Invoke-AfterVMNetworkingRemovalHook -AdditionalHooksDir $AdditionalHooksDir

if ($HideHeaders -ne $true) {
    Write-Log '---------------------------------------------------------------'
    Write-Log 'Multi-VM Kubernetes stopped.'
    Write-Log '---------------------------------------------------------------'
}


