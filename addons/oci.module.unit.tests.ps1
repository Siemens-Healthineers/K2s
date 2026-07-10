# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\oci.module.psm1" -PassThru -Force).Name
}

Describe 'ConvertTo-CanonicalJson' -Tag 'unit', 'ci', 'addon', 'oci' {
    Context 'key ordering' {
        It 'sorts keys lexicographically at top level' {
            InModuleScope $moduleName {
                $result = ConvertTo-CanonicalJson -InputObject @{ z = 1; a = 2; m = 3 }
                $result | Should -Be '{"a":2,"m":3,"z":1}'
            }
        }

        It 'sorts keys at every nesting level' {
            InModuleScope $moduleName {
                $result = ConvertTo-CanonicalJson -InputObject @{ b = @{ y = 1; x = 2 }; a = 0 }
                $result | Should -Be '{"a":0,"b":{"x":2,"y":1}}'
            }
        }
    }

    Context 'string escaping' {
        It 'does not escape solidus (/)' {
            InModuleScope $moduleName {
                $result = ConvertTo-CanonicalJson -InputObject @{ k = 'a/b' }
                $result | Should -Be '{"k":"a/b"}'
            }
        }

        It 'escapes double-quote and backslash' {
            InModuleScope $moduleName {
                $result = ConvertTo-CanonicalJson -InputObject @{ k = 'say "hi"\path' }
                $result | Should -Be '{"k":"say \"hi\"\\path"}'
            }
        }
    }

    Context 'array handling' {
        It 'preserves array element order' {
            InModuleScope $moduleName {
                $result = ConvertTo-CanonicalJson -InputObject @{ arr = @('c', 'a', 'b') }
                $result | Should -Be '{"arr":["c","a","b"]}'
            }
        }
    }
}

Describe 'Get-TarDiffId' -Tag 'unit', 'ci', 'addon', 'oci' {
    Context 'absent layer' {
        It 'returns SHA-256 of empty bytes for null path' {
            InModuleScope $moduleName {
                $result = Get-TarDiffId -Path $null
                # SHA-256("") is a fixed constant
                $result | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            }
        }

        It 'returns SHA-256 of empty bytes for nonexistent path' {
            InModuleScope $moduleName {
                $result = Get-TarDiffId -Path 'C:\does-not-exist-xyz.tar.gz'
                $result | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            }
        }

        It 'returns SHA-256 of empty bytes for empty string path' {
            InModuleScope $moduleName {
                $result = Get-TarDiffId -Path ''
                $result | Should -Be 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            }
        }
    }

    Context 'real tar.gz file' {
        BeforeAll {
            # Build a minimal deterministic tar.gz in a temp directory.
            $script:tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "oci-test-$([System.IO.Path]::GetRandomFileName())"
            New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
            $script:srcDir = Join-Path $script:tmpDir 'src'
            New-Item -ItemType Directory -Path $script:srcDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $script:srcDir 'hello.txt'), 'hello', [System.Text.UTF8Encoding]::new($false))

            $script:tarPath = Join-Path $script:tmpDir 'test.tar.gz'
            # Use deterministic flags matching New-TarGzArchive -ArchiveContents.
            Push-Location $script:srcDir
            try {
                & tar --format=ustar --sort=name --mtime=0 --uid=0 --gid=0 -czf $script:tarPath . 2>&1 | Out-Null
            } finally { Pop-Location }

            # Patch gzip header deterministically (mirrors Set-DeterministicGzipHeader).
            $bytes = [System.IO.File]::ReadAllBytes($script:tarPath)
            $bytes[4] = 0x00; $bytes[5] = 0x00; $bytes[6] = 0x00; $bytes[7] = 0x00
            $bytes[9] = 0xFF
            [System.IO.File]::WriteAllBytes($script:tarPath, $bytes)
        }

        AfterAll {
            Remove-Item -Path $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'returns a 64-char lowercase hex string' {
            InModuleScope $moduleName -Parameters @{ TarPath = $script:tarPath } {
                param($TarPath)
                $result = Get-TarDiffId -Path $TarPath
                $result | Should -Match '^[0-9a-f]{64}$'
            }
        }

        It 'returns the same DiffID for identical content on repeated calls (determinism)' {
            InModuleScope $moduleName -Parameters @{ TarPath = $script:tarPath } {
                param($TarPath)
                $first  = Get-TarDiffId -Path $TarPath
                $second = Get-TarDiffId -Path $TarPath
                $first | Should -Be $second
            }
        }

        It 'DiffID differs from SHA-256 of the compressed blob' {
            InModuleScope $moduleName -Parameters @{ TarPath = $script:tarPath } {
                param($TarPath)
                $diffId      = Get-TarDiffId -Path $TarPath
                $compressedDigest = (Get-FileHash -Path $TarPath -Algorithm SHA256).Hash.ToLower()
                # Compressed and uncompressed digests must differ (they hash different byte streams).
                $diffId | Should -Not -Be $compressedDigest
            }
        }

        It 'DiffID changes when file content changes' {
            InModuleScope $moduleName -Parameters @{ TmpDir = $script:tmpDir } {
                param($TmpDir)
                $srcDir2 = Join-Path $TmpDir 'src2'
                New-Item -ItemType Directory -Path $srcDir2 -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $srcDir2 'hello.txt'), 'CHANGED', [System.Text.UTF8Encoding]::new($false))
                $tarPath2 = Join-Path $TmpDir 'test2.tar.gz'
                Push-Location $srcDir2
                try {
                    & tar --format=ustar --sort=name --mtime=0 --uid=0 --gid=0 -czf $tarPath2 . 2>&1 | Out-Null
                } finally { Pop-Location }
                $bytes = [System.IO.File]::ReadAllBytes($tarPath2)
                $bytes[4] = 0x00; $bytes[5] = 0x00; $bytes[6] = 0x00; $bytes[7] = 0x00; $bytes[9] = 0xFF
                [System.IO.File]::WriteAllBytes($tarPath2, $bytes)

                $originalDiffId = Get-TarDiffId -Path (Join-Path $TmpDir 'test.tar.gz')
                $changedDiffId  = Get-TarDiffId -Path $tarPath2
                $originalDiffId | Should -Not -Be $changedDiffId
            }
        }
    }
}

