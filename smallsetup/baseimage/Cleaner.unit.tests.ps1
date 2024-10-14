# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    . "$PSScriptRoot\..\common\GlobalFunctions.ps1"

    $baseImageModule = "$PSScriptRoot\BaseImage.module.psm1"
    $baseImageModuleName = (Import-Module $baseImageModule -PassThru -Force).Name
}

Describe 'Cleaner.ps1' -Tag 'unit', 'ci', 'baseimage' {
    BeforeAll {
        $scriptFile = "$PSScriptRoot\Cleaner.ps1"
    }
    BeforeEach {
        $expectedVmName = 'KUBEMASTER_IN_PROVISIONING'
        Mock Get-VM { $null } 
        Mock Write-Log {  }
        Mock Remove-VirtualMachineForBaseImageProvisioning { } 
        Mock Remove-NetworkForProvisioning { }
        Mock Test-Path { $false } -ParameterFilter { $Path -eq $global:ProvisioningTargetDirectory }
        Mock Test-Path { $false } -ParameterFilter { $Path -eq $global:DownloadsDirectory }
    }
    Context 'virtual machine' {
        It "with name '<virtualMachineNameToUse>' stopped?: <shallStop>" -ForEach @(
            @{ virtualMachineNameToUse = 'KUBEMASTER_IN_PROVISIONING'; shallStop = $true }
            @{ virtualMachineNameToUse = 'other name'; shallStop = $false }
        ) {
            Mock Get-VM { @{ Name = $virtualMachineNameToUse } } 
            Mock Stop-VirtualMachineForBaseImageProvisioning { }

            Invoke-Expression -Command "$scriptFile"

            if ($shallStop) {
                $expectedTimes = 1
            }
            else {
                $expectedTimes = 0
            }
            Should -Invoke -CommandName Stop-VirtualMachineForBaseImageProvisioning -Times $expectedTimes -ParameterFilter { $Name -eq $expectedVmName }
        }
        It 'removed and network connector deleted' {
            Invoke-Expression -Command "$scriptFile"

            Should -Invoke -CommandName Remove-VirtualMachineForBaseImageProvisioning -Times 1 -ParameterFilter { $VmName -eq $expectedVmName -and $VhdxFilePath -eq "$global:BinDirectory\provisioning\Debian-11-Base-In-Provisioning-For-Kubemaster.vhdx" }
            Should -Invoke -CommandName Remove-NetworkForProvisioning -Times 1 -ParameterFilter { $NatName -eq 'VmProvisioningNat' -and $SwitchName -eq 'VmProvisioningSwitch' }
        }
    }
    Context 'directories' {
        It 'removed' {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $global:ProvisioningTargetDirectory }
            Mock Test-Path { $true } -ParameterFilter { $Path -eq $global:DownloadsDirectory }
            Mock Remove-Item { }

            Invoke-Expression -Command "$scriptFile"

            Should -Invoke -CommandName Remove-Item -Times 1 -ParameterFilter { $Path -eq $global:ProvisioningTargetDirectory -and $Recurse -eq $true -and $Force -eq $true }
            Should -Invoke -CommandName Remove-Item -Times 1 -ParameterFilter { $Path -eq $global:DownloadsDirectory -and $Recurse -eq $true -and $Force -eq $true }
        }
        
    }
}