# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule = "$PSScriptRoot\..\..\..\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule


function Add-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [switch] $ForceOnlineInstallation = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [string] $JoinCommand = $(throw 'Argument missing: JoinCommand'),
        [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
        [string] $K8sBinsPath = ''
    )
    Stop-InstallIfNoMandatoryServiceIsRunning

    Write-Log 'Starting installation of K2s worker node on Windows host.'

    # Install loopback adapter for l2bridge
    New-DefaultLoopbackAdater

    Write-Log 'Add vfp rules'
    $rootConfiguration = Get-RootConfigk2s
    $vfpRoutingRules = $rootConfiguration.psobject.properties['vfprules-k2s'].value | ConvertTo-Json
    Add-VfpRulesToWindowsNode -VfpRulesInJsonFormat $vfpRoutingRules

    $kubernetesVersion = Get-DefaultK8sVersion

    Initialize-WinNode -KubernetesVersion $kubernetesVersion `
        -HostGW:$true `
        -Proxy:"$Proxy" `
        -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
        -ForceOnlineInstallation $ForceOnlineInstallation `
        -PodSubnetworkNumber $PodSubnetworkNumber `
        -K8sBinsPath $K8sBinsPath


    # join the cluster
    Write-Log "Preparing Kubernetes $KubernetesVersion by joining nodes" -Console

    Initialize-KubernetesCluster -AdditionalHooksDir $AdditionalHooksDir -PodSubnetworkNumber $PodSubnetworkNumber -JoinCommand $JoinCommand
}

function Start-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
        [switch] $ResetHns = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
        [switch] $UseCachedK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [string] $DnsServers = $(throw 'Argument missing: DnsServers')
    )

    $smallsetup = Get-RootConfigk2s
    $vfpRoutingRules = $smallsetup.psobject.properties['vfprules-k2s'].value | ConvertTo-Json
    Add-VfpRulesToWindowsNode -VfpRulesInJsonFormat $vfpRoutingRules

    $ipControlPlane = Get-ConfiguredIPControlPlane
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value

    # routes for services
    Write-Log "Remove obsolete route to $clusterCIDRServicesWindows"
    route delete $clusterCIDRServicesWindows >$null 2>&1
    Write-Log "Add route 1 to Windows Services CIDR:$clusterCIDRServicesWindows with metric 7"
    route -p add $clusterCIDRServicesWindows $ipControlPlane METRIC 7 | Out-Null

    Start-WindowsWorkerNode -DnsServers $DnsServers -ResetHns:$ResetHns -AdditionalHooksDir $AdditionalHooksDir -UseCachedK2sVSwitches:$UseCachedK2sVSwitches -SkipHeaderDisplay:$SkipHeaderDisplay -PodSubnetworkNumber $PodSubnetworkNumber

    $clusterCIDRNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber
    Add-WinDnsProxyListenAddress -IpAddress $clusterCIDRNextHop

    Update-NodeLabelsAndTaints -WorkerMachineName $env:computername

}

function Stop-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
        [switch] $CacheK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Stopping K2s worker node on Windows host'
    }

    $clusterCIDRNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber
    Remove-WinDnsProxyListenAddress -IpAddress $clusterCIDRNextHop

    Stop-WindowsWorkerNode -PodSubnetworkNumber $PodSubnetworkNumber -AdditionalHooksDir $AdditionalHooksDir -CacheK2sVSwitches:$CacheK2sVSwitches -SkipHeaderDisplay:$SkipHeaderDisplay

    # Remove routes
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value
    route delete $clusterCIDRServicesWindows >$null 2>&1

    Remove-VfpRulesFromWindowsNode

    Write-Log 'K2s worker node on Windows host stopped.'
}

function Remove-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
        [switch] $SkipPurge = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
        [switch] $SkipHeaderDisplay = $false
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Removing K2s worker node on Windows host from cluster'
    }

    Write-Log 'Remove external switch'
    Remove-ExternalSwitch

    Write-Log 'Uninstall the worker node artifacts from the Windows host'
    Uninstall-WinNode -ShallowUninstallation $SkipPurge

    Write-Log 'Uninstall the loopback adapter'
    Uninstall-LoopbackAdapter

    Write-Log 'Remove vfp rules'
    Remove-VfpRulesFromWindowsNode

    Write-Log 'Uninstalling K2s worker node on Windows host done.'
}

function Start-WindowsWorkerNode {
    param (
        [string]$VfpRules,
        [string]$NetworkAdapterName,
        [string] $DnsServers = $(throw 'Argument missing: DnsServers'),
        [string]$PodNetworkGatewayIpAddress,
        [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
        [switch] $ResetHns = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
        [switch] $UseCachedK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    function Get-NeedsStopFirst () {
        if ((Get-Process 'flanneld' -ErrorAction SilentlyContinue) -or
                (Get-Process 'kubelet' -ErrorAction SilentlyContinue) -or
                (Get-Process 'kube-proxy' -ErrorAction SilentlyContinue)) {
            return $true
        }
        return $false
    }

    $kubePath = Get-KubePath
    Import-Module "$kubePath\smallsetup\hns.v2.psm1" -WarningAction:SilentlyContinue -Force

    if (Get-NeedsStopFirst) {
        Write-Log 'Stopping existing K8s system...'
        Stop-WindowsWorkerNode -PodSubnetworkNumber $PodSubnetworkNumber -AdditionalHooksDir $AdditionalHooksDir -CacheK2sVSwitches:$UseCachedK2sVSwitches -SkipHeaderDisplay:$SkipHeaderDisplay
        Start-Sleep 10
    }

    if ($ResetHns) {
        Write-Log 'Doing a full reset of the HNS network'
        Get-HNSNetwork | Remove-HNSNetwork
    }

    Test-ExistingExternalSwitch

    $adapterName = Get-L2BridgeName
    Write-Log "Using network adapter '$adapterName'"
    Enable-LoopbackAdapter

    Write-Log 'Starting windows services' -Console
    Start-Service -Name 'vmcompute'
    Start-Service -Name 'hns'

    Write-Log 'Figuring out IPv4DefaultGateway'
    $if = Get-NetIPConfiguration -InterfaceAlias "$adapterName" -ErrorAction SilentlyContinue 2>&1 | Out-Null
    $gw = Get-LoopbackAdapterGateway
    if ( $if ) {
        $gw = $if.IPv4DefaultGateway.NextHop
        Write-Log "Gateway found (from interface '$adapterName'): $gw"
    }
    Write-Log "The following gateway IP address will be used: $gw"

    New-ExternalSwitch -adapterName $adapterName -PodSubnetworkNumber $PodSubnetworkNumber

    Invoke-Hook -HookName 'BeforeStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

    $loopbackAdapterIfIndex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "vEthernet ($adapterName)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex' -First 1
    $loopbackAdapterAlias = Get-NetIPInterface | Where-Object InterfaceAlias -Like "vEthernet ($adapterName)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'InterfaceAlias' -First 1

    if ($null -eq $loopbackAdapterIfIndex -or $null -eq $loopbackAdapterAlias) {
        Write-Log 'Unable to find the loopback adapter' -Error
        Write-Log 'Found following interfaces:'
        Get-NetIPInterface | Write-Log
        throw 'Unable to find the loopback adapter'
    }

    Write-Log "Found Loopback adapter with Alias: '$loopbackAdapterAlias' and ifIndex: '$loopbackAdapterIfIndex'"
    $ipAddressForLoopbackAdapter = Get-LoopbackAdapterIP
    Set-NetIPInterface -InterfaceIndex $loopbackAdapterIfIndex -Dhcp Disabled
    $dnsServersAsArray = $DnsServers -split ','
    Set-IPAdressAndDnsClientServerAddress -IPAddress $ipAddressForLoopbackAdapter -DefaultGateway $gw -Index $loopbackAdapterIfIndex -DnsAddresses $dnsServersAsArray
    Set-InterfacePrivate -InterfaceAlias "$loopbackAdapterAlias"
    Set-DnsClient -InterfaceIndex $loopbackAdapterIfIndex -RegisterThisConnectionsAddress $false | Out-Null
    netsh int ipv4 set int "$loopbackAdapterAlias" forwarding=enabled | Out-Null
    Set-NetIPInterface -InterfaceIndex $loopbackAdapterIfIndex -InterfaceMetric 102
    
    Write-Log 'Ensuring service log directories exists'
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

    $SleepInLoop = 2
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

            $l2BridgeSwitchName = Get-L2BridgeSwitchName
            $l2BridgeInterfaceIndex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*$l2BridgeSwitchName*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
            Set-NetIPInterface -InterfaceIndex $l2BridgeInterfaceIndex -InterfaceMetric 101
            Write-Output "Index for interface $l2BridgeSwitchName : ($l2BridgeInterfaceIndex) -> metric 101"

            # $setupConfigRoot = Get-RootConfigk2s
            $clusterCIDRWorker = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber #$setupConfigRoot.psobject.properties['podNetworkWorkerCIDR'].value
            $clusterCIDRNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber #$setupConfigRoot.psobject.properties['cbr0'].value

            # routes for Windows pods
            Write-Output "Remove obsolete route to $clusterCIDRWorker"
            route delete $clusterCIDRWorker >$null 2>&1
            Write-Output "Add route to Windows Pods on host CIDR:$clusterCIDRWorker with metric 5"
            route -p add $clusterCIDRWorker $clusterCIDRNextHop METRIC 5 | Out-Null

            Write-Output "Routing entries added.`n"

            # remove routes to non existent gateways
            $cbr0Gateway = $setupConfigRoot.psobject.properties['cbr0Gateway'].value
            Write-Log "Remove obsolete route to $cbr0Gateway"
            Remove-NetRoute  -DestinationPrefix 0.0.0.0/0 -NextHop $cbr0Gateway -Confirm:$false -ErrorAction SilentlyContinue
            $loopbackGateway = $setupConfigRoot.psobject.properties['loopbackGateway'].value
            Write-Log "Remove obsolete route to $loopbackGateway"
            Remove-NetRoute  -DestinationPrefix 0.0.0.0/0 -NextHop $loopbackGateway -Confirm:$false -ErrorAction SilentlyContinue

            Write-Output "Networking setup done.`n"
            break;
        }
        elseif ($cbr0Stopwatch.Elapsed.TotalSeconds -gt 150) {
            Stop-Service flanneld
            Write-Output "FAIL: No cbr0 switch found, timeout. Aborting.`n"
            Write-Output 'For troubleshooting look into the log file C:\var\log\flanneld'
            Write-Output ''
            throw 'Timeout: flanneld failed to create cbr0 switch'
        }

        Start-Sleep -s $SleepInLoop
    }

    CheckFlannelConfig

    Invoke-Hook -HookName 'AfterStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir
}

