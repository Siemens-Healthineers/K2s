# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
	$moduleName = (Import-Module "$PSScriptRoot\services.module.psm1" -PassThru -Force).Name
	Mock -ModuleName $moduleName Write-Log {}
}

Describe 'Update-NssmServiceInstallPath' -Tag 'unit', 'ci', 'update' {
	It 'returns an empty result when the service does not exist' {
		Mock -ModuleName $moduleName Get-Service { $null }
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k' -NewPath 'C:\k2s\1.9.0' -NssmPath 'nssm.exe'
		$result.Count | Should -Be 0
	}

	It 'returns an empty result when the nssm registry parameters are missing' {
		Mock -ModuleName $moduleName Get-Service { [pscustomobject]@{ Name = 'containerd'; Status = 'Stopped' } }
		# Scope the mock to the service Parameters registry key so unrelated Test-Path calls are not intercepted.
		Mock -ModuleName $moduleName Test-Path { $false } -ParameterFilter { $LiteralPath -like 'HKLM:\SYSTEM\CurrentControlSet\Services\*\Parameters' }
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k' -NewPath 'C:\k2s\1.9.0' -NssmPath 'nssm.exe'
		$result.Count | Should -Be 0
	}

	It 'trims trailing backslashes from OldPath so an exact-root registry value still matches' {
		Mock -ModuleName $moduleName Get-Service { [pscustomobject]@{ Name = 'containerd'; Status = 'Stopped' } }
		Mock -ModuleName $moduleName Test-Path { $true } -ParameterFilter { $LiteralPath -like 'HKLM:\SYSTEM\CurrentControlSet\Services\*\Parameters' }
		# AppDirectory is exactly the install root; without trimming, OldPath 'C:\k\' would not match it.
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ AppDirectory = 'C:\k' } }
		# Harmless real executable stub so the internal '& $NssmPath set ...' call exits cleanly.
		$nssmStub = Join-Path $TestDrive 'nssm.cmd'
		Set-Content -Path $nssmStub -Value "@echo off`r`nexit /b 0" -NoNewline
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k\' -NewPath 'C:\k2s\1.9.0\' -NssmPath $nssmStub
		$result.Keys | Should -Contain 'AppDirectory'
		$result['AppDirectory'] | Should -Be 'C:\k'
	}
}


