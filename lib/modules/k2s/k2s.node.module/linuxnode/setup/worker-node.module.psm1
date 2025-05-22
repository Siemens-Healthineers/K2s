# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule =   "$PSScriptRoot\..\..\..\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule

function Add-LinuxWorkerNodeOnNewVM {
    Param(
        [string] $WorkerNodeName = $(throw 'Argument missing: WorkerNodeName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of master VM (Linux)')]
        [long] $MasterVMMemory = 8GB,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for master VM (Linux)')]
        [long] $MasterVMProcessorCount = 6,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of master VM (Linux)')]
        [uint64] $MasterDiskSize = 10GB,
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'DNS Addresses if available')]
        [string]$DnsServers = $(throw 'Argument missing: DnsServers'),
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [switch] $ForceOnlineInstallation = $false
    )

    Write-Log 'Starting addition of new node...'
    Write-Log "Setting up $($workerNodeParams.VmName) VM"

    $workerNodeParams = @{
        Hostname = $WorkerNodeName
        IpAddress = $IpAddress
        GatewayIpAddress = Get-ConfiguredKubeSwitchIP
        DnsServers= $DnsServers
        VmName = $WorkerNodeName
        VMMemoryStartupBytes = $MasterVMMemory
        VMProcessorCount = $MasterVMProcessorCount
        VMDiskSize = $MasterDiskSize
        Proxy = $Proxy
        DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
        ForceOnlineInstallation = $ForceOnlineInstallation
    }
    New-LinuxVmAsWorkerNode @workerNodeParams

    $remoteUsername = Get-DefaultUserNameWorkerNode
    $remoteUser = "$remoteUserName@$IpAddress"
    $remoteUserPwd = Get-DefaultUserPwdWorkerNode

    Wait-ForSSHConnectionToLinuxVMViaPwd -User $remoteUser -UserPwd $remoteUserPwd

    Write-Log "Copying ZScaler Root CA certificate to node '$WorkerNodeName'"
    Copy-ToRemoteComputerViaUserAndPwd -Source "$(Get-KubePath)\lib\modules\k2s\k2s.node.module\linuxnode\setup\certificate\ZScalerRootCA.crt" -Target "/tmp/ZScalerRootCA.crt" -IpAddress $IpAddress
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo mv /tmp/ZScalerRootCA.crt /usr/local/share/ca-certificates/" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaUserAndPwd -CmdToExecute "sudo update-ca-certificates" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -IgnoreErrors).Output | Write-Log
    Write-Log "Zscaler certificate added to CA certificates of node '$WorkerNodeName'"

    Write-Log 'Remove previous VM key from known_hosts file'
    ssh-keygen.exe -R $IpAddress 2>&1 | ForEach-Object { "$_" } | Out-Null

    Copy-LocalPublicSshKeyToRemoteComputer -UserName $remoteUsername -UserPwd $remoteUserPwd -IpAddress $IpAddress
    Wait-ForSSHConnectionToLinuxVMViaSshKey -User $remoteUser

    (Invoke-CmdOnVmViaSSHKey "sudo sed -i '/nameservers:/!b;n;s/addresses: \[.*\]/addresses: [$(Get-ConfiguredIPControlPlane)]/' /etc/netplan/10-k2s.yaml" -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey 'sudo systemctl restart systemd-networkd' -IpAddress $IpAddress).Output | Write-Log

    Join-LinuxNode -NodeName $WorkerNodeName -NodeUserName $remoteUsername -NodeIpAddress $IpAddress

    Remove-VmAccessViaUserAndPwd -IpAddress $IpAddress
}

function Start-LinuxWorkerNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Number of processors for VM')]
        [string] $VmProcessors,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = $(throw 'Argument missing: Hostname')
    )

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName
    Add-RouteToLinuxWorkerNode -NodeName $NodeName -IpAddress $IpAddress -ClusterCIDRWorker $clusterCIDRWorker

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log "K2s worker node '$NodeName' started"
    }
}

function Stop-LinuxWorkerNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $NodeName = $(throw 'Argument missing: Hostname')
    )

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName
    Remove-RouteToLinuxWorkerNode -NodeName $NodeName -ClusterCIDRWorker $clusterCIDRWorker

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log "K2s worker node '$NodeName' stopped"
    }
}

function Remove-LinuxWorkerNodeOnNewVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $NodeName = $(throw 'Argument missing: NodeName')
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log "Removing K2s worker node '$NodeName'"
    }

    $kubeToolsPath = Get-KubeToolsPath
    $ipAddress = &"$kubeToolsPath\kubectl.exe" get nodes $NodeName -o jsonpath="{.status.addresses[?(@.type=='InternalIP')].address}"
    if ([string]::IsNullOrWhiteSpace($ipAddress)) {
        throw "Cannot obtain IP address of node '$NodeName'"
    }

    &"$kubeToolsPath\kubectl.exe" drain $NodeName --ignore-daemonsets --delete-emptydir-data 2>&1 | ForEach-Object { "$_" } | Write-Log
    &"$kubeToolsPath\kubectl.exe" delete node $NodeName 2>&1 | ForEach-Object { "$_" } | Write-Log

    Stop-VirtualMachine -VmName $NodeName -Wait
    Remove-VirtualMachine $NodeName

    Write-Log 'Remove key from known_hosts file'
    ssh-keygen.exe -R $ipAddress 2>&1 | ForEach-Object { "$_" } | Out-Null

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log "Removing K2s worker node '$NodeName' done."
    }
}

function Add-LinuxWorkerNodeOnExistingUbuntuVM {
    Param(
        [string] $VmName = $(throw 'Argument missing: VmName'),
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $ClusterIpAddress = $(throw 'Argument missing: ClusterIpAddress'),
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = ''
    )

    Write-Log "Prepare the computer $IpAddress for provisioning"
    Set-UpComputerBeforeProvisioning -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy

    Install-DebPackagesAndAddContainerImagesIntoRemoteComputer -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy

    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo mkdir -p /etc/netplan/backup' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "find /etc/netplan -maxdepth 1 -type f -exec sudo mv {} /etc/netplan/backup ';'" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $controlPlaneIpAddress = Get-ConfiguredIPControlPlane
    $networkPrefix = Get-ConfiguredClusterNetworkPrefix
    $networkInterfaceName = 'eth0'
    Add-RemoteIPAddress -UserName $UserName -IPAddress $IpAddress -RemoteIpAddress $ClusterIpAddress -PrefixLength $networkPrefix -RemoteIpAddressGateway $windowsHostIpAddress -DnsEntries $controlPlaneIpAddress -NetworkInterfaceName $networkInterfaceName
    Disconnect-VMNetworkAdapter -VmName $VmName -ErrorAction Stop
    $switchName = Get-ControlPlaneNodeDefaultSwitchName
    Connect-VMNetworkAdapter -VmName $VmName -SwitchName $switchName -ErrorAction Stop
    Wait-ForSSHConnectionToLinuxVMViaSshKey -User "$UserName@$ClusterIpAddress"

    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
    $transparentProxy = "http://$($windowsHostIpAddress):8181"
    Set-ProxySettingsOnKubenode -ProxySettings $transparentProxy -UserName $UserName -IpAddress $ClusterIpAddress

    $k8sFormattedNodeName = $NodeName.ToLower()
    Join-LinuxNode -NodeName $k8sFormattedNodeName.ToLower() -NodeUserName $UserName -NodeIpAddress $ClusterIpAddress
}

function Remove-LinuxWorkerNodeOnExistingUbuntuVM {
    Param(
        [string] $VmName = $(throw 'Argument missing: VmName'),
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [switch] $SkipHeaderDisplay = $false
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log "Removing K2s worker node '$NodeName'"
    }

    Remove-ProxySettingsOnKubenode -UserName $UserName -IpAddress $IpAddress

    $k8sFormattedNodeName = $NodeName.ToLower()
    $clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
    if ($clusterState -match $k8sFormattedNodeName) {
        Remove-LinuxNode -NodeName $k8sFormattedNodeName -NodeUserName $UserName -NodeIpAddress $IpAddress
    }

    Remove-KubernetesArtifacts -UserName $UserName -IpAddress $IpAddress

    (Invoke-CmdOnVmViaSSHKey -CmdToExecute "if [[ -d /etc/netplan/backup ]]; then find /etc/netplan/backup -maxdepth 1 -type f -exec sudo mv {} /etc/netplan ';';fi" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo rm -rf /etc/netplan/backup' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
    Remove-RemoteIPAddress -UserName $UserName -IpAddress $IpAddress

    Disconnect-VMNetworkAdapter -VmName $VmName -ErrorAction Stop
    Write-Log "Stopping VM $VmName"
    Stop-VM -Name $VmName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $VmName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
    }
    Write-Log "Starting VM $VmName"
    Start-VM -Name $VmName

    Write-Log "Important: reconnect manually the VM '$VmName' to the corresponding switch."
    Write-Log "Important: enable swap manually if it was enabled before adding the VM '$VmName' to the cluster."

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log "Removing K2s worker node '$NodeName' done."
    }
}

