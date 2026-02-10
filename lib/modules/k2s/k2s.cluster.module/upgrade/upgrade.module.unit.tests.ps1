# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
	$moduleName = (Import-Module "$PSScriptRoot\upgrade.module.psm1" -PassThru -Force).Name
}
Import-Module "$PSScriptRoot\..\..\..\k2s\k2s.cluster.module"
Import-Module "$PSScriptRoot\..\..\..\k2s\k2s.infra.module"
Import-Module "$PSScriptRoot\..\..\..\..\..\addons\addons.module.psm1"

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
			Should -Invoke RestartCluster -Exactly 1 -Scope It

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
			Should -Invoke RestartCluster -Exactly 0 -Scope It

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
			Should -Invoke RestartCluster -Exactly 0 -Scope It

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
			Should -Invoke RestartCluster -Exactly 0 -Scope It

			# Assert that the function returns $false
			$result | Should -Be $false
		}
	}
}

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
			Should -Invoke Write-Log -Exactly 1 -Scope It
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
			Should -Invoke Write-Log -Exactly 2 -Scope It
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
			Should -Invoke Invoke-Cmd -Exactly 1 -Scope It -ParameterFilter { $Executable -eq "C:\Current\KubePath\k2s.exe" -and $Arguments -eq "stop" }

			# Assert that Write-Log was called with the expected message
			Should -Invoke Write-Log -Exactly 3 -Scope It
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

