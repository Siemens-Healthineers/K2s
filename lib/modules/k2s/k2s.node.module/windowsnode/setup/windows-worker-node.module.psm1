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
    New-DefaultLoopbackAdapter

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

    Set-RoutesToWindowsWorkloads

    Start-WindowsWorkerNode -DnsServers $DnsServers -ResetHns:$ResetHns -AdditionalHooksDir $AdditionalHooksDir -UseCachedK2sVSwitches:$UseCachedK2sVSwitches -SkipHeaderDisplay:$SkipHeaderDisplay -PodSubnetworkNumber $PodSubnetworkNumber

    $clusterCIDRNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber
    Add-WinDnsProxyListenAddress -IpAddress $clusterCIDRNextHop

    Update-NodeLabelsAndTaints -WorkerMachineName $env:computername

    Set-KubeSwitchToPrivate
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

    $startTime = Get-Date

    Write-Log 'Ensuring service log directories exists'
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\containerd"
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\dnsproxy"
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\dockerd"
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\flanneld"
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\httpproxy"
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\kubelet"
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\containers"
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\pods"
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\bridge"
    EnsureDirectoryPathExists -DirPath "$(Get-SystemDriveLetter):\var\log\vfprules"

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

    New-ExternalSwitch -adapterName $adapterName -PodSubnetworkNumber $PodSubnetworkNumber

    Invoke-Hook -HookName 'BeforeStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir

    Set-LoopbackAdapterExtendedProperties -AdapterName $adapterName -DnsServers $DnsServers
    
    Write-Log 'Starting Kubernetes services on the Windows node' -Console
    Start-ServiceAndSetToAutoStart -Name 'containerd'
    Start-ServiceAndSetToAutoStart -Name 'httpproxy'
    Confirm-LoopbackAdapterIP
    Start-ServiceAndSetToAutoStart -Name 'flanneld' -IgnoreErrors
    Start-ServiceAndSetToAutoStart -Name 'kubelet'
    Start-ServiceAndSetToAutoStart -Name 'kubeproxy'

    Wait-NetworkL2BridgeReady -PodSubnetworkNumber $PodSubnetworkNumber

    CheckFlannelConfig

    $endTime = Get-Date
    $durationSeconds = Get-DurationInSeconds -StartTime $startTime -EndTime $endTime
    Write-Log "K8s services started on the Windows node after $iteration attempts, total duration: ${durationSeconds} seconds"

    Invoke-Hook -HookName 'AfterStartK8sNetwork' -AdditionalHooksDir $AdditionalHooksDir
}

