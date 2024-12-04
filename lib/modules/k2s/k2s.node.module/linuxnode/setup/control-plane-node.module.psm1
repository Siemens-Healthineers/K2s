# SPDX-FileCopyrightText: © 2024 Siemens Healthcare AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule =   "$PSScriptRoot\..\..\..\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

function New-ControlPlaneNodeOnNewVM {
    Param(
        # Main parameters
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
        [long] $MasterVMMemory = 8GB,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
        [long] $MasterVMProcessorCount = 6,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
        [uint64] $MasterDiskSize = 50GB,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
        [string]$DnsServers = $(throw 'Argument missing: DnsServers'),
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [switch] $ForceOnlineInstallation = $false,

        # These are specific developer options
        [parameter(Mandatory = $false, HelpMessage = 'Exit after initial checks')]
        [switch] $CheckOnly = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
        [switch] $WSL = $false
    )

    Write-Log 'Prerequisites checks before installation' -Console

    Test-PathPrerequisites
    Test-ControlPlanePrerequisites -MasterVMProcessorCount $MasterVMProcessorCount -MasterVMMemory $MasterVMMemory -MasterDiskSize $MasterDiskSize
    Test-WindowsPrerequisites -WSL:$WSL
    Stop-InstallationIfRequiredCurlVersionNotInstalled
    Write-WarningIfRequiredSshVersionNotInstalled

    if ($CheckOnly) {
        Write-Log 'Early exit (CheckOnly)'
        return
    }

    Write-Log 'Starting installation...'

    Set-ConfigWslFlag -Value $([bool]$WSL)

    $controlPlaneParams = @{
        Hostname = Get-ConfigControlPlaneNodeHostname
        IpAddress = Get-ConfiguredIPControlPlane
        GatewayIpAddress = Get-ConfiguredKubeSwitchIP
        DnsServers= $DnsServers
        VmName = 'KubeMaster'
        VMMemoryStartupBytes = $MasterVMMemory
        VMProcessorCount = $MasterVMProcessorCount
        VMDiskSize = $MasterDiskSize
        Proxy = $Proxy
        DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
        ForceOnlineInstallation = $ForceOnlineInstallation
    }

    if ($WSL) {
        Write-Log "Setting up $($controlPlaneParams.VmName) Distro" -Console
        Write-Log 'vEthernet (WSL) switch will be reconfigured! Your existing WSL distros will not work properly until you stop the cluster.'
        Write-Log 'Configuring WSL2'
        Set-WSL -MasterVMMemory $MasterVMMemory -MasterVMProcessorCount $MasterVMProcessorCount
        New-WslLinuxVmAsControlPlaneNode @controlPlaneParams
        Start-WSL
        Set-WSLSwitch -IpAddress $($controlPlaneParams.GatewayIpAddress)
    }
    else {
        Write-Log "Setting up $($controlPlaneParams.VmName) VM" -Console
        New-LinuxVmAsControlPlaneNode @controlPlaneParams
        New-KubeSwitch
        Connect-KubeSwitch
    }

    Wait-ForSSHConnectionToLinuxVMViaPwd

    $controlPlaneUserName = $(Get-DefaultUserNameControlPlane) 
    $controlPlaneUserPwd = $(Get-DefaultUserPwdControlPlane)
    $controlPlaneIpAddress = $($controlPlaneParams.IpAddress)

    Write-Log "Copy deb packages from control plane to Windows host"
    Copy-DebPackagesFromControlPlaneToWindowsHost -IpAddress $controlPlaneIpAddress  -UserName $controlPlaneUserName -UserPwd $controlPlaneUserPwd
    Write-Log "Copy container images from control plane to Windows host"
    Copy-KubernetesImagesFromControlPlaneNodeToWindowsHost -IpAddress $controlPlaneIpAddress  -UserName $controlPlaneUserName -UserPwd $controlPlaneUserPwd
    
    New-SshKey -IpAddress $controlPlaneIpAddress
    Copy-LocalPublicSshKeyToRemoteComputer -UserName $controlPlaneUserName -UserPwd $controlPlaneUserPwd -IpAddress $controlPlaneIpAddress
    Wait-ForSSHConnectionToLinuxVMViaSshKey

    Remove-ControlPlaneAccessViaUserAndPwd
    
    # add kubectl to Windows host
    Install-KubectlTool
    # copy kubectl config file into Windows host
    Copy-KubeConfigFromControlPlaneNode
    Add-K8sContext

    $hostname = (Invoke-CmdOnControlPlaneViaSSHKey -CmdToExecute 'hostname' -NoLog).Output
    Set-ConfigControlPlaneNodeHostname($hostname)

    # add to Path variable
    Set-EnvVars

    Update-NodeLabelsAndTaints
}

