# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\base-image.module.psm1"
    $moduleName = (Import-Module $module -PassThru -Force).Name

    Mock -ModuleName $moduleName Write-Log { }
}

Describe 'Get-Sha512HexLower' -Tag 'unit', 'ci', 'k2s', 'linuxnode' {
    Context 'known content' {
        It 'returns lowercase 128-char hex matching expected SHA512' {
            InModuleScope $moduleName {
                $tmpFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
                try {
                    [System.IO.File]::WriteAllText($tmpFile, 'hello k2s')

                    # Compute expected hash independently
                    $sha = [System.Security.Cryptography.SHA512]::Create()
                    try {
                        $stream = [System.IO.File]::OpenRead($tmpFile)
                        try {
                            $bytes = $sha.ComputeHash($stream)
                        }
                        finally {
                            $stream.Dispose()
                        }
                    }
                    finally {
                        $sha.Dispose()
                    }
                    $expected = [System.BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()

                    $result = Get-Sha512HexLower -LiteralPath $tmpFile

                    $result | Should -Be $expected
                    $result | Should -Match '^[a-f0-9]{128}$'
                }
                finally {
                    if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force }
                }
            }
        }
    }

    Context 'non-existent file' {
        It 'throws for a path that does not exist' {
            InModuleScope $moduleName {
                $missing = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'does-not-exist-k2s-test.bin')

                { Get-Sha512HexLower -LiteralPath $missing } | Should -Throw
            }
        }
    }
}