function Stop-WindowsWorkerNode {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
        [switch] $CacheK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )

    Write-Log 'Stopping Kubernetes services on the Windows node' -Console

    Stop-ServiceAndSetToManualStart 'kubeproxy'
    Stop-ServiceAndSetToManualStart 'kubelet'
    Stop-ServiceAndSetToManualStart 'flanneld'
    Stop-ServiceAndSetToManualStart 'windows_exporter'
    Stop-ServiceAndSetToManualStart 'containerd'

    $shallRestartDocker = $false
    if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
        Stop-ServiceProcess 'docker' 'dockerd'
        $shallRestartDocker = $true
    }

    Write-Log 'Stopping K8s network' -Console
    Restart-WinService 'hns'

    Invoke-Hook -HookName 'BeforeStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

    if (!$CacheK2sVSwitches) {
        # Remove the external switch
        Remove-ExternalSwitch

        Write-Log 'Delete network policies'
        Get-HnsPolicyList | Remove-HnsPolicyList -ErrorAction SilentlyContinue
        Write-Log 'Cleaning up registry for NicList'
        Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\VMSMP\Parameters\NicList' | Remove-Item -ErrorAction SilentlyContinue | Out-Null
    }

    Write-Log 'Removing old logfiles'
    Remove-Item -Force "$(Get-SystemDriveLetter):\var\log\flanneld\flannel*.*" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
    Remove-Item -Force "$(Get-SystemDriveLetter):\var\log\kubelet\*.*" -Recurse -Confirm:$False -ErrorAction SilentlyContinue
    Remove-Item -Force "$(Get-SystemDriveLetter):\var\log\kubeproxy\*.*" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

    if ($shallRestartDocker) {
        Start-ServiceProcess 'docker'
    }

    $podNetworkCIDR = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber
    # Remove routes
    route delete $podNetworkCIDR >$null 2>&1

    Invoke-Hook -HookName 'AfterStopK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

    Disable-LoopbackAdapter

    Write-Log 'K2s worker node on Windows host stopped.'
}

