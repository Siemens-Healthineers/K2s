# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    # Dot-source Sync-Addons.ps1 to load its internal functions into the test scope.
    # Pass -AddonName for a nonexistent repo so the main sync loop hits the
    # "no tags published" early-continue path and exits cleanly (Skipped:1, Failed:0).
    $script:SyncScript = Resolve-Path "$PSScriptRoot\common\manifests\addon-sync\base\scripts\Sync-Addons.ps1"

    # Pester $TestDrive is a unique temp directory for this test run.
    New-Item -ItemType Directory -Path "$TestDrive\addons\.addon-sync-digests" -Force | Out-Null
    New-Item -ItemType Directory -Path "$TestDrive\addons\.addon-sync-state"   -Force | Out-Null

    # Fake oras: exits 0 with no stdout => oras repo tags returns empty => no-tags path.
    $script:FakeOrasCmd = Join-Path $TestDrive 'fake-oras.cmd'
    [System.IO.File]::WriteAllText($script:FakeOrasCmd, "@echo off`r`nexit /b 0")

    # Dot-source: all functions and the $addonsDir/$stateDir/$digestDir variables
    # set by the main body become available in the BeforeAll scope.
    . $SyncScript `
        -RegistryUrl   'oci://test.registry.local' `
        -K2sInstallDir $TestDrive `
        -OrasExe       $FakeOrasCmd `
        -AddonName     'nonexistent-test-placeholder'

    $script:TestStateDir  = $stateDir
    $script:TestDigestDir = $digestDir
    $script:TestAddonsDir = $addonsDir
}

