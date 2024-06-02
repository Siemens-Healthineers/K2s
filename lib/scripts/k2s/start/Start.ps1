# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
This script is only valid for the K2s Setup installed with Install.ps1
It starts the kubernetes cluster again, after it has been stopped with Stop.ps1

.DESCRIPTION
t.b.d.
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Number of processors for VM')]
    [string] $VmProcessors,
    [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
    [switch] $ResetHns = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Do not check current IP at start')]
    [switch] $SkipIpCheck = $false,
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

# script variables:
$script:fixedIpWasSet = $false

function Get-NeedsStopFirst () {
    if ((Get-Process 'flanneld' -ErrorAction SilentlyContinue) -or
            (Get-Process 'kubelet' -ErrorAction SilentlyContinue) -or
            (Get-Process 'kube-proxy' -ErrorAction SilentlyContinue)) {
        return $true
    }
    return $false
}

function Update-IpAddress {
    param (
        [Parameter()]
        [string] $adapterName,
        [Parameter()]
        [string] $gateway
    )
    # Do this only once, guarded by $fixedIpWasSet
    if (!$fixedIpWasSet) {
        $ipAddressForLoopbackAdapter = Get-LoopbackAdapterIP

        Write-Log 'Try to get the valid network interface'
        $ipindex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*vEthernet ($adapterName)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
        if ( $ipindex ) {
            Write-Log "           interface 'vEthernet ($adapterName)' with index $ipindex found:"
            $ipaddress = $ipAddressForLoopbackAdapter
            Write-Log "           setting IP address manually to $ipaddress"
            Write-Log "           setting IP address 'vEthernet ($adapterName)' with index $ipindex manually to $ipaddress"
            Set-NetIPInterface -InterfaceIndex $ipindex -Dhcp Disabled
            Write-Log '           Checking whether Physical adapter has DNS Servers'
            $loopbackAdapter = Get-L2BridgeName
            $physicalInterfaceIndex = Get-NetAdapter -Physical | Where-Object Status -Eq 'Up' | Where-Object Name -ne $loopbackAdapter | Select-Object -expand 'ifIndex'
            $dnservers = Get-DnsClientServerAddress -InterfaceIndex $physicalInterfaceIndex -AddressFamily IPv4
            Write-Log "           DNSServers found in Physical Adapter ($physicalInterfaceIndex) : $($dnservers.ServerAddresses)"
            Set-IPAdressAndDnsClientServerAddress -IPAddress $ipaddress -DefaultGateway $gateway -Index $ipindex -DnsAddresses $dnservers.ServerAddresses
            $script:fixedIpWasSet = $true
        }
        else {
            Write-Log "           interface 'vEthernet ($adapterName)' not yet available"
        }
    }
}

function GetNetworkAdapterNameFromInterfaceAlias([string]$interfaceAlias) {
    [regex]$regex = ".*\((.*)\).*"
    $foundValue = ""
    $result = $regex.match($interfaceAlias)
    if ($result.Success -and $result.Groups.Count -gt 1) {
        $foundValue = $result.Groups[1].Value
    }
    return $foundValue
}

function EnsureDirectoryPathExists(
    [string]$DirPath
) {
    if (-not (Test-Path $DirPath)) {
        New-Item -Path $DirPath -ItemType Directory -Force | Out-Null
    }
}

# in case of other drives a specific flannel file needs to created automatically on drive
# kubelet unfortunately has no central way to configure centrally drive in windows
function CheckFlannelConfig () {
    $flannelFile = "$(Get-InstallationDriveLetter):\run\flannel\subnet.env"
    $existsFlannelFile = Test-Path -Path $flannelFile
    if( $existsFlannelFile ) {
        Write-Log "Flannel file $flannelFile exists"
        return
    }
    # only in case that we used another drive than C for the installation
    if( !(Get-InstallationDriveLetter -eq Get-SystemDriveLetter)) {
        $i = 0
        $flannelFileSource = "$(Get-SystemDriveLetter):\run\flannel\subnet.env"
        Write-Log "Check $flannelFileSource file creation, this can take minutes depending on your network setup ..."
        while ($true) {
            $i++
            Write-Log "flannel handling loop (iteration #$i):"
            if( Test-Path -Path $flannelFileSource ) {
                $targetPath = "$(Get-InstallationDriveLetter):\run\flannel"
                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                Copy-Item -Path $flannelFileSource -Destination $targetPath -Force | Out-Null
                break
            }
            Start-Sleep -s 5

            # End the loop
            if ($i -eq 50) {
                throw "Fatal: Flannel failed to create file: $flannelFileSource for target drive $(Get-InstallationDriveLetter):\run\flannel\subnet.env !"
            }
        }
    }
}

if ($SkipHeaderDisplay -ne $true) {
    Write-Log 'Starting kubernetes cluster on Windows host' -Console
}

Write-Log 'Checking prerequisites'

Set-ConfigLoggedInRegistry -Value ''

$HostGW = Get-ConfigHostGW
if ($HostGW) {
    Write-Log 'Using host-gw as network mode'
}
else {
    Write-Log 'Using vxlan as network mode'
}

$WSL = Get-ConfigWslFlag
if ($WSL) {
    Write-Log 'Using WSL2 as hosting environment for control plane node'
}
else {
    Write-Log 'Using Hyper-V as hosting environment for control plane node'
}

if (Get-NeedsStopFirst) {
    Write-Log 'Stopping existing kubernetes cluster on Windows host'
    &"$PSScriptRoot\..\stop\Stop.ps1" -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay
    Start-Sleep 10
}

if ($ResetHns) {
    Write-Log 'Doing a full reset of the HNS network'
    Get-HNSNetwork | Remove-HNSNetwork
}

$ProgressPreference = 'SilentlyContinue'

Enable-LoopbackAdapter

$NumOfProcessors = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
if ([int]$NumOfProcessors -lt 4) {
    throw 'You need at least 4 logical processors'
}

if ($VmProcessors -ne '') {
    # Do not reset VMProcessorCount with default value unless supplied from the user
    if ([int]$VmProcessors -ge [int]$NumOfProcessors) {
        $VmProcessors = [int]$NumOfProcessors
        Write-Log "Reduced number of cores for VM to $VmProcessors"
    }
}

$switchname = Get-ControlPlaneNodeDefaultSwitchName

Write-Log 'Configuring network for windows node' -Console
Restart-WinService 'vmcompute'
Restart-WinService 'hns'
Restart-NlaSvc

$adapterName = Get-L2BridgeName
Write-Log "Using network adapter '$adapterName'"

Write-Log 'Figuring out IPv4DefaultGateway'
$if = Get-NetIPConfiguration -InterfaceAlias "$adapterName" -ErrorAction SilentlyContinue 2>&1 | Out-Null
$gw =  $global:Gateway_LoopbackAdapter
if( $if ) {
    $gw = $if.IPv4DefaultGateway.NextHop
    Write-Log "Gateway found: $gw"
}

Set-IndexForDefaultSwitch

# create the l2 bridge in advance
New-ExternalSwitch -adapterName $adapterName

# Because of stability issues network settings are recreated every time we start the machine
# or we restart the service !!!!! (StopServices.ps1 also cleans up the entire network setup)
# stop VM
Write-Log 'Reconfiguring VM'
$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
Write-Log "Configuring $controlPlaneVMHostName VM" -Console
Stop-VM -Name $controlPlaneVMHostName -Force -WarningAction SilentlyContinue

if ($VmProcessors -ne '') {
    # change cores
    Set-VMProcessor $controlPlaneVMHostName -Count $VmProcessors
}

# Remove old switch
Write-Log 'Updating VM networking...'
Remove-KubeSwitch

# create internal switch for VM
New-KubeSwitch

# connect VM to switch
Connect-KubeSwitch

# add DNS proxy for cluster searches
Add-DnsServer $switchname

Invoke-RecreateNAT

$controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
$ipControlPlane = Get-ConfiguredIPControlPlane

$i = 0;
while ($true) {
    $i++
    Write-Log "VM Handling loop (iteration #$i):"
    Start-Sleep -s 4

    if ( $i -eq 1 ) {
        Write-Log "           stopping VM ($i)"
        Stop-VM -Name $controlPlaneVMHostName -Force -WarningAction SilentlyContinue

        $state = (Get-VM -Name $controlPlaneVMHostName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
        while (!$state) {
            Write-Log "           still waiting for stop, current VM state: $(Get-VM -Name $controlPlaneVMHostName | Select-Object -expand 'State')"
            Start-Sleep -s 1
        }

        Write-Log "           re-starting VM ($i)"
        Start-VM -Name $controlPlaneVMHostName
        Start-Sleep -s 4
    }

    $con = Test-Connection $ipControlPlane -Count 1 -ErrorAction SilentlyContinue
    if ($con) {
        Write-Log "           ping succeeded to $controlPlaneVMHostName VM"
        $startStatus = (Get-VM -Name $controlPlaneVMHostName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Running
        if ($startStatus) {
            Write-Log "           $controlPlaneVMHostName VM Started"
            break;
        }
    }

    if ($i -eq 3) {
        # If the connection did not succeed or VM is not in Running state, try starting again for three times
        $startCycle = 0
        $startState = (Get-VM -Name $controlPlaneVMHostName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Running
        while (!$startState -And $startCycle -lt 3) {
            $startCycle++
            Write-Log "           still waiting for start, current VM state: $(Get-VM -Name $controlPlaneVMHostName | Select-Object -expand 'State')"
            Start-VM -Name $controlPlaneVMHostName
            Start-Sleep -s 4
            $startState = (Get-VM -Name $controlPlaneVMHostName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Running
        }
    }

    # End the loop if the connection to VM is unsuccessful
    if ($i -eq 10) {
        throw "Fatal: Failed to connect to $controlPlaneVMHostName VM"
    }
}

Wait-ForSSHConnectionToLinuxVMViaSshKey

Invoke-TimeSync

$ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
$ipNextHop = Get-ConfiguredKubeSwitchIP
$ipControlPlane = Get-ConfiguredIPControlPlane
$setupConfigRoot = Get-RootConfigk2s
$clusterCIDRMaster = $setupConfigRoot.psobject.properties['podNetworkMasterCIDR'].value
$clusterCIDRServices = $setupConfigRoot.psobject.properties['servicesCIDR'].value
$clusterCIDRServicesLinux = $setupConfigRoot.psobject.properties['servicesCIDRLinux'].value
$clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value
$clusterCIDRHost = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR'].value
$clusterCIDRNextHop = $setupConfigRoot.psobject.properties['cbr0'].value

# route for VM
Write-Log "Remove obsolete route to $ipControlPlaneCIDR"
route delete $ipControlPlaneCIDR >$null 2>&1
Write-Log "Add route to $ipControlPlaneCIDR"
route -p add $ipControlPlaneCIDR $ipNextHop METRIC 3 | Out-Null

# routes for Linux pods
Write-Log "Remove obsolete route to $clusterCIDRMaster"
route delete $clusterCIDRMaster >$null 2>&1
Write-Log "Add route to $clusterCIDRMaster"
route -p add $clusterCIDRMaster $ipControlPlane METRIC 4 | Out-Null

# routes for services
route delete $clusterCIDRServices >$null 2>&1
Write-Log "Remove obsolete route to $clusterCIDRServicesLinux"
route delete $clusterCIDRServicesLinux >$null 2>&1
Write-Log "Add route to $clusterCIDRServicesLinux"
route -p add $clusterCIDRServicesLinux $ipControlPlane METRIC 6 | Out-Null
Write-Log "Remove obsolete route to $clusterCIDRServicesWindows"
route delete $clusterCIDRServicesWindows >$null 2>&1
Write-Log "Add route to $clusterCIDRServicesWindows"
route -p add $clusterCIDRServicesWindows $ipControlPlane METRIC 7 | Out-Null

# enable ip forwarding
netsh int ipv4 set int "vEthernet ($switchname)" forwarding=enabled | Out-Null
netsh int ipv4 set int 'vEthernet (Ethernet)' forwarding=enabled | Out-Null

Invoke-Hook -HookName 'BeforeStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

Write-Log "Ensure service log directories exists" -Console
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\containerd"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\dnsproxy"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\dockerd"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\flanneld"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\httpproxy"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\kubelet"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\windows_exporter"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\containers"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\pods"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\bridge"
EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\vfprules"

Write-Log 'Starting Kubernetes services on the Windows node' -Console

Start-ServiceAndSetToAutoStart -Name 'containerd'
Start-ServiceAndSetToAutoStart -Name 'flanneld' -IgnoreErrors
Start-ServiceAndSetToAutoStart -Name 'kubelet'
Start-ServiceAndSetToAutoStart -Name 'kubeproxy'
Start-ServiceAndSetToAutoStart -Name 'windows_exporter'


# loop to check the state of the services for Kubernetes
$i = 0;
$cbr0Stopwatch = [system.diagnostics.stopwatch]::StartNew()
Write-Log 'waiting for cbr0 switch to be created by flanneld...'
Start-Sleep -s 2
Write-Log 'Be prepared for several seconds of disconnected network!'
Start-Sleep -s 1
$SleepInLoop = 2
$AutoconfigDetected = 0
$lastShownFlannelPid = 0
$FlannelStartDetected = 0
while ($true) {
    $i++
    $currentFlannelPid = (Get-Process flanneld -ErrorAction SilentlyContinue).Id
    Write-NodeServiceStatus -Iteration $i
    Update-IpAddress -adapterName $adapterName -gateway $gw

    if ($currentFlannelPid -ne $null -and $currentFlannelPid -ne $lastShownFlannelPid) {
        $FlannelStartDetected++
        if ($FlannelStartDetected -gt 1) {
            Write-Log "           PID for flanneld service: $currentFlannelPid  (restarted after failure)"
        }
        else {
            Write-Log "           PID for flanneld service: $currentFlannelPid"
        }
        $lastShownFlannelPid = $currentFlannelPid
    }

    $cbr0 = Get-NetIpInterface | Where-Object InterfaceAlias -Like '*cbr0*' | Where-Object AddressFamily -Eq IPv4
    if ( !$HostGW ) {
        Write-Log 'VXLAN mode, no need to wait for cbr0 switch'
        $cbr0 = $true
    }

    if ( $cbr0 ) {
        Write-Log '           OK: cbr0 switch is now found'
        Write-Log 'OK: cbr0 switch is now found'

        # change firewall connection profile
        Write-Log "Set connection profile for firewall rules to 'Private'"
        $ProgressPreference = 'SilentlyContinue'

        Set-InterfacePrivate -InterfaceAlias "vEthernet ($adapterName)"
        Write-Log "flanneld: $((Get-Service -Name "flanneld" -ErrorAction SilentlyContinue).Status)"
        if ($WSL) {
            $interfaceAlias = Get-NetAdapter -Name "vEthernet (WSL*)" -ErrorAction SilentlyContinue -IncludeHidden | Select-Object -expandproperty name
            New-NetFirewallRule -DisplayName 'WSL Inbound' -Group "k2s" -Direction Inbound -InterfaceAlias $interfaceAlias -Action Allow
            New-NetFirewallRule -DisplayName 'WSL Outbound'-Group "k2s" -Direction Outbound -InterfaceAlias $interfaceAlias -Action Allow
        }
        else {
            Set-InterfacePrivate -InterfaceAlias "vEthernet ($switchname)"
        }

        Write-Log 'Change metrics at network interfaces'
        # change index
        $ipindex1 = Get-NetIPInterface | ? InterfaceAlias -Like "*$switchname*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
        Write-Log "Index for interface $switchname : ($ipindex1) -> metric 25"
        Set-NetIPInterface -InterfaceIndex $ipindex1 -InterfaceMetric 25
        $ipindex2 = Get-NetIPInterface | ? InterfaceAlias -Like '*Default*' | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
        if ( $ipindex2 ) {
            Write-Log "Index for interface Default : ($ipindex2) -> metric 35"
            Set-NetIPInterface -InterfaceIndex $ipindex2 -InterfaceMetric 35
        }

        $l2BridgeSwitchName = Get-L2BridgeSwitchName
        $l2BridgeInterfaceIndex = Get-NetIPInterface | ? InterfaceAlias -Like "*$l2BridgeSwitchName*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
        Set-NetIPInterface -InterfaceIndex $l2BridgeInterfaceIndex -InterfaceMetric 5
        Write-Log "Index for interface $l2BridgeSwitchName : ($l2BridgeInterfaceIndex) -> metric 5"

        # routes for Windows pods
        Write-Log "Remove obsolete route to $clusterCIDRHost"
        route delete $clusterCIDRHost >$null 2>&1
        Write-Log "Add route to $clusterCIDRHost"
        route -p add $clusterCIDRHost $clusterCIDRNextHop METRIC 5 | Out-Null

        Write-Log "Networking setup done."
        break;
    }
    else {
        Write-Log '           No cbr0 switch created so far...'
        if ($cbr0Stopwatch.Elapsed.TotalSeconds -gt 150) {
            Stop-Service flanneld
            Write-Log "FAIL: No cbr0 switch found, timeout. Aborting."
            Write-Log 'flanneld logging is in C:\var\log\flanneld, look for errors there'
            Write-Log "`n`nAlready known reasons for this cbr0 problem:"
            Write-Log ' * Usage of certain docking stations: Try to connect the ethernet cable directly'
            Write-Log '   to your PC, not with a docking station'
            Write-Log ' * Usage of WLAN: Try to connect with cable, not WiFi'
            Write-Log ' * Windows IP autoconfiguration APIPA: Try to run'
            Write-Log "     powershell $kubePath\smallsetup\FixAutoconfiguration.ps1"
            Write-Log ''
            throw 'timeout: flanneld failed to create cbr0 switch'
        }
        $ip = (Get-NetIPAddress -InterfaceAlias "vEthernet ($adapterName)" -ErrorAction SilentlyContinue )
        if ($ip -ne $null -and $ip.IPAddress -match '^169.254.' -and $ip.AddressState -match '^Prefer'  ) {
            # IP 169.254.x.y is chosen by Windows Autoconfig APIPA. This is fatal for us.
            # Make sure that it is not only a transient problem, wait for at least 4 times
            $AutoconfigDetected++;
        }
        if ($AutoconfigDetected -ge 4) {
            Write-Log "FAIL: interface 'vEthernet ($adapterName)' was configured by Windows autoconfiguration. Aborting."
            Write-Log "`n`nERROR: network interface 'vEthernet ($adapterName)' was reconfigured by Windows IP autoconfiguration!"
            Write-Log 'This prevents K8s networking to startup properly. You must disable autoconfiguration'
            Write-Log 'in the registry. Do the following steps as administrator:'
            Write-Log " - powershell $kubePath\smallsetup\FixAutoconfiguration.ps1"
            Write-Log ' - netcfg -d'
            Write-Log ' - reboot machine'
            Write-Log " - try Startk8s.cmd again.`n"
            Stop-Service flanneld
            throw 'Fatal: interface was reconfigured by Windows autoconfiguration'
        }
        #        if ($FlannelStartDetected -ge 4)
        #        {
        #            Write-Log "FAIL: flanneld failed to create cbr0 switch, even after 3 restarts. Aborting.`n"
        #            Write-Log "`n`nERROR: flanneld failed to create cbr0 switch, even after 3 restarts. Aborting."
        #            Write-Log "flanneld logging is in C:\var\log\flanneld, look for errors there"
        #            Stop-Service flanneld
        #            throw "Fatal: flanneld failed to create cbr0 switch"
        #        }
        if ($i -eq 10) {
            $SleepInLoop = 5
        }

        Write-Log "No cbr0 switch found, still waiting...`n"
    }

    Start-Sleep -s $SleepInLoop
}

# start dns proxy
Write-Log 'Starting dns proxy'
Start-ServiceAndSetToAutoStart -Name 'httpproxy'
Start-ServiceAndSetToAutoStart -Name 'dnsproxy'

CheckFlannelConfig

$currentErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'

Update-NodeLabelsAndTaints -WorkerMachineName $env:computername

$ErrorActionPreference = $currentErrorActionPreference

Invoke-AddonsHooks -HookType 'AfterStart'

Invoke-Hook -HookName 'AfterStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

Write-Log 'Kubernetes start finished'