function CheckFlannelConfig {
    $flannelFile = "$(Get-InstallationDriveLetter):\run\flannel\subnet.env"
    $existsFlannelFile = Test-Path -Path $flannelFile
    if ( $existsFlannelFile ) {
        Write-Log "Flannel file $flannelFile exists"
        return
    }
    # only in case that we used another drive than C for the installation
    if ( ($(Get-InstallationDriveLetter) -ne $(Get-SystemDriveLetter))) {
        $i = 0
        $flannelFileSource = "$(Get-SystemDriveLetter):\run\flannel\subnet.env"
        Write-Log "Check $flannelFileSource file creation, this can take minutes depending on your network setup ..."
        while ($true) {
            $i++
            Write-Log "flannel handling loop (iteration #$i):"
            if ( Test-Path -Path $flannelFileSource ) {
                $targetPath = "$(Get-InstallationDriveLetter):\run\flannel"
                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                Copy-Item -Path $flannelFileSource -Destination $targetPath -Force | Out-Null
                break
            }
            Start-Sleep -s 5

            # End the loop
            if ($i -eq 100) {
                throw "Fatal: Flannel failed to create file: $flannelFileSource for target drive $(Get-InstallationDriveLetter):\run\flannel\subnet.env !"
            }
        }
    }
}