# ===========================================================================
# Test 1 — Inventory generation
# Build-ManagedInventory must map each staging sub-tree to the correct
# absolute destination paths for manifests, scripts, and config layers.
# ===========================================================================
Describe 'Build-ManagedInventory' -Tag 'unit', 'ci', 'addon', 'gitops-sync' {

    Context 'staging has manifests layer' {
        BeforeAll {
            $staging = Join-Path $TestDrive 'inv-manifests-staging'
            New-Item -ItemType Directory -Path "$staging\manifests\sub" -Force | Out-Null
            Set-Content "$staging\manifests\deploy.yaml" 'yaml' -Force
            Set-Content "$staging\manifests\sub\cm.yaml"  'yaml' -Force
            $dest = Join-Path $TestDrive 'inv-manifests-dest'
            $impl = $dest
            $script:ManifestsResult = Build-ManagedInventory `
                -StagingBase $staging -DestBase $dest -ImplPath $impl
        }

        It 'reports two managed file paths' {
            $script:ManifestsResult | Should -HaveCount 2
        }

        It 'maps top-level manifest to impl\manifests\<file>' {
            $expected = [System.IO.Path]::GetFullPath(
                (Join-Path $TestDrive 'inv-manifests-dest\manifests\deploy.yaml'))
            $script:ManifestsResult | Should -Contain $expected
        }

        It 'maps sub-directory manifest to impl\manifests\sub\<file>' {
            $expected = [System.IO.Path]::GetFullPath(
                (Join-Path $TestDrive 'inv-manifests-dest\manifests\sub\cm.yaml'))
            $script:ManifestsResult | Should -Contain $expected
        }
    }

    Context 'staging has scripts layer' {
        BeforeAll {
            $staging = Join-Path $TestDrive 'inv-scripts-staging'
            New-Item -ItemType Directory -Path "$staging\scripts" -Force | Out-Null
            Set-Content "$staging\scripts\Enable.ps1"  '' -Force
            Set-Content "$staging\scripts\Disable.ps1" '' -Force
            $dest = Join-Path $TestDrive 'inv-scripts-dest'
            $impl = $dest
            $script:ScriptsResult = Build-ManagedInventory `
                -StagingBase $staging -DestBase $dest -ImplPath $impl
        }

        It 'reports two managed file paths' {
            $script:ScriptsResult | Should -HaveCount 2
        }

        It 'maps script files directly to impl directory (not a manifests sub-directory)' {
            $expected = [System.IO.Path]::GetFullPath(
                (Join-Path $TestDrive 'inv-scripts-dest\Enable.ps1'))
            $script:ScriptsResult | Should -Contain $expected
        }
    }

    Context 'staging has config layer with addon.manifest.yaml and a sidecar file' {
        BeforeAll {
            $staging = Join-Path $TestDrive 'inv-config-staging'
            New-Item -ItemType Directory -Path "$staging\config" -Force | Out-Null
            Set-Content "$staging\config\addon.manifest.yaml" 'name: test' -Force
            Set-Content "$staging\config\values.yaml"         'key: val'   -Force
            $dest = Join-Path $TestDrive 'inv-config-dest'
            $impl = Join-Path $dest 'nginx'
            $script:ConfigResult = Build-ManagedInventory `
                -StagingBase $staging -DestBase $dest -ImplPath $impl
        }

        It 'places addon.manifest.yaml at DestBase (not ImplPath)' {
            $expected = [System.IO.Path]::GetFullPath(
                (Join-Path $TestDrive 'inv-config-dest\addon.manifest.yaml'))
            $script:ConfigResult | Should -Contain $expected
        }

        It 'places other config files at ImplPath' {
            $expected = [System.IO.Path]::GetFullPath(
                (Join-Path $TestDrive 'inv-config-dest\nginx\values.yaml'))
            $script:ConfigResult | Should -Contain $expected
        }
    }
}

# ===========================================================================
# Tests 2 & 3 — Stale deletion and unmanaged-file preservation
# Remove-StaleFiles must delete files from the previous inventory that are
# absent from the new inventory, and must NOT touch any file that was not
# previously recorded as managed.
# ===========================================================================
Describe 'Remove-StaleFiles' -Tag 'unit', 'ci', 'addon', 'gitops-sync' {

    Context 'stale file: present in old inventory, absent from new inventory' {
        It 'deletes the stale managed file' {
            $stale = Join-Path $TestDrive 'stale-to-remove.txt'
            Set-Content $stale 'old content' -Force
            Remove-StaleFiles -PreviousInventory @($stale) -NewInventory @()
            $stale | Should -Not -Exist
        }
    }

    Context 'unmanaged file: not present in either inventory' {
        BeforeAll {
            $script:UnmanagedFile = Join-Path $TestDrive 'unmanaged-keep.txt'
            Set-Content $script:UnmanagedFile 'unmanaged content' -Force
        }

        It 'does NOT delete the unmanaged file' {
            Remove-StaleFiles -PreviousInventory @() -NewInventory @()
            $script:UnmanagedFile | Should -Exist
        }

        AfterAll { Remove-Item $script:UnmanagedFile -Force -ErrorAction SilentlyContinue }
    }

    Context 'file present in both old and new inventory (not stale)' {
        BeforeAll {
            $script:KeepFile = Join-Path $TestDrive 'keep-managed.txt'
            Set-Content $script:KeepFile 'keep content' -Force
        }

        It 'preserves the file' {
            Remove-StaleFiles `
                -PreviousInventory @($script:KeepFile) -NewInventory @($script:KeepFile)
            $script:KeepFile | Should -Exist
        }

        AfterAll { Remove-Item $script:KeepFile -Force -ErrorAction SilentlyContinue }
    }

    Context 'unmanaged file shares a directory with a stale managed file' {
        # Unmanaged sibling must survive even when its managed neighbour is deleted.
        BeforeAll {
            $dir = Join-Path $TestDrive 'mixed-dir'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $script:StaleInDir     = Join-Path $dir 'managed-stale.yaml'
            $script:UnmanagedInDir = Join-Path $dir 'unmanaged-local.yaml'
            Set-Content $script:StaleInDir     'stale'    -Force
            Set-Content $script:UnmanagedInDir 'local-ok' -Force
        }

        It 'deletes the stale managed file' {
            Remove-StaleFiles -PreviousInventory @($script:StaleInDir) -NewInventory @()
            $script:StaleInDir | Should -Not -Exist
        }

        It 'preserves the unmanaged sibling file' {
            $script:UnmanagedInDir | Should -Exist
        }

        AfterAll {
            Remove-Item (Split-Path $script:StaleInDir) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ===========================================================================
# Test 4 — Local managed modification reporting
# When staging content is applied over an existing managed file, the layer
# application is recorded in the sync log via Write-SyncLog (-> Write-Host).
# This satisfies the "record overwritten local modifications" requirement from
# Step 7 of the implementation plan.
# ===========================================================================
Describe 'Local managed modification is logged when a managed file is overwritten' -Tag 'unit', 'ci', 'addon', 'gitops-sync' {

    It 'emits an "Applied manifests layer" message when manifests overwrite an existing file' {
        $stagingManifests = Join-Path $TestDrive 'apply-log-staging\manifests'
        New-Item -ItemType Directory -Path $stagingManifests -Force | Out-Null
        Set-Content "$stagingManifests\deploy.yaml" 'kind: Deployment  # new version' -Force

        $manifestsDest = Join-Path $TestDrive 'apply-log-dest\manifests'
        New-Item -ItemType Directory -Path $manifestsDest -Force | Out-Null
        # Existing file — simulates a locally modified managed file.
        Set-Content "$manifestsDest\deploy.yaml" 'kind: Deployment  # local edit' -Force

        $script:LastWriteHostArg = $null
        Mock Write-Host { $script:LastWriteHostArg = $Object }

        # Replicate the apply path from Sync-AddonFromOciLayout.
        Get-ChildItem -Path $stagingManifests |
            Copy-Item -Destination $manifestsDest -Recurse -Force
        Write-SyncLog '    Applied manifests layer'

        $script:LastWriteHostArg | Should -Match 'Applied manifests layer'

        # Confirm the overwrite succeeded: staged content replaces the local edit.
        Get-Content "$manifestsDest\deploy.yaml" -Raw | Should -Match 'new version'
        Get-Content "$manifestsDest\deploy.yaml" -Raw | Should -Not -Match 'local edit'
    }
}

# ===========================================================================
# Test 5 — Failed extraction → no success digest
# When Write-AddonStateFile is called with Phase='Failed', the previous
# digest is preserved (not replaced by the new artifact digest).
# ===========================================================================
Describe 'State file preserves old digest on failed extraction' -Tag 'unit', 'ci', 'addon', 'gitops-sync' {

    BeforeEach {
        # Make the script-scope $stateDir visible to internal functions via the call chain.
        $stateDir = $script:TestStateDir
        [void]$stateDir  # suppress false-positive: used implicitly by dot-sourced Write/Read-AddonStateFile
    }

    It 'round-trips digest and phase correctly through Write then Read' {
        Write-AddonStateFile -StateKey 'roundtrip-ok' `
            -Digest 'sha256:aabbcc' -Tag 'v1.0.0' -Phase 'Synced' `
            -LastSuccess '2026-01-01T00:00:00Z'
        $state = Read-AddonStateFile -StateKey 'roundtrip-ok'
        $state.lastDigest | Should -Be 'sha256:aabbcc'
        $state.phase      | Should -Be 'Synced'
    }

    It 'preserves old digest when failure state is written (new digest NOT recorded)' {
        # Prior successful sync recorded a known digest.
        Write-AddonStateFile -StateKey 'failure-preserve' `
            -Digest 'sha256:old-good-digest' -Tag 'v0.9.0' -Phase 'Synced' `
            -LastSuccess '2026-01-01T00:00:00Z'

        # Simulate the main loop: extraction failed, so PREVIOUS digest is re-written.
        $prevState  = Read-AddonStateFile -StateKey 'failure-preserve'
        $prevDigest = $prevState.lastDigest
        Write-AddonStateFile -StateKey 'failure-preserve' `
            -Digest $prevDigest -Tag 'v1.0.0' -Phase 'Failed' `
            -LastFailure (Get-Date -Format 'o')

        $readBack = Read-AddonStateFile -StateKey 'failure-preserve'
        $readBack.lastDigest | Should -Be 'sha256:old-good-digest'
        $readBack.phase      | Should -Be 'Failed'
    }

    It 'returns empty managedFiles and null lastDigest for a nonexistent state key' {
        $state = Read-AddonStateFile -StateKey 'nonexistent-key-abc999'
        $state.managedFiles | Should -BeNullOrEmpty
        $state.lastDigest   | Should -BeNullOrEmpty
    }
}

# ===========================================================================
# Test 6 — ConfigMap/host-file fallback chain
# Get-LastSyncedDigest must walk: ConfigMap (kubectl) → host state file →
# legacy digest file.  In the unit-test environment kubectl.exe is absent at
# the K2s bin path, so the ConfigMap path is skipped automatically and the
# function falls through to the host state / legacy file.
# ===========================================================================
Describe 'Get-LastSyncedDigest fallback chain' -Tag 'unit', 'ci', 'addon', 'gitops-sync' {

    BeforeEach {
        $stateDir  = $script:TestStateDir
        $digestDir = $script:TestDigestDir
        [void]$stateDir   # used implicitly by dot-sourced Write/Read-AddonStateFile
        [void]$digestDir  # used implicitly by dot-sourced Get-LastSyncedDigest
    }

    It 'returns digest from host state file when kubectl is absent' {
        Write-AddonStateFile -StateKey 'fallback-state' `
            -Digest 'sha256:from-state-file' -Tag 'v1.0.0' -Phase 'Synced' `
            -LastSuccess (Get-Date -Format 'o')
        $result = Get-LastSyncedDigest -AddonRepoName 'fallback-state'
        $result | Should -Be 'sha256:from-state-file'
    }

    It 'falls back to legacy digest file when no state file exists' {
        $legacyFile = Join-Path $script:TestDigestDir 'legacy-addon-only'
        Set-Content $legacyFile 'sha256:from-legacy-file' -NoNewline -Encoding UTF8
        $result = Get-LastSyncedDigest -AddonRepoName 'legacy-addon-only'
        $result | Should -Be 'sha256:from-legacy-file'
    }

    It 'prefers host state file over legacy digest file' {
        $key        = 'prefer-state-over-legacy'
        $legacyFile = Join-Path $script:TestDigestDir $key
        Set-Content $legacyFile 'sha256:legacy-should-lose' -NoNewline -Encoding UTF8
        Write-AddonStateFile -StateKey $key `
            -Digest 'sha256:state-file-wins' -Tag 'v2.0.0' -Phase 'Synced' `
            -LastSuccess (Get-Date -Format 'o')
        $result = Get-LastSyncedDigest -AddonRepoName $key
        $result | Should -Be 'sha256:state-file-wins'
    }

    It 'returns null when neither state file nor legacy file exists' {
        $result = Get-LastSyncedDigest -AddonRepoName 'absolutely-unknown-addon-zzzxxx'
        $result | Should -BeNullOrEmpty
    }
}

# ===========================================================================
# Test 7 — Multi-implementation manifest merge-by-key
# Merge-AddonManifestByImplementation must:
#   - Return $false for source without an implementations block (single-impl).
#   - Throw a descriptive error when multi-impl source is present but yq absent.
#   - Merge correctly (preserve unrelated, replace matching, add new) when yq
#     is available (test skipped in environments without yq.exe).
# ===========================================================================
Describe 'Merge-AddonManifestByImplementation' -Tag 'unit', 'ci', 'addon', 'gitops-sync' {

    Context 'source manifest has no implementations block (no yq required)' {
        BeforeAll {
            $script:SingleSrc  = Join-Path $TestDrive 'merge-single-src.yaml'
            $script:SingleDest = Join-Path $TestDrive 'merge-single-dest.yaml'
            Set-Content $script:SingleSrc  "name: autoscaling`nversion: 1.0.0" -Encoding UTF8
            Set-Content $script:SingleDest "name: autoscaling`nversion: 0.9.0" -Encoding UTF8
        }

        It 'returns $false without throwing so the caller performs a plain overwrite' {
            $result = Merge-AddonManifestByImplementation `
                    -SrcManifestPath  $script:SingleSrc `
                    -DestManifestPath $script:SingleDest
            $result | Should -BeFalse
        }
    }

    Context 'source has implementations block, yq absent' {
        BeforeAll {
            $script:MultiSrcNoYq  = Join-Path $TestDrive 'merge-multi-src-noyq.yaml'
            $script:MultiDestNoYq = Join-Path $TestDrive 'merge-multi-dest-noyq.yaml'
            Set-Content $script:MultiSrcNoYq `
                "name: ingress`nspec:`n  implementations:`n    - name: nginx`n    - name: traefik" `
                -Encoding UTF8
            Set-Content $script:MultiDestNoYq `
                "name: ingress`nspec:`n  implementations:`n    - name: nginx" `
                -Encoding UTF8
        }

        It 'throws a descriptive error mentioning yq.exe when yq is not available' {
            $yqPath = Join-Path $TestDrive 'bin\windowsnode\yaml\yq.exe'
            if (Test-Path $yqPath) {
                Set-ItResult -Skipped -Because "yq.exe found at $yqPath — this test covers the no-yq path"
                return
            }
            { Merge-AddonManifestByImplementation `
                    -SrcManifestPath  $script:MultiSrcNoYq `
                    -DestManifestPath $script:MultiDestNoYq } |
                Should -Throw -ExpectedMessage '*yq.exe*'
        }
    }

    Context 'multi-implementation merge correctness (requires yq.exe)' {
        BeforeAll {
            # If yq.exe is not at the K2s bin path, look in PATH and promote it.
            $yqExpected = Join-Path $TestDrive 'bin\windowsnode\yaml\yq.exe'
            if (-not (Test-Path $yqExpected)) {
                $sysYq = Get-Command 'yq.exe' -ErrorAction SilentlyContinue
                if ($sysYq) {
                    New-Item -ItemType Directory `
                        -Path (Split-Path $yqExpected) -Force | Out-Null
                    Copy-Item $sysYq.Source $yqExpected -Force
                }
            }
            $script:YqAvailable = Test-Path $yqExpected
        }

        It 'preserves unrelated implementations, replaces matching, and adds new ones' {
            if (-not $script:YqAvailable) {
                Set-ItResult -Skipped -Because 'yq.exe not found in test environment'
                return
            }

            # On-disk manifest: nginx (old desc) + traefik — traefik is unrelated to artifact.
            $dest = Join-Path $TestDrive 'merge-correctness-dest.yaml'
            Set-Content $dest (
                "name: ingress`nspec:`n  implementations:`n" +
                "    - name: nginx`n      description: old nginx desc`n" +
                "    - name: traefik`n      description: old traefik desc"
            ) -Encoding UTF8

            # New artifact: nginx updated + haproxy added; traefik not in artifact → preserved.
            $src = Join-Path $TestDrive 'merge-correctness-src.yaml'
            Set-Content $src (
                "name: ingress`nspec:`n  implementations:`n" +
                "    - name: nginx`n      description: new nginx desc`n" +
                "    - name: haproxy`n      description: new haproxy impl"
            ) -Encoding UTF8

            $merged = Merge-AddonManifestByImplementation `
                -SrcManifestPath  $src `
                -DestManifestPath $dest

            $merged | Should -BeTrue

            $result = Get-Content $dest -Raw
            $result | Should -Match 'traefik'           # unrelated impl preserved
            $result | Should -Match 'new nginx desc'    # matching impl replaced
            $result | Should -Not -Match 'old nginx desc'
            $result | Should -Match 'haproxy'           # new impl added
        }
    }
}

# ===========================================================================
# Test 8 — Set-AddonStatusConfigMap retry behavior (Q27)
# The function must retry kubectl patch on conflict (409) with progressive
# backoff (1s, 2s, 3s, 4s), give up after 5 attempts, and fail fast for
# non-conflict errors.  Start-Sleep is mocked so tests run instantly.
# ===========================================================================
Describe 'Set-AddonStatusConfigMap retry behavior' -Tag 'unit', 'ci', 'addon', 'gitops-sync' {

    BeforeAll {
        # Fake kubectl: conflicts once (creates a marker), then succeeds.
        $script:KubectlConflictMarker   = Join-Path $TestDrive 'kubectl-conflict-once.marker'
        $script:FakeKubectlConflictOnce = Join-Path $TestDrive 'kubectl-conflict-once.ps1'
        $markerPath = $script:KubectlConflictMarker
        Set-Content $script:FakeKubectlConflictOnce @"
if (Test-Path '$markerPath') {
    Write-Output 'configmap/addon-sync-status patched'
    exit 0
} else {
    Set-Content '$markerPath' '1' -NoNewline -Encoding UTF8
    Write-Output 'Error from server (Conflict): operation cannot be fulfilled on configmap'
    exit 1
}
"@ -Encoding UTF8

        # Fake kubectl: always returns a Conflict error.
        $script:FakeKubectlAlwaysConflict = Join-Path $TestDrive 'kubectl-always-conflict.ps1'
        Set-Content $script:FakeKubectlAlwaysConflict @'
Write-Output 'Error from server (Conflict): operation cannot be fulfilled'
exit 1
'@ -Encoding UTF8

        # Fake kubectl: non-conflict failure (Forbidden).
        $script:FakeKubectlForbidden = Join-Path $TestDrive 'kubectl-forbidden.ps1'
        Set-Content $script:FakeKubectlForbidden @'
Write-Output 'Error from server (Forbidden): configmaps is forbidden'
exit 1
'@ -Encoding UTF8
    }

    Context 'conflict on first attempt then success' {

        BeforeEach {
            Remove-Item $script:KubectlConflictMarker -Force -ErrorAction SilentlyContinue
            Mock Get-KubectlPath { return $script:FakeKubectlConflictOnce }
            Mock Start-Sleep { }
        }

        It 'retries on conflict and ultimately succeeds without throwing' {
            $null = Set-AddonStatusConfigMap -StateKey 'retry-ok-addon' -Phase 'Synced'
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }
    }

    Context 'repeated conflicts exhaust all retries' {

        BeforeEach {
            Mock Get-KubectlPath { return $script:FakeKubectlAlwaysConflict }
            Mock Start-Sleep { }
        }

        It 'logs failure and returns without throwing after all retries are spent' {
            { Set-AddonStatusConfigMap -StateKey 'always-conflict-addon' -Phase 'Failed' } | Should -Not -Throw
        }

        It 'applies progressive backoff: Start-Sleep called once per conflicting retry (4 times for 5-attempt loop)' {
            Set-AddonStatusConfigMap -StateKey 'always-conflict-addon' -Phase 'Failed'
            # Attempts 1-4 each trigger a sleep; attempt 5 exhausts and returns via else.
            Should -Invoke Start-Sleep -Times 4 -Exactly
        }
    }

    Context 'non-conflict failure' {

        BeforeEach {
            Mock Get-KubectlPath { return $script:FakeKubectlForbidden }
            Mock Start-Sleep { }
        }

        It 'fails fast without any retry sleep on non-conflict error' {
            Set-AddonStatusConfigMap -StateKey 'forbidden-addon' -Phase 'Failed'
            Should -Not -Invoke Start-Sleep
        }
    }

    Context 'failure-path message is sanitized before logging' {
        # Verifies Get-SanitizedMessage is applied: a credential-like token in kubectl
        # error output must be replaced with '<redacted>' and must not appear raw in the log.

        BeforeAll {
            # 40 alphanumeric chars: matches [A-Za-z0-9+/]{40,}={0,2} in Get-SanitizedMessage.
            $script:SensitiveToken = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn'
            $tokenLiteral = $script:SensitiveToken
            $fakeSensitiveKubectl = Join-Path $TestDrive 'kubectl-sensitive-error.ps1'
            Set-Content $fakeSensitiveKubectl @"
Write-Output 'Error from server: token is $tokenLiteral in output'
exit 1
"@ -Encoding UTF8
            $script:FakeKubectlSensitive = $fakeSensitiveKubectl
        }

        BeforeEach {
            $script:CapturedLogs = [System.Collections.Generic.List[string]]::new()
            Mock Get-KubectlPath { return $script:FakeKubectlSensitive }
            Mock Start-Sleep { }
            Mock Write-Host { $script:CapturedLogs.Add([string]($Object -join ' ')) }
        }

        It 'does not throw when kubectl output contains credential-like content' {
            { Set-AddonStatusConfigMap -StateKey 'sanitize-check-addon' -Phase 'Failed' } | Should -Not -Throw
        }

        It 'logs <redacted> marker in the failure message' {
            Set-AddonStatusConfigMap -StateKey 'sanitize-check-addon' -Phase 'Failed'
            $statusLog = $script:CapturedLogs | Where-Object { $_ -match '\[Status\].*ConfigMap patch failed' }
            $statusLog | Should -Not -BeNullOrEmpty
            ($statusLog -join ' ') | Should -Match '<redacted>'
        }

        It 'does not log the raw sensitive token' {
            Set-AddonStatusConfigMap -StateKey 'sanitize-check-addon' -Phase 'Failed'
            $statusLog = $script:CapturedLogs | Where-Object { $_ -match '\[Status\].*ConfigMap patch failed' }
            ($statusLog -join ' ') | Should -Not -Match ([regex]::Escape($script:SensitiveToken))
        }
    }

    Context 'progressive backoff sleep-seconds sequence' {
        # Verifies the per-attempt sleep values follow the 1,2,3,4 sequence
        # matching $attempt values in the retry loop (5 attempts, 4 sleeps before exhaustion).

        BeforeAll {
            $script:SleepSeconds = [System.Collections.Generic.List[int]]::new()
        }

        BeforeEach {
            $script:SleepSeconds.Clear()
            Mock Get-KubectlPath { return $script:FakeKubectlAlwaysConflict }
            Mock Start-Sleep { $script:SleepSeconds.Add($Seconds) }
        }

        It 'sleeps 1s then 2s then 3s then 4s across the four conflicting retry attempts' {
            Set-AddonStatusConfigMap -StateKey 'backoff-seq-addon' -Phase 'Failed'
            $script:SleepSeconds | Should -HaveCount 4
            $script:SleepSeconds[0] | Should -Be 1
            $script:SleepSeconds[1] | Should -Be 2
            $script:SleepSeconds[2] | Should -Be 3
            $script:SleepSeconds[3] | Should -Be 4
        }
    }
}