function Start-LinuxWorkerNodeOnExistingVM {
    Param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false
    )

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName
    Add-RouteToLinuxWorkerNode -NodeName $NodeName -IpAddress $IpAddress -ClusterCIDRWorker $clusterCIDRWorker

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log "K2s worker node '$NodeName' started"
    }
}

function Stop-LinuxWorkerNodeOnExistingVM {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
        [switch] $SkipHeaderDisplay = $false,
        [string] $NodeName = $(throw 'Argument missing: Hostname')
    )

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName
    Remove-RouteToLinuxWorkerNode -NodeName $NodeName -ClusterCIDRWorker $clusterCIDRWorker

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log "K2s worker node '$NodeName' stopped"
    }
}

function Add-LinuxWorkerNodeOnUbuntuBareMetal {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $WindowsHostIpAddress = $(throw 'Argument missing: WindowsHostIpAddress'),
        [string] $Proxy = '',
        [string] $AdditionalHooksDir = ''
    )

    $nodeParams = @{
        Name = $NodeName
        IpAddress = $IpAddress
        UserName = $UserName
        Proxy = $Proxy
        NodeType = 'HOST'
        Role = 'worker'
        OS = 'linux'
        PodCIDR = '' # will be filled during start of node
    }
    Add-NodeConfig @nodeParams

    Write-Log "Installing node essentials" -Console

    Write-Log "Prepare the computer $IpAddress for provisioning"
    Set-UpComputerBeforeProvisioning -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy

    Install-DebPackagesAndAddContainerImagesIntoRemoteComputer -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy

    $doBeforeJoining = {
        Write-Log "Configuring networking for adding the node" -Console
        # add a route to the cluster network over the Windows host IP address
        $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route add $controlPlaneCIDR via $WindowsHostIpAddress" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

        $podNetworkCIDR = Get-ConfiguredClusterCIDR
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route add $podNetworkCIDR via $WindowsHostIpAddress" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

        $networkInterfaceName = (Get-NetIPAddress | Where-Object { $_.AddressFamily -eq "IPv4" -and ($_.IPAddress -match $WindowsHostIpAddress)} | Select-Object -ExpandProperty InterfaceAlias)
        if ([string]::IsNullOrWhiteSpace($networkInterfaceName)) {
            throw "Cannot find the network interface belonging to the IP address '$WindowsHostIpAddress'"
        }

        netsh int ipv4 set int $networkInterfaceName forwarding=enabled | Out-Null
    }

    Write-Log "Joining new node to the cluster" -Console
    $k8sFormattedNodeName = $NodeName.ToLower()
    Join-LinuxNode -NodeName $k8sFormattedNodeName.ToLower() -NodeUserName $UserName -NodeIpAddress $IpAddress -PreStepHook $doBeforeJoining
}

function Remove-LinuxWorkerNodeOnUbuntuBareMetal {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $AdditionalHooksDir = ''
    )
    Write-Log "Removing K2s worker node '$NodeName'"

    $doAfterRemoving = {
        # delete routes
        $controlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route delete $controlPlaneCIDR" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

        $podNetworkCIDR = Get-ConfiguredClusterCIDR
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip route delete $podNetworkCIDR" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

        # delete network interface 'cni0' that was created by flannel
        (Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo ip link delete cni0" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

        Write-Log "Reconfigured networking for node removal" -Console
    }

    $k8sFormattedNodeName = $NodeName.ToLower()
    $clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
    if ($clusterState -match $k8sFormattedNodeName) {
        Remove-LinuxNode -NodeName $k8sFormattedNodeName -NodeUserName $UserName -NodeIpAddress $IpAddress -PostStepHook $doAfterRemoving
        Write-Log "Removed node from the cluster" -Console
    }

    Remove-KubernetesArtifacts -UserName $UserName -IpAddress $IpAddress
    Write-Log "Removed node essentials from the remote machine" -Console

    Remove-NodeConfig -Name $NodeName

    Write-Log "Removing K2s worker node '$NodeName' complete."
}

