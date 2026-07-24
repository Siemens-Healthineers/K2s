# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

BeforeAll {
    function global:Write-Log { param([string]$Message, [switch]$Console, [switch]$Error) }

    . "$PSScriptRoot\New-K2sDelta.Hash.ps1"
}

Describe 'Get-Sha256HexLower' -Tag 'unit', 'ci', 'k2s', 'package' {

    BeforeAll {
        $script:tempFile = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($script:tempFile, 'Hello, K2s!', [System.Text.Encoding]::ASCII)

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes('Hello, K2s!')
            $hashBytes = $sha256.ComputeHash($bytes)
        }
        finally {
            $sha256.Dispose()
        }
        $script:expectedHash = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
    }

    AfterAll {
        if (Test-Path $script:tempFile) { Remove-Item $script:tempFile -Force }
    }

    It 'returns the correct SHA-256 hex digest for known ASCII content' {
        $result = Get-Sha256HexLower -LiteralPath $script:tempFile
        $result | Should -Be $script:expectedHash
    }

    It 'result matches lowercase hex pattern ^[a-f0-9]{64}$' {
        $result = Get-Sha256HexLower -LiteralPath $script:tempFile
        $result | Should -Match '^[a-f0-9]{64}$'
    }
}

Describe 'Get-FileMap backward-compat fields' -Tag 'unit', 'ci', 'k2s', 'package' {

    BeforeAll {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('K2sDeltaHashTest_' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:tempDir | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:tempDir 'sample.txt'), 'test data', [System.Text.Encoding]::ASCII)
    }

    AfterAll {
        if (Test-Path $script:tempDir) { Remove-Item $script:tempDir -Recurse -Force }
    }

    It 'each entry has both .Hash and .Sha256 fields' {
        $map = Get-FileMap -root $script:tempDir -label test
        $map.Count | Should -Be 1
        foreach ($key in $map.Keys) {
            $entry = $map[$key]
            $entry.PSObject.Properties.Name | Should -Contain 'Hash'
            $entry.PSObject.Properties.Name | Should -Contain 'Sha256'
        }
    }

    It '.Hash and .Sha256 are equal and non-empty' {
        $map = Get-FileMap -root $script:tempDir -label test
        foreach ($key in $map.Keys) {
            $entry = $map[$key]
            $entry.Hash | Should -Not -BeNullOrEmpty
            $entry.Sha256 | Should -Not -BeNullOrEmpty
            $entry.Hash | Should -Be $entry.Sha256
        }
    }
}
