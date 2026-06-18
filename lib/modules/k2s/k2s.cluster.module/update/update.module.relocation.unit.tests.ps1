# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
	$moduleName = (Import-Module "$PSScriptRoot\update.module.psm1" -PassThru -Force).Name
	Mock -ModuleName $moduleName Write-Log {}
}

Describe 'Get-K2sManagedServiceName' -Tag 'unit', 'ci', 'update' {
	It 'returns the K2s-managed Windows services' {
		$services = Get-K2sManagedServiceName
		$services | Should -Contain 'containerd'
		$services | Should -Contain 'kubelet'
		$services | Should -Contain 'kubeproxy'
		$services | Should -Contain 'flanneld'
		$services | Should -Contain 'dnsproxy'
		$services | Should -Contain 'httpproxy'
		$services | Should -Contain 'windows_exporter'
		$services | Should -Contain 'docker'
	}

	It 'contains no duplicate entries' {
		$services = Get-K2sManagedServiceName
		($services | Sort-Object -Unique).Count | Should -Be $services.Count
	}
}

Describe 'Copy-UnchangedInstallationFiles' -Tag 'unit', 'ci', 'update' {
	BeforeEach {
		$old = Join-Path $TestDrive 'old'
		$new = Join-Path $TestDrive 'new'
		New-Item -ItemType Directory -Path $old -Force | Out-Null
		New-Item -ItemType Directory -Path $new -Force | Out-Null

		# Previous installation (seed source)
		Set-Content -Path (Join-Path $old 'a.txt') -Value 'old-a' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $old 'sub') -Force | Out-Null
		Set-Content -Path (Join-Path $old 'sub\b.txt') -Value 'old-b' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $old 'wholedir') -Force | Out-Null
		Set-Content -Path (Join-Path $old 'wholedir\old1.txt') -Value 'old-1' -NoNewline
		Set-Content -Path (Join-Path $old 'wholedir\old2.txt') -Value 'old-2' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $old 'otherdir') -Force | Out-Null
		Set-Content -Path (Join-Path $old 'otherdir\c.txt') -Value 'old-c' -NoNewline

		# New installation (delta package directory) - already contains changed + wholesale files
		Set-Content -Path (Join-Path $new 'a.txt') -Value 'new-a' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $new 'wholedir') -Force | Out-Null
		Set-Content -Path (Join-Path $new 'wholedir\new1.txt') -Value 'new-1' -NoNewline
	}

	It 'seeds files that are missing in the new folder' {
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir', 'otherdir') | Should -BeTrue
		(Test-Path (Join-Path $new 'sub\b.txt')) | Should -BeTrue
		Get-Content (Join-Path $new 'sub\b.txt') -Raw | Should -Be 'old-b'
	}

	It 'does not overwrite files that already exist (changed delta files)' {
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir', 'otherdir') | Out-Null
		Get-Content (Join-Path $new 'a.txt') -Raw | Should -Be 'new-a'
	}

	It 'excludes wholesale directories that the delta already provides in the new folder' {
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir', 'otherdir') | Out-Null
		(Test-Path (Join-Path $new 'wholedir\old1.txt')) | Should -BeFalse
		(Test-Path (Join-Path $new 'wholedir\old2.txt')) | Should -BeFalse
		(Test-Path (Join-Path $new 'wholedir\new1.txt')) | Should -BeTrue
	}

	It 'seeds wholesale directories that did not change (absent in the new folder)' {
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir', 'otherdir') | Out-Null
		(Test-Path (Join-Path $new 'otherdir\c.txt')) | Should -BeTrue
		Get-Content (Join-Path $new 'otherdir\c.txt') -Raw | Should -Be 'old-c'
	}
}

Describe 'Remove-DeltaPackageArtifact' -Tag 'unit', 'ci', 'update' {
	It 'removes delta-only artifacts and keeps installation files' {
		$install = Join-Path $TestDrive 'install'
		New-Item -ItemType Directory -Path $install -Force | Out-Null
		Set-Content -Path (Join-Path $install 'delta-manifest.json') -Value '{}' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $install 'image-delta') -Force | Out-Null
		Set-Content -Path (Join-Path $install 'image-delta\img.tar') -Value 'x' -NoNewline
		New-Item -ItemType Directory -Path (Join-Path $install 'debian-delta') -Force | Out-Null
		Set-Content -Path (Join-Path $install 'k2s.exe') -Value 'binary' -NoNewline

		Remove-DeltaPackageArtifact -InstallPath $install

		(Test-Path (Join-Path $install 'delta-manifest.json')) | Should -BeFalse
		(Test-Path (Join-Path $install 'image-delta')) | Should -BeFalse
		(Test-Path (Join-Path $install 'debian-delta')) | Should -BeFalse
		(Test-Path (Join-Path $install 'k2s.exe')) | Should -BeTrue
	}

	It 'does not fail when no delta artifacts are present' {
		$install = Join-Path $TestDrive 'install2'
		New-Item -ItemType Directory -Path $install -Force | Out-Null
		Set-Content -Path (Join-Path $install 'k2s.exe') -Value 'binary' -NoNewline
		{ Remove-DeltaPackageArtifact -InstallPath $install } | Should -Not -Throw
		(Test-Path (Join-Path $install 'k2s.exe')) | Should -BeTrue
	}
}
