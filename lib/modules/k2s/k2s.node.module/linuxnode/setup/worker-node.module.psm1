# SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
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
    #Remove-VmAccessViaUserAndPwd -IpAddress $IpAddress

    Join-LinuxNode -NodeName $WorkerNodeName -NodeUserName $remoteUsername -NodeIpAddress $IpAddress
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

    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRWorkerTemplate = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR_2'].value

    $assignedPodSubnetworkNumber = Get-AssignedPodSubnetworkNumber -NodeName $NodeName
    $clusterCIDRWorker = $clusterCIDRWorkerTemplate.Replace('X', $assignedPodSubnetworkNumber)

    # routes for Linux pods
    Write-Log "Remove obsolete route to $clusterCIDRWorker"
    route delete $clusterCIDRWorker >$null 2>&1
    Write-Log "Add route to $clusterCIDRWorker"
    route -p add $clusterCIDRWorker $IpAddress METRIC 4 | Out-Null

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

    $setupConfigRoot = Get-RootConfigk2s
    $clusterCIDRWorkerTemplate = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR_2'].value

    $assignedPodSubnetworkNumber = Get-AssignedPodSubnetworkNumber -NodeName $NodeName
    $clusterCIDRWorker = $clusterCIDRWorkerTemplate.Replace('X', $assignedPodSubnetworkNumber)

    # routes for Linux pods
    Write-Log "Remove obsolete route to $clusterCIDRWorker"
    route delete $clusterCIDRWorker >$null 2>&1
    
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

Export-ModuleMember -Function Add-LinuxWorkerNodeOnNewVM, 
Start-LinuxWorkerNodeOnNewVM, 
Stop-LinuxWorkerNodeOnNewVM, 
Remove-LinuxWorkerNodeOnNewVM