Describe "PerformClusterUpgrade" {
	BeforeAll {
		# Mock the dependencies
		Mock -ModuleName $moduleName Get-LogFilePath -MockWith { return "C:\Logs\logfile.log" }
		Mock -ModuleName $moduleName Get-Content -MockWith { return "log content" }
		Mock -ModuleName $moduleName Set-Content
		Mock -ModuleName $moduleName Remove-SetupConfigIfExisting
		Mock -ModuleName $moduleName Start-Sleep
		Mock -ModuleName $moduleName Invoke-ClusterInstall
		Mock -ModuleName $moduleName Wait-ForAPIServer
		Mock -ModuleName $moduleName Invoke-UpgradeBackupRestoreHooks
		Mock -ModuleName $moduleName Get-KubeToolsPath -MockWith { return "C:\KubeTools" }
		Mock -ModuleName $moduleName Import-NotNamespacedResources
		Mock -ModuleName $moduleName Import-NamespacedResources
		Mock -ModuleName $moduleName Restore-LogFile
		Mock -ModuleName $moduleName Write-Log
		Mock -ModuleName $moduleName Write-Progress
		Mock -ModuleName $moduleName Get-ProductVersion -MockWith { return "1.0.0" }
		Mock -ModuleName $moduleName Get-KubePath -MockWith { return "C:\KubePath" }
		Mock -ModuleName $moduleName Write-RefreshEnvVariables
		Mock -ModuleName $moduleName Out-File
		Mock -ModuleName $moduleName Wait-ForAPIServerInGivenKubePath
		Mock -ModuleName $moduleName Get-KubeBinPathGivenKubePath -MockWith { return "C:\KubeBinPath" }
	}

	It "should perform cluster upgrade with execute hooks successfully" {
		InModuleScope $moduleName {
			$memoryVM = [ref]"4GB"
			$coresVM = [ref]"2"
			$storageVM = [ref]"100GB"
			$enabledAddonsList = [System.Collections.ArrayList]@([pscustomobject]@{ Name = 'dashboard' })
			$hooksBackupPath = [ref]"C:\Backup\Hooks"
			$logFilePathBeforeUninstall = [ref]"C:\Backup\logfile.log"

			Mock Invoke-ClusterUninstall

			PerformClusterUpgrade -ExecuteHooks -ShowProgress -DeleteFiles -ShowLogs -K2sPathToInstallFrom "C:\K2sPath" -Config "config.yaml" -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall

			# Assert that the mocked functions were called
			Should -Invoke Invoke-ClusterUninstall -Exactly 1 -Scope It
			Should -Invoke Invoke-ClusterInstall -Exactly 1 -Scope It
			Should -Invoke Invoke-UpgradeBackupRestoreHooks -Exactly 1 -Scope It -ParameterFilter { $HookType -eq "Restore" -and $BackupDir -eq $hooksBackupPath.Value }
			Should -Invoke Import-NotNamespacedResources -Exactly 1 -Scope It
			Should -Invoke Import-NamespacedResources -Exactly 1 -Scope It
			Should -Invoke Restore-LogFile -Exactly 1 -Scope It
			Should -Invoke Write-Log -Times 1 -Scope It
			Should -Invoke Write-Progress -Times 1 -Scope It
		}
	}
	
	It "should perform cluster upgrade without execute hooks successfully" {
		InModuleScope $moduleName {
			$memoryVM = [ref]"4GB"
			$coresVM = [ref]"2"
			$storageVM = [ref]"100GB"
			$enabledAddonsList = [System.Collections.ArrayList]@()
			$hooksBackupPath = [ref]"C:\Backup\Hooks"
			$logFilePathBeforeUninstall = [ref]"C:\Backup\logfile.log"

			Mock Invoke-ClusterUninstall
			PerformClusterUpgrade -ShowProgress -DeleteFiles -ShowLogs -K2sPathToInstallFrom "C:\K2sPath" -Config "config.yaml" -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall

			# Assert that the mocked functions were called
			Should -Invoke  Invoke-ClusterUninstall -Exactly 1 -Scope It
			Should -Invoke Invoke-ClusterInstall -Exactly 1 -Scope It
			Should -Invoke Invoke-UpgradeBackupRestoreHooks -Exactly 0 -Scope It -ParameterFilter { $HookType -eq "Restore" -and $BackupDir -eq $hooksBackupPath.Value }
			Should -Invoke Import-NotNamespacedResources -Exactly 1 -Scope It
			Should -Invoke Import-NamespacedResources -Exactly 1 -Scope It
			Should -Invoke Restore-LogFile -Exactly 1 -Scope It
			Should -Invoke Write-Log -Times 1 -Scope It
			Should -Invoke Write-Progress -Times 1 -Scope It
		}
	}

	It "should throw an error if an exception occurs" {
		InModuleScope $moduleName {
			Mock Invoke-ClusterUninstall -MockWith { throw "Uninstall failed" }
	
			$memoryVM = [ref]"4GB"
			$coresVM = [ref]"2"
			$storageVM = [ref]"100GB"
			$enabledAddonsList = [System.Collections.ArrayList]@()
			$hooksBackupPath = [ref]"C:\Backup\Hooks"
			$logFilePathBeforeUninstall = [ref]"C:\Backup\logfile.log"
	
			{ PerformClusterUpgrade -ShowProgress -DeleteFiles -ShowLogs -K2sPathToInstallFrom "C:\K2sPath" -Config "config.yaml" -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -memoryVM $memoryVM -coresVM $coresVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall } | Should -Throw "Uninstall failed"
		}
	}
}

