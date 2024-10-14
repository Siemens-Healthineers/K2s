# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Starts the K8s cluster.

.DESCRIPTION
Starts the K8s cluster and sets up networking, file sharing, etc.

.PARAMETER HideHeaders
Specifies whether to hide headers console output, e.g. when script runs in the context of a parent script.

.PARAMETER ShowLogs
Show all logs in terminal

.PARAMETER AdditionalHooksDir
Directory containing additional hooks to be executed after local hooks are executed.

.EXAMPLE
PS> Start_MultiVMK8sSetup.ps1

.EXAMPLE
PS> Start_MultiVMK8sSetup.ps1 -HideHeaders $true
Header log entries will not be written/logged to the console.

.EXAMPLE
PS> Start_MultiVMK8sSetup.ps1 -AdditonalHooks 'C:\AdditionalHooks'
For specifying additional hooks to be executed.

#>

param(
    [parameter(Mandatory = $false, HelpMessage = 'Set to TRUE to omit script headers.')]
    [switch] $HideHeaders = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = ''
)

#################################################################################################
# FUNCTIONS                                                                                     #
#################################################################################################

function Get-IsAtLeastOneNodeOnline () {
    return ((Get-IsVmOperating -VmName $global:MultiVMWindowsVMName) -eq $true) -or ((Get-IsVmOperating -VmName $global:VMName) -eq $true)
}

function Start-SleepWithProgress {
    param (
        [Parameter(Mandatory = $true)]
        [int]$Seconds
    )

    $elapsedSeconds = 0
    $intervalSeconds = 1

    Write-Log "Waiting for $($Seconds)s ..."

    do {
        Write-Log '.<<<'

                Start-Sleep -Seconds $intervalSeconds

        $elapsedSeconds += $intervalSeconds

    } while ($elapsedSeconds -lt $Seconds)

    if ($elapsedSeconds -gt 0) {
        Write-Log '.'
    }
}

#################################################################################################
# SCRIPT START                                                                                  #
#################################################################################################

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1
Import-Module "$PSScriptRoot/../../addons/addons.module.psm1"

Import-Module "$PSScriptRoot/../ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

if ($Trace) {
    Set-PSDebug -Trace 1
}

if ($HideHeaders -ne $true) {
    Write-Log '---------------------------------------------------------------'
    Write-Log 'Multi-VM Kubernetes starting ...'
    Write-Log '---------------------------------------------------------------'
}

if (Get-IsAtLeastOneNodeOnline) {
    Write-Log 'At least one node is online, stopping them first ...'

    & "$global:KubernetesPath\smallsetup\multivm\Stop_MultiVMK8sSetup.ps1" -HideHeaders -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs

    Start-SleepWithProgress 10
}

$WSL = Get-WSLFromConfig
$switchname = ''
if ($WSL) {
    Write-Log 'Using WSL2 as hosting environment for KubeMaster'
    $switchname = $global:WSLSwitchName
}
else {
    Write-Log 'Using Hyper-V as hosting environment for KubeMaster'
    $switchname = $global:SwitchName
}

$linuxOnly = Get-LinuxOnlyFromConfig

if ($linuxOnly -eq $true) {
    Write-Log 'K8s cluster is starting in Linux-only mode'
}

# set ConfigKey_LoggedInRegistry empty, since not logged in into registry after restart anymore
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry -Value ''

Write-Log 'Configuring network for VMs' -Console

# Remove old switch
Write-Log 'Updating VM networking ...'
# TODO: already done in stop script
if (!$WSL) {
    Get-VMNetworkAdapter -VMName $global:VMName | Disconnect-VMNetworkAdapter
}

if ($linuxOnly -ne $true) {
    # TODO: already done in stop script
    Get-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName | Disconnect-VMNetworkAdapter
}

# TODO: already done in stop script
$sw = Get-VMSwitch -Name $global:SwitchName -ErrorAction SilentlyContinue
if ( $sw ) {
    Remove-VMSwitch -Name $global:SwitchName -Force
}