function Start-LinuxWorkerNodeOnUbuntuBareMetal {
    Param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $AdditionalHooksDir = '',
        [switch] $ObtainCIDR = $false
    )

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName -ObtainCIDR:$ObtainCIDR
    Add-RouteToLinuxWorkerNode -NodeName $NodeName -IpAddress $IpAddress -ClusterCIDRWorker $clusterCIDRWorker
    Add-WorkerVFPRoute -NodeName $NodeName -ClusterCIDRWorker $clusterCIDRWorker

    Write-Log "K2s worker node '$NodeName' started" -Console
}

function Add-WorkerVFPRoute {
    Param(
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [string] $ClusterCIDRWorker = $(throw 'Argument missing: Hostname')
    )

    $setupConfigRoot = Get-RootConfigk2s
    $defaultGateway = $setupConfigRoot.psobject.properties['cbr0'].value
    Add-VfpRoute -Name $NodeName -Subnet $ClusterCIDRWorker -Gateway $defaultGateway
}

function Stop-LinuxWorkerNodeOnUbuntuBareMetal {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $AdditionalHooksDir = '',
        [switch] $SkipHeaderDisplay = $false

    )

    $clusterCIDRWorker = Get-ClusterCIDRWorker -NodeName $NodeName
    Remove-RouteToLinuxWorkerNode -NodeName $NodeName -ClusterCIDRWorker $clusterCIDRWorker
    Remove-VfpRoute -Name $NodeName

    Write-Log "K2s worker node '$NodeName' stopped" -Console
}

function Get-ClusterCIDRWorker {
    Param (
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [switch] $ObtainCIDR = $false
    )

    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRWorkerTemplate = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR_2'].value

    $clusterCIDRWorker = ''
    if (!$ObtainCIDR) {
        Write-Log 'Getting Node CIDR from config'
        $node = Get-NodeConfig -NodeName $NodeName
        if ($null -ne $node) {
            $clusterCIDRWorker = $node.PodCIDR
        }
    }

    if ($clusterCIDRWorker -eq '' -or $ObtainCIDR) {
        $output = Get-AssignedPodSubnetworkNumber -NodeName $NodeName
        if ($output.Success) {
            $assignedPodSubnetworkNumber = $output.PodSubnetworkNumber
            $clusterCIDRWorker = $clusterCIDRWorkerTemplate.Replace('X', $assignedPodSubnetworkNumber)

            Update-NodeConfig -Name $NodeName -Updates @{
                PodCIDR = $clusterCIDRWorker
            }
        } else {
            throw "Cannot obtain pod network information from node '$NodeName'"
        }
    }

    return $clusterCIDRWorker
}

function Add-RouteToLinuxWorkerNode {
    Param(
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [string] $ClusterCIDRWorker = $(throw 'Argument missing: ClusterCIDRWorker')
    )

    # routes for Linux pods to external nodes
    Write-Log "Remove obsolete route to $ClusterCIDRWorker"
    route delete $ClusterCIDRWorker >$null 2>&1
    Write-Log "Add route to Pods for node:$NodeName CIDR:$ClusterCIDRWorker"
    route -p add $ClusterCIDRWorker $IpAddress METRIC 4 | Out-Null
}

function Remove-RouteToLinuxWorkerNode {
    Param(
        [string] $NodeName = $(throw 'Argument missing: Hostname'),
        [string] $ClusterCIDRWorker = $(throw 'Argument missing: ClusterCIDRWorker')
    )

    # routes for Linux pods
    Write-Log "Remove obsolete route to $ClusterCIDRWorker"
    route delete $ClusterCIDRWorker >$null 2>&1
}

