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
        Mock -ModuleName $moduleName Write-Log { $log.Add($Messages) | Out-Null }
        Mock -ModuleName $moduleName Invoke-Cmd { return 0 }
    }

    It 'calls Write-Log with correct message' {
        InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
            Invoke-ClusterInstall
            $log.Count | Should -BeGreaterOrEqual 3
            $log[3] | Should -Be 'Install of cluster successfully called'
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
            Assert-MockCalled Invoke-Cmd -ParameterFilter { $Executable -Match 'k2sx.exe' }
            Should -Invoke -CommandName Invoke-Cmd -Times 1 -Exactly
        }
    }
}

Describe 'Invoke-ClusterUninstall' -Tag 'unit', 'ci', 'upgrade' {
    BeforeAll {
        $log = [System.Collections.ArrayList]@()
        Mock -ModuleName $moduleName Copy-Item { }
        Mock -ModuleName $moduleName Write-Log { $log.Add($Messages) | Out-Null }
        Mock -ModuleName $moduleName Invoke-Cmd { return 0 }
        Mock -ModuleName $moduleName Test-Path { return $true }
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
            Assert-MockCalled Invoke-Cmd -ParameterFilter { $Executable -Match 'k2s.exe' }
            Should -Invoke -CommandName Invoke-Cmd -Times 1 -Exactly
        }
    }
}

Describe 'Remove-SetupConfigIfExisting' -Tag 'unit', 'ci', 'upgrade' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log { }
        Mock -ModuleName $moduleName Get-SetupConfigFilePath { return 'my-config' }
        Mock -ModuleName $moduleName Remove-Item { }
    }

    Context 'config not existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $false } -ParameterFilter { $Path -eq 'my-config' }
        }

        It 'does nothing' {
            InModuleScope -ModuleName $moduleName {
                Remove-SetupConfigIfExisting

                Should -Invoke -Scope Context Remove-Item -Times 0
            }
        }
    }

    Context 'config existing' {
        BeforeAll {
            Mock -ModuleName $moduleName Test-Path { return $true } -ParameterFilter { $Path -eq 'my-config' }
        }

        It 'removes the config' {
            InModuleScope -ModuleName $moduleName {
                Remove-SetupConfigIfExisting

                Should -Invoke -Scope Context Remove-Item -Times 1 -ParameterFilter { $Path -eq 'my-config' }
            }
        }
    }
}

Describe "Restart-ClusterIfBuildVersionMismatch" {
    BeforeAll {
        $log = [System.Collections.ArrayList]@()
        Mock -ModuleName $moduleName RestartCluster  {  }
        Mock -ModuleName $moduleName Write-Log { $log.Add($Messages) | Out-Null }
    }

    It "should restart the cluster if only the build version is different" {
        InModuleScope -ModuleName $moduleName {
            $currentVersion = "1.2.3"
            $nextVersion = "1.2.4"
            $installFolder = "C:\Program Files\K2s"
            $kubePath = "C:\Program Files\K2s\kube"

            $result = Restart-ClusterIfBuildVersionMismatch -currentVersion $currentVersion -nextVersion $nextVersion -installFolder $installFolder -kubePath $kubePath
            # Assert that RestartCluster was called
            Assert-MockCalled -CommandName RestartCluster -Exactly 1 -Scope It

            # Assert that the function returns $false
            $result | Should -Be $false
        }
    }

    It "should not restart the cluster if the major version is different" {
        InModuleScope -ModuleName $moduleName {
            $currentVersion = "1.2.3"
            $nextVersion = "2.0.0"
            $installFolder = "C:\Program Files\K2s"
            $kubePath = "C:\Program Files\K2s\kube"

            $result = Restart-ClusterIfBuildVersionMismatch -currentVersion $currentVersion -nextVersion $nextVersion -installFolder $installFolder -kubePath $kubePath

            # Assert that RestartCluster was not called
            Assert-MockCalled -CommandName RestartCluster -Exactly 0 -Scope It

            # Assert that the function returns $true
            $result | Should -Be $true
        }
    }

    It "should not restart the cluster if the minor version is increased by more than one" {
        InModuleScope -ModuleName $moduleName {
            $currentVersion = "1.2.3"
            $nextVersion = "1.4.0"
            $installFolder = "C:\Program Files\K2s"
            $kubePath = "C:\Program Files\K2s\kube"

            $result = Restart-ClusterIfBuildVersionMismatch -currentVersion $currentVersion -nextVersion $nextVersion -installFolder $installFolder -kubePath $kubePath

            # Assert that RestartCluster was not called
            Assert-MockCalled -CommandName RestartCluster -Exactly 0 -Scope It

            # Assert that the function returns $true
            $result | Should -Be $true
        }
    }

    It "should not restart the cluster if the minor version is the same and the build version is the same" {
        InModuleScope -ModuleName $moduleName {
            $currentVersion = "1.2.3"
            $nextVersion = "1.2.3"
            $installFolder = "C:\Program Files\K2s"
            $kubePath = "C:\Program Files\K2s\kube"

            $result = Restart-ClusterIfBuildVersionMismatch -currentVersion $currentVersion -nextVersion $nextVersion -installFolder $installFolder -kubePath $kubePath

            # Assert that RestartCluster was not called
            Assert-MockCalled -CommandName RestartCluster -Exactly 0 -Scope It

            # Assert that the function returns $false
            $result | Should -Be $false
        }
    }
}

Import-Module "$PSScriptRoot\..\..\..\k2s\k2s.cluster.module"

Describe "RestartCluster" {
    BeforeAll {
        $log = [System.Collections.ArrayList]@()
        Mock -ModuleName $moduleName Write-Log {
            $log.Add($Messages) | Out-Null }
        Mock -ModuleName $moduleName Invoke-Cmd { return 0 }
        Mock -ModuleName $moduleName Get-SetupInfo { return @{ Name = "k2s" } }
    }

    It "should not restart the cluster if it is not running" {
        InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
            Mock Get-RunningState { return @{ IsRunning = $false } }
            RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath"
            # Assert that Write-Log was called with the expected message
            Assert-MockCalled -CommandName Write-Log -Exactly 1 -Scope It
            $log.Count | Should -BeGreaterOrEqual 1
            $log[0] | Should -Be 'Cluster is not running, no need to restart'
        }
    }

    It "should log a message if the k2s.exe does not exist" {
        InModuleScope -ModuleName $moduleName -Parameters @{log = $log } {
            Mock Get-RunningState { return @{ IsRunning = $true } }
            Mock Test-Path  { return $false }
            RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath"
            # Assert that Write-Log was called with the expected message
            Assert-MockCalled -CommandName Write-Log -Exactly 2 -Scope It
            $log.Count | Should -BeGreaterOrEqual 2
            $log[2] | Should -Be "K2s exe: 'C:\Current\KubePath\k2s.exe' does not exist. Skipping stop."
        }
    }

    It "should restart the cluster if it is running and k2s.exe exists" {
        InModuleScope -ModuleName $moduleName -Parameters @{log = $log }  {
            Mock Get-RunningState { return @{ IsRunning = $true } }
            Mock Test-Path  { return $true }
            RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath"
            # Assert that Invoke-Cmd was called with the expected arguments
            Assert-MockCalled -CommandName Invoke-Cmd -Exactly 1 -Scope It -ParameterFilter { $Executable -eq "C:\Current\KubePath\k2s.exe" -and $Arguments -eq "stop" }

            # Assert that Write-Log was called with the expected message
            Assert-MockCalled -CommandName Write-Log -Exactly 3 -Scope It
            $log.Count | Should -BeGreaterOrEqual 5
            $log[4] | Should -Be "Stop of cluster successfully called"
            $log[5] | Should -Be "Start of cluster successfully called"
        }
    }

    It "should throw an exception if stopping the cluster fails" {
        InModuleScope -ModuleName $moduleName  -Parameters @{log = $log } {
            Mock Get-RunningState { return @{ IsRunning = $true } }
            Mock Test-Path  { return $true }
            Mock Invoke-Cmd { return 1 }
            { RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath" } | Should -Throw -ExpectedMessage 'Error: Not possible to stop existing cluster!'
        }
    }

    It "should throw an exception if starting the cluster fails" {
        InModuleScope -ModuleName $moduleName  -Parameters @{log = $log } {
            Mock Get-RunningState { return @{ IsRunning = $true } }
            $script:count = 0
            Mock Test-Path  { return $true }
            Mock Invoke-Cmd {
                # This is done to simulate that the first call to Invoke-Cmd is successful and the second fails
                $script:count++
                if ($script:count++ -eq 1) {
                    return 0
                } else {
                    return 1
                }
             }
            { RestartCluster -CurrentKubePath "C:\Current\KubePath" -NextVersionKubePath "C:\Next\KubePath" } | Should -Throw -ExpectedMessage 'Error: Not possible to start cluster!'
        }
    }
}