# create internal switch for VM
if (!$WSL) {
    New-VMSwitch -Name $global:SwitchName -SwitchType Internal -MinimumBandwidthMode Weight | Out-Null
    New-NetIPAddress -IPAddress $global:IP_NextHop -PrefixLength 24 -InterfaceAlias "vEthernet ($global:SwitchName)" | Out-Null
    # add DNS proxy for cluster searches
    Add-DnsServer $global:SwitchName

    # connect VM to switch
    $ad = Get-VMNetworkAdapter -VMName $global:VMName
    if ( !($ad) ) {
        Write-Log "Adding network adapter to VM '$global:VMName' ..."
        Add-VMNetworkAdapter -VMName $global:VMName -Name 'Network Adapter'
    }

    Connect-VMNetworkAdapter -VMName $global:VMName -SwitchName $global:SwitchName

    Write-Log "Starting $global:VMName VM" -Console
    Start-VirtualMachine -VmName $global:VMName
}
else {
    Write-Log 'Configuring KubeMaster Distro' -Console
    wsl --shutdown
    Start-WSL
    Set-WSLSwitch
    # add DNS proxy for cluster searches
    Add-DnsServer $switchname
}

if ($linuxOnly -ne $true) {
    $nad = Get-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName
    if ( !($nad) ) {
        Write-Log "Adding network adapter to VM '$global:MultiVMWindowsVMName' ..."
        Add-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName -Name 'Network Adapter'
    }

    Connect-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName -SwitchName $switchname

    Write-Log "Starting $global:MultiVMWindowsVMName VM" -Console
    Start-VirtualMachine -VmName $global:MultiVMWindowsVMName -Wait

    Wait-ForSSHConnectionToWindowsVMViaSshKey

    $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

    Invoke-Command -Session $session {
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1
        Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
        Initialize-Logging -Nested:$true

        Set-IndexForDefaultSwitch

        Set-SpecificVFPRules
    }

    Write-Log "Set IP address: $global:MultiVMWinNodeIP"
}

# configure NAT
Write-Log 'Configure NAT ...'
if (Get-NetNat -Name $global:NetNatName -ErrorAction SilentlyContinue) {
    Write-Log " $global:NetNatName exists, removing it ..."
    Remove-NetNat -Name $global:NetNatName -Confirm:$False | Out-Null
}

New-NetNat -Name $global:NetNatName -InternalIPInterfaceAddressPrefix $global:IP_CIDR | Out-Null

$ErrorActionPreference = 'Continue'

Wait-ForSSHConnectionToLinuxVMViaSshKey

if ($linuxOnly -ne $true) {
    Wait-ForSSHConnectionToWindowsVMViaSshKey
}

Perform-TimeSync

$ErrorActionPreference = 'Stop'

# TODO: code clone from Stop script
# route for VM
Write-Log "Remove obsolete route to $global:IP_CIDR"
Invoke-ExpressionAndCheckExitCode "route delete $global:IP_CIDR >`$null 2>&1"

Write-Log "Add route to $global:IP_CIDR"
route -p add $global:IP_CIDR $global:IP_NextHop METRIC 3 | Out-Null

# routes for Linux pods
Write-Log "Remove obsolete route to $global:ClusterCIDR_ServicesLinux"
Invoke-ExpressionAndCheckExitCode "route delete $global:ClusterCIDR_ServicesLinux >`$null 2>&1"
Write-Log "Add route to $global:ClusterCIDR_ServicesLinux"
route -p add $global:ClusterCIDR_ServicesLinux $global:IP_Master METRIC 6 | Out-Null
Write-Log "Remove obsolete route to $global:ClusterCIDR_ServicesWindows"
Invoke-ExpressionAndCheckExitCode "route delete $global:ClusterCIDR_ServicesWindows >`$null 2>&1"
Write-Log "Add route to $global:ClusterCIDR_ServicesWindows"
route -p add $global:ClusterCIDR_ServicesWindows $global:IP_Master METRIC 7 | Out-Null

Write-Log "Remove obsolete route to $global:ClusterCIDR_Host"
Invoke-ExpressionAndCheckExitCode "route delete $global:ClusterCIDR_Host >`$null 2>&1"
Write-Log "Add route to $global:ClusterCIDR_Host"
route -p add $global:ClusterCIDR_Host $global:MultiVMWinNodeIP METRIC 8 | Out-Null

Write-Log "Remove obsolete route to $global:ClusterCIDR_Master"
Invoke-ExpressionAndCheckExitCode "route delete $global:ClusterCIDR_Master >`$null 2>&1"
Write-Log "Add route to $global:ClusterCIDR_Master"
route -p add $global:ClusterCIDR_Master $global:IP_Master METRIC 9 | Out-Null

