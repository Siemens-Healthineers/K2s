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
PS> .\lib\scripts\multivm\start\Start.ps1

.EXAMPLE
PS> .\lib\scripts\multivm\start\Start.ps1 -HideHeaders $true
Header log entries will not be written/logged to the console.

.EXAMPLE
PS> .\lib\scripts\multivm\start\Start.ps1 -AdditonalHooks 'C:\AdditionalHooks'
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

$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule
$kubePath = Get-KubePath
Import-Module "$kubePath/addons/addons.module.psm1"

$controlPlaneHostName = Get-ConfigControlPlaneNodeHostname
$multiVMWindowsVMName = Get-ConfigVMNodeHostname

#################################################################################################
# FUNCTIONS                                                                                     #
#################################################################################################

function Get-IsAtLeastOneNodeOnline () {
    return ((Get-IsVmOperating -VmName $multiVMWindowsVMName) -eq $true) -or ((Get-IsVmOperating -VmName $controlPlaneHostName) -eq $true)
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

# run command silently to suppress non-error output that get treated as errors
function Invoke-ExpressionAndCheckExitCode($commandExpression) {
    $tempErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'

    Invoke-Expression $commandExpression

    if ($LastExitCode -ne 0) {
        Write-Log "Command caused silently an unknown error. Re-running this command with `$ErrorActionPreference = 'Stop' to catch the error message..."

        $ErrorActionPreference = 'Stop'

        Invoke-Expression $commandExpression
    }

    $ErrorActionPreference = $tempErrorActionPreference
}

#################################################################################################
# SCRIPT START                                                                                  #
#################################################################################################

Initialize-Logging -ShowLogs:$ShowLogs
$ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
$ipNextHop = Get-ConfiguredKubeSwitchIP
$ipControlPlane = Get-ConfiguredIPControlPlane
$setupConfigRoot = Get-RootConfigk2s
$clusterCIDRMaster = $setupConfigRoot.psobject.properties['podNetworkMasterCIDR'].value
$clusterCIDRWorker = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR'].value
$clusterCIDRServicesLinux = $setupConfigRoot.psobject.properties['servicesCIDRLinux'].value
$clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value
$clusterCIDRNextHop = $setupConfigRoot.psobject.properties['cbr0'].value

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

    & "$PSScriptRoot\..\stop\Stop.ps1" -HideHeaders -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs

    Start-SleepWithProgress 10
}

$switchname = Get-ControlPlaneNodeDefaultSwitchName

# set ConfigKey_LoggedInRegistry empty, since not logged in into registry after restart anymore
Set-ConfigLoggedInRegistry -Value ''

Write-Log 'Configuring network for VMs' -Console

# Remove old switch
Write-Log 'Updating VM networking ...'
Get-VMNetworkAdapter -VMName $controlPlaneHostName | Disconnect-VMNetworkAdapter
Get-VMNetworkAdapter -VMName $multiVMWindowsVMName | Disconnect-VMNetworkAdapter
$sw = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if ( $sw ) {
    Remove-VMSwitch -Name $switchName -Force
}

New-VMSwitch -Name $switchName -SwitchType Internal -MinimumBandwidthMode Weight | Out-Null
New-NetIPAddress -IPAddress $ipNextHop -PrefixLength 24 -InterfaceAlias "vEthernet ($switchName)" | Out-Null
# add DNS proxy for cluster searches
Add-DnsServer $switchName

# connect VM to switch
$ad = Get-VMNetworkAdapter -VMName $controlPlaneHostName
if ( !($ad) ) {
    Write-Log "Adding network adapter to VM '$controlPlaneHostName' ..."
    Add-VMNetworkAdapter -VMName $controlPlaneHostName -Name 'Network Adapter'
}

Connect-VMNetworkAdapter -VMName $controlPlaneHostName -SwitchName $switchName

Write-Log "Starting $controlPlaneHostName VM" -Console
Start-VirtualMachine -VmName $controlPlaneHostName

$nad = Get-VMNetworkAdapter -VMName $multiVMWindowsVMName
if ( !($nad) ) {
    Write-Log "Adding network adapter to VM '$multiVMWindowsVMName' ..."
    Add-VMNetworkAdapter -VMName $multiVMWindowsVMName -Name 'Network Adapter'
}

Connect-VMNetworkAdapter -VMName $multiVMWindowsVMName -SwitchName $switchname

Write-Log "Starting $multiVMWindowsVMName VM" -Console
Start-VirtualMachine -VmName $multiVMWindowsVMName -Wait

Wait-ForSSHConnectionToWindowsVMViaSshKey

$session = Open-DefaultWinVMRemoteSessionViaSSHKey

Invoke-Command -Session $session {
    Set-Location "$env:SystemDrive\k"
    Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

    Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
    Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
    Initialize-Logging -Nested:$true

    Set-IndexForDefaultSwitch

    Set-VMVFPRules
}

$rootConfig = Get-RootConfigk2s
$multivmRootConfig = $rootConfig.psobject.properties['multivm'].value
$multiVMWinNodeIP = $multivmRootConfig.psobject.properties['multiVMK8sWindowsVMIP'].value

Write-Log "Set IP address: $multiVMWinNodeIP"

# configure NAT
Invoke-RecreateNAT
New-DefaultNetNat

$ErrorActionPreference = 'Continue'

Wait-ForSSHConnectionToLinuxVMViaSshKey
Wait-ForSSHConnectionToWindowsVMViaSshKey

