# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\setupinfo.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Confirm-SetupTypeIsValid' -Tag 'unit' {
    It 'validation error contains "<expected>" when setup type is "<type>"' -ForEach @(
        @{ Type = $null; Expected = 'not-installed' }
        @{ Type = 'invalid type'; Expected = 'not-installed' }
        @{ Type = 'k2s'; Expected = $null }
        @{ Type = 'MultiVMK8s'; Expected = $null }
        @{ Type = 'BuildOnlyEnv'; Expected = 'no-cluster' }
    ) {
        InModuleScope $moduleName -Parameters @{Type = $Type; Expected = $Expected } {
            $result = Confirm-SetupTypeIsValid -SetupType $Type

            if ($Expected -eq $null) {
                $result | Should -BeNullOrEmpty
            }
            else {
                $result | Should -Match $Expected
            }
        }
    }
}

Describe 'Get-SetupInfo' -Tag 'unit' {
    Context 'setup type is valid' {
        Context "type is 'MultiVMK8s'" {
            BeforeAll {
                Mock -ModuleName $moduleName Get-ConfigSetupType { return 'MultiVMK8s' }
                Mock -ModuleName $moduleName Get-ConfigLinuxOnly { return $null }
                Mock -ModuleName $moduleName Confirm-SetupTypeIsValid { return $null } -ParameterFilter { $SetupType -eq 'MultiVMK8s' }
                Mock -ModuleName $moduleName Get-ProductVersion { return '1.2.3' }
            }

            It 'returns setup type without validation error' {
                $result = Get-SetupInfo
                $result.Name | Should -Be 'MultiVMK8s'
                $result.ValidationError | Should -BeNullOrEmpty
                $result.LinuxOnly | Should -BeFalse
                $result.Version | Should -Be 'v1.2.3'
            } 
        }
        
        Context 'Linux-only option set' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-ConfigSetupType { return 'MultiVMK8s' }
                Mock -ModuleName $moduleName Get-ConfigLinuxOnly { return $true }
                Mock -ModuleName $moduleName Confirm-SetupTypeIsValid { return $null } -ParameterFilter { $SetupType -eq 'MultiVMK8s' }
                Mock -ModuleName $moduleName Get-ProductVersion { return '1.2.3' }
            }

            It 'returns setup type with Linux-only hint' {
                $result = Get-SetupInfo
                $result.Name | Should -Be 'MultiVMK8s'
                $result.ValidationError | Should -BeNullOrEmpty
                $result.LinuxOnly | Should -BeTrue
                $result.Version | Should -Be 'v1.2.3'
            } 
        }    
    }
    
    Context 'setup type is invalid' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-ConfigSetupType { return 'invalid' }
            Mock -ModuleName $moduleName Get-ConfigLinuxOnly { return $false }
            Mock -ModuleName $moduleName Confirm-SetupTypeIsValid { return 'invalid-type' } -ParameterFilter { $SetupType -eq 'invalid' }
            Mock -ModuleName $moduleName Get-ProductVersion { }
        }

        It 'returns setup type with validation error' {
            $result = Get-SetupInfo
            $result.Name | Should -Be 'invalid'
            $result.ValidationError | Should -Be 'invalid-type'
            $result.LinuxOnly | Should -BeFalse
        }
    }
}