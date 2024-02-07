# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
This script is only valid for the Small K8s Setup installed with InstallK8s.ps1
It starts the kubernetes cluster again, after is has been stopped with StopK8s.ps1

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
    [string] $AdditionalHooksDir = ''
)

&$PSScriptRoot\common\GlobalVariables.ps1
. $PSScriptRoot\common\GlobalFunctions.ps1
Import-Module "$PSScriptRoot/../addons/addons.module.psm1"

Import-Module "$PSScriptRoot/ps-modules/log/log.module.psm1"

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
Set-Location $global:KubernetesPath

$isReusingExistingLinuxComputer = Get-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_ReuseExistingLinuxComputerForMasterNode

# script variables:
$script:fixedIpWasSet = $false

Import-Module "$global:KubernetesPath\smallsetup\hns.v2.psm1" -WarningAction:SilentlyContinue -Force

function NeedsStopFirst () {
    if ((Get-Process 'flanneld' -ErrorAction SilentlyContinue) -or
            (Get-Process 'kubelet' -ErrorAction SilentlyContinue) -or
            (Get-Process 'kube-proxy' -ErrorAction SilentlyContinue)) {
        return $true
    }
    return $false
}

function EnsureDirectoryPathExists(
    [string]$DirPath
) {
    if (-not (Test-Path $DirPath)) {
        New-Item -Path $DirPath -ItemType Directory -Force | Out-Null
    }
}

