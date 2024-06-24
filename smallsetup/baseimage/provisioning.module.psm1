# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

&"$PSScriptRoot\..\common\GlobalVariables.ps1"
# dot source common functions into scope
. "$PSScriptRoot\..\common\GlobalFunctions.ps1"

$validationModule = "$global:KubernetesPath\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
$baseImageModule = "$PSScriptRoot\BaseImage.module.psm1"
$linuxNodeModule = "$global:KubernetesPath\smallsetup\linuxnode\linuxnode.module.psm1"
$linuxNodeDebianModule = "$global:KubernetesPath\smallsetup\linuxnode\debian\linuxnode.debian.module.psm1"

Import-Module $validationModule, $baseImageModule, $linuxNodeModule, $linuxNodeDebianModule

$downloadsDirectory = $global:DownloadsDirectory
$provisioningTargetDirectory = $global:ProvisioningTargetDirectory

$KubemasterVmProvisioningVmName = 'KUBEMASTER_IN_PROVISIONING'
$RawBaseImageInProvisioningForKubemasterImageName = 'Debian-11-Base-In-Provisioning-For-Kubemaster.vhdx'
$VmProvisioningNatName = 'KubemasterVmProvisioningNat'
$VmProvisioningSwitchName = 'KubemasterVmProvisioningSwitch'

$KubeworkerVmProvisioningVmName = 'KUBEWORKER_IN_PROVISIONING'
$RawBaseImageInProvisioningForKubeworkerImageName = 'Debian-11-Base-In-Provisioning-For-Kubeworker.vhdx'
$KubeworkerVmProvisioningNatName = 'KubeworkerVmProvisioningNat'
$KubeworkerVmProvisioningSwitchName = 'KubeworkerVmProvisioningSwitch'

$kubemasterRootfsName = $global:KubemasterRootfsName

class VmParameters {
    [string]$VmName
    [long]  $MemoryStartupBytes
    [long]  $ProcessorCount
    [uint64]$DiskSize
    [string]$IsoFileName
    [string]$InProvisioningVhdxFileName
    [string]$ProvisionedVhdxFileName
}

class GuestOsParameters {
    [string]$UserName
    [string]$UserPwd
    [string]$NetworkInterfaceName
    [string]$Hostname
}

class NetworkParameters {
    [string]$HostIpAddress
    [string]$GuestIpAddress
    [string]$NatName
    [string]$NatIpAddress
    [string]$SwitchName
    [string]$HostNetworkPrefixLength
}