function Wait-NetworkL2BridgeReady {
    Param(
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )
    $setupConfigRoot = Get-RootConfigk2s
    # loop to check the state of the services for Kubernetes
    $i = 0;
    $cbr0Stopwatch = [system.diagnostics.stopwatch]::StartNew()

    $SleepInLoop = 2
    $lastShownFlannelPid = 0
    $FlannelStartDetected = 0

    while ($true) {
        $i++

        # check flanneld
        $currentFlannelPid = (Get-Process flanneld -ErrorAction SilentlyContinue).Id
        Write-NodeServiceStatus -Iteration $i
        if ($null -ne $currentFlannelPid -and $currentFlannelPid -ne $lastShownFlannelPid) {
            $FlannelStartDetected++
            if ($FlannelStartDetected -gt 1) {
                Write-Output "           PID for flanneld service: $currentFlannelPid  (restarted after failure)"
            }
            else {
                Write-Output "           PID for flanneld service: $currentFlannelPid"
            }
            $lastShownFlannelPid = $currentFlannelPid
        }

        # check cbr0
        $cbr0 = Get-NetIpInterface | Where-Object InterfaceAlias -Like '*cbr0*' | Where-Object AddressFamily -Eq IPv4
        if ( $cbr0 ) {
            Write-Output '           OK: cbr0 switch is now found'
            Write-Output "`nOK: cbr0 switch is now found"

            $l2BridgeSwitchName = Get-L2BridgeSwitchName
            $l2BridgeInterfaceIndex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*$l2BridgeSwitchName*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
            Set-NetIPInterface -InterfaceIndex $l2BridgeInterfaceIndex -InterfaceMetric 101
            Write-Output "Index for interface $l2BridgeSwitchName : ($l2BridgeInterfaceIndex) -> metric 101"

            Set-RoutesToWindowsWorkloads

            Write-Output "Routing entries added.`n"

            # remove routes to non existent gateways
            $cbr0Gateway = $setupConfigRoot.psobject.properties['cbr0Gateway'].value
            Write-Log "Remove obsolete route to $cbr0Gateway"
            Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop $cbr0Gateway -Confirm:$false -ErrorAction SilentlyContinue
            $loopbackGateway = $setupConfigRoot.psobject.properties['loopbackGateway'].value
            Write-Log "Remove obsolete route to $loopbackGateway"
            Remove-NetRoute -DestinationPrefix 0.0.0.0/0 -NextHop $loopbackGateway -Confirm:$false -ErrorAction SilentlyContinue

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
    Stop-ServiceAndSetToManualStart 'httpproxy'
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

function Set-RoutesToKubemaster {
    # the usage of these routes was removed because windows takes care on it's own for such routes !!!
    # route for VM
    $ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP

    # get the index of the master node switch
    # $ipindex = Get-MasterNodeSwitchIndex
    # if (-not $ipindex) {
    Write-Log 'No index found for master node switch, set routes to kubemaster with no interface index'
    Write-Log "Remove obsolete route to $ipControlPlaneCIDR"
    route delete $ipControlPlaneCIDR >$null 2>&1
    Write-Log "Add route to host network for master CIDR:$ipControlPlaneCIDR with metric 3"
    route -p add $ipControlPlaneCIDR $windowsHostIpAddress METRIC 3 | Out-Null 
    # }
    # else {
    #     Write-Log "Index for master node switch: $ipindex"
    #     Write-Log "Remove obsolete route to $ipControlPlaneCIDR"
    #     route delete $ipControlPlaneCIDR >$null 2>&1
    #     Write-Log "Add route to host network for master CIDR:$ipControlPlaneCIDR with metric 3"
    #     route -p add $ipControlPlaneCIDR $windowsHostIpAddress METRIC 3 IF $ipindex | Out-Null 
    # }
}

function Set-RoutesToLinuxWorkloads {
    # routes for Linux pods
    $ipControlPlane = Get-ConfiguredIPControlPlane
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRMaster = $setupConfigRoot.psobject.properties['podNetworkMasterCIDR'].value
    $clusterCIDRServices = $setupConfigRoot.psobject.properties['servicesCIDR'].value
    $clusterCIDRServicesLinux = $setupConfigRoot.psobject.properties['servicesCIDRLinux'].value
    Write-Log "Remove obsolete route to $clusterCIDRMaster"
    route delete $clusterCIDRMaster >$null 2>&1
    Write-Log "Add route to Linux master pods CIDR:$clusterCIDRMaster with metric 4"
    route -p add $clusterCIDRMaster $ipControlPlane METRIC 4 | Out-Null
    # routes for Linux services
    route delete $clusterCIDRServices >$null 2>&1
    Write-Log "Remove obsolete route to $clusterCIDRServicesLinux"
    route delete $clusterCIDRServicesLinux >$null 2>&1
    Write-Log "Add route to Linux Services CIDR:$clusterCIDRServicesLinux with metric 6"
    route -p add $clusterCIDRServicesLinux $ipControlPlane METRIC 6 | Out-Null
}

function Set-RoutesToWindowsWorkloads {
    $ipControlPlane = Get-ConfiguredIPControlPlane
    $setupConfigRoot = Get-RootConfigk2s
    $PodSubnetworkNumber = '1'
    $clusterCIDRWorker = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber 
    $clusterCIDRNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber 
    # routes for Windows pods
    Write-Log "Remove obsolete route to $clusterCIDRWorker"
    route delete $clusterCIDRWorker >$null 2>&1
    Write-Log "Add route to Windows Pods on host CIDR:$clusterCIDRWorker with metric 5"
    route -p add $clusterCIDRWorker $clusterCIDRNextHop METRIC 5 | Out-Null
    $clusterCIDRServicesWindows = $setupConfigRoot.psobject.properties['servicesCIDRWindows'].value
    # routes for services
    Write-Log "Remove obsolete route to $clusterCIDRServicesWindows"
    route delete $clusterCIDRServicesWindows >$null 2>&1
    Write-Log "Add route 1 to Windows Services CIDR:$clusterCIDRServicesWindows with metric 7"
    route -p add $clusterCIDRServicesWindows $ipControlPlane METRIC 7 | Out-Null
}

function Repair-K2sRoutes {
    Set-RoutesToKubemaster
    Set-RoutesToLinuxWorkloads
    Set-RoutesToWindowsWorkloads
    # TODO: add routes for additional nodes
}

Export-ModuleMember -Function Add-WindowsWorkerNodeOnWindowsHost,
Remove-WindowsWorkerNodeOnWindowsHost,
Start-WindowsWorkerNodeOnWindowsHost,
Stop-WindowsWorkerNodeOnWindowsHost,
Wait-NetworkL2BridgeReady,
Repair-K2sRoutes,
Set-RoutesToKubemaster,
Set-RoutesToLinuxWorkloads,
Set-RoutesToWindowsWorkloads