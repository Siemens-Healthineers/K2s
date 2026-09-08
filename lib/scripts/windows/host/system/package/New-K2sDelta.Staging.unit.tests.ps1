# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

BeforeAll {
    function global:Write-Log { param([string]$Message, [switch]$Console, [switch]$ErrorFlag) }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

    . "$PSScriptRoot\New-K2sDelta.Staging.ps1"

    function New-TestWindowsNodeArtifactsZip {
        param(
            [Parameter(Mandatory = $true)]
            [string] $Path,
            [Parameter(Mandatory = $true)]
            [byte[]] $Content,
            [Parameter(Mandatory = $true)]
            [datetime] $LastWriteTime,
            [string] $EntryName = 'kubetools/kubelet.exe'
        )

        $archive = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry = $archive.CreateEntry($EntryName)
            $entry.LastWriteTime = $LastWriteTime
            $stream = $entry.Open()
            try {
                $stream.Write($Content, 0, $Content.Length)
            }
            finally {
                $stream.Dispose()
            }
        }
        finally {
            $archive.Dispose()
        }
    }
}

Describe 'Copy-WindowsNodeArtifactsToStaging' -Tag 'unit', 'ci', 'k2s', 'package' {
    BeforeAll {
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('K2sDeltaStagingTest_' + [System.Guid]::NewGuid().ToString('N'))
        $script:oldExtract = Join-Path $script:testRoot 'old'
        $script:newExtract = Join-Path $script:testRoot 'new'
        $script:stageDir = Join-Path $script:testRoot 'stage'
        New-Item -ItemType Directory -Path $script:oldExtract, $script:newExtract, $script:stageDir -Force | Out-Null

        $oldZipPath = Join-Path $script:oldExtract 'bin\WindowsNodeArtifacts.zip'
        $newZipPath = Join-Path $script:newExtract 'bin\WindowsNodeArtifacts.zip'
        New-Item -ItemType Directory -Path (Split-Path $oldZipPath -Parent), (Split-Path $newZipPath -Parent) -Force | Out-Null
        $contentBefore = [byte[]]::new(4097)
        $contentAfter = [byte[]]::new(4097)
        $contentAfter[4096] = 1
        $timestamp = [datetime]::SpecifyKind([datetime]::Parse('2025-01-01T00:00:00Z'), [System.DateTimeKind]::Utc)

        New-TestWindowsNodeArtifactsZip -Path $oldZipPath -Content $contentBefore -LastWriteTime $timestamp
        New-TestWindowsNodeArtifactsZip -Path $newZipPath -Content $contentAfter -LastWriteTime $timestamp
    }

    AfterAll {
        if (Test-Path $script:testRoot) { Remove-Item $script:testRoot -Recurse -Force }
    }

    It 'detects content changes after the first 4096 bytes when ZIP metadata matches' {
        $result = Copy-WindowsNodeArtifactsToStaging -Context @{
            OldExtract = $script:oldExtract
            NewExtract = $script:newExtract
            StageDir   = $script:stageDir
        }

        $result.Success | Should -BeTrue
        $result.ChangedFiles | Should -Be 1
        $result.UnchangedFiles | Should -Be 0
        Test-Path (Join-Path $script:stageDir 'bin\kube\kubelet.exe') | Should -BeTrue
    }

    It 'rejects ZIP entries that escape the staging target' {
        $maliciousZipPath = Join-Path $script:newExtract 'bin\WindowsNodeArtifacts.zip'
        Remove-Item -LiteralPath $maliciousZipPath -Force
        New-TestWindowsNodeArtifactsZip -Path $maliciousZipPath -Content ([byte[]](1, 2, 3)) -LastWriteTime ([datetime]::UtcNow) -EntryName 'kubetools/../../outside.exe'

        $result = Copy-WindowsNodeArtifactsToStaging -Context @{
            OldExtract = (Join-Path $script:testRoot 'missing-old')
            NewExtract = $script:newExtract
            StageDir   = $script:stageDir
        }

        $result.Success | Should -BeFalse
        $result.ErrorMessage | Should -Match 'traversal|escapes extraction root'
        Test-Path (Join-Path $script:testRoot 'outside.exe') | Should -BeFalse
    }
}