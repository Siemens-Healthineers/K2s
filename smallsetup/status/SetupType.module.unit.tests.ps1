# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\SetupType.module.psm1"

    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Confirm-SetupTypeIsValid' -Tag 'unit' {
    It 'validation error contains "<expected>" when setup type is "<type>"' -ForEach @(
        @{ Type = $null; Expected = 'not installed' }
        @{ Type = 'invalid type'; Expected = 'not installed' }
        @{ Type = 'k2s'; Expected = $null }
        @{ Type = 'MultiVMK8s'; Expected = $null }
        @{ Type = 'BuildOnlyEnv'; Expected = 'build-only' }
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

Describe 'Get-SetupType' -Tag 'unit' {
    Context 'setup type is valid' {
        Context "type is 'MultiVMK8s'" {
            BeforeAll {
                Mock -ModuleName $moduleName Get-ConfigValue { return 'MultiVMK8s' } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'SetupType' }
                Mock -ModuleName $moduleName Get-LinuxOnlyFromConfig { return $false }
                Mock -ModuleName $moduleName Confirm-SetupTypeIsValid { return $null } -ParameterFilter { $SetupType -eq 'MultiVMK8s' }
            }

            It 'returns setup type without validation error' {
                $result = Get-SetupType
                $result.Name | Should -Be 'MultiVMK8s'
                $result.ValidationError | Should -BeNullOrEmpty
                $result.LinuxOnly | Should -BeFalse
            } 
        }
        
        Context 'Linux-only option set' {
            BeforeAll {
                Mock -ModuleName $moduleName Get-ConfigValue { return 'MultiVMK8s' } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'SetupType' }
                Mock -ModuleName $moduleName Get-LinuxOnlyFromConfig { return $true }
                Mock -ModuleName $moduleName Confirm-SetupTypeIsValid { return $null } -ParameterFilter { $SetupType -eq 'MultiVMK8s' }
            }

            It 'returns setup type with Linux-only hint' {
                $result = Get-SetupType
                $result.Name | Should -Be 'MultiVMK8s'
                $result.ValidationError | Should -BeNullOrEmpty
                $result.LinuxOnly | Should -BeTrue
            } 
        }
    
    }
    
    Context 'setup type is invalid' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-ConfigValue { return 'invalid' } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'SetupType' }
            Mock -ModuleName $moduleName Get-LinuxOnlyFromConfig { return $false }
            Mock -ModuleName $moduleName Confirm-SetupTypeIsValid { return 'invalid-type' } -ParameterFilter { $SetupType -eq 'invalid' }
        }

        It 'returns setup type with validation error' {
            $result = Get-SetupType
            $result.Name | Should -Be 'invalid'
            $result.ValidationError | Should -Be 'invalid-type'
            $result.LinuxOnly | Should -BeFalse
        }
    }

    Context 'version info is present' {
        BeforeAll {
            Mock -ModuleName $moduleName Get-ConfigValue { return 'MultiVMK8s' } -ParameterFilter { $Path -match 'setup.json' -and $Key -eq 'SetupType' }
            Mock -ModuleName $moduleName Get-LinuxOnlyFromConfig { return $false }
            Mock -ModuleName $moduleName Confirm-SetupTypeIsValid { return $null } -ParameterFilter { $SetupType -eq 'MultiVMK8s' }
        }

        It 'returns version info' {
            $result = Get-SetupType
            $result.Version | Should -Be "v$global:ProductVersion"
        } 
    }
}