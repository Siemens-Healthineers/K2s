# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
	$moduleName = (Import-Module "$PSScriptRoot\services.module.psm1" -PassThru -Force).Name
	Mock -ModuleName $moduleName Write-Log {}

	# Creates a platform-appropriate executable stub that exits with the given code, so the tests run
	# on both Windows (.cmd) and Linux/macOS CI agents (.sh with a shebang + execute bit).
	function New-NssmExitStub {
		param(
			[Parameter(Mandatory = $true)] [int] $ExitCode,
			[Parameter(Mandatory = $true)] [string] $Directory
		)
		if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) {
			$stub = Join-Path $Directory "nssm-stub-$ExitCode.cmd"
			Set-Content -Path $stub -Value "@echo off`r`nexit /b $ExitCode" -NoNewline
		} else {
			$stub = Join-Path $Directory "nssm-stub-$ExitCode.sh"
			Set-Content -Path $stub -Value "#!/bin/sh`nexit $ExitCode" -NoNewline
			& chmod +x $stub
		}
		return $stub
	}
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
		$nssmStub = New-NssmExitStub -ExitCode 0 -Directory $TestDrive
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k\' -NewPath 'C:\k2s\1.9.0\' -NssmPath $nssmStub
		$result.Keys | Should -Contain 'AppDirectory'
		$result['AppDirectory'] | Should -Be 'C:\k'
	}

	It 'does not record a parameter for rollback when nssm returns a non-zero exit code' {
		Mock -ModuleName $moduleName Get-Service { [pscustomobject]@{ Name = 'containerd'; Status = 'Stopped' } }
		Mock -ModuleName $moduleName Test-Path { $true } -ParameterFilter { $LiteralPath -like 'HKLM:\SYSTEM\CurrentControlSet\Services\*\Parameters' }
		Mock -ModuleName $moduleName Get-ItemProperty { [pscustomobject]@{ AppDirectory = 'C:\k' } }
		# nssm stub that fails (e.g. ACL-protected registry key / locked service): exits non-zero.
		$nssmStub = New-NssmExitStub -ExitCode 1 -Directory $TestDrive
		$result = Update-NssmServiceInstallPath -Name 'containerd' -OldPath 'C:\k' -NewPath 'C:\k2s\1.9.0' -NssmPath $nssmStub
		# The failed parameter must NOT be reported as updated, so the caller does not believe
		# the relocation succeeded for a service that still points at the old path.
		$result.Keys | Should -Not -Contain 'AppDirectory'
		$result.Count | Should -Be 0
	}
}


