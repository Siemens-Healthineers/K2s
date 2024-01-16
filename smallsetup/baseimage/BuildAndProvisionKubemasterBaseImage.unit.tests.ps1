# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    . "$PSScriptRoot\..\common\GlobalFunctions.ps1"

    $validationModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
    $validationModuleName = (Import-Module $validationModule -PassThru -Force).Name

    $baseImageModule = "$PSScriptRoot\BaseImage.module.psm1"
    $baseImageModuleName = (Import-Module $baseImageModule -PassThru -Force).Name

    $linuxNodeModule = "$PSScriptRoot\..\linuxnode\linuxnode.module.psm1"
    $linuxNodeModuleName = (Import-Module $linuxNodeModule -PassThru -Force).Name

    $linuxNodeDebianModule = "$PSScriptRoot\..\linuxnode\debian\linuxnode.debian.module.psm1"
    $linuxNodeDebianModuleName = (Import-Module $linuxNodeDebianModule -PassThru -Force).Name
}

Describe 'BuildAndProvisioningKubemasterBaseImage.ps1' -Tag 'unit', 'baseimage' {
    BeforeAll {
        $scriptFile = "$PSScriptRoot\BuildAndProvisionKubemasterBaseImage.ps1"
    }
    Context 'script parameters' {
        BeforeEach {
            $targetPath = "myFolder\myTargetFile.vhdx"
            $parentFolder = "myFolder"
            Mock Assert-LegalCharactersInPath { return $true }
            Mock Assert-Pattern { return $true } 
            Mock Assert-Path { 'asserted path' }
            Mock Split-Path { $parentFolder }
        }
        Context 'OutputPath parameter' {
            It 'is mandatory' {
                { &$scriptFile } | Get-ExceptionMessage | Should -BeLike '*OutputPath*'
            }
            It 'validated' {
                Mock Import-Module { exit 0 }

                &$scriptFile -OutputPath $targetPath

                Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1  -ParameterFilter { $Path -eq $targetPath } 
                Should -Invoke -CommandName Assert-Pattern -Times 1 -ParameterFilter { $Path -eq $targetPath -and $Pattern -eq ".*\.vhdx$" }
                Should -Invoke -CommandName Assert-Path -Times 1  -ParameterFilter { $Path -eq "$parentFolder" -and $PathType -eq "Container" -and $ShallExist -eq $true}
            }
        }
        Context 'default values' {
            It 'are provided' {
                function assert-parameters {
                    $VMMemoryStartupBytes | Should -Be 8GB
                    $VMProcessorCount | Should -Be 4
                    $VMDiskSize | Should -Be 50GB
                    $Proxy | Should -Be ''
                    $KeepArtifactsUsedOnProvisioning | Should -Be $false
                }

                Mock Import-Module { 
                   assert-parameters
                   exit 0 
                }

                &$scriptFile -OutputPath $targetPath

                Should -Invoke -CommandName Assert-LegalCharactersInPath -Times 1  -ParameterFilter { $Path -eq $targetPath } 
            }
        }
        Context 'passed values' {
            It 'are available' {
                $expectedParameters = @{
                    VMMemoryStartupBytes = 2GB
                    VMProcessorCount = 2
                    VMDiskSize = 5GB
                    Proxy = 'myProxy'
                    OutputPath = $targetPath
                }
    
                function assert-parameters {
                    $VMMemoryStartupBytes | Should -Be $expectedParameters.VMMemoryStartupBytes
                    $VMProcessorCount | Should -Be $expectedParameters.VMProcessorCount
                    $VMDiskSize | Should -Be $expectedParameters.VMDiskSize
                    $Proxy | Should -Be $expectedParameters.Proxy
                    $OutputPath | Should -Be $expectedParameters.OutputPath
                    $KeepArtifactsUsedOnProvisioning | Should -Be $true
                }
    
                Mock Import-Module { 
                   assert-parameters
                   exit 0 
                }
    
                &$scriptFile @expectedParameters -KeepArtifactsUsedOnProvisioning
            }
        }
    }
    Context 'Creates base image file' {
        BeforeEach {
            $outputPath = "myFolder\myTargetFile.vhdx"
            Mock Assert-LegalCharactersInPath { return $true }
            Mock Assert-Pattern { return $true } 
            Mock Assert-Path { 'asserted path' }
            Mock Split-Path { '' }
        }
        It 'base image exists? <baseImageExists>; keep artifacts? <keepArtifacts>' -ForEach @(
            @{ baseImageExists = $true; keepArtifacts = $false }
            @{ baseImageExists = $false; keepArtifacts = $false }
            @{ baseImageExists = $true; keepArtifacts = $true }
            @{ baseImageExists = $false; keepArtifacts = $true }
        ) {
            # arrange
            $expectedUserName = 'remote'
            $expectedUserPwd = 'admin'
            $expectedVmName = 'KUBEMASTER_IN_PROVISIONING'
            $expectedHostIpAddress = '172.19.1.100'
            $expectedVmIpAddress = '172.19.1.1'
            $expectedNetworkAdapterName = 'eth0'
            $expectedKubernetesVersion = 'v1.25.13' 
            $expectedCrioVersion = '1.25.2'
            $expectedClusterCIDR='172.20.0.0/16' 
            $expectedClusterCIDR_Services='172.21.0.0/16'
            $expectedKubeDnsServiceIP='172.21.0.10'
            $expectedNetworkInterfaceCni0IP_Master='172.20.0.1'


            $expectedDownloadsDirectory = "$global:BinDirectory\downloads"
            $expectedProvisioningDirectory = "$global:BinDirectory\provisioning"
            $expectedScriptParameters = @{
                VMMemoryStartupBytes = 2GB
                VMProcessorCount = 2
                VMDiskSize = 5GB
                Proxy = 'myProxy'
                OutputPath = $outputPath
            }
            $global:actualMethodCallSequence = @()
            Mock Write-Log { }
            Mock Test-Path { $baseImageExists } -ParameterFilter { $Path -eq $expectedScriptParameters.OutputPath }
            Mock Remove-Item { }
            Mock Remove-SshKeyFromKnownHostsFile { $global:actualMethodCallSequence += 'Remove-SshKeyFromKnownHostsFile' } -ParameterFilter { $IPAddress -eq $expectedHostIpAddress }
            Mock New-DebianCloudBasedVirtualMachine {
                $global:actualMethodCallSequence += 'New-DebianCloudBasedVirtualMachine'
                $global:actualVirtualMachineParams = $VirtualMachineParams
                $global:actualNetworkParams = $NetworkParams
                $global:actualIsoFileParams = $IsoFileParams
                $global:actualWorkingDirectoriesParams = $WorkingDirectoriesParams
            }
            Mock Start-VirtualMachineAndWaitForHeartbeat { $global:actualMethodCallSequence += 'Start-VirtualMachineAndWaitForHeartbeat' } -ParameterFilter { $Name -eq $expectedVmName }
            Mock Wait-ForSshPossible { $global:actualMethodCallSequence += 'Wait-ForSshPossible' } -ParameterFilter { $RemoteUser -eq 'remote@172.19.1.100' -and $RemotePwd -eq $expectedUserPwd -and $SshTestCommand -eq 'which ls' -and $ExpectedSshTestCommandResult -eq '/usr/bin/ls' }
            Mock New-MasterNode { 
                $global:actualMethodCallSequence += 'New-MasterNode' 
                &$Hook
            } -ParameterFilter { $ComputerIP -eq $expectedHostIpAddress -and $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $Proxy -eq $expectedScriptParameters.Proxy -and $K8sVersion -eq $expectedKubernetesVersion -and $CrioVersion -eq $expectedCrioVersion -and $ClusterCIDR -eq $expectedClusterCIDR -and $ClusterCIDR_Services -eq $expectedClusterCIDR_Services -and $KubeDnsServiceIP -eq $expectedKubeDnsServiceIP -and $NetworkInterfaceName -eq $expectedNetworkAdapterName -and $NetworkInterfaceCni0IP_Master -eq $expectedNetworkInterfaceCni0IP_Master }
            Mock Install-Tools { $global:actualMethodCallSequence += 'Install-Tools' } -ParameterFilter { $IpAddress -eq $expectedHostIpAddress -and $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $Proxy -eq $expectedScriptParameters.Proxy }
            Mock Add-SupportForWSL { $global:actualMethodCallSequence += 'Add-SupportForWSL' } -ParameterFilter { $IpAddress -eq $expectedHostIpAddress -and $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $NetworkInterfaceName -eq $expectedNetworkAdapterName -and $GatewayIP -eq $expectedVmIpAddress }
            Mock Stop-VirtualMachineForBaseImageProvisioning { $global:actualMethodCallSequence += 'Stop-VirtualMachineForBaseImageProvisioning' } -ParameterFilter { $Name -eq $expectedVmName}
            Mock Copy-VhdxFile { $global:actualMethodCallSequence += 'Copy-VhdxFile' } -ParameterFilter { $SourceFilePath -eq "$expectedProvisioningDirectory\Debian-11-Base-In-Provisioning-For-Kubemaster.vhdx" -and $TargetPath -eq "$expectedProvisioningDirectory\Debian-11-Base-Provisioned-For-Kubemaster.vhdx"}
            Mock Wait-ForSSHConnectionToLinuxVMViaPwd { $global:actualMethodCallSequence += 'Wait-ForSSHConnectionToLinuxVMViaPwd' }
            Mock New-RootfsForWSL { $global:actualMethodCallSequence += 'New-RootfsForWSL' } -ParameterFilter { $IpAddress -eq $expectedHostIpAddress -and $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $VhdxFile -eq "$expectedProvisioningDirectory\Debian-11-Base-Provisioned-For-Kubemaster.vhdx" -and $RootfsName -eq 'Kubemaster-Base.rootfs.tar.gz' -and $TargetPath -eq $global:BinDirectory }
            Mock Remove-VirtualMachineForBaseImageProvisioning { $global:actualMethodCallSequence += 'Remove-VirtualMachineForBaseImageProvisioning' } -ParameterFilter { $VhdxFilePath -eq "$expectedProvisioningDirectory\Debian-11-Base-In-Provisioning-For-Kubemaster.vhdx" -and $VmName -eq $expectedVmName }
            Mock Remove-NetworkForProvisioning { $global:actualMethodCallSequence += 'Remove-NetworkForProvisioning' } -ParameterFilter { $NatName -eq 'VmProvisioningNat' -and $SwitchName -eq 'VmProvisioningSwitch' }
            Mock Copy-Item { $global:actualMethodCallSequence += 'Copy-Item' } -ParameterFilter { $Path -eq "$expectedProvisioningDirectory\Debian-11-Base-Provisioned-For-Kubemaster.vhdx" -and $Destination -eq $expectedScriptParameters.OutputPath }

            $KeepArtifactsUsedOnProvisioning = ''
            if ($keepArtifacts) {
                $KeepArtifactsUsedOnProvisioning = '-KeepArtifactsUsedOnProvisioning'
            }

            # act 
            Invoke-Expression -Command  "&'$scriptFile' @expectedScriptParameters $KeepArtifactsUsedOnProvisioning"

            # assert
            if ($baseImageExists) {
                $expectedOutputPathDeletionTimes = 1
            } else {
                $expectedOutputPathDeletionTimes = 0
            }
            Should -Invoke -CommandName Remove-Item -Times $expectedOutputPathDeletionTimes -ParameterFilter { $Path -eq $expectedScriptParameters.OutputPath -and $Force -eq $true }
            Should -Invoke -CommandName Remove-SshKeyFromKnownHostsFile -Times 1 -ParameterFilter { $IpAddress -eq $expectedHostIpAddress }
            
            $expectedVirtualMachineParams = @{
                VmName= "KUBEMASTER_IN_PROVISIONING"
                VhdxName="Debian-11-Base-In-Provisioning-For-Kubemaster.vhdx"
                VMMemoryStartupBytes=$expectedScriptParameters.VMMemoryStartupBytes
                VMProcessorCount=$expectedScriptParameters.VMProcessorCount
                VMDiskSize=$expectedScriptParameters.VMDiskSize
            }
            $expectedNetworkParams = @{
                Proxy=$expectedScriptParameters.Proxy
                SwitchName='VmProvisioningSwitch'
                HostIpAddress=$expectedVmIpAddress
                HostIpPrefixLength=24
                NatName='VmProvisioningNat'
                NatIpAddress='172.19.1.0'
            }

            $expectedIsoFileParams = @{
                IsoFileCreatorToolPath="$global:BinPath\cloudinitisobuilder.exe"
                IsoFileName='cloud-init-provisioning.iso'
                SourcePath="$PSScriptRoot\cloud-init-templates"
                Hostname='kubemaster'
                NetworkInterfaceName=$expectedNetworkAdapterName
                IPAddressVM=$expectedHostIpAddress
                IPAddressGateway=$expectedVmIpAddress
                UserName=$expectedUserName
                UserPwd=$expectedUserPwd
            }
            $expectedWorkingDirectoriesParams = @{
                DownloadsDirectory=$expectedDownloadsDirectory
                ProvisioningDirectory=$expectedProvisioningDirectory
            }

            Compare-Hashtables -Left $actualVirtualMachineParams -Right $expectedVirtualMachineParams | Should -Be $true
            Compare-Hashtables -Left $actualNetworkParams -Right $expectedNetworkParams | Should -Be $true
            Compare-Hashtables -Left $actualIsoFileParams -Right $expectedIsoFileParams | Should -Be $true
            Compare-Hashtables -Left $actualWorkingDirectoriesParams -Right $expectedWorkingDirectoriesParams | Should -Be $true
                
            if ($keepArtifacts) {
                $expectedRemoveItemCalledTimes = 0
            } else {
                $expectedRemoveItemCalledTimes = 1
            }
            Should -Invoke -CommandName Remove-Item -Times $expectedRemoveItemCalledTimes -ParameterFilter { $Path -eq $expectedWorkingDirectoriesParams.ProvisioningDirectory -and $Recurse -eq $true -and $Force -eq $true }
            Should -Invoke -CommandName Remove-Item -Times $expectedRemoveItemCalledTimes -ParameterFilter { $Path -eq $expectedWorkingDirectoriesParams.DownloadsDirectory -and $Recurse -eq $true -and $Force -eq $true }

            $expectedMethodCallSequence = @(
                'Remove-SshKeyFromKnownHostsFile',
                'New-DebianCloudBasedVirtualMachine',
                'Start-VirtualMachineAndWaitForHeartbeat',
                'Wait-ForSshPossible',
                'New-MasterNode',
                'Install-Tools',
                'Add-SupportForWSL',
                'Stop-VirtualMachineForBaseImageProvisioning',
                'Copy-VhdxFile',
                'Start-VirtualMachineAndWaitForHeartbeat',
                'Wait-ForSSHConnectionToLinuxVMViaPwd',
                'New-RootfsForWSL',
                'Stop-VirtualMachineForBaseImageProvisioning',
                'Remove-VirtualMachineForBaseImageProvisioning',
                'Remove-NetworkForProvisioning',
                'Copy-Item')
            $actualMethodCallSequence | Should -Be $expectedMethodCallSequence
        }
    }
}