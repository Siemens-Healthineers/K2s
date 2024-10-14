# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\upgrade.module.psm1" -PassThru -Force).Name
}

Describe 'Assert-UpgradeVersionIsValid' -Tag 'unit', 'ci', 'upgrade' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    It "returns '<ExpectedResult>' when current version is '<Current>' and new version is'<New>'" -ForEach @(
        @{ ExpectedResult = $true; Current = '1.0.0'; New = '1.0.1' }
        @{ ExpectedResult = $true; Current = '1.0.0'; New = '1.0.11' }
        @{ ExpectedResult = $true; Current = '1.0.0'; New = '1.1.0' }
        @{ ExpectedResult = $true; Current = '1.0.0'; New = '1.1.11' }
        @{ ExpectedResult = $true; Current = '1.1.1'; New = '1.2.0' }
        @{ ExpectedResult = $true; Current = '1.2.3'; New = '1.3.444' }
        @{ ExpectedResult = $true; Current = '2.3.4'; New = '2.4.0' }

        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.2.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '2.0.0' }
        @{ ExpectedResult = $false; Current = '2.0.0'; New = '2.2.0' }
        
        @{ ExpectedResult = $false; Current = '1.1.0'; New = '1.0.0' }
        @{ ExpectedResult = $false; Current = '1.1.1'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '2.0.0'; New = '1.0.0' }

        @{ ExpectedResult = $false; Current = '1.0'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1' }

        @{ ExpectedResult = $false; Current = '1.o.o'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1.o' }

        @{ ExpectedResult = $false; Current = '1'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '2' }

        @{ ExpectedResult = $false; Current = '1.0.0.0'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1.0.0' }

        @{ ExpectedResult = $false; Current = '1.0.0-beta'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1.0-beta' }
    ) {
        InModuleScope $moduleName -Parameters @{ ExpectedResult = $ExpectedResult; Current = $Current; New = $New } {
            Assert-UpgradeVersionIsValid -VersionInstalled $Current -VersionToBeUsed $New | Should -Be $ExpectedResult
        }
    }
}

Describe 'Invoke-ClusterInstall' -Tag 'unit', 'ci', 'upgrade' {
    BeforeAll {
        $log = [System.Collections.ArrayList]@()
        Mock -ModuleName $moduleName Copy-Item { }
        Mock -ModuleName $moduleName Write-Log  { $log.Add($Messages) | Out-Null }
        Mock -ModuleName $moduleName Invoke-Cmd { return 0 }
    }

    It 'calls Write-Log with correct message' {
        InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
            Invoke-ClusterInstall
            $log.Count | Should -BeGreaterOrEqual 3
            $log[2] | Should -Be 'Install of cluster successfully called'
        }
    }

    It 'calls Copy-Item with correct source and destination' {
        InModuleScope -ModuleName $moduleName {
            Invoke-ClusterInstall
            Assert-MockCalled Copy-Item -ParameterFilter { $Path -eq "$kubePath\k2s.exe" -and $Destination -eq "$kubePath\k2sx.exe" -and $Force -and $PassThru }
        }
    }

    It 'calls Invoke-Cmd with correct command' {
        InModuleScope -ModuleName $moduleName {
            Invoke-ClusterInstall
            Assert-MockCalled Invoke-Cmd -ParameterFilter { $Executable -Match "k2sx.exe" }
            Should -Invoke -CommandName Invoke-Cmd -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ClusterUninstall' -Tag 'unit', 'ci', 'upgrade' {
    BeforeAll {
        $log = [System.Collections.ArrayList]@()
        Mock -ModuleName $moduleName Copy-Item { }
        Mock -ModuleName $moduleName Write-Log  { $log.Add($Messages) | Out-Null }
        Mock -ModuleName $moduleName Invoke-Cmd { return 0 } 
    }

    It 'calls Write-Log with correct message' {
        InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
            Invoke-ClusterUninstall
            $log.Count | Should -BeGreaterOrEqual 3
            $log[2] | Should -Be 'Uninstall of cluster successfully called'
        }
    }

    It 'calls Invoke-Cmd with correct command' {
        InModuleScope -ModuleName $moduleName {
            Invoke-ClusterUninstall
            Assert-MockCalled Invoke-Cmd -ParameterFilter { $Executable -Match "k2s.exe" }
            Should -Invoke -CommandName Invoke-Cmd -Times 1 -Exactly
        }
    }
}



