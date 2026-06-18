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
		Mock -ModuleName $moduleName Test-Path { $false }
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k' -NewPath 'C:\k2s\1.9.0' -NssmPath 'nssm.exe'
		$result.Count | Should -Be 0
	}
}
