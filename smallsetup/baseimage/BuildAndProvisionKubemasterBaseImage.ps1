# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

param (
    [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of VM')]
    [long]$VMMemoryStartupBytes = 8GB,
    [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for VM')]
    [long]$VMProcessorCount = 4,
    [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of VM')]
    [uint64]$VMDiskSize = 50GB,
    [parameter(Mandatory = $false, HelpMessage = 'The HTTP proxy if available.')]
    [string]$Proxy = '',
    [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
    [ValidateScript({ Assert-Pattern -Path $_ -Pattern ".*\.vhdx$" })]
    [parameter(Mandatory = $false, HelpMessage = 'The path to save the provisioned base image.')]
    [string] $OutputPath = $(throw "Argument missing: OutputPath"),
    [parameter(Mandatory = $false, HelpMessage = 'Keep artifacts used on provisioning')]
    [switch] $KeepArtifactsUsedOnProvisioning = $false
    )

    Assert-Path -Path (Split-Path $OutputPath) -PathType "Container" -ShallExist $true | Out-Null

&"$PSScriptRoot\..\common\GlobalVariables.ps1"
# dot source common functions into script scope
. "$PSScriptRoot\..\common\GlobalFunctions.ps1"

$validationModule = "$global:KubernetesPath\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
$baseImageModule = "$PSScriptRoot\BaseImage.module.psm1"
$linuxNodeModule = "$global:KubernetesPath\smallsetup\linuxnode\linuxnode.module.psm1"
$linuxNodeDebianModule = "$global:KubernetesPath\smallsetup\linuxnode\debian\linuxnode.debian.module.psm1"

Import-Module $validationModule,$baseImageModule,$linuxNodeModule,$linuxNodeDebianModule

. "$PSScriptRoot\CommonVariables.ps1"

if (Test-Path $OutputPath) {
	Remove-Item -Path $OutputPath -Force
    Write-Log "Deleted already existing provisioned image '$OutputPath'"
} else {
    Write-Log "Provisioned image '$OutputPath' does not exist. Nothing to delete."
}

$computerIP = $global:IP_Master
$userName = $global:RemoteUserName_Master
$userPwd = $global:VMPwd

Write-Log "Remove eventually existing key for IP $computerIP from 'known_hosts' file"
Remove-SshKeyFromKnownHostsFile -IpAddress $computerIP

$RawBaseImageProvisionedForKubemasterImageName = "Debian-11-Base-Provisioned-For-Kubemaster.vhdx"
$inProvisioningVhdxName = $RawBaseImageInProvisioningForKubemasterImageName
$provisionedVhdxName = $RawBaseImageProvisionedForKubemasterImageName
$vmName = $VmProvisioningVmName

$VmProvisioningIpAddressHost = $global:IP_NextHop
$VmProvisioningIpAddressNat = $global:IP_CIDR.Substring(0, $global:IP_CIDR.IndexOf("/"))
$VmProvisioningPrefixLength = $global:IP_CIDR.Substring($global:IP_CIDR.IndexOf("/") + 1)
$VmProvisioningIpAddressVirtualMachine = $global:IP_Master
$IsoFileCreatorTool = "cloudinitisobuilder.exe"
$CloudInitProvisioningFileName = "cloud-init-provisioning.iso"

$VirtualMachineParams = @{
    VmName= $vmName
    VhdxName=$inProvisioningVhdxName
    VMMemoryStartupBytes=$VMMemoryStartupBytes
    VMProcessorCount=$VMProcessorCount
    VMDiskSize=$VMDiskSize
}
$NetworkParams = @{
    Proxy=$Proxy
    SwitchName=$VmProvisioningSwitchName
    HostIpAddress=$VmProvisioningIpAddressHost
    HostIpPrefixLength=$VmProvisioningPrefixLength
    NatName=$VmProvisioningNatName
    NatIpAddress=$VmProvisioningIpAddressNat
}
$IsoFileParams = @{
    IsoFileCreatorToolPath="$global:BinPath\$IsoFileCreatorTool"
    IsoFileName=$CloudInitProvisioningFileName
    SourcePath="$PSScriptRoot\cloud-init-templates"
    Hostname=$global:ControlPlaneNodeHostname
    NetworkInterfaceName=($global:ControlPlaneNodeNetworkInterfaceName)
    IPAddressVM=($VmProvisioningIpAddressVirtualMachine)
    IPAddressGateway=($VmProvisioningIpAddressHost)
    UserName=($global:RemoteUserName_Master)
    UserPwd=($global:VMPwd)
}
$WorkingDirectoriesParams = @{
    DownloadsDirectory=$global:DownloadsDirectory
    ProvisioningDirectory=$global:ProvisioningTargetDirectory
}

New-DebianCloudBasedVirtualMachine -VirtualMachineParams $VirtualMachineParams -NetworkParams $NetworkParams -IsoFileParams $IsoFileParams -WorkingDirectoriesParams $WorkingDirectoriesParams

Write-Log "Start the VM $vmName"
Start-VirtualMachineAndWaitForHeartbeat -Name $vmName

$user = "$UserName@$computerIP"
# let's check if the connection to the remote computer is possible
Write-Log "Checking if an SSH login into remote computer '$computerIP' with user '$user' is possible"
Wait-ForSshPossible -RemoteUser "$user" -RemotePwd "$userPwd" -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'

$addToMasterNode = {
    Install-Tools -IpAddress $computerIP -UserName $userName -UserPwd $userPwd -Proxy $Proxy
    Add-SupportForWSL -IpAddress $computerIP -UserName $userName -UserPwd $userPwd -NetworkInterfaceName $global:ControlPlaneNodeNetworkInterfaceName -GatewayIP $global:IP_NextHop
}

$masterNodeParameters = @{
    IpAddress = $computerIP
    UserName = $userName
    UserPwd = $userPwd
    Proxy=$Proxy
    K8sVersion = $global:KubernetesVersion 
    CrioVersion = $global:CrioVersion
    ClusterCIDR=$global:ClusterCIDR 
    ClusterCIDR_Services=$global:ClusterCIDR_Services
    KubeDnsServiceIP=$global:KubeDnsServiceIP
    GatewayIP=$global:IP_NextHop
    NetworkInterfaceName=$global:ControlPlaneNodeNetworkInterfaceName
    NetworkInterfaceCni0IP_Master=$global:NetworkInterfaceCni0IP_Master
    Hook = $addToMasterNode
}

New-MasterNode @masterNodeParameters

Write-Log "Stop the VM $vmName"
Stop-VirtualMachineForBaseImageProvisioning -Name $vmName

$inProvisioningVhdxPath = "$global:ProvisioningTargetDirectory\$inProvisioningVhdxName"
$provisionedVhdxPath = "$global:ProvisioningTargetDirectory\$provisionedVhdxName"
Copy-VhdxFile -SourceFilePath $inProvisioningVhdxPath -TargetPath $provisionedVhdxPath
Write-Log "Provisioned image available as $provisionedVhdxPath"

Write-Log "Start the VM $vmName again for rootfs creation"
Start-VirtualMachineAndWaitForHeartbeat -Name $vmName

# for the next steps we need ssh access, so let's wait for ssh
Write-Log "Wait until a remote connection to the VM is possible"
Wait-ForSSHConnectionToLinuxVMViaPwd

Write-Log "Create KubeMaster-Base.rootfs.tar.gz for use in WSL2"
New-RootfsForWSL -IpAddress $global:IP_Master -UserName $global:RemoteUserName_Master -UserPwd $global:VMPwd -VhdxFile $provisionedVhdxPath -RootfsName $global:KubemasterRootfsName -TargetPath $global:BinDirectory

Write-Log "Stop the VM $vmName"
Stop-VirtualMachineForBaseImageProvisioning -Name $vmName

Write-Log "Detach the image from Hyper-V"
Remove-VirtualMachineForBaseImageProvisioning -VhdxFilePath $inProvisioningVhdxPath -VmName $vmName
Write-Log "Remove the network for provisioning the image"
Remove-NetworkForProvisioning -NatName $VmProvisioningNatName -SwitchName $VmProvisioningSwitchName

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