Invoke-TimeSync -WorkerVM:$true

$ErrorActionPreference = 'Stop'

# TODO: code clone from Stop script
# route for VM
Write-Log "Remove obsolete route to $ipControlPlaneCIDR"
Invoke-ExpressionAndCheckExitCode "route delete $ipControlPlaneCIDR >`$null 2>&1"

Write-Log "Add route to $ipControlPlaneCIDR"
route -p add $ipControlPlaneCIDR $ipNextHop METRIC 3 | Out-Null

# routes for Linux pods
Write-Log "Remove obsolete route to $clusterCIDRServicesLinux"
Invoke-ExpressionAndCheckExitCode "route delete $clusterCIDRServicesLinux >`$null 2>&1"
Write-Log "Add route to $clusterCIDRServicesLinux"
route -p add $clusterCIDRServicesLinux $ipControlPlane METRIC 6 | Out-Null
Write-Log "Remove obsolete route to $clusterCIDRServicesWindows"
Invoke-ExpressionAndCheckExitCode "route delete $clusterCIDRServicesWindows >`$null 2>&1"
Write-Log "Add route to $clusterCIDRServicesWindows"
route -p add $clusterCIDRServicesWindows $ipControlPlane METRIC 7 | Out-Null

Write-Log "Remove obsolete route to $clusterCIDRWorker"
Invoke-ExpressionAndCheckExitCode "route delete $clusterCIDRWorker >`$null 2>&1"
Write-Log "Add route to $clusterCIDRWorker"
route -p add $clusterCIDRWorker $multiVMWinNodeIP METRIC 8 | Out-Null

Write-Log "Remove obsolete route to $clusterCIDRMaster"
Invoke-ExpressionAndCheckExitCode "route delete $clusterCIDRMaster >`$null 2>&1"
Write-Log "Add route to $clusterCIDRMaster"
route -p add $clusterCIDRMaster $ipControlPlane METRIC 9 | Out-Null

# enable ip forwarding
netsh int ipv4 set int "vEthernet ($switchname)" forwarding=enabled | Out-Null
netsh int ipv4 set int 'vEthernet (Ethernet)' forwarding=enabled | Out-Null

Invoke-Hook -HookName 'BeforeStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

Wait-ForSSHConnectionToLinuxVMViaSshKey

$session = Open-DefaultWinVMRemoteSessionViaSSHKey

Invoke-Command -Session $session {
    Set-Location "$env:SystemDrive\k"
    Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

    Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
    Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
    Initialize-Logging -Nested:$true

    Write-Output 'Starting Kubernetes services on vm node'

    $adapterName = Get-L2BridgeName
    Write-Output "Using network adapter '$adapterName'"
    Enable-LoopbackAdapter

    New-ExternalSwitch -adapterName $adapterName

    $ipindexEthernet = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*vEthernet ($adapterName*)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
    $loopbackAdapterAlias  = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*vEthernet ($adapterName*)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'InterfaceAlias'

    $ipAddressForLoopbackAdapter = Get-LoopbackAdapterIP
    $ipGatewayLoopbackAdapter = Get-LoopbackAdapterGateway
    Set-IPAdressAndDnsClientServerAddress -IPAddress $ipAddressForLoopbackAdapter -DefaultGateway $ipGatewayLoopbackAdapter -Index $ipindexEthernet
    Set-DnsClient -InterfaceIndex $ipindexEthernet -RegisterThisConnectionsAddress $false | Out-Null
    netsh int ipv4 set int "$loopbackAdapterAlias" forwarding=enabled | Out-Null
    netsh int ipv4 set int 'Ethernet' forwarding=enabled | Out-Null

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

            $l2BridgeSwitchName = Get-L2BridgeSwitchName
            $l2BridgeInterfaceIndex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*$l2BridgeSwitchName*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
            Set-NetIPInterface -InterfaceIndex $l2BridgeInterfaceIndex -InterfaceMetric 5
            Write-Output "Index for interface $l2BridgeSwitchName : ($l2BridgeInterfaceIndex) -> metric 5"

            Write-Output 'Adding DNS server for internet lookup'
            netsh interface ip set dns "$loopbackAdapterAlias" static 8.8.8.8

            # routes for Windows pods
            Write-Output "Remove obsolete route to $using:clusterCIDRWorker"
            route delete $using:clusterCIDRWorker >$null 2>&1
            Write-Output "Add route to $using:clusterCIDRWorker"
            route -p add $using:clusterCIDRWorker $using:clusterCIDRNextHop METRIC 5 | Out-Null

            Write-Output "Networking setup done.`n"
            break;
        }
        else {
            Write-Output '           No cbr0 switch created so far...'

            # set fixed ip address
            netsh interface ip set address name="$loopbackAdapterAlias" static $ipAddressForLoopbackAdapter 255.255.255.0 $ipGatewayLoopbackAdapter

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
                Write-Output "     powershell $kubePath\smallsetup\FixAutoconfiguration.ps1"
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
                Write-Output " - powershell $kubePath\smallsetup\FixAutoconfiguration.ps1"
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

Update-NodeLabelsAndTaints -WorkerMachineName $multiVMWindowsVMName

Invoke-AddonsHooks -HookType 'AfterStart'

Invoke-Hook -HookName 'AfterStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

if ($HideHeaders -ne $true) {
    Write-Log '---------------------------------------------------------------'
    Write-Log 'Multi-VM Kubernetes started and operational.'
    Write-Log '---------------------------------------------------------------'
}