# enable ip forwarding
netsh int ipv4 set int "vEthernet ($switchname)" forwarding=enabled | Out-Null
netsh int ipv4 set int 'vEthernet (Ethernet)' forwarding=enabled | Out-Null

Invoke-Hook -HookName 'BeforeStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

Wait-ForSSHConnectionToLinuxVMViaSshKey

if ($linuxOnly -ne $true) {

    $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

    Invoke-Command -Session $session {
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        # load global settings
        &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1

        # import global functions
        . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1
        Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
        Initialize-Logging -Nested:$true

        Write-Output 'Starting K8s services'

        $adapterName = Get-L2BridgeNIC
        Write-Output "Using network adapter '$adapterName'"
        Import-Module "$global:KubernetesPath\smallsetup\LoopbackAdapter.psm1" -Force
        Set-LoopbackAdapterProperties -Name $global:LoopbackAdapter -IPAddress $global:IP_LoopbackAdapter -Gateway $global:Gateway_LoopbackAdapter
        Import-Module "$global:KubernetesPath\smallsetup\hns.v2.psm1" -WarningAction:SilentlyContinue -Force
        CreateExternalSwitch -adapterName $adapterName

        $ipindexEthernet = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*vEthernet ($adapterName*)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
        $loopbackAdapterAlias = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*vEthernet ($adapterName*)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'InterfaceAlias'

        Set-IPAdressAndDnsClientServerAddress -IPAddress $global:IP_LoopbackAdapter -DefaultGateway $global:Gateway_LoopbackAdapter -Index $ipindexEthernet
        netsh int ipv4 set int "$loopbackAdapterAlias" forwarding=enabled | Out-Null
        netsh int ipv4 set int "Ethernet" forwarding=enabled | Out-Null

        Start-ServiceAndSetToAutoStart -Name 'containerd'
        Start-ServiceAndSetToAutoStart -Name 'flanneld'
        Start-ServiceAndSetToAutoStart -Name 'kubelet'
        Start-ServiceAndSetToAutoStart -Name 'kubeproxy'
        Start-ServiceAndSetToAutoStart -Name 'windows_exporter'

        # loop to check the state of the services for Kubernetes
        $i = 0;
        $cbr0Stopwatch = [system.diagnostics.stopwatch]::StartNew()

        Write-Output 'waiting for cbr0 switch to be created by flanneld...'
        Start-Sleep -s 2

        Write-Output 'Be prepared for several seconds of disconnected network!'
        Start-Sleep -s 1

        $SleepInLoop = 2
        $AutoconfigDetected = 0
        $lastShownFlannelPid = 0
        $FlannelStartDetected = 0

        while ($true) {
            $i++
            $currentFlannelPid = (Get-Process flanneld -ErrorAction SilentlyContinue).Id
            Write-NodeServiceStatus -Iteration $i

            if ($currentFlannelPid -ne $null -and $currentFlannelPid -ne $lastShownFlannelPid) {
                $FlannelStartDetected++
                if ($FlannelStartDetected -gt 1) {
                    Write-Output "           PID for flanneld service: $currentFlannelPid  (restarted after failure)"
                }
                else {
                    Write-Output "           PID for flanneld service: $currentFlannelPid"
                }
                $lastShownFlannelPid = $currentFlannelPid
            }
            $cbr0 = Get-NetIpInterface | Where-Object InterfaceAlias -Like '*cbr0*' | Where-Object AddressFamily -Eq IPv4

            if ( $cbr0 ) {
                Write-Output '           OK: cbr0 switch is now found'
                Write-Output "`nOK: cbr0 switch is now found"

                # change firewall connection profile
                Write-Output "Set connection profile for firewall rules to 'Private'"
                $ProgressPreference = 'SilentlyContinue'
                Set-InterfacePrivate -InterfaceAlias "$loopbackAdapterAlias"

                Write-Output 'Change metrics at network interfaces'
                # change index
                $ipindex2 = Get-NetIPInterface | Where-Object InterfaceAlias -Like '*Default*' | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
                if ( $ipindex2 ) {
                    Write-Log "Index for interface Default : ($ipindex2) -> metric 35"
                    Set-NetIPInterface -InterfaceIndex $ipindex2 -InterfaceMetric 35
                }

                $l2BridgeInterfaceIndex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*$global:L2BridgeSwitchName*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
                Set-NetIPInterface -InterfaceIndex $l2BridgeInterfaceIndex -InterfaceMetric 5
                Write-Output "Index for interface $global:L2BridgeSwitchName : ($l2BridgeInterfaceIndex) -> metric 5"

                Write-Output 'Adding DNS server for internet lookup'
                netsh interface ip set dns "$loopbackAdapterAlias" static 8.8.8.8

                # routes for Windows pods
                Write-Output "Remove obsolete route to $global:ClusterCIDR_Host"
                route delete $global:ClusterCIDR_Host >$null 2>&1
                Write-Output "Add route to $global:ClusterCIDR_Host"
                route -p add $global:ClusterCIDR_Host $global:ClusterCIDR_NextHop METRIC 5 | Out-Null

                Write-Output "Networking setup done.`n"
                break;
            }
            else {
                Write-Output '           No cbr0 switch created so far...'

                # set fixed ip address
                netsh interface ip set address name="$loopbackAdapterAlias" static $global:IP_LoopbackAdapter 255.255.255.0 $global:Gateway_LoopbackAdapter

                # check total duration
                if ($cbr0Stopwatch.Elapsed.TotalSeconds -gt 150) {
                    Stop-Service flanneld
                    Write-Output "FAIL: No cbr0 switch found, timeout. Aborting.`n"
                    Write-Output 'flanneld logging is in C:\var\log\flanneld, look for errors there'
                    Write-Output "`n`nAlready known reasons for this cbr0 problem:"
                    Write-Output ' * Usage of certain docking stations: Try to connect the ethernet cable directly'
                    Write-Output '   to your PC, not with a docking station'
                    Write-Output ' * Usage of WLAN: Try to connect with cable, not WiFi'
                    Write-Output ' * Windows IP autoconfiguration APIPA: Try to run'
                    Write-Output "     powershell $global:KubernetesPath\smallsetup\FixAutoconfiguration.ps1"
                    Write-Output ''
                    throw 'timeout: flanneld failed to create cbr0 switch'
                }
                $ip = (Get-NetIPAddress -InterfaceAlias 'vEthernet (Ethernet)' -ErrorAction SilentlyContinue )
                if ($ip -ne $null -and $ip.IPAddress -match '^169.254.' -and $ip.AddressState -match '^Prefer'  ) {
                    # IP 169.254.x.y is chosen by Windows Autoconfig APIPA. This is fatal for us.
                    # Make sure that it is not only a transient problem, wait for at least 4 times
                    $AutoconfigDetected++;
                }
                if ($AutoconfigDetected -ge 4) {
                    Write-Output "FAIL: interface 'vEthernet (Ethernet)' was configured by Windows autoconfiguration. Aborting.`n"
                    Write-Output "`n`nERROR: network interface 'vEthernet (Ethernet)' was reconfigured by Windows IP autoconfiguration!"
                    Write-Output 'This prevents K8s networking to startup properly. You must disable autoconfiguration'
                    Write-Output 'in the registry. Do the following steps as administrator:'
                    Write-Output " - powershell $global:KubernetesPath\smallsetup\FixAutoconfiguration.ps1"
                    Write-Output ' - netcfg -d'
                    Write-Output ' - reboot machine'
                    Write-Output " - try Startk8s.cmd again.`n"
                    Stop-Service flanneld
                    throw 'Fatal: interface was reconfigured by Windows autoconfiguration'
                }

                if ($i -eq 10) {
                    $SleepInLoop = 5
                }

                Write-Output "No cbr0 switch found, still waiting...`n"
            }

            Start-Sleep -s $SleepInLoop
        }

        Start-ServiceAndSetToAutoStart -Name 'httpproxy'
    }

    # wait a bit to let VM come up completely
    Start-Sleep 2
}

if ($linuxOnly -eq $true) {
    Update-NodeLabelsAndTaints
}
else {
    Update-NodeLabelsAndTaints -WorkerMachineName $global:MultiVMWindowsVMName
}

Invoke-AddonsHooks -HookType 'AfterStart'

Invoke-Hook -HookName 'AfterStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

if ($HideHeaders -ne $true) {
    Write-Log '---------------------------------------------------------------'
    Write-Log 'Multi-VM Kubernetes started and operational.'
    Write-Log '---------------------------------------------------------------'
}