function UpdateIpAddress {
    param (
        [Parameter()]
        [string] $adapterName,
        [Parameter()]
        [string] $gateway
    )
    # Do this only once, guarded by $fixedIpWasSet
    if (!$fixedIpWasSet) {
        $ipAddressForLoopbackAdapter = $global:IP_LoopbackAdapter

        Write-Log 'Try to get the valid network interface'
        $ipindex = Get-NetIPInterface | ? InterfaceAlias -Like "*vEthernet ($adapterName)*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
        if ( $ipindex ) {
            Write-Log "           interface 'vEthernet ($adapterName)' with index $ipindex found:"
            $ipaddress = $ipAddressForLoopbackAdapter
            Write-Log "           setting IP address manually to $ipaddress"
            Write-Log "           setting IP address 'vEthernet ($adapterName)' with index $ipindex manually to $ipaddress"
            Set-NetIPInterface -InterfaceIndex $ipindex -Dhcp Disabled
            Write-Log '           Checking whether Physical adapter has DNS Servers'
            $physicalInterfaceIndex = Get-NetAdapter -Physical | Where-Object Status -Eq 'Up' | Where-Object Name -ne $global:LoopbackAdapter | select -expand 'ifIndex'
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

if ($global:HeaderLineShown -ne $true) {
    Write-Log 'Starting syngo small kubernetes system on Windows'
    $global:HeaderLineShown = $true
}

# in case of other drives a specific flannel file needs to created automatically on drive
# kubelet unfortunately has no central way to configure centrally drive in windows
function CheckFlannelConfig () {
    $flannelFile = "$($global:InstallationDriveLetter):\run\flannel\subnet.env"
    $existsFlannelFile = Test-Path -Path $flannelFile
    if( $existsFlannelFile ) {
        Write-Log "Flannel file $flannelFile exists"
        return
    }
    # only in case that we used another drive than C for the installation
    if( !($global:InstallationDriveLetter -eq $global:SystemDriveLetter)) {
        $i = 0
        $flannelFileSource = "$($global:SystemDriveLetter):\run\flannel\subnet.env"
        Write-Log "Check $flannelFileSource file creation, this can take minutes depending on your network setup ..."
        while ($true) {
            $i++
            Write-Log "flannel handling loop (iteration #$i):"
            if( Test-Path -Path $flannelFileSource ) {
                $targetPath = "$($global:InstallationDriveLetter):\run\flannel"
                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                Copy-Item -Path $flannelFileSource -Destination $targetPath -Force | Out-Null
                break
            }
            Start-Sleep -s 5

            # End the loop
            if ($i -eq 50) {
                throw "Fatal: Flannel failed to create file: $flannelFileSource for target drive $($global:InstallationDriveLetter):\run\flannel\subnet.env !"
            }
        }
    }
}

Write-Log 'Checking prerequisites'

# set ConfigKey_LoggedInRegistry empty, since not logged in into registry after restart anymore
Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry -Value ''

$UseContainerd = Get-UseContainerdFromConfig
if ($UseContainerd) {
    Write-Log 'Using containerd on Windows side as container runtime'
}
else {
    Write-Log 'Using Docker on Windows side as container runtime'
}

$HostGW = Get-HostGwFromConfig
if ($HostGW) {
    Write-Log 'Using host-gw as network mode'
}
else {
    Write-Log 'Using vxlan as network mode'
}

$WSL = Get-WSLFromConfig
if ($WSL) {
    Write-Log 'Using WSL2 as hosting environment for KubeMaster'
}
else {
    Write-Log 'Using Hyper-V as hosting environment for KubeMaster'
}

if (NeedsStopFirst) {
    Write-Log 'Stopping existing K8s system...'
    &"$global:KubernetesPath\smallsetup\StopK8s.ps1" -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs
    Start-Sleep 10
}

if ($ResetHns) {
    Write-Log 'Doing a full reset of the HNS network'
    Get-HNSNetwork | Remove-HNSNetwork
}

$ProgressPreference = 'SilentlyContinue'

Write-Log "Enabling network adapter $global:LoopbackAdapter"
Enable-NetAdapter -Name $global:LoopbackAdapter -Confirm:$false -ErrorAction SilentlyContinue

Import-Module "$global:KubernetesPath\smallsetup\LoopbackAdapter.psm1" -Force
Set-LoopbackAdapterProperties -Name $global:LoopbackAdapter -IPAddress $global:IP_LoopbackAdapter -Gateway $global:Gateway_LoopbackAdapter

$adapterName = Get-L2BridgeNIC
Write-Log "Using network adapter '$adapterName'"

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

$switchname = ''
if ($WSL) {
    $switchname = $global:WSLSwitchName
}
elseif ($isReusingExistingLinuxComputer) {
    $interfaceAlias =  get-netipaddress -IPAddress $global:IP_NextHop | Select-Object -ExpandProperty "InterfaceAlias"
    $switchName = GetNetworkAdapterNameFromInterfaceAlias($interfaceAlias)
    if ([string]::IsNullOrWhiteSpace($switchName)) {
        throw "The network adapter name having the IP $global:IP_NextHop could not be found."
    }
}
else {
    $switchname = $global:SwitchName
}

Write-Log 'Configuring network for windows node' -Console
Restart-WinService 'hns'

Write-Log 'Figuring out IPv4DefaultGateway'
$gw = (Get-NetIPConfiguration -InterfaceAlias "$adapterName").IPv4DefaultGateway.NextHop
Write-Log "Gateway found: $gw"

Set-IndexForDefaultSwitch

# create the l2 bridge in advance
CreateExternalSwitch -adapterName $adapterName

if (!$WSL -and !$isReusingExistingLinuxComputer) {
    # Because of stability issues network settings are recreated every time we start the machine
    # or we restart the service !!!!! (StopServices.ps1 also cleans up the entire network setup)
    # stop VM
    Write-Log 'Reconfiguring VM'
    Write-Log "Configuring $global:VMName VM" -Console
    Stop-VM -Name $global:VMName -Force -WarningAction SilentlyContinue

    if ($VmProcessors -ne '') {
        # change cores
        Set-VMProcessor $global:VMName -Count $VmProcessors
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
} elseif ($isReusingExistingLinuxComputer) {
    # add DNS proxy for cluster searches
    Add-DnsServer $switchname
}

# configure NAT
Write-Log 'Configure NAT...'
if (Get-NetNat -Name $global:NetNatName -ErrorAction SilentlyContinue) {
    Write-Log "  $global:NetNatName exists, removing it"
    Remove-NetNat -Name $global:NetNatName -Confirm:$False | Out-Null
}
# New-NetNat -Name $global:NetNatName -InternalIPInterfaceAddressPrefix $global:IP_CIDR | Out-Null

# disable IPv6
# Disable-NetAdapterBinding -Name "vEthernet ($global:SwitchName)" -ComponentID ms_tcpip6 | Out-Null

#check VM status
if (!$WSL -and !$isReusingExistingLinuxComputer) {
    $i = 0;
    while ($true) {
        $i++
        Write-Log "VM Handling loop (iteration #$i):"
        Start-Sleep -s 4

        if ( $i -eq 1 ) {
            Write-Log "           stopping VM ($i)"
            Stop-VM -Name $global:VMName -Force -WarningAction SilentlyContinue

            $state = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
            while (!$state) {
                Write-Log "           still waiting for stop, current VM state: $(Get-VM -Name $global:VMName | Select-Object -expand 'State')"
                Start-Sleep -s 1
            }

            Write-Log "           re-starting VM ($i)"
            Start-VM -Name $global:VMName
            Start-Sleep -s 4
        }

        $con = Test-Connection $global:IP_Master -Count 1 -ErrorAction SilentlyContinue
        if ($con) {
            Write-Log "           ping succeeded to $global:VMName VM"
            $startStatus = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Running
            if ($startStatus) {
                Write-Log "           $global:VMName VM Started"
                break;
            }
        }

        if ($i -eq 3) {
            # If the connection did not succeed or VM is not in Running state, try starting again for three times
            $startCycle = 0
            $startState = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Running
            while (!$startState -And $startCycle -lt 3) {
                $startCycle++
                Write-Log "           still waiting for start, current VM state: $(Get-VM -Name $global:VMName | Select-Object -expand 'State')"
                Start-VM -Name $global:VMName
                Start-Sleep -s 4
                $startState = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Running
            }
        }

        # End the loop if the connection to VM is unsuccessful
        if ($i -eq 10) {
            throw "Fatal: Failed to connect to $global:VMName VM"
        }
    }
}
elseif ($WSL) {
    Write-Log 'Configuring KubeMaster Distro' -Console
    wsl --shutdown
    Start-WSL
    Set-WSLSwitch
    # add DNS proxy for cluster searches
    Add-DnsServer $switchname
}
Wait-ForSSHConnectionToLinuxVMViaSshKey
Perform-TimeSync

# route for VM
Write-Log "Remove obsolete route to $global:IP_CIDR"
route delete $global:IP_CIDR >$null 2>&1
Write-Log "Add route to $global:IP_CIDR"
route -p add $global:IP_CIDR $global:IP_NextHop METRIC 3 | Out-Null

# routes for Linux pods
Write-Log "Remove obsolete route to $global:ClusterCIDR_Master"
route delete $global:ClusterCIDR_Master >$null 2>&1
Write-Log "Add route to $global:ClusterCIDR_Master"
route -p add $global:ClusterCIDR_Master $global:IP_Master METRIC 4 | Out-Null

# routes for services
route delete $global:ClusterCIDR_Services >$null 2>&1
Write-Log "Remove obsolete route to $global:ClusterCIDR_ServicesLinux"
route delete $global:ClusterCIDR_ServicesLinux >$null 2>&1
Write-Log "Add route to $global:ClusterCIDR_ServicesLinux"
route -p add $global:ClusterCIDR_ServicesLinux $global:IP_Master METRIC 6 | Out-Null
Write-Log "Remove obsolete route to $global:ClusterCIDR_ServicesWindows"
route delete $global:ClusterCIDR_ServicesWindows >$null 2>&1
Write-Log "Add route to $global:ClusterCIDR_ServicesWindows"
route -p add $global:ClusterCIDR_ServicesWindows $global:IP_Master METRIC 7 | Out-Null

# enable ip forwarding
netsh int ipv4 set int "vEthernet ($switchname)" forwarding=enabled | Out-Null
netsh int ipv4 set int 'vEthernet (Ethernet)' forwarding=enabled | Out-Null

Invoke-Hook -HookName BeforeStartK8sNetwork -AdditionalHooksDir $AdditionalHooksDir

Write-Log "Ensure service log directories exists" -Console
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\containerd"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\dnsproxy"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\dockerd"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\flanneld"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\httpproxy"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\kubelet"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\windows_exporter"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\containers"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\pods"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\bridge"
EnsureDirectoryPathExists -DirPath "$($global:SystemDriveLetter):\var\log\vfprules"

Write-Log 'Starting K8s services' -Console
Start-ServiceAndSetToAutoStart -Name 'containerd'
Start-ServiceAndSetToAutoStart -Name 'flanneld'
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
    UpdateIpAddress -adapterName $adapterName -gateway $gw

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
        if ($WSL) {
            New-NetFirewallRule -DisplayName 'WSL Inbound' -Group "k2s" -Direction Inbound -InterfaceAlias 'vEthernet (WSL)' -Action Allow
            New-NetFirewallRule -DisplayName 'WSL Outbound'-Group "k2s" -Direction Outbound -InterfaceAlias 'vEthernet (WSL)' -Action Allow
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

        $l2BridgeInterfaceIndex = Get-NetIPInterface | ? InterfaceAlias -Like "*$global:L2BridgeSwitchName*" | ? AddressFamily -Eq IPv4 | select -expand 'ifIndex'
        Set-NetIPInterface -InterfaceIndex $l2BridgeInterfaceIndex -InterfaceMetric 5
        Write-Log "Index for interface $global:L2BridgeSwitchName : ($l2BridgeInterfaceIndex) -> metric 5"

        # routes for Windows pods
        Write-Log "Remove obsolete route to $global:ClusterCIDR_Host"
        route delete $global:ClusterCIDR_Host >$null 2>&1
        Write-Log "Add route to $global:ClusterCIDR_Host"
        route -p add $global:ClusterCIDR_Host $global:ClusterCIDR_NextHop METRIC 5 | Out-Null

        Write-Log "Networking setup done.`n"
        break;
    }
    else {
        Write-Log '           No cbr0 switch created so far...'
        if ($cbr0Stopwatch.Elapsed.TotalSeconds -gt 150) {
            Stop-Service flanneld
            Write-Log "FAIL: No cbr0 switch found, timeout. Aborting.`n"
            Write-Log 'flanneld logging is in C:\var\log\flanneld, look for errors there'
            Write-Log "`n`nAlready known reasons for this cbr0 problem:"
            Write-Log ' * Usage of certain docking stations: Try to connect the ethernet cable directly'
            Write-Log '   to your PC, not with a docking station'
            Write-Log ' * Usage of WLAN: Try to connect with cable, not WiFi'
            Write-Log ' * Windows IP autoconfiguration APIPA: Try to run'
            Write-Log "     powershell $global:KubernetesPath\smallsetup\FixAutoconfiguration.ps1"
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
            Write-Log "FAIL: interface 'vEthernet ($adapterName)' was configured by Windows autoconfiguration. Aborting.`n"
            Write-Log "`n`nERROR: network interface 'vEthernet ($adapterName)' was reconfigured by Windows IP autoconfiguration!"
            Write-Log 'This prevents K8s networking to startup properly. You must disable autoconfiguration'
            Write-Log 'in the registry. Do the following steps as administrator:'
            Write-Log " - powershell $global:KubernetesPath\smallsetup\FixAutoconfiguration.ps1"
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

Write-Log 'Script StartK8s.ps1 finished'