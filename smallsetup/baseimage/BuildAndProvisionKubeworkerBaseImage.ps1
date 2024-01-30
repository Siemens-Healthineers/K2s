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
    # [ValidateScript({ Assert-LegalCharactersInPath -Path $_ })]
    # [ValidateScript({ Assert-Pattern -Path $_ -Pattern ".*\.vhdx$" })]
    [parameter(Mandatory = $false, HelpMessage = 'The path to save the provisioned base image.')]
    [string] $OutputPath = $(throw "Argument missing: OutputPath"),
    [parameter(Mandatory = $false, HelpMessage = 'Keep artifacts used on provisioning')]
    [switch] $KeepArtifactsUsedOnProvisioning = $false
    )

&"$PSScriptRoot\..\common\GlobalVariables.ps1"
# dot source common functions into script scope
. "$PSScriptRoot\..\common\GlobalFunctions.ps1"

Initialize-Logging -ShowLogs

$validationModule = "$global:KubernetesPath\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
$baseImageModule = "$PSScriptRoot\BaseImage.module.psm1"
$linuxNodeModule = "$global:KubernetesPath\smallsetup\linuxnode\linuxnode.module.psm1"
$linuxNodeDebianModule = "$global:KubernetesPath\smallsetup\linuxnode\debian\linuxnode.debian.module.psm1"

Import-Module $validationModule,$baseImageModule,$linuxNodeModule,$linuxNodeDebianModule

. "$PSScriptRoot\CommonVariables.ps1"

Assert-Path -Path (Split-Path $OutputPath) -PathType "Container" -ShallExist $true | Out-Null

if (Test-Path $OutputPath) {
	Remove-Item -Path $OutputPath -Force
    Write-Log "Deleted already existing provisioned image '$OutputPath'"
} else {
    Write-Log "Provisioned image '$OutputPath' does not exist. Nothing to delete."
}

$computerIP = "172.18.12.22" #$global:IP_Master
$userName = $global:RemoteUserName_Master
$userPwd = $global:VMPwd

Write-Log "Remove eventually existing key for IP $computerIP from 'known_hosts' file"
Remove-SshKeyFromKnownHostsFile -IpAddress $computerIP

$inProvisioningVhdxName = $RawBaseImageInProvisioningForKubeworkerImageName2
$provisionedVhdxName = "Debian-11-Base-Provisioned-For-Kubeworker.vhdx"
$vmName = $VmProvisioningVmName2

$VmProvisioningIpAddressHost = "172.18.12.1" #$global:IP_NextHop
$VmProvisioningIpAddressNat = "172.18.12.0" #$global:IP_CIDR.Substring(0, $global:IP_CIDR.IndexOf("/"))
$VmProvisioningPrefixLength = "24" #$global:IP_CIDR.Substring($global:IP_CIDR.IndexOf("/") + 1)
$VmProvisioningIpAddressVirtualMachine = "172.18.12.22" #$global:IP_Master
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
    SwitchName=$VmProvisioningSwitchName2
    HostIpAddress=$VmProvisioningIpAddressHost
    HostIpPrefixLength=$VmProvisioningPrefixLength
    NatName=$VmProvisioningNatName2
    NatIpAddress=$VmProvisioningIpAddressNat
}
$IsoFileParams = @{
    IsoFileCreatorToolPath="$global:BinPath\$IsoFileCreatorTool"
    IsoFileName=$CloudInitProvisioningFileName
    SourcePath="$PSScriptRoot\cloud-init-templates"
    Hostname="kubeworkerbase" #$global:ControlPlaneNodeHostname
    NetworkInterfaceName='eth0' #($global:ControlPlaneNodeNetworkInterfaceName)
    IPAddressVM=($VmProvisioningIpAddressVirtualMachine)
    IPAddressGateway=($VmProvisioningIpAddressHost)
    UserName=$userName #($global:RemoteUserName_Master)
    UserPwd=$userPwd #($global:VMPwd)
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
    # Install-Tools -IpAddress $computerIP -UserName $userName -UserPwd $userPwd -Proxy $Proxy
    # Add-SupportForWSL -IpAddress $computerIP -UserName $userName -UserPwd $userPwd -NetworkInterfaceName $global:ControlPlaneNodeNetworkInterfaceName -GatewayIP $global:IP_NextHop
}

$workerNodeParameters = @{
    IpAddress = $computerIP
    UserName = $userName
    UserPwd = $userPwd
    Proxy=$Proxy
    K8sVersion = $global:KubernetesVersion 
    CrioVersion = $global:CrioVersion
    Hook = $addToMasterNode
}

New-WorkerNode @workerNodeParameters

Write-Log "Stop the VM $vmName"
Stop-VirtualMachineForBaseImageProvisioning -Name $vmName

$inProvisioningVhdxPath = "$global:ProvisioningTargetDirectory\$inProvisioningVhdxName"
$provisionedVhdxPath = "$global:ProvisioningTargetDirectory\$provisionedVhdxName"
Copy-VhdxFile -SourceFilePath $inProvisioningVhdxPath -TargetPath $provisionedVhdxPath
Write-Log "Provisioned image available as $provisionedVhdxPath"

Write-Log "Detach the image from Hyper-V"
Remove-VirtualMachineForBaseImageProvisioning -VhdxFilePath $inProvisioningVhdxPath -VmName $vmName
Write-Log "Remove the network for provisioning the image"
Remove-NetworkForProvisioning -NatName $VmProvisioningNatName2 -SwitchName $VmProvisioningSwitchName2

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