Describe "PrepareClusterUpgrade" {
	BeforeAll {
		# Mock the dependencies
		Mock -ModuleName $moduleName Get-SetupInfo -MockWith { return @{ Name = "k2s" } }
		Mock -ModuleName $moduleName Get-LinuxVMCores -MockWith { return 4 }
		Mock -ModuleName $moduleName Get-LinuxVMMemory -MockWith { return 16 }
		Mock -ModuleName $moduleName Get-LinuxVMStorageSize -MockWith { return 100 }
		Mock -ModuleName $moduleName Assert-UpgradeOperation -MockWith { return $true }
		Mock -ModuleName $moduleName Enable-ClusterIsRunning
		Mock -ModuleName $moduleName Get-EnabledAddons -MockWith { return [System.Collections.ArrayList]@() }
		Mock -ModuleName $moduleName Assert-YamlTools
		Mock -ModuleName $moduleName Get-ClusterInstalledFolder -MockWith { return "C:\Cluster" }
		Mock -ModuleName $moduleName Test-Path -MockWith { return $true }
		Mock -ModuleName $moduleName Export-ClusterResources
		Mock -ModuleName $moduleName Invoke-UpgradeBackupRestoreHooks
		Mock -ModuleName $moduleName Backup-LogFile
		Mock -ModuleName $moduleName Write-Log
		Mock -ModuleName $moduleName Write-Progress
	}

	It "should prepare cluster upgrade successfully" {
		InModuleScope $moduleName {
			$coresVM = [ref]0
			$memoryVM = [ref]0
			$storageVM = [ref]0
			$enabledAddonsList = [ref]$null
			$hooksBackupPath = [ref]""
			$logFilePathBeforeUninstall = [ref]""

			$result = PrepareClusterUpgrade -ShowProgress -SkipResources -ShowLogs -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall

			# Assert that the mocked functions were called
			Should -Invoke Get-SetupInfo -Exactly 1 -Scope It
			Should -Invoke Assert-UpgradeOperation -Exactly 1 -Scope It
			Should -Invoke Enable-ClusterIsRunning -Exactly 1 -Scope It
			Should -Invoke Get-EnabledAddons -Exactly 1 -Scope It
			Should -Invoke Get-LinuxVMCores -Exactly 1 -Scope It
			Should -Invoke Get-LinuxVMMemory -Exactly 1 -Scope It
			Should -Invoke Get-LinuxVMStorageSize -Exactly 1 -Scope It
			Should -Invoke Assert-YamlTools -Exactly 1 -Scope It
			Should -Invoke Get-ClusterInstalledFolder -Exactly 1 -Scope It
			Should -Invoke Test-Path -Exactly 1 -Scope It
			Should -Invoke Export-ClusterResources -Exactly 1 -Scope It
			Should -Invoke Invoke-UpgradeBackupRestoreHooks -Exactly 1 -Scope It
			Should -Invoke Backup-LogFile -Exactly 1 -Scope It
			Should -Invoke Write-Log -Times 1 -Scope It
			Should -Invoke Write-Progress -Times 1 -Scope It

			# Assert the return value
			$result | Should -Be $true
		}
	}

	It "should return false if no previous version of K2s is installed" {
		InModuleScope $moduleName {
			Mock Get-SetupInfo -MockWith { return @{ Name = $null } }

			$coresVM = [ref]0
			$memoryVM = [ref]0
			$storageVM = [ref]0
			$enabledAddonsList = [ref]$null
			$hooksBackupPath = [ref]""
			$logFilePathBeforeUninstall = [ref]""

			$result = PrepareClusterUpgrade -ShowProgress -SkipResources -ShowLogs -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall

			# Assert that the mocked functions were called
			Should -Invoke Get-SetupInfo -Exactly 1 -Scope It
			Should -Invoke Write-Log -Times 1 -Scope It
			Should -Invoke Write-Progress -Times 1 -Scope It

			# Assert the return value
			$result | Should -Be $false
		}
	}

	It "should throw an error if the setup name is not 'k2s'" {
		InModuleScope $moduleName {
			Mock Get-SetupInfo -MockWith { return @{ Name = "other" } }

			$coresVM = [ref]0
			$memoryVM = [ref]0
			$storageVM = [ref]0
			$enabledAddonsList = [ref]$null
			$hooksBackupPath = [ref]""
			$logFilePathBeforeUninstall = [ref]""

			{ PrepareClusterUpgrade -ShowProgress -SkipResources -ShowLogs -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall } | Should -Throw "Upgrade is only available for 'k2s' setup"
		}
	}

	It "should handle errors and log them" {
		InModuleScope $moduleName {
			Mock Get-SetupInfo -MockWith { throw "Unexpected error" }

			$coresVM = [ref]0
			$memoryVM = [ref]0
			$storageVM = [ref]0
			$enabledAddonsList = [ref]$null
			$hooksBackupPath = [ref]""
			$logFilePathBeforeUninstall = [ref]""

			{ PrepareClusterUpgrade -ShowProgress -SkipResources -ShowLogs -Proxy "http://proxy" -BackupDir "C:\Backup" -AdditionalHooksDir "C:\Hooks" -coresVM $coresVM -memoryVM $memoryVM -storageVM $storageVM -enabledAddonsList $enabledAddonsList -hooksBackupPath $hooksBackupPath -logFilePathBeforeUninstall $logFilePathBeforeUninstall } | Should -Throw "Unexpected error"

			# Assert that the mocked functions were called
			Should -Invoke Write-Log -Times 1 -Scope It
		}
	}
}