function Start-ControlPlaneNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Number of processors for VM')]
        [string] $VmProcessors,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Use cached vSwitches')]
        [switch] $UseCachedK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $DnsServers = $(throw 'Argument missing: DnsServers')
    )

    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP

    function CheckKubeSwitchInExpectedState() {
        $controlPlaneNodeDefaultSwitchName = Get-ControlPlaneNodeDefaultSwitchName
        $if = Get-NetConnectionProfile -InterfaceAlias "vEthernet ($controlPlaneNodeDefaultSwitchName)" -ErrorAction SilentlyContinue
        if (!$if) {
            Write-Log "vEthernet ($controlPlaneNodeDefaultSwitchName) not found."
            return $false
        }
        if ($if.NetworkCategory -ne 'Private') {
            Write-Log "vEthernet ($controlPlaneNodeDefaultSwitchName) not set to private."
            return $false
        }
        $if = Get-NetIPAddress -InterfaceAlias "vEthernet ($controlPlaneNodeDefaultSwitchName)" -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if (!$if) {
            Write-Log "Unable get IP Address for host on vEthernet ($controlPlaneNodeDefaultSwitchName) interface..."
            return $false
        }
        if ($if.IPAddress -ne $windowsHostIpAddress) {
            Write-Log "IP Address of Host on vEthernet ($controlPlaneNodeDefaultSwitchName) is not $windowsHostIpAddress ..."
            return $false
        }
        return $true
    }

    function EnsureCni0InterfaceIsCreated {
        param (
            [string] $VmName = $(throw 'Argument missing: VmName'),
            [bool] $WSL  = $(throw 'Argument missing: WSL')
        )
        $i = 0
        while($true) {
            $controlPlaneCni0IpAddr = Get-Cni0IpAddressInControlPlaneUsingSshWithRetries -Retries 30 -RetryTimeoutInSeconds 5
            $expectedControlPlaneCni0IpAddr = Get-ConfiguredMasterNetworkInterfaceCni0IP

            if ($controlPlaneCni0IpAddr -ne $expectedControlPlaneCni0IpAddr) {
                Write-Log "cni0 interface in $controlPlaneVMHostName is not correctly initialized."
                Write-Log "           Expected:$expectedControlPlaneCni0IpAddr"
                Write-Log "           Actual:$controlPlaneCni0IpAddr"

                if ($i -eq 3) {
                    throw "cni0 interface in $controlPlaneVMHostName is not correctly initialized after $i retries."
                }
            } else {
                Write-Log "cni0 interface in $controlPlaneVMHostName correctly initialized."
                break
            }
            if (!$WSL) {
                Stop-VirtualMachine -VmName $VmName -Wait
                Start-VirtualMachine -VmName $VmName -Wait
            } else {
                wsl --shutdown
                Start-WSL
            }
            Wait-ForSSHConnectionToLinuxVMViaSshKey
            $i++
        }
    }

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Starting K2s control plane'
    }

    $WSL = Get-ConfigWslFlag
    if ($WSL) {
        Write-Log 'Using WSL2 as hosting environment for the control plane node'
    }
    else {
        Write-Log 'Using Hyper-V as hosting environment for the control plane node'
    }


    $NumOfProcessors = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    if ([int]$NumOfProcessors -lt 4) {
        throw 'Your Windows host needs at least 4 logical processors'
    }

    if ($VmProcessors -ne '') {
        # Do not reset VMProcessorCount with default value unless supplied from the user
        if ([int]$VmProcessors -ge [int]$NumOfProcessors) {
            Write-Log "Amount of logical processors on Windows host: $NumOfProcessors. Specified amount of processors for the VM: $VmProcessors."
            $VmProcessors = [int]$NumOfProcessors
            Write-Log "Cannot use a greater value of processors than the available logical ones. The VM will have $VmProcessors processors."
        }
    }

    $switchname = ''
    if ($WSL) {
        $switchname = Get-WslSwitchName
    }
    else {
        $switchname = Get-ControlPlaneNodeDefaultSwitchName
    }

    Set-IndexForDefaultSwitch

    $controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
    $ipControlPlane = Get-ConfiguredIPControlPlane

    $ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR

    if (!$WSL) {
        # Because of stability issues network settings are recreated every time we start the machine
        # or we restart the service !!!!! (StopServices.ps1 also cleans up the entire network setup)
        # stop VM
        Write-Log 'Reconfiguring VM'
        Write-Log "Configuring $controlPlaneVMHostName VM" -Console
        Stop-VirtualMachine -VmName $controlPlaneVMHostName -Wait

        if ($VmProcessors -ne '') {
            # change cores
            Set-VMProcessor $controlPlaneVMHostName -Count $VmProcessors
        }

        $kubeSwitchInExpectedState = CheckKubeSwitchInExpectedState
        if(!$UseCachedK2sVSwitches -or !$kubeSwitchInExpectedState) {
            # Remove old switch
            Write-Log 'Updating VM networking...'
            Remove-KubeSwitch

            # create switch for VM
            New-KubeSwitch
            Set-InterfacePrivate -InterfaceAlias "vEthernet ($switchname)"

            # connect VM to switch
            Connect-KubeSwitch
        }

        Start-VirtualMachine -VmName $controlPlaneVMHostName -Wait
    } else {
        Write-Log 'Configuring KubeMaster Distro' -Console
        wsl --shutdown
        Start-WSL
        Set-WSLSwitch -IpAddress $windowsHostIpAddress

        $interfaceAlias = Get-NetAdapter -Name "vEthernet (WSL*)" -ErrorAction SilentlyContinue -IncludeHidden | Select-Object -expandproperty name
        New-NetFirewallRule -DisplayName 'WSL Inbound' -Group "k2s" -Direction Inbound -InterfaceAlias $interfaceAlias -Action Allow
        New-NetFirewallRule -DisplayName 'WSL Outbound'-Group "k2s" -Direction Outbound -InterfaceAlias $interfaceAlias -Action Allow
    }

    # add DNS proxy for cluster searches
    Add-DnsServer $switchname

    # route for VM
    Write-Log "Remove obsolete route to $ipControlPlaneCIDR"
    route delete $ipControlPlaneCIDR >$null 2>&1
    Write-Log "Add route to host network for master CIDR:$ipControlPlaneCIDR with metric 3"
    route -p add $ipControlPlaneCIDR $windowsHostIpAddress METRIC 3 | Out-Null

    Wait-ForSSHConnectionToLinuxVMViaSshKey

    EnsureCni0InterfaceIsCreated -VmName $controlPlaneVMHostName -WSL:$WSL

    $ipindex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "*$switchname*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
    Write-Log "Index for interface $switchname : ($ipindex) -> metric 25"
    Set-NetIPInterface -InterfaceIndex $ipindex -InterfaceMetric 25

    Invoke-TimeSync

    Write-Log 'Set the DNS server(s) used by the Windows Host as the default DNS server(s) of the VM'
    (Invoke-CmdOnControlPlaneViaSSHKey "sudo sed -i 's/dns-nameservers.*/dns-nameservers $DnsServers/' /etc/network/interfaces.d/10-k2s").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl restart networking').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl restart dnsmasq').Output | Write-Log

    $ipControlPlane = Get-ConfiguredIPControlPlane
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRMaster = $setupConfigRoot.psobject.properties['podNetworkMasterCIDR'].value
    $clusterCIDRServices = $setupConfigRoot.psobject.properties['servicesCIDR'].value
    $clusterCIDRServicesLinux = $setupConfigRoot.psobject.properties['servicesCIDRLinux'].value

    # routes for Linux pods
    Write-Log "Remove obsolete route to $clusterCIDRMaster"
    route delete $clusterCIDRMaster >$null 2>&1
    Write-Log "Add route to Linux master pods CIDR:$clusterCIDRMaster with metric 4"
    route -p add $clusterCIDRMaster $ipControlPlane METRIC 4 | Out-Null

    # routes for services
    route delete $clusterCIDRServices >$null 2>&1
    Write-Log "Remove obsolete route to $clusterCIDRServicesLinux"
    route delete $clusterCIDRServicesLinux >$null 2>&1
    Write-Log "Add route to Linux Services CIDR:$clusterCIDRServicesLinux with metric 6"
    route -p add $clusterCIDRServicesLinux $ipControlPlane METRIC 6 | Out-Null


    # enable ip forwarding
    netsh int ipv4 set int "vEthernet ($switchname)" forwarding=enabled | Out-Null
    netsh int ipv4 set int 'vEthernet (Ethernet)' forwarding=enabled | Out-Null

    # Double check for KubeSwitch is in expected Private state
    Set-InterfacePrivate -InterfaceAlias "vEthernet ($switchname)"

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'K2s control plane started'
    }
}