Describe 'Get-SyncContentHash' -Tag 'unit', 'ci', 'addon', 'oci' {
    # SHA-256 of empty bytes — used as sentinel for absent layers.
    $emptyDiffId = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'

    Context 'return format' {
        It 'returns a 64-char lowercase hex string' {
            InModuleScope $moduleName -Parameters @{ Empty = $emptyDiffId } {
                param($Empty)
                $result = Get-SyncContentHash -AddonName 'test-addon' -AddonVersion '1.0.0' `
                    -DiffIds @($Empty, $Empty, $Empty, $Empty)
                $result | Should -Match '^[0-9a-f]{64}$'
            }
        }
    }

    Context 'determinism' {
        It 'produces the same hash for identical inputs' {
            InModuleScope $moduleName -Parameters @{ Empty = $emptyDiffId } {
                param($Empty)
                $first  = Get-SyncContentHash -AddonName 'my-addon' -AddonVersion '2.3.4' `
                    -DiffIds @($Empty, $Empty, $Empty, $Empty)
                $second = Get-SyncContentHash -AddonName 'my-addon' -AddonVersion '2.3.4' `
                    -DiffIds @($Empty, $Empty, $Empty, $Empty)
                $first | Should -Be $second
            }
        }
    }

    Context 'sensitivity' {
        It 'hash changes when addonName changes' {
            InModuleScope $moduleName -Parameters @{ Empty = $emptyDiffId } {
                param($Empty)
                $h1 = Get-SyncContentHash -AddonName 'addon-a' -AddonVersion '1.0.0' `
                    -DiffIds @($Empty, $Empty, $Empty, $Empty)
                $h2 = Get-SyncContentHash -AddonName 'addon-b' -AddonVersion '1.0.0' `
                    -DiffIds @($Empty, $Empty, $Empty, $Empty)
                $h1 | Should -Not -Be $h2
            }
        }

        It 'hash changes when addonVersion changes' {
            InModuleScope $moduleName -Parameters @{ Empty = $emptyDiffId } {
                param($Empty)
                $h1 = Get-SyncContentHash -AddonName 'addon' -AddonVersion '1.0.0' `
                    -DiffIds @($Empty, $Empty, $Empty, $Empty)
                $h2 = Get-SyncContentHash -AddonName 'addon' -AddonVersion '2.0.0' `
                    -DiffIds @($Empty, $Empty, $Empty, $Empty)
                $h1 | Should -Not -Be $h2
            }
        }

        It 'hash changes when layer 0 DiffID changes' {
            InModuleScope $moduleName -Parameters @{ Empty = $emptyDiffId } {
                param($Empty)
                $fakeDiffId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                $h1 = Get-SyncContentHash -AddonName 'addon' -AddonVersion '1.0.0' `
                    -DiffIds @($Empty,       $Empty, $Empty, $Empty)
                $h2 = Get-SyncContentHash -AddonName 'addon' -AddonVersion '1.0.0' `
                    -DiffIds @($fakeDiffId,  $Empty, $Empty, $Empty)
                $h1 | Should -Not -Be $h2
            }
        }

        It 'hash changes when layer 1 DiffID changes' {
            InModuleScope $moduleName -Parameters @{ Empty = $emptyDiffId } {
                param($Empty)
                $fakeDiffId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                $h1 = Get-SyncContentHash -AddonName 'addon' -AddonVersion '1.0.0' `
                    -DiffIds @($Empty, $Empty,       $Empty, $Empty)
                $h2 = Get-SyncContentHash -AddonName 'addon' -AddonVersion '1.0.0' `
                    -DiffIds @($Empty, $fakeDiffId,  $Empty, $Empty)
                $h1 | Should -Not -Be $h2
            }
        }

        It 'diffIds array order matters (layer 0 != layer 1 swap)' {
            InModuleScope $moduleName -Parameters @{ Empty = $emptyDiffId } {
                param($Empty)
                $diffA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                $diffB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                $h1 = Get-SyncContentHash -AddonName 'addon' -AddonVersion '1.0.0' `
                    -DiffIds @($diffA, $diffB, $Empty, $Empty)
                $h2 = Get-SyncContentHash -AddonName 'addon' -AddonVersion '1.0.0' `
                    -DiffIds @($diffB, $diffA, $Empty, $Empty)
                $h1 | Should -Not -Be $h2
            }
        }
    }

    Context 'canonical JSON structure' {
        It 'input object keys are in expected lexicographic order' {
            # Verify the canonical JSON produced by Get-SyncContentHash matches the expected
            # serialisation from the Phase 0.3 spec: addonName < addonVersion < diffIds.
            InModuleScope $moduleName -Parameters @{ Empty = $emptyDiffId } {
                param($Empty)
                $inputObj = @{
                    addonName    = 'myAddon'
                    addonVersion = '3.1.4'
                    diffIds      = @($Empty, $Empty, $Empty, $Empty)
                }
                $json = ConvertTo-CanonicalJson -InputObject $inputObj
                # Keys must appear in order: addonName, addonVersion, diffIds
                $nameIdx    = $json.IndexOf('"addonName"')
                $versionIdx = $json.IndexOf('"addonVersion"')
                $diffIdx    = $json.IndexOf('"diffIds"')
                $nameIdx    | Should -BeLessThan $versionIdx
                $versionIdx | Should -BeLessThan $diffIdx
            }
        }
    }
}

Describe 'Module exports correct public functions' -Tag 'unit', 'ci', 'addon', 'oci' {
    It 'exports Get-TarDiffId' {
        InModuleScope $moduleName {
            Get-Command -Module $moduleName -Name 'Get-TarDiffId' | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports Get-SyncContentHash' {
        InModuleScope $moduleName {
            Get-Command -Module $moduleName -Name 'Get-SyncContentHash' | Should -Not -BeNullOrEmpty
        }
    }

    It 'exports ConvertTo-CanonicalJson' {
        InModuleScope $moduleName {
            Get-Command -Module $moduleName -Name 'ConvertTo-CanonicalJson' | Should -Not -BeNullOrEmpty
        }
    }

}

Describe 'Tar extraction safety checks' -Tag 'unit', 'ci', 'addon', 'oci' {
    It 'Expand-TarArchive rejects path traversal entries' {
        InModuleScope $moduleName {
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName New-Item { }
            Mock -ModuleName $moduleName tar {
                return @('drwxr-xr-x 0 0 0 0 Jan 1 00:00 good/', '-rw-r--r-- 0 0 0 1 Jan 1 00:00 ../evil.txt')
            } -ParameterFilter { $args -contains '-tvf' }

            { Expand-TarArchive -ArchivePath 'C:\tmp\a.tar' -DestinationPath 'C:\tmp\out' } | Should -Throw '*[OCI] Unsafe tar entry path rejected*'
        }
    }

    It 'Expand-TarGzArchive rejects absolute path entries' {
        InModuleScope $moduleName {
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName New-Item { }
            Mock -ModuleName $moduleName tar {
                return @('-rw-r--r-- 0 0 0 1 Jan 1 00:00 /root/evil.txt')
            } -ParameterFilter { $args -contains '-tvzf' }

            { Expand-TarGzArchive -ArchivePath 'C:\tmp\a.tar.gz' -DestinationPath 'C:\tmp\out' } | Should -Throw '*[OCI] Unsafe tar entry path rejected*'
        }
    }

    It 'Expand-TarArchive rejects symlink entries' {
        InModuleScope $moduleName {
            Mock -ModuleName $moduleName Test-Path { return $true }
            Mock -ModuleName $moduleName New-Item { }
            Mock -ModuleName $moduleName tar {
                return @('lrwxrwxrwx 0 0 0 0 Jan 1 00:00 link -> target')
            } -ParameterFilter { $args -contains '-tvf' }

            { Expand-TarArchive -ArchivePath 'C:\tmp\a.tar' -DestinationPath 'C:\tmp\out' } | Should -Throw '*[OCI] Unsafe tar entry type*'
        }
    }
}
