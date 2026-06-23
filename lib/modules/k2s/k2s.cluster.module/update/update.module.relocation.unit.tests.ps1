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

	It 'seeds missing files in a wholesale directory without overwriting delta-provided files' {
		# The new folder's wholesale dir already has the delta's new1.txt (a changed file) but is
		# missing old1.txt/old2.txt (unchanged binaries). Those must be seeded so e.g. an unchanged
		# containerd.exe is not lost, while the delta's newer file is preserved.
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir', 'otherdir') | Out-Null
		(Test-Path (Join-Path $new 'wholedir\old1.txt')) | Should -BeTrue
		(Test-Path (Join-Path $new 'wholedir\old2.txt')) | Should -BeTrue
		(Test-Path (Join-Path $new 'wholedir\new1.txt')) | Should -BeTrue
		Get-Content (Join-Path $new 'wholedir\new1.txt') -Raw | Should -Be 'new-1'
	}

	It 'seeds an empty wholesale directory from the previous installation (offline-package case)' {
		# Reproduces the real failure: bin\containerd is staged EMPTY in the delta (binaries live in
		# WindowsNodeArtifacts.zip), so its unchanged binaries must be seeded or containerd cannot start.
		New-Item -ItemType Directory -Path (Join-Path $new 'wholedir-empty') -Force | Out-Null
		New-Item -ItemType Directory -Path (Join-Path $old 'wholedir-empty') -Force | Out-Null
		Set-Content -Path (Join-Path $old 'wholedir-empty\containerd.exe') -Value 'binary' -NoNewline
		Copy-UnchangedInstallationFiles -OldInstallPath $old -NewInstallPath $new -WholesaleDirs @('wholedir-empty') | Out-Null
		(Test-Path (Join-Path $new 'wholedir-empty\containerd.exe')) | Should -BeTrue
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

Describe 'Set-K2sInstallationHome' -Tag 'unit', 'ci', 'update' {
	It 'returns false when the services module is missing at the destination' {
		# Empty destination: lib\...\services.module.psm1 is absent, so the function aborts early
		# before touching any service, machine environment variable, or setup.json. This intentionally
		# returns before importing any module so the test never loads a stub named 'services.module'.
		$to = Join-Path $TestDrive 'to-no-services'
		New-Item -ItemType Directory -Path $to -Force | Out-Null
		$result = Set-K2sInstallationHome -FromPath (Join-Path $TestDrive 'from') -ToPath $to
		$result | Should -BeFalse
	}
}

Describe 'Select-PrunableRemovedFile' -Tag 'unit', 'ci', 'update' {
	It 'keeps genuine removals outside bin and wholesale directories' {
		$removed = @('lib/manifests/clusterip-webhook/certgen-create-job.yaml', 'cfg/old-thing.yaml')
		$result = Select-PrunableRemovedFile -RemovedFiles $removed -WholesaleDirs @('bin/cni', 'bin/containerd')
		$result | Should -Contain 'lib/manifests/clusterip-webhook/certgen-create-job.yaml'
		$result | Should -Contain 'cfg/old-thing.yaml'
		$result.Count | Should -Be 2
	}

	It 'never prunes essential binaries or other files under bin/' {
		# Reproduces the real-world false positives that broke the re-home (nssm.exe deleted).
		$removed = @('bin/nssm.exe', 'bin/helm.exe', 'bin/jq.exe', 'bin/crictl.yaml', 'bin/containerd/ctr.exe')
		$result = Select-PrunableRemovedFile -RemovedFiles $removed -WholesaleDirs @('bin/containerd')
		$result.Count | Should -Be 0
	}

	It 'excludes files under an explicit wholesale directory even outside bin' {
		$removed = @('addons/registry/old.yaml', 'data/stale.txt')
		$result = Select-PrunableRemovedFile -RemovedFiles $removed -WholesaleDirs @('addons/registry')
		$result | Should -Not -Contain 'addons/registry/old.yaml'
		$result | Should -Contain 'data/stale.txt'
	}

	It 'handles backslash separators and empty entries' {
		$removed = @('bin\nssm.exe', '', 'lib\foo\bar.yaml')
		$result = Select-PrunableRemovedFile -RemovedFiles $removed -WholesaleDirs @()
		$result | Should -Not -Contain 'bin\nssm.exe'
		$result | Should -Contain 'lib\foo\bar.yaml'
		$result.Count | Should -Be 1
	}
}

Describe 'Get-GuestConfigApplyAllowlist' -Tag 'unit', 'ci', 'update' {
	It 'allows only /usr/local/bin host tools by default' {
		$allow = Get-GuestConfigApplyAllowlist
		$allow | Should -Contain '/usr/local/bin/'
		$allow.Count | Should -Be 1
	}
}

Describe 'Test-GuestConfigApplyAllowed' -Tag 'unit', 'ci', 'update' {
	It 'permits the Linux helm and yq host tools' {
		Test-GuestConfigApplyAllowed 'usr/local/bin/helm' | Should -BeTrue
		Test-GuestConfigApplyAllowed 'usr/local/bin/yq' | Should -BeTrue
	}

	It 'permits absolute and backslash forms of allowlisted paths' {
		Test-GuestConfigApplyAllowed '/usr/local/bin/helm' | Should -BeTrue
		Test-GuestConfigApplyAllowed 'usr\local\bin\yq' | Should -BeTrue
	}

	It 'rejects cluster-identity files even though creation already excludes them' {
		Test-GuestConfigApplyAllowed 'etc/kubernetes/admin.conf' | Should -BeFalse
		Test-GuestConfigApplyAllowed 'etc/kubernetes/pki/ca.crt' | Should -BeFalse
		Test-GuestConfigApplyAllowed 'var/lib/kubelet/config.yaml' | Should -BeFalse
	}

	It 'rejects other system binaries outside the allowlist' {
		Test-GuestConfigApplyAllowed 'usr/bin/helm' | Should -BeFalse
		Test-GuestConfigApplyAllowed 'lib/systemd/system/kubelet.service' | Should -BeFalse
	}

	It 'rejects empty or null input' {
		Test-GuestConfigApplyAllowed '' | Should -BeFalse
		Test-GuestConfigApplyAllowed $null | Should -BeFalse
	}
}

Describe 'Invoke-GuestConfigDeltaApply' -Tag 'unit', 'ci', 'update' {
	It 'returns success with nothing applied when the manifest has no guest-config payload' {
		$manifest = [pscustomobject]@{ GuestConfigRelativePath = $null }
		$result = Invoke-GuestConfigDeltaApply -DeltaRoot $TestDrive -Manifest $manifest
		$result.Success | Should -BeTrue
		$result.Applied.Count | Should -Be 0
	}

	It 'skips all entries and never reaches the VM when only non-allowlisted files are present' {
		$deltaRoot = Join-Path $TestDrive 'delta'
		$guestDir = Join-Path $deltaRoot 'guest-config'
		New-Item -ItemType Directory -Path (Join-Path $guestDir 'etc\kubernetes') -Force | Out-Null
		Set-Content -Path (Join-Path $guestDir 'etc\kubernetes\admin.conf') -Value 'secret' -NoNewline
		$manifest = [pscustomobject]@{
			GuestConfigRelativePath = 'guest-config'
			GuestConfigDiff         = [pscustomobject]@{ CopiedFiles = @('etc/kubernetes/admin.conf') }
		}
		$result = Invoke-GuestConfigDeltaApply -DeltaRoot $deltaRoot -Manifest $manifest
		$result.Applied.Count | Should -Be 0
		$result.Skipped | Should -Contain 'etc/kubernetes/admin.conf'
	}
}