function Stop-ControlPlaneNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Cache vSwitches on stop')]
        [switch] $CacheK2sVSwitches,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
        [switch] $SkipHeaderDisplay = $false
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Stopping K2s control plane'
    }

    # reset default namespace
    $kubeToolsPath = Get-KubeToolsPath
    $kubectlExe = "$kubeToolsPath\kubectl.exe"
    if (Test-Path "$kubectlExe") {
        Write-Log 'Resetting default namespace for kubernetes'
        &"$kubectlExe" config set-context --current --namespace=default | Out-Null
    }

    $WSL = Get-ConfigWslFlag

    $switchname = ''
    if ($WSL) {
        $switchname = Get-WslSwitchName
    }
    else {
        $switchname = Get-ControlPlaneNodeDefaultSwitchName
    }

    if ($WSL) {
        wsl --shutdown
        $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
        Remove-NetIPAddress -IPAddress $windowsHostIpAddress -PrefixLength 24 -Confirm:$False -ErrorAction SilentlyContinue

        $hns = $(Get-HNSNetwork)
        $hns | Where-Object Name -Like ('*' + $switchname + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
        Restart-WinService 'WslService'
    }
    else {
        # stop vm
        $controlPlaneVMHostName = Get-ConfigControlPlaneNodeHostname
        if ($(Get-VM | Where-Object Name -eq $controlPlaneVMHostName | Measure-Object).Count -eq 1 ) {
            Write-Log ('Stopping ' + $controlPlaneVMHostName + ' VM') -Console
            Stop-VM -Name $controlPlaneVMHostName -Force -WarningAction SilentlyContinue
        }
        if (!$CacheK2sVSwitches) {
            Remove-KubeSwitch
        }
    }

    Reset-DnsServer $switchname

    $ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRMaster = $setupConfigRoot.psobject.properties['podNetworkMasterCIDR'].value
    $clusterCIDRServices = $setupConfigRoot.psobject.properties['servicesCIDR'].value
    $clusterCIDRServicesLinux = $setupConfigRoot.psobject.properties['servicesCIDRLinux'].value

    # Remove routes
    Write-Log "Remove route to $ipControlPlaneCIDR"
    route delete $ipControlPlaneCIDR >$null 2>&1
    Write-Log "Remove route to $clusterCIDRMaster"
    route delete $clusterCIDRMaster >$null 2>&1
    Write-Log "Remove route to $clusterCIDRServices"
    route delete $clusterCIDRServices >$null 2>&1
    route delete $clusterCIDRServicesLinux >$null 2>&1

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'K2s control plane stopped'
    }
}

