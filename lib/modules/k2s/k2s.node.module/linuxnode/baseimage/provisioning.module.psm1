# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$validationModule = "$PSScriptRoot\..\..\..\k2s.infra.module\validation\validation.module.psm1"
$baseImageModule = "$PSScriptRoot\baseimage.module.psm1"
$commonSetupModule = "$PSScriptRoot\..\distros\common-setup.module.psm1"
$linuxNodeDebianModule = "$PSScriptRoot\..\distros\debian\debian.module.psm1"

Import-Module $validationModule, $baseImageModule, $commonSetupModule, $linuxNodeDebianModule

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"
Import-Module $logModule, $configModule, $pathModule, $vmModule

$kubeBinPath = Get-KubeBinPath

$downloadsDirectory = "$kubeBinPath\downloads"
$provisioningTargetDirectory = "$kubeBinPath\provisioning"
$crioVersion = '1.25.2'

$VmProvisioningVmName = 'KUBEMASTER_IN_PROVISIONING'
$RawBaseImageInProvisioningForKubemasterImageName = 'Debian-11-Base-In-Provisioning-For-Kubemaster.vhdx'
$VmProvisioningNatName = 'VmProvisioningNat'
$VmProvisioningSwitchName = 'VmProvisioningSwitch'

$kubemasterRootfsName = Get-ControlPlaneVMRootfsPath

$setupConfigRoot = Get-RootConfigk2s

function New-VmBaseImageProvisioning {
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
        [ValidateScript({ Assert-Pattern -Path $_ -Pattern '.*\.vhdx$' })]
        [parameter(Mandatory = $false, HelpMessage = 'The path to save the provisioned base image.')]
        [string] $OutputPath = $(throw 'Argument missing: OutputPath'),
        [parameter(Mandatory = $false, HelpMessage = 'Keep artifacts used on provisioning')]
        [switch] $KeepArtifactsUsedOnProvisioning = $false
    )

    Assert-Path -Path (Split-Path $OutputPath) -PathType 'Container' -ShallExist $true | Out-Null

    if (Test-Path $OutputPath) {
        Remove-Item -Path $OutputPath -Force
        Write-Log "Deleted already existing provisioned image '$OutputPath'"
    }
    else {
        Write-Log "Provisioned image '$OutputPath' does not exist. Nothing to delete."
    }

    $computerIP = Get-ConfiguredIPControlPlane
    $userName = Get-DefaultUserNameControlPlane
    $userPwd = Get-DefaultUserPwdControlPlane

    Write-Log "Remove eventually existing key for IP $computerIP from 'known_hosts' file"
    Remove-SshKeyFromKnownHostsFile -IpAddress $computerIP

    $RawBaseImageProvisionedForKubemasterImageName = 'Debian-11-Base-Provisioned-For-Kubemaster.vhdx'
    $inProvisioningVhdxName = $RawBaseImageInProvisioningForKubemasterImageName
    $provisionedVhdxName = $RawBaseImageProvisionedForKubemasterImageName
    $vmName = $VmProvisioningVmName

    $VmProvisioningIpAddressHost = Get-ConfiguredKubeSwitchIP
    $ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
    $VmProvisioningIpAddressNat = $ipControlPlaneCIDR.Substring(0, $ipControlPlaneCIDR.IndexOf('/'))
    $VmProvisioningPrefixLength = $ipControlPlaneCIDR.Substring($ipControlPlaneCIDR.IndexOf('/') + 1)
    $VmProvisioningIpAddressVirtualMachine = $computerIP
    $IsoFileCreatorTool = 'cloudinitisobuilder.exe'
    $CloudInitProvisioningFileName = 'cloud-init-provisioning.iso'
    $interfaceName = Get-ControlPlaneNodeNetworkInterfaceName

    $VirtualMachineParams = @{
        VmName               = $vmName
        VhdxName             = $inProvisioningVhdxName
        VMMemoryStartupBytes = $VMMemoryStartupBytes
        VMProcessorCount     = $VMProcessorCount
        VMDiskSize           = $VMDiskSize
    }
    $NetworkParams = @{
        Proxy              = $Proxy
        SwitchName         = $VmProvisioningSwitchName
        HostIpAddress      = $VmProvisioningIpAddressHost
        HostIpPrefixLength = $VmProvisioningPrefixLength
        NatName            = $VmProvisioningNatName
        NatIpAddress       = $VmProvisioningIpAddressNat
    }
    $IsoFileParams = @{
        IsoFileCreatorToolPath = "$kubeBinPath\$IsoFileCreatorTool"
        IsoFileName            = $CloudInitProvisioningFileName
        SourcePath             = "$PSScriptRoot\cloud-init-templates"
        Hostname               = Get-ConfigControlPlaneNodeHostname
        NetworkInterfaceName   = ($interfaceName)
        IPAddressVM            = ($VmProvisioningIpAddressVirtualMachine)
        IPAddressGateway       = ($VmProvisioningIpAddressHost)
        UserName               = ($userName)
        UserPwd                = ($userPwd)
    }

    $WorkingDirectoriesParams = @{
        DownloadsDirectory    = $downloadsDirectory
        ProvisioningDirectory = $provisioningTargetDirectory
    }

    New-DebianCloudBasedVirtualMachine -VirtualMachineParams $VirtualMachineParams -NetworkParams $NetworkParams -IsoFileParams $IsoFileParams -WorkingDirectoriesParams $WorkingDirectoriesParams

    Write-Log "Start the VM $vmName"
    Start-VirtualMachineAndWaitForHeartbeat -Name $vmName

    $user = "$UserName@$computerIP"
    # let's check if the connection to the remote computer is possible
    Write-Log "Checking if an SSH login into remote computer '$computerIP' with user '$user' is possible"
    Wait-ForSshPossible -User "$user" -UserPwd "$userPwd" -SshTestCommand 'which ls' -ExpectedSshTestCommandResult '/usr/bin/ls'

    $addToMasterNode = {
        Install-Tools -IpAddress $computerIP -UserName $userName -UserPwd $userPwd -Proxy $Proxy
        Add-SupportForWSL -IpAddress $computerIP -UserName $userName -UserPwd $userPwd -NetworkInterfaceName $interfaceName -GatewayIP $VmProvisioningIpAddressHost
    }

    $masterNodeParameters = @{
        IpAddress                     = $computerIP
        UserName                      = $userName
        UserPwd                       = $userPwd
        Proxy                         = $Proxy
        K8sVersion                    = Get-ConfigInstalledKubernetesVersion
        CrioVersion                   = $crioVersion
        ClusterCIDR                   = Get-ConfiguredClusterCIDR
        ClusterCIDR_Services          = Get-ConfiguredClusterCIDRServices
        KubeDnsServiceIP              = $setupConfigRoot.psobject.properties['kubeDnsServiceIP'].value
        GatewayIP                     = $VmProvisioningIpAddressHost
        NetworkInterfaceName          = $interfaceName
        NetworkInterfaceCni0IP_Master = $setupConfigRoot.psobject.properties['masterNetworkInterfaceCni0IP'].value
        Hook                          = $addToMasterNode
    }

    New-MasterNode @masterNodeParameters

    Write-Log "Stop the VM $vmName"
    Stop-VirtualMachineForBaseImageProvisioning -Name $vmName

    $inProvisioningVhdxPath = "$provisioningTargetDirectory\$inProvisioningVhdxName"
    $provisionedVhdxPath = "$provisioningTargetDirectory\$provisionedVhdxName"
    Copy-VhdxFile -SourceFilePath $inProvisioningVhdxPath -TargetPath $provisionedVhdxPath
    Write-Log "Provisioned image available as $provisionedVhdxPath"

    Write-Log "Start the VM $vmName again for rootfs creation"
    Start-VirtualMachineAndWaitForHeartbeat -Name $vmName

    # for the next steps we need ssh access, so let's wait for ssh
    Write-Log 'Wait until a remote connection to the VM is possible'
    Wait-ForSSHConnectionToLinuxVMViaPwd

    Write-Log 'Create KubeMaster-Base.rootfs.tar.gz for use in WSL2'
    New-RootfsForWSL -IpAddress $computerIP -UserName $userName -UserPwd $userPwd -VhdxFile $provisionedVhdxPath -RootfsName $kubemasterRootfsName -TargetPath $kubeBinPath

    Write-Log "Stop the VM $vmName"
    Stop-VirtualMachineForBaseImageProvisioning -Name $vmName

    Write-Log 'Detach the image from Hyper-V'
    Remove-VirtualMachineForBaseImageProvisioning -VhdxFilePath $inProvisioningVhdxPath -VmName $vmName
    Write-Log 'Remove the network for provisioning the image'
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
}