function Install-DebPackagesAndAddContainerImagesIntoRemoteComputer {
    Param(
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $Proxy = ''
    )
    $controlPlaneUserName = Get-DefaultUserNameControlPlane
    $controlPlaneIpAddress = Get-ConfiguredIPControlPlane
    $installedDistributionOnControlPlane = Get-InstalledDistribution -UserName $controlPlaneUserName -IpAddress $controlPlaneIpAddress
    $installedDistributionOnRemoteComputer = Get-InstalledDistribution -UserName $UserName -IpAddress $IpAddress
    Write-Log "Installed distribution in the control plane: $installedDistributionOnControlPlane"
    Write-Log "Installed distribution in the machine with IP '$IpAddress': $installedDistributionOnRemoteComputer"
    $baseDirectoryOfKubenodeDebPackagesOnWindowsHost = Get-BaseDirectoryOfKubenodeDebPackagesOnWindowsHost
    $windowsHostDebPackagesSourcePath = "$baseDirectoryOfKubenodeDebPackagesOnWindowsHost\$installedDistributionOnRemoteComputer"

    $linuxNodeArtifactsPackagePath = Get-PathOfLinuxNodeArtifactsPackageOnWindowsHost
    $linuxNodeArtifactsPath = Get-DirectoryOfLinuxNodeArtifactsOnWindowsHost

    $packagePathExists = $(Test-Path -Path $linuxNodeArtifactsPackagePath)
    $linuxNodeArtifactsPathExists = $(Test-Path -Path $linuxNodeArtifactsPath)
    Write-Log "Zip file '$linuxNodeArtifactsPackagePath' with Linux node artifacts exists?: $packagePathExists"
    Write-Log "Folder '$linuxNodeArtifactsPath' with Linux node artifacts exists?: $linuxNodeArtifactsPathExists"

    if (!($linuxNodeArtifactsPathExists) -and ($packagePathExists)) {
        Write-Log "Create folder '$linuxNodeArtifactsPath'"
        New-Item -Path $linuxNodeArtifactsPath -ItemType Directory -Force | Out-Null
        Write-Log "Extracting content of file '$linuxNodeArtifactsPackagePath' into '$linuxNodeArtifactsPath'"
        Expand-Archive -LiteralPath $linuxNodeArtifactsPackagePath -DestinationPath $linuxNodeArtifactsPath
    } 

    $distributionDebPackagesSourcePathExists = $(Test-Path -Path $windowsHostDebPackagesSourcePath)
    Write-Log "Folder with deb packages '$windowsHostDebPackagesSourcePath' exists?: $distributionDebPackagesSourcePathExists"
    if ($distributionDebPackagesSourcePathExists) {
        Write-Log "The content of the folder '$windowsHostDebPackagesSourcePath' will be used"
    } else {
        if ($installedDistributionOnRemoteComputer -eq $installedDistributionOnControlPlane) {
            Write-Log "The installed distribution in the machine with IP '$IpAddress' ('$installedDistributionOnRemoteComputer') is equal to the control plane's distribution --> its deb packages will be copied into '$windowsHostDebPackagesSourcePath'"
            Copy-DebPackagesFromControlPlaneToWindowsHost -TargetPath "$windowsHostDebPackagesSourcePath"
        } else {
            Write-Log "The installed distribution in the machine with IP '$IpAddress' ('$installedDistributionOnRemoteComputer') is different from the control plane's distribution ('$installedDistributionOnControlPlane') --> no deb packages will be copied from the control plane"
        }        
    }

    $kubernetesDebPackagesTargetPath = Get-KubernetesDebPackagesPath -UserName $UserName
    Add-KubernetesArtifactsToRemoteComputer -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -SourcePath $windowsHostDebPackagesSourcePath -TargetPath $kubernetesDebPackagesTargetPath
    Install-KubernetesArtifacts -UserName $UserName -IpAddress $IpAddress -Proxy $Proxy -SourcePath $kubernetesDebPackagesTargetPath

    $buildahDebPackagesTargetPath = Get-BuildahDebPackagesPath -UserName $UserName
    Add-BuildahArtifactsToRemoteComputer -UserName $UserName -IpAddress $IpAddress -SourcePath $windowsHostDebPackagesSourcePath -TargetPath $buildahDebPackagesTargetPath
    Install-BuildahDebPackages -UserName $UserName -IpAddress $IpAddress -SourcePath $buildahDebPackagesTargetPath

    Copy-KubernetesImagesFromControlPlaneToRemoteComputer -UserName $UserName -IpAddress $IpAddress
}

Export-ModuleMember -Function Add-LinuxWorkerNodeOnNewVM,
Start-LinuxWorkerNodeOnNewVM,
Stop-LinuxWorkerNodeOnNewVM,
Remove-LinuxWorkerNodeOnNewVM,
Start-LinuxWorkerNodeOnExistingVM,
Stop-LinuxWorkerNodeOnExistingVM,
Add-LinuxWorkerNodeOnExistingUbuntuVM,
Remove-LinuxWorkerNodeOnExistingUbuntuVM,
Add-LinuxWorkerNodeOnUbuntuBareMetal,
Remove-LinuxWorkerNodeOnUbuntuBareMetal,
Start-LinuxWorkerNodeOnUbuntuBareMetal,
Stop-LinuxWorkerNodeOnUbuntuBareMetal