function Remove-ControlPlaneNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
        [switch] $SkipPurge = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
        [switch] $SkipHeaderDisplay = $false
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Uninstalling K2s control plane'
    }

    $WSL = Get-ConfigWslFlag
    $VmName = 'KubeMaster'

    if ($WSL) {
        wsl --shutdown | Out-Null
        wsl --unregister $VmName | Out-Null
    } else {
        Stop-VirtualMachine -VmName $VmName -Wait
        Remove-VirtualMachine $VmName
    }

    Write-Log 'Cleaning up' -Console

    Clear-ProvisioningArtifacts

    $linuxnodePath = "$(Get-KubeBinPath)\linuxnode"
    Write-Log "Delete folder '$linuxnodePath' if existing"
    if (Test-Path $linuxnodePath) {
        Write-Log "Deleting folder '$linuxnodePath'"
        Remove-Item -Path $linuxnodePath -Recurse -Force
    }
    
    if ($DeleteFilesForOfflineInstallation) {
        $kubemasterBaseFilePath = Get-KubemasterBaseFilePath
        $kubemasterRootfsPath = Get-ControlPlaneOnWslRootfsFilePath
        $kubenodeBaseFilePath = "$(Split-Path $kubemasterBaseFilePath)\$(Get-KubenodeBaseFileName)"
        Write-Log "Delete file '$kubemasterBaseFilePath' if existing"
        if (Test-Path $kubemasterBaseFilePath) {
            Remove-Item $kubemasterBaseFilePath -Force
        }
        Write-Log "Delete file '$kubemasterRootfsPath' if existing"
        if (Test-Path $kubemasterRootfsPath) {
            Remove-Item $kubemasterRootfsPath -Force
        }
        Write-Log "Delete file '$kubenodeBaseFilePath' if existing"
        if (Test-Path $kubenodeBaseFilePath) {
            Remove-Item $kubenodeBaseFilePath -Force
        }
    }

    Write-Log 'Remove previous VM key from known_hosts file'
    $ipControlPlane = Get-ConfiguredIPControlPlane
    ssh-keygen.exe -R $ipControlPlane 2>&1 | % { "$_" } | Out-Null

    if (!$SkipPurge) {
        Remove-SshKey -IpAddress $ipControlPlane
    }

    Clear-WinNode -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

    Reset-EnvVars

    Write-Log 'Uninstalling K2s control plane done.'
}

Export-ModuleMember -Function New-ControlPlaneNodeOnNewVM,
Start-ControlPlaneNodeOnNewVM,
Stop-ControlPlaneNodeOnNewVM,
Remove-ControlPlaneNodeOnNewVM