#Cleaner.ps1
function Clear-ProvisioningArtifacts {
    $vmName = $VmProvisioningVmName

    $vm = Get-VM | Where-Object Name -Like $vmName

    Write-Log "Ensure VM $vmName is stopped" -Console
    if ($null -ne $vm) {
        Stop-VirtualMachineForBaseImageProvisioning -Name $vmName
    }

    $inProvisioningImagePath = "$provisioningTargetDirectory\$RawBaseImageInProvisioningForKubemasterImageName"

    Write-Log 'Detach the image from Hyper-V' -Console
    Remove-VirtualMachineForBaseImageProvisioning -VmName $vmName -VhdxFilePath $inProvisioningImagePath
    Write-Log 'Remove the network for provisioning the image' -Console
    Remove-NetworkForProvisioning -NatName $VmProvisioningNatName -SwitchName $VmProvisioningSwitchName

    if (Test-Path $provisioningTargetDirectory) {
        Write-Log "Deleting folder '$provisioningTargetDirectory'" -Console
        Remove-Item -Path $provisioningTargetDirectory -Recurse -Force
    }

    if (Test-Path $downloadsDirectory) {
        Write-Log "Deleting folder '$downloadsDirectory'" -Console
        Remove-Item -Path $downloadsDirectory -Recurse -Force
    }
}

Export-ModuleMember New-VmBaseImageProvisioning, Clear-ProvisioningArtifacts