function New-VmBaseImageProvisioning {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern '.*\.vhdx$' })]
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the provisioned base image.')]
        [string] $OutputPath = $(throw 'Argument missing: OutputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'Keep artifacts used on provisioning')]
        [bool] $KeepArtifactsUsedOnProvisioning = $false
    )

    Assert-Path -Path (Split-Path $OutputPath) -PathType 'Container' -ShallExist $true | Out-Null

    if (Test-Path $OutputPath) {
        Remove-Item -Path $OutputPath -Force
        Write-Log "Deleted already existing provisioned image '$OutputPath'"
    }
    else {
        Write-Log "Provisioned image '$OutputPath' does not exist. Nothing to delete."
    }

    [VmParameters]$vmParameters = [VmParameters]::new() 
    $vmParameters.DiskSize = $VMDiskSize
    $vmParameters.InProvisioningVhdxFileName = $RawBaseImageInProvisioningForKubemasterImageName
    $vmParameters.IsoFileName = 'cloud-init-kubemaster-provisioning.iso'
    $vmParameters.MemoryStartupBytes = $VMMemoryStartupBytes
    $vmParameters.ProcessorCount = $VMProcessorCount
    $vmParameters.ProvisionedVhdxFileName = 'Debian-11-Base-Provisioned-For-Kubemaster.vhdx'
    $vmParameters.VmName = $KubemasterVmProvisioningVmName

    [GuestOsParameters]$guestOsParameters = [GuestOsParameters]::new() 
    $guestOsParameters.Hostname = $global:ControlPlaneNodeHostname
    $guestOsParameters.NetworkInterfaceName = $global:ControlPlaneNodeNetworkInterfaceName
    $guestOsParameters.UserName = $global:RemoteUserName_Master
    $guestOsParameters.UserPwd = $global:VMPwd

    $mainNetworkCIDR = $global:IP_CIDR
    $VmProvisioningIpAddressNat = $mainNetworkCIDR.Substring(0, $mainNetworkCIDR.IndexOf('/'))
    $VmProvisioningPrefixLength = $mainNetworkCIDR.Substring($mainNetworkCIDR.IndexOf('/') + 1)

    [NetworkParameters]$networkParameters = [NetworkParameters]::new() 
    $networkParameters.GuestIpAddress = $global:IP_Master
    $networkParameters.HostIpAddress = $global:IP_NextHop
    $networkParameters.HostNetworkPrefixLength = $VmProvisioningPrefixLength
    $networkParameters.NatIpAddress = $VmProvisioningIpAddressNat
    $networkParameters.NatName = $VmProvisioningNatName
    $networkParameters.SwitchName = $VmProvisioningSwitchName

    $createControlPlaneNode = {

        $addToControlPlaneNode = {
            Install-Tools -IpAddress $global:IP_Master -UserName $guestOsParameters.UserName -UserPwd $guestOsParameters.UserPwd -Proxy $Proxy
            Add-SupportForWSL -IpAddress $global:IP_Master -UserName $guestOsParameters.UserName -UserPwd $guestOsParameters.UserPwd -NetworkInterfaceName $guestOsParameters.NetworkInterfaceName -GatewayIP $networkParameters.HostIpAddress
        }

        $masterNodeParameters = @{
            IpAddress                     = $networkParameters.GuestIpAddress
            UserName                      = $guestOsParameters.UserName
            UserPwd                       = $guestOsParameters.UserPwd
            Proxy                         = $Proxy
            K8sVersion                    = $global:KubernetesVersion
            ClusterCIDR                   = $global:ClusterCIDR 
            ClusterCIDR_Services          = $global:ClusterCIDR_Services
            KubeDnsServiceIP              = $global:KubeDnsServiceIP
            GatewayIP                     = $networkParameters.HostIpAddress
            NetworkInterfaceName          = $guestOsParameters.NetworkInterfaceName
            NetworkInterfaceCni0IP_Master = $global:NetworkInterfaceCni0IP_Master
            Hook                          = $addToControlPlaneNode
        }
    
        New-MasterNode @masterNodeParameters
    }

    $createRootfsForWSL = {
        $vmName = $vmParameters.VmName

        Write-Log "Start the VM $vmName again for rootfs creation"
        Start-VirtualMachineAndWaitForHeartbeat -Name $vmName

        # for the next steps we need ssh access, so let's wait for ssh
        Write-Log 'Wait until a remote connection to the VM is possible'
        Wait-ForSSHConnectionToLinuxVMViaPwd

        $provisionedVhdxPath = "$provisioningTargetDirectory\$($vmParameters.ProvisionedVhdxFileName)"

        Write-Log 'Create KubeMaster-Base.rootfs.tar.gz for use in WSL2'
        New-RootfsForWSL -IpAddress $global:IP_Master -UserName $guestOsParameters.UserName -UserPwd $guestOsParameters.UserPwd -VhdxFile $provisionedVhdxPath -RootfsName $kubemasterRootfsName -TargetPath $global:BinDirectory

        Write-Log "Stop the VM $vmName"
        Stop-VirtualMachineForBaseImageProvisioning -Name $vmName
    }

    $baseImageCreationParameters = @{
        VmParameters                    = $vmParameters
        GuestOsParameters               = $guestOsParameters
        NetworkParameters               = $networkParameters
        Proxy                           = $Proxy
        NodeRoleAssignmentHook          = $createControlPlaneNode
        AfterProvisioningFinishedHook   = $createRootfsForWSL
        OutputPath                      = $OutputPath
        KeepArtifactsUsedOnProvisioning = $KeepArtifactsUsedOnProvisioning
    }

    New-ProvisionedBaseImage @baseImageCreationParameters
}

function New-KubeworkerBaseImage {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
        [long]$VMMemoryStartupBytes,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
        [long]$VMProcessorCount,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
        [uint64]$VMDiskSize,
        [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
        [string]$Proxy = '',
        [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern '.*\.vhdx$' })]
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the provisioned base image.')]
        [string] $OutputPath = $(throw 'Argument missing: OutputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'Keep artifacts used on provisioning')]
        [bool] $KeepArtifactsUsedOnProvisioning = $false
    )

    Assert-Path -Path (Split-Path $OutputPath) -PathType 'Container' -ShallExist $true | Out-Null

    if (Test-Path $OutputPath) {
        Remove-Item -Path $OutputPath -Force
        Write-Log "Deleted already existing provisioned image '$OutputPath'"
    }
    else {
        Write-Log "Provisioned image '$OutputPath' does not exist. Nothing to delete."
    }

    [VmParameters]$vmParameters = [VmParameters]::new() 
    $vmParameters.DiskSize = $VMDiskSize
    $vmParameters.InProvisioningVhdxFileName = $RawBaseImageInProvisioningForKubeworkerImageName
    $vmParameters.IsoFileName = 'cloud-init-kubeworker-provisioning.iso'
    $vmParameters.MemoryStartupBytes = $VMMemoryStartupBytes
    $vmParameters.ProcessorCount = $VMProcessorCount
    $vmParameters.ProvisionedVhdxFileName = 'Debian-11-Base-Provisioned-For-Kubeworker.vhdx'
    $vmParameters.VmName = $KubeworkerVmProvisioningVmName

    [GuestOsParameters]$guestOsParameters = [GuestOsParameters]::new() 
    $guestOsParameters.Hostname = Get-HostnameForProvisioningWorkerNode
    $guestOsParameters.NetworkInterfaceName = 'eth0'
    $guestOsParameters.UserName = Get-DefaultUserNameWorkerNode
    $guestOsParameters.UserPwd = Get-DefaultUserPwdWorkerNode

    [NetworkParameters]$networkParameters = [NetworkParameters]::new() 
    $networkParameters.GuestIpAddress = Get-VmIpForProvisioningWorkerNode
    $networkParameters.HostIpAddress = Get-HostIpForProvisioningWorkerNode
    $networkParameters.HostNetworkPrefixLength = Get-NetworkPrefixLengthForProvisioningWorkerNode
    $networkParameters.NatIpAddress = Get-NatIpForProvisioningWorkerNode
    $networkParameters.NatName = $KubeworkerVmProvisioningNatName
    $networkParameters.SwitchName = $KubeworkerVmProvisioningSwitchName

    $createWorkerNode = {
        $addToWorkerNode = { }

        $workerNodeParameters = @{
            IpAddress   = $networkParameters.GuestIpAddress
            UserName    = $guestOsParameters.UserName
            UserPwd     = $guestOsParameters.UserPwd
            Proxy       = $Proxy
            K8sVersion  = $global:KubernetesVersion
            Hook        = $addToWorkerNode
        }

        New-WorkerNode @workerNodeParameters
    }
    
    $baseImageCreationParameters = @{
        VmParameters                    = $vmParameters
        GuestOsParameters               = $guestOsParameters
        NetworkParameters               = $networkParameters
        Proxy                           = $Proxy
        NodeRoleAssignmentHook          = $createWorkerNode
        AfterProvisioningFinishedHook   = { }
        OutputPath                      = $OutputPath
        KeepArtifactsUsedOnProvisioning = $KeepArtifactsUsedOnProvisioning
    }

    New-ProvisionedBaseImage @baseImageCreationParameters
}

function New-ProvisionedBaseImage {
    param (
        [VmParameters]$VmParameters = $(throw 'Argument missing: VmParameters'),
        [GuestOsParameters]$GuestOsParameters = $(throw 'Argument missing: GuestOsParameters'),
        [NetworkParameters]$NetworkParameters = $(throw 'Argument missing: NetworkParameters'),
        [string] $Proxy = $(throw 'Argument missing: Proxy'),
        [scriptblock] $NodeRoleAssignmentHook = $(throw 'Argument missing: NodeRoleAssignmentHook'),
        [scriptblock] $AfterProvisioningFinishedHook = $(throw 'Argument missing: AfterProvisioningFinishedHook'),
        [string] $OutputPath = $(throw 'Argument missing: OutputPath'),
        [bool] $KeepArtifactsUsedOnProvisioning = $(throw 'Argument missing: KeepArtifactsUsedOnProvisioning')
    )

    $vmIP = $NetworkParameters.GuestIpAddress
    $userName = $GuestOsParameters.UserName
    $userPwd = $GuestOsParameters.UserPwd

    Write-Log "Remove eventually existing key for IP $vmIP from 'known_hosts' file"
    Remove-SshKeyFromKnownHostsFile -IpAddress $vmIP

    $inProvisioningVhdxName = $VmParameters.InProvisioningVhdxFileName
    $provisionedVhdxName = $VmParameters.ProvisionedVhdxFileName
    $vmName = $VmParameters.VmName

    $IsoFileCreatorTool = 'cloudinitisobuilder.exe'

    $VirtualMachineParams = @{
        VmName               = $vmName
        VhdxName             = $inProvisioningVhdxName
        VMMemoryStartupBytes = $VmParameters.MemoryStartupBytes
        VMProcessorCount     = $VmParameters.ProcessorCount
        VMDiskSize           = $VmParameters.DiskSize
    }
    $NetworkParams = @{
        Proxy              = $Proxy
        SwitchName         = $NetworkParameters.SwitchName
        HostIpAddress      = $NetworkParameters.HostIpAddress
        HostIpPrefixLength = $NetworkParameters.HostNetworkPrefixLength
        NatName            = $NetworkParameters.NatName
        NatIpAddress       = $NetworkParameters.NatIpAddress
    }
    $IsoFileParams = @{
        IsoFileCreatorToolPath = "$global:BinDirectory\$IsoFileCreatorTool"
        IsoFileName            = $VmParameters.IsoFileName
        SourcePath             = "$PSScriptRoot\cloud-init-templates"
        Hostname               = $GuestOsParameters.Hostname
        NetworkInterfaceName   = $GuestOsParameters.NetworkInterfaceName
        IPAddressVM            = $vmIP
        IPAddressGateway       = $NetworkParameters.HostIpAddress
        UserName               = $userName
        UserPwd                = $userPwd
    }

    $WorkingDirectoriesParams = @{
        DownloadsDirectory    = $downloadsDirectory
        ProvisioningDirectory = $provisioningTargetDirectory
    }

    New-DebianCloudBasedVirtualMachine -VirtualMachineParams $VirtualMachineParams -NetworkParams $NetworkParams -IsoFileParams $IsoFileParams -WorkingDirectoriesParams $WorkingDirectoriesParams

    Write-Log "Start the VM $vmName"
    Start-VirtualMachineAndWaitForHeartbeat -Name $vmName

    $user = "$userName@$vmIP"
    # let's check if the connection to the remote computer is possible
    Write-Log "Checking if an SSH login into remote computer '$vmIP' with user '$user' is possible"
    Wait-ForSshPossible -RemoteUser "$user" -RemotePwd "$userPwd" -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'

    Write-Log 'Run role assignment hook'
    &$NodeRoleAssignmentHook
    Write-Log 'Role assignment finished'

    Write-Log "Stop the VM $vmName"
    Stop-VirtualMachineForBaseImageProvisioning -Name $vmName

    $inProvisioningVhdxPath = "$provisioningTargetDirectory\$inProvisioningVhdxName"
    $provisionedVhdxPath = "$provisioningTargetDirectory\$provisionedVhdxName"
    Copy-VhdxFile -SourceFilePath $inProvisioningVhdxPath -TargetPath $provisionedVhdxPath
    Write-Log "Provisioned image available as $provisionedVhdxPath"

    Write-Log 'Run WSL support creation hook'
    &$AfterProvisioningFinishedHook
    Write-Log 'WSL support creation finished'

    Write-Log 'Detach the image from Hyper-V'
    Remove-VirtualMachineForBaseImageProvisioning -VhdxFilePath $inProvisioningVhdxPath -VmName $vmName
    Write-Log 'Remove the network for provisioning the image'
    Remove-NetworkForProvisioning -NatName $NetworkParameters.NatName -SwitchName $NetworkParameters.SwitchName

    Copy-Item -Path $provisionedVhdxPath -Destination $OutputPath
    Write-Log "Provisioned image '$provisionedVhdxPath' available as '$OutputPath'"

    if (!$KeepArtifactsUsedOnProvisioning) {
        $provisioningFolder = $WorkingDirectoriesParams.ProvisioningDirectory
        $downloadsFolder = $WorkingDirectoriesParams.DownloadsDirectory
        Write-Log "Flag 'KeepArtifactsUsedOnProvisioning' == $KeepArtifactsUsedOnProvisioning -> Delete artifacts used on provisioning: "
        Write-Log "  - deleting folder '$provisioningFolder'"
        Remove-Item -Path $provisioningFolder -Recurse -Force
        Write-Log "  - deleting folder '$downloadsFolder'"
        Remove-Item -Path $downloadsFolder -Recurse -Force
    }
}
function Get-VmIpForProvisioningWorkerNode {
    return '172.18.12.22'
}

function Get-HostIpForProvisioningWorkerNode {
    return '172.18.12.1'
}

function Get-NatIpForProvisioningWorkerNode {
    return '172.18.12.0'
}

function Get-NetworkPrefixLengthForProvisioningWorkerNode {
    return '24'
}

function Get-DefaultUserNameWorkerNode {
    return $global:RemoteUserName_Master
}

function Get-DefaultUserPwdWorkerNode {
    return $global:VMPwd
}

function Get-HostnameForProvisioningWorkerNode {
    return 'kubeworkerbase'
}

function Clear-ProvisioningArtifacts {
    $kubemasterVmName = $KubemasterVmProvisioningVmName
    $kubeworkerVmName = $KubeworkerVmProvisioningVmName

    $stopVm = { 
        param(
            [string]$VmName = $(throw 'Argument missing: VmName')
        ) 

        $vm = Get-VM | Where-Object Name -Like $VmName
        Write-Log "Ensure VM $VmName is stopped"
        if ($null -ne $vm) {
            Stop-VirtualMachineForBaseImageProvisioning -Name $VmName
        }
    }
    &$stopVm -VmName $kubemasterVmName
    &$stopVm -VmName $kubeworkerVmName

    $removeVm = {
        param(
            [string]$VmName = $(throw 'Argument missing: VmName'),
            [string]$NatName = $(throw 'Argument missing: NatName'),
            [string]$SwitchName = $(throw 'Argument missing: SwitchName'),
            [string]$VhdxFilePath = $(throw 'Argument missing: VhdxFilePath')
        ) 

        Write-Log "Detach the image '$VhdxFilePath' from the VM '$VmName'" -Console
        Remove-VirtualMachineForBaseImageProvisioning -VmName $VmName -VhdxFilePath $VhdxFilePath
        Write-Log "Remove the switch '$SwitchName' and nat '$NatName' for provisioning the image" -Console
        Remove-NetworkForProvisioning -NatName $NatName -SwitchName $SwitchName
    }

    $kubemasterInProvisioningImagePath = "$provisioningTargetDirectory\$RawBaseImageInProvisioningForKubemasterImageName"
    $kubeworkerInProvisioningImagePath = "$provisioningTargetDirectory\$RawBaseImageInProvisioningForKubeworkerImageName"

    &$removeVm -VmName $kubemasterVmName -NatName $VmProvisioningNatName -SwitchName $VmProvisioningSwitchName -VhdxFilePath $kubemasterInProvisioningImagePath 
    &$removeVm -VmName $kubeworkerVmName -NatName $KubeworkerVmProvisioningNatName -SwitchName $KubeworkerVmProvisioningSwitchName -VhdxFilePath $kubeworkerInProvisioningImagePath 

    if (Test-Path $provisioningTargetDirectory) {
        Write-Log "Deleting folder '$provisioningTargetDirectory'"
        Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
    }

    if (Test-Path $downloadsDirectory) {
        Write-Log "Deleting folder '$downloadsDirectory'"
        Remove-Item -Path $downloadsDirectory -Recurse -Force
    }
}

Export-ModuleMember New-VmBaseImageProvisioning, New-KubeworkerBaseImage, Clear-ProvisioningArtifacts