function EnsureDirectoryPathExists(
    [string]$DirPath
) {
    if (-not (Test-Path $DirPath)) {
        New-Item -Path $DirPath -ItemType Directory -Force | Out-Null
    }
}

function Restart-WinServiceVmCompute {
    # Rationale for the logic used in this function:
    #  if a virtual machine is running under WSL when the Windows service 'vmcompute' is restarted
    #  the Windows host freezes and a blue screen is displayed.
    #  This was observed in Microsoft Windows 10 Version 22H2 (OS Build 19045)
    $windowsServiceName = 'vmcompute'
    $isWslUsed = Get-ConfigWslFlag
    if ($isWslUsed) {
        Write-Log "Shutdown WSL before restarting Windows service '$windowsServiceName'"
        wsl --shutdown
    }
    Restart-WinService $windowsServiceName
    if ($isWslUsed) {
        Write-Log "Start WSL after restarting Windows service '$windowsServiceName'"
        Start-WSL
    }
}

function Add-WindowsWorkerNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Windows Image to use')]
        [string] $Image,
        [parameter(Mandatory = $false, HelpMessage = 'Windows hostname')]
        [string] $Hostname = $(throw 'Argument missing: Name'),
        [parameter(Mandatory = $false, HelpMessage = 'Windows hostname')]
        [string] $VmName = $(throw 'Argument missing: VmName'),
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of Windows VM')]
        [long] $VMStartUpMemory = $(throw 'Argument missing: VMStartUpMemory'),
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [long] $VMDiskSize = $(throw 'Argument missing: VMDiskSize'),
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors of Windows VM')]
        [long] $VMProcessorCount = $(throw 'Argument missing: VMProcessorCount'),
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [parameter(HelpMessage = 'DNS Addresses')]
        [string] $DnsAddresses = $(throw 'Argument missing: DnsAddresses'),
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [switch] $ForceOnlineInstallation = $false
    )

    $workerNodeParams = @{
        Image                             = $Image
        Hostname                          = 'no_hostname'
        VmName                            = $VmName
        VMStartUpMemory                   = $VMStartUpMemory
        VMProcessorCount                  = $VMProcessorCount
        VMDiskSize                        = $VMDiskSize
        DnsAddresses                      = $DnsAddresses
        Proxy                             = $Proxy
        DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
        ForceOnlineInstallation           = $ForceOnlineInstallation
    }

    New-WindowsVmForWorkerNode @workerNodeParams

    $vmPwd = Get-DefaultTempPwd

    $session1 = Open-RemoteSession -VMName $VmName -VmPwd $vmPwd

    Invoke-Command -Session $session1 -WarningAction SilentlyContinue {
        Rename-Computer -NewName $using:Hostname -Force | Out-Null
    }
    Stop-VirtualMachine -VmName $VmName -Wait
    Start-VirtualMachine -VmName $VmName -Wait

    $session2 = Open-RemoteSession -VMName $VmName -VmPwd $vmPwd

    $kubePath = Get-KubePath
    Write-Log "Copying sources from $kubePath..."
    # Write-Log 'Copy Source from Host to VM node'
    Invoke-Command -Session $session2 { New-Item -Path 'C:\k' -ItemType Directory }
    Invoke-Command -Session $session2 { New-Item -Path 'C:\k\bin' -ItemType Directory }
    Copy-Item -ToSession $session2 -Path (Get-Item -Path "$kubePath\*" -Exclude ('.git', '.github', '.vscode', '.gitignore', 'bin', 'addons', 'test', 'docs', 'build' )).FullName -Destination 'c:\k' -Recurse -Force
    Copy-Item -ToSession $session2 -Path (Get-Item -Path "$kubePath\bin\*" -Exclude ('*.vhdx', '*.gz', 'windowsnode' )).FullName -Destination 'c:\k\bin' -Recurse -Force
    Write-Log '  done.'

    $gatewayIpAddress = Get-ConfiguredKubeSwitchIP
    Set-VmIPAddress -PSSession $session2 -IPAddr $IpAddress -DefaultGatewayIpAddr $gatewayIpAddress -DnsAddr $IpAddress -MaskPrefixLength 24

    Write-Log 'Copy K8s config file to VM...'
    $userPath = Invoke-Command -Session $session2 { return "$(Resolve-Path '~')" }
    $target = "$userPath\.kube"
    Invoke-Command -Session $session2 { New-Item -Path $using:target -ItemType Directory }
    Copy-Item -ToSession $session2 -Path "$(Resolve-Path '~\.kube')\config" -Destination "$target\config"
    Write-Log '   done.'

    $joinCommand = New-JoinCommand
    $kubernetesVersion = Get-DefaultK8sVersion
    $ipControlPlane = Get-ConfiguredIPControlPlane

    Invoke-Command -Session $session2 -WarningAction SilentlyContinue {
        Set-Location $env:SystemDrive\k
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1
        Initialize-Logging -Nested:$true

        Set-EnvVars
        Invoke-DeployWinArtifacts -KubernetesVersion $using:kubernetesVersion -Proxy $using:Proxy

        Install-WinHttpProxy -Proxy $using:Proxy

        $windowsArtifactsDirectory = Get-WindowsArtifactsDirectory
        Invoke-DeployDnsProxyArtifacts $windowsArtifactsDirectory
        $ipWorkerNode = $using:IpAddress
        $ipControlPlane = $using:ipControlPlane
        Install-WinDnsProxy -ListenIpAddresses @($ipWorkerNode) -UpstreamIpAddressForCluster $ipControlPlane -UpstreamIpAddressesForNonCluster $($using:DnsAddresses -split ',')

        $transparentProxy = "http://$($ipWorkerNode):8181"

        $params = @{
            Proxy               = $transparentProxy
            PodSubnetworkNumber = '1'
            JoinCommand         = $using:joinCommand
        }
        Add-WindowsWorkerNodeOnWindowsHost @params

        # create shell shortcut
        $WshShell = New-Object -comObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut("$Home\Desktop\cmd.lnk")
        $Shortcut.TargetPath = 'C:\Windows\System32\cmd.exe'
        $Shortcut.Arguments = "/K `"cd c:\k`""
        $Shortcut.Save()

        # Stop Microsoft Defender interference with K2s setup
        Add-K2sToDefenderExclusion
    }

    Write-Log 'Initialize ssh connection to Windows VM'
    Initialize-SSHConnectionToWinVM $session2 $IpAddress
    Enable-SSHRemotingViaSSHKeyToWinNode $session2

    $adminWinNode = Get-DefaultWinVMName
    $windowsVMKey = Get-DefaultWinVMKey
    # Initiate first time ssh to establish connection over key for subsequent operations
    ssh.exe -n -o StrictHostKeyChecking=no -i $windowsVMKey $adminWinNode hostname 2> $null

    Disable-PasswordAuthenticationToWinNode

    Write-Log "Collecting kubernetes images and storing them to $(Get-KubernetesImagesFilePath)."
    Write-KubernetesImagesIntoJson -WorkerVM $true
}

function Start-WindowsWorkerNodeOnNewVM {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Do a full reset of the HNS network at start')]
        [switch] $ResetHns = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
        [switch] $UseCachedK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $SwitchName = $(throw 'Argument missing: SwitchName'),
        [string] $VmName = $(throw 'Argument missing: VmName'),
        [string] $VfpRules = $(throw 'Argument missing: VfpRules'),
        [string] $VmIpAddress = $(throw 'Argument missing: VmIpAddress'),
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [string] $Hostname = $(throw 'Argument missing: Hostname'),
        [string] $DnsServers = $(throw 'Argument missing: DnsServers')
    )

    $timezoneStandardNameOnHost = (Get-TimeZone).StandardName

    $windowsVmName = $VmName

    $isVmExisting = Get-VmExists -VmName $windowsVmName
    if ($isVmExisting) {
        Disconnect-NetworkAdapterFromVm -VmName $windowsVmName
        Connect-NetworkAdapterToVm -VmName $windowsVmName -SwitchName $SwitchName

        $isVmRunning = Get-IsVmOperating -VmName $windowsVmName
        if (!$isVmRunning) {
            Start-VirtualMachine -VmName $windowsVmName -Wait
        }
    }
    else {
        throw "The VM '$windowsVmName' does not exist"
    }

    Wait-ForSSHConnectionToWindowsVMViaSshKey

    $session = Open-DefaultWinVMRemoteSessionViaSSHKey

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
        Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
        Initialize-Logging -Nested:$true

        Set-IndexForDefaultSwitch

        Start-WinHttpProxy
        Start-WinDnsProxy

        netsh int ipv4 set int 'Ethernet' forwarding=enabled | Out-Null

        $workerNodeStartParams = @{
            ResetHns              = $using:ResetHns
            AdditionalHooksDir    = $using:AdditionalHooksDir
            UseCachedK2sVSwitches = $using:UseCachedK2sVSwitches
            SkipHeaderDisplay     = $using:SkipHeaderDisplay
            DnsServers            = $using:DnsServers
            PodSubnetworkNumber   = $using:PodSubnetworkNumber
        }
        Start-WindowsWorkerNodeOnWindowsHost @workerNodeStartParams

        Set-TimeZone -Name $using:timezoneStandardNameOnHost
    }

    $ipControlPlane = Get-ConfiguredIPControlPlane
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value
    $clusterCIDRWorker = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber

    # routes for Windows pods
    Write-Output "Remove obsolete route to $clusterCIDRWorker"
    route delete $clusterCIDRWorker >$null 2>&1
    Write-Output "Add route 2 to PODS CIDR:$clusterCIDRWorker with metric 5"
    route -p add $clusterCIDRWorker $VmIpAddress METRIC 5 | Out-Null

    # routes for Windows services
    Write-Log "Remove obsolete route to $clusterCIDRServicesWindows"
    route delete $clusterCIDRServicesWindows >$null 2>&1
    Write-Log "Add route 2 to Windows Services CIDR:$clusterCIDRServicesWindows with metric 7"
    route -p add $clusterCIDRServicesWindows $ipControlPlane METRIC 7 | Out-Null
}

function Stop-WindowsWorkerNodeOnNewVM {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
        [switch] $CacheK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [string] $SwitchName = $(throw 'Argument missing: SwitchName')
    )

    $windowsVmName = Get-ConfigVMNodeHostname
    $isVmExisting = Get-VmExists -VmName $windowsVmName
    if ($isVmExisting) {
        $isVmRunning = Get-IsVmOperating -VmName $windowsVmName
        if (!$isVmRunning) {
            Disconnect-NetworkAdapterFromVm -VmName $windowsVmName
            Connect-NetworkAdapterToVm -VmName $windowsVmName -SwitchName $SwitchName
            Start-VirtualMachine -VmName $windowsVmName -Wait
        }

        Wait-ForSSHConnectionToWindowsVMViaSshKey

        $session = Open-DefaultWinVMRemoteSessionViaSSHKey

        Invoke-Command -Session $session {
            Set-Location "$env:SystemDrive\k"
            Set-ExecutionPolicy Bypass -Force -ErrorAction SilentlyContinue

            Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1
            Import-Module $env:SystemDrive\k\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1
            Initialize-Logging -Nested:$true

            Stop-WinHttpProxy
            Stop-WinDnsProxy

            $workerNodeStopParams = @{
                AdditionalHooksDir  = $using:AdditionalHooksDir
                CacheK2sVSwitches   = $using:CacheK2sVSwitches
                SkipHeaderDisplay   = $using:SkipHeaderDisplay
                PodSubnetworkNumber = $using:PodSubnetworkNumber
            }
            Stop-WindowsWorkerNodeOnWindowsHost @workerNodeStopParams
        }

        Stop-VirtualMachine -VmName $windowsVmName -Wait
        Disconnect-NetworkAdapterFromVm -VmName $windowsVmName
    }

    # Remove routes
    $clusterCIDRWorker = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber
    route delete $clusterCIDRWorker >$null 2>&1
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value
    route delete $clusterCIDRServicesWindows >$null 2>&1
}

function Remove-WindowsWorkerNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber'),
        [string] $VmName = $(throw 'Argument missing: VmName'),
        [string] $SwitchName = $(throw 'Argument missing: SwitchName')
    )

    $isVmExisting = Get-VmExists -VmName $VmName

    if ($isVmExisting) {
        $isVmRunning = Get-IsVmOperating -VmName $VmName
        if ($isVmRunning) {
            Stop-VirtualMachine -VmName $VmName -Wait
        }
        Disconnect-NetworkAdapterFromVm -VmName $VmName
        Remove-VirtualMachine $VmName
    }

    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value
    $clusterCIDRWorker = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber

    # routes for Windows pods
    Write-Output "Remove obsolete route to $clusterCIDRWorker"
    route delete $clusterCIDRWorker >$null 2>&1
    # routes for services
    Write-Log "Remove obsolete route to $clusterCIDRServicesWindows"
    route delete $clusterCIDRServicesWindows >$null 2>&1

    Write-Log 'Remove previous VM key from known_hosts file'
    $vmWinNodeIP = Get-WindowsVmIpAddress
    ssh-keygen.exe -R $vmWinNodeIP 2>&1 | % { "$_" } | Out-Null

    $windowsVMKey = Get-DefaultWinVMKey
    $windowsVMKeyDirectory = Split-Path $windowsVMKey
    Remove-Item -Path $windowsVMKeyDirectory -Recurse -Force | Out-Null

    if ($DeleteFilesForOfflineInstallation) {
        $kubeBinPath = Get-KubeBinPath
        $windowsBaseFilePath = "$kubeBinPath\Windows-Base.vhdx"
        $windowsKubenodeBaseFilePath = "$kubeBinPath\Windows-Kubeworker-Base.vhdx"
        if (Test-Path $windowsBaseFilePath) {
            Remove-Item -Path $windowsBaseFilePath -Force
        }
        if (Test-Path $windowsKubenodeBaseFilePath) {
            Remove-Item -Path $windowsKubenodeBaseFilePath -Force
        }
    }
}

function Get-VmExists {
    param(
        [string] $VmName = $(throw 'Argument missing: VmName')
    )

    $vm = Get-VM | Where-Object Name -eq $VmName
    return ($null -ne $vm)
}

Export-ModuleMember -Function Add-WindowsWorkerNodeOnWindowsHost,
Remove-WindowsWorkerNodeOnWindowsHost,
Start-WindowsWorkerNodeOnWindowsHost,
Stop-WindowsWorkerNodeOnWindowsHost,
Add-WindowsWorkerNodeOnNewVM,
Start-WindowsWorkerNodeOnNewVM,
Stop-WindowsWorkerNodeOnNewVM,
Remove-WindowsWorkerNodeOnNewVM