Describe 'Assert-UpgradeOperation with Force flag' -Tag 'unit', 'ci', 'upgrade' {
	BeforeAll {
		Mock -ModuleName $moduleName Write-Log { }
		Mock -ModuleName $moduleName Get-ClusterInstalledFolder { return "C:\k" }
		Mock -ModuleName $moduleName Get-ClusterCurrentVersion { return "1.0.0" }
		Mock -ModuleName $moduleName Get-ConfigSetupType { return "k2s" }
		Mock -ModuleName $moduleName Get-KubePath { return "C:\k2" }
		Mock -ModuleName $moduleName Restart-ClusterIfBuildVersionMismatch { return $true }
	}

	Context "When Force flag is not set" {
		It "should reject upgrade between non-consecutive versions" {
			InModuleScope $moduleName {
				# Setup: Set product version to simulate a jump of 2 minor versions
				$script:productVersion = "1.2.0"

				# Test
				{ Assert-UpgradeOperation } | Should -Throw "Upgrade not supported from 1.0.0 to 1.2.0*"
			}
		}

		It "should reject upgrade between different major versions" {
			InModuleScope $moduleName {
				# Setup: Set product version to simulate major version change
				$script:productVersion = "2.0.0"

				# Test
				{ Assert-UpgradeOperation } | Should -Throw "Upgrade not supported from 1.0.0 to 2.0.0*"
			}
		}
	}

	Context "When Force flag is set" {
		It "should allow upgrade between non-consecutive versions" {
			InModuleScope $moduleName {
				# Setup: Set product version to simulate a jump of 2 minor versions
				$script:productVersion = "1.2.0"

				# Test
				Assert-UpgradeOperation -Force | Should -Be $true
			}
		}

		It "should allow upgrade between different major versions" {
			InModuleScope $moduleName {
				# Setup: Set product version to simulate major version change
				$script:productVersion = "2.0.0"

				# Test
				Assert-UpgradeOperation -Force | Should -Be $true
			}
		}

		It "should still validate version format" {
			InModuleScope $moduleName {
				# Setup: Set invalid version format
				$script:productVersion = "2.x.0"

				# Test
				{ Assert-UpgradeOperation -Force } | Should -Throw "*Upgrade not supported*"
			}
		}
	}

	Context "Common validation regardless of Force flag" {
		It "should reject when install folders are the same" {
            InModuleScope $moduleName {
                # Setup: Mock Get-ClusterInstalledFolder and Get-KubePath to return same path
                Mock Get-ClusterInstalledFolder { return "C:\same" }
                Mock Get-KubePath { return "C:\same" }
                $script:productVersion = "1.1.0"

                # Test
                { Assert-UpgradeOperation -Force } | Should -Throw "Current cluster is available from same folder*"
            }
        }

		It "should reject when setup type is not k2s" {
			InModuleScope $moduleName {
				# Setup
				Mock Get-ConfigSetupType { return "other" }
				$script:productVersion = "1.1.0"

				# Test
				{ Assert-UpgradeOperation -Force } | Should -Throw "Upgrade only supported in the default variant*"
			}
		}
	}
}