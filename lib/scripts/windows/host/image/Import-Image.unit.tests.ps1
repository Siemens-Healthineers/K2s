# SPDX-FileCopyrightText:  © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot/Image-Common.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe 'Image import helpers' -Tag 'unit', 'ci', 'image' {
    It 'returns preflight failures instead of exiting when return-status mode is requested' {
        InModuleScope $moduleName {
            Mock Test-SystemAvailability { [PSCustomObject]@{ Message = 'cluster unavailable' } }

            $result = Initialize-ImageScriptContext -ReturnStatus

            $result | Should -BeFalse
        }
    }

    It 'reports a failed Linux remote import using the result Success property and attempts cleanup' {
        InModuleScope $moduleName {
            Mock Copy-ToRemoteComputerViaSshKey {}
            $script:remoteCommandCount = 0
            Mock Invoke-CmdOnVmViaSSHKey {
                $script:remoteCommandCount++
                if ($script:remoteCommandCount -eq 1) {
                    return [PSCustomObject]@{ Success = $false; Output = 'remote import failed' }
                }
                return [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'image.tar' -NodeInfo @{
                Kind = 'LinuxWorker'
                Name = 'worker-1'
                Username = 'k2s'
                IpAddress = '192.0.2.1'
            }

            $result | Should -BeFalse
            $script:remoteCommandCount | Should -Be 2
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 2 -Exactly
        }
    }

    It 'reports Linux copy exceptions, skips import, and still attempts remote cleanup' {
        InModuleScope $moduleName {
            Mock Copy-ToRemoteComputerViaSshKey { throw 'copy failed' }
            Mock Invoke-CmdOnVmViaSSHKey {
                [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'image.tar' -NodeInfo @{
                Kind = 'LinuxWorker'
                Name = 'worker-1'
                Username = 'k2s'
                IpAddress = '192.0.2.1'
            }

            $result | Should -BeFalse
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Times 1 -Exactly
        }
    }

    It 'does not treat ctr output plus a false status as a successful import' {
        InModuleScope $moduleName {
            $result = Test-ImageImportSuccess -Result @('ctr import failed', $false)

            $result | Should -BeFalse
            (Test-ImageImportSuccess -Result ([PSCustomObject]@{ Success = $false; Output = 'ctr import failed' })) | Should -BeFalse
            (Test-ImageImportSuccess -Result ([PSCustomObject]@{ Success = $true; Output = '' })) | Should -BeTrue
        }
    }

    Context 'Linux image import routing for single- and multi-image archives' {
        BeforeAll {
            function New-TestManifestEntries {
                param([int]$Count)
                @(1..$Count | ForEach-Object {
                        [PSCustomObject]@{ Config = "config$_.json"; RepoTags = @("example.local/image${_}:v1"); Layers = @("layer$_.tar") }
                    })
            }

            $script:controlPlane = @{ Kind = 'ControlPlane'; Name = 'control-plane' }
            $script:cleanupCommand = 'sudo rm -f /tmp/import.tar'
            $script:legacyDockerCommand = 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1'
            $script:legacyOciCommand = 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1'
        }

        BeforeEach {
            $script:executedCommands = [System.Collections.Generic.List[string]]::new()
            $script:failingCommands = @()
            $script:cleanupSucceeds = $true
            $script:manifestInfo = [PSCustomObject]@{ State = 'NotFound'; Entries = @() }

            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-DockerArchiveManifestInfo { $script:manifestInfo }
            Mock -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey {}
            Mock -ModuleName $moduleName Copy-ToRemoteComputerViaSshKey {}
            $commandMock = {
                $script:executedCommands.Add([string]$CmdToExecute)
                $succeeded = if ($CmdToExecute -eq $script:cleanupCommand) { $script:cleanupSucceeds } else { $script:failingCommands -notcontains $CmdToExecute }
                [PSCustomObject]@{ Success = $succeeded; Output = '' }
            }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey $commandMock
            Mock -ModuleName $moduleName Invoke-CmdOnVmViaSSHKey $commandMock
        }

        It 'keeps the unindexed docker-archive command for a single-entry archive with -DockerArchive' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 1) }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 1 -Exactly
        }

        It 'keeps the unindexed oci-archive command for a single-entry archive without -DockerArchive' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 1) }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyOciCommand|$script:cleanupCommand"
        }

        It 'imports each entry of a two-entry archive once, in order, with an indexed selector' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2) }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@(
                    'sudo buildah pull docker-archive:/tmp/import.tar:@0 2>&1'
                    'sudo buildah pull docker-archive:/tmp/import.tar:@1 2>&1'
                    $script:cleanupCommand
                ) -join '|')
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter { $Source -eq 'C:\images\multi.tar' -and $Target -eq '/tmp/import.tar' }
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Times 2 -Exactly -ParameterFilter {
                $CmdToExecute -like 'sudo buildah pull docker-archive:/tmp/import.tar:@* 2>&1' -and $Retries -eq 3 -and $Timeout -eq 10 -and $NoLog
            }
        }

        It 'automatically uses docker-archive selectors @0..@4 for a five-entry archive without -DockerArchive' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 5) }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            $expected = @(0..4 | ForEach-Object { "sudo buildah pull docker-archive:/tmp/import.tar:@$_ 2>&1" }) + $script:cleanupCommand
            ($script:executedCommands -join '|') | Should -BeExactly ($expected -join '|')
            @($script:executedCommands | Where-Object { $_ -like '*oci-archive*' }).Count | Should -Be 0
        }

        It 'issues a single pull for an entry with multiple RepoTags and no separate tag commands' {
            $entries = New-TestManifestEntries -Count 2
            $entries[0].RepoTags = @('example.local/python:3', 'example.local/python:3.14')
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            $script:executedCommands.Count | Should -Be 3
            @($script:executedCommands | Where-Object { $_ -eq 'sudo buildah pull docker-archive:/tmp/import.tar:@0 2>&1' }).Count | Should -Be 1
            @($script:executedCommands | Where-Object { $_ -match 'buildah tag' }).Count | Should -Be 0
        }

        It 'imports an untagged entry, logs a warning, and does not fail because of the missing tags' {
            $entries = New-TestManifestEntries -Count 2
            $entries[1].RepoTags = $null
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            $script:executedCommands | Should -Contain 'sudo buildah pull docker-archive:/tmp/import.tar:@1 2>&1'
            Should -Invoke -ModuleName $moduleName Write-Log -ParameterFilter { "$Messages" -match 'entry @1 has no RepoTags' }
        }

        It 'attempts every entry after a middle entry fails, reports failure, and does not roll back' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 5) }
            $script:failingCommands = @('sudo buildah pull docker-archive:/tmp/import.tar:@2 2>&1')

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            $expected = @(0..4 | ForEach-Object { "sudo buildah pull docker-archive:/tmp/import.tar:@$_ 2>&1" }) + $script:cleanupCommand
            ($script:executedCommands -join '|') | Should -BeExactly ($expected -join '|')
            @($script:executedCommands | Where-Object { $_ -match 'rmi' }).Count | Should -Be 0
            Should -Invoke -ModuleName $moduleName Write-Log -ParameterFilter { "$Messages" -match 'archive entry @2 \(example\.local/image3:v1\)' }
            Should -Invoke -ModuleName $moduleName Write-Log -ParameterFilter { "$Messages" -match 'Imported 4 of 5 images' }
        }

        It 'logs a warning and uses the legacy command for an invalid manifest' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Invalid'; Entries = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\broken.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Write-Log -ParameterFilter { "$Messages" -match 'empty or invalid manifest\.json' }
        }

        It 'uses the legacy oci-archive command for an empty manifest' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Invalid'; Entries = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\empty.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyOciCommand|$script:cleanupCommand"
        }

        It 'keeps the legacy oci-archive command for OCI-only (add-on style) archives without manifest.json' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'NotFound'; Entries = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\addon-image.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyOciCommand|$script:cleanupCommand"
        }

        It 'runs no pulls but still cleans up when copying a multi-image archive fails' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2) }
            Mock -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey { throw 'copy failed' }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly $script:cleanupCommand
        }

        It 'reports failure when cleanup fails after all entries were imported' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2) }
            $script:cleanupSucceeds = $false

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            $script:executedCommands.Count | Should -Be 3
            $script:executedCommands[2] | Should -BeExactly $script:cleanupCommand
        }

        It 'routes a multi-image import to a Linux worker with its IP address and user name' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2) }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo @{
                Kind      = 'LinuxWorker'
                Name      = 'worker-1'
                Username  = 'k2s'
                IpAddress = '192.0.2.1'
            } -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@(
                    'sudo buildah pull docker-archive:/tmp/import.tar:@0 2>&1'
                    'sudo buildah pull docker-archive:/tmp/import.tar:@1 2>&1'
                    $script:cleanupCommand
                ) -join '|')
            Should -Invoke -ModuleName $moduleName Copy-ToRemoteComputerViaSshKey -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'C:\images\multi.tar' -and $Target -eq '/tmp/import.tar' -and $UserName -eq 'k2s' -and $IpAddress -eq '192.0.2.1'
            }
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnVmViaSSHKey -Times 3 -Exactly -ParameterFilter {
                $IpAddress -eq '192.0.2.1' -and $UserName -eq 'k2s' -and $Retries -eq 3 -and $Timeout -eq 10
            }
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 0 -Exactly
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Times 0 -Exactly
        }
    }

    Context 'Get-DockerArchiveManifestInfo with generated archives' {
        BeforeAll {
            $script:tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'

            function New-TestArchive {
                param([string]$Name, [hashtable]$Files)
                $sourceDir = Join-Path $TestDrive "$Name-src"
                New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
                foreach ($fileName in $Files.Keys) {
                    Set-Content -LiteralPath (Join-Path $sourceDir $fileName) -Value $Files[$fileName] -Encoding Ascii -NoNewline
                }
                $archivePath = Join-Path $TestDrive "$Name.tar"
                & $script:tarExe -cf $archivePath -C $sourceDir @($Files.Keys)
                if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to create test archive '$archivePath'" }
                return $archivePath
            }

            function Get-ManifestInfoInModule {
                param([string]$Path)
                InModuleScope $moduleName -Parameters @{ Path = $Path } {
                    param($Path)
                    Get-DockerArchiveManifestInfo -ImagePath $Path
                }
            }

            $script:twoEntryManifest = '[{"Config":"a.json","RepoTags":["example.local/a:1"],"Layers":["a/layer.tar"]},{"Config":"b.json","RepoTags":["example.local/b:1","example.local/b:latest"],"Layers":["b/layer.tar"]}]'
        }

        BeforeEach {
            Mock -ModuleName $moduleName Write-Log {}
        }

        It 'reports Valid with two entries for a two-entry manifest' {
            $archive = New-TestArchive -Name 'two-entries' -Files @{ 'manifest.json' = $script:twoEntryManifest; 'a.json' = '{}'; 'b.json' = '{}' }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
            @($info.Entries)[1].RepoTags | Should -Contain 'example.local/b:latest'
        }

        It 'detects a one-entry manifest as Valid and keeps the unindexed <Label>-archive pull' -ForEach @(
            @{ DockerArchive = $true; Label = 'docker'; ExpectedCommand = 'sudo buildah pull docker-archive:/tmp/import.tar 2>&1' }
            @{ DockerArchive = $false; Label = 'oci'; ExpectedCommand = 'sudo buildah pull oci-archive:/tmp/import.tar 2>&1' }
        ) {
            # A one-element JSON array exercises the PS 5.1 ConvertFrom-Json handling in the real detection helper
            $archive = New-TestArchive -Name "single-entry-$Label" -Files @{
                'manifest.json' = '[{"Config":"a.json","RepoTags":["example.local/single:1","example.local/single:latest"],"Layers":["a/layer.tar"]}]'
                'a.json'        = '{}'
            }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 1
            @(@($info.Entries)[0].RepoTags) | Should -Be @('example.local/single:1', 'example.local/single:latest')

            $script:executedCommands = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey {}
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                $script:executedCommands.Add([string]$CmdToExecute)
                [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' } -DockerArchive:$DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$ExpectedCommand|sudo rm -f /tmp/import.tar"
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 1 -Exactly
            Should -Invoke -ModuleName $moduleName Write-Log -Times 0 -Exactly -ParameterFilter { "$Messages" -match 'invalid manifest|contains \d+ images' }
        }

        It 'reports Valid based on manifest.json when the archive also contains index.json' {
            $archive = New-TestArchive -Name 'dual-format' -Files @{
                'manifest.json' = $script:twoEntryManifest
                'index.json'    = '{"schemaVersion":2,"manifests":[]}'
                'oci-layout'    = '{"imageLayoutVersion":"1.0.0"}'
            }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
        }

        It 'reports Invalid for an empty JSON array' {
            $archive = New-TestArchive -Name 'empty-array' -Files @{ 'manifest.json' = '[]' }

            (Get-ManifestInfoInModule -Path $archive).State | Should -Be 'Invalid'
        }

        It 'reports Invalid for a JSON object instead of an array' {
            $archive = New-TestArchive -Name 'json-object' -Files @{ 'manifest.json' = '{"Config":"a.json","RepoTags":["example.local/a:1"]}' }

            (Get-ManifestInfoInModule -Path $archive).State | Should -Be 'Invalid'
        }

        It 'reports Invalid for malformed JSON' {
            $archive = New-TestArchive -Name 'malformed' -Files @{ 'manifest.json' = '[{"Config": "a.json", ' }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Invalid'
            @($info.Entries).Count | Should -Be 0
        }

        It 'reports NotFound for an OCI-only archive without manifest.json' {
            $archive = New-TestArchive -Name 'oci-only' -Files @{
                'index.json' = '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:0","size":1}]}'
                'oci-layout' = '{"imageLayoutVersion":"1.0.0"}'
            }

            (Get-ManifestInfoInModule -Path $archive).State | Should -Be 'NotFound'
        }

        It 'reports Unavailable for a missing archive path' {
            $info = Get-ManifestInfoInModule -Path (Join-Path $TestDrive 'does-not-exist.tar')

            $info.State | Should -Be 'Unavailable'
            @($info.Entries).Count | Should -Be 0
        }

        It 'imports a generated two-entry archive entry by entry without mocking manifest detection' {
            $archive = New-TestArchive -Name 'end-to-end' -Files @{ 'manifest.json' = $script:twoEntryManifest }
            $script:executedCommands = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey {}
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                $script:executedCommands.Add([string]$CmdToExecute)
                [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@(
                    'sudo buildah pull docker-archive:/tmp/import.tar:@0 2>&1'
                    'sudo buildah pull docker-archive:/tmp/import.tar:@1 2>&1'
                    'sudo rm -f /tmp/import.tar'
                ) -join '|')
        }

        It 'imports a Docker-style blobs/sha256 archive with index.json and gzip layers entry by entry in manifest order' {
            # Synthetic fixture modelled on the 'docker save' layout (Docker 25+, containerd image store); not produced by Docker.
            # Only manifest.json detection and @<index> selection are under test; Buildah's layer decompression is not.
            $sourceDir = Join-Path $TestDrive 'docker-style-src'
            $blobDir = Join-Path $sourceDir 'blobs\sha256'
            New-Item -ItemType Directory -Path $blobDir -Force | Out-Null
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            $getHex = { param([byte[]]$Bytes) -join ($sha256.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) }
            $addBlob = { param([byte[]]$Bytes) $hex = & $getHex $Bytes; [IO.File]::WriteAllBytes((Join-Path $blobDir $hex), $Bytes); "blobs/sha256/$hex" }
            $newGzipLayer = {
                param([string]$Name)
                $layerSrc = Join-Path $TestDrive "layer-$Name"
                New-Item -ItemType Directory -Path $layerSrc -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $layerSrc "$Name.txt") -Value $Name -Encoding Ascii -NoNewline
                (Get-Item -LiteralPath (Join-Path $layerSrc "$Name.txt")).LastWriteTimeUtc = [datetime]'2020-01-01Z'
                $layerTar = Join-Path $TestDrive "layer-$Name.tar"
                & $script:tarExe -cf $layerTar -C $layerSrc "$Name.txt"
                if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to create layer '$Name'" }
                $tarBytes = [IO.File]::ReadAllBytes($layerTar)
                $buffer = New-Object IO.MemoryStream
                $gzip = New-Object IO.Compression.GZipStream($buffer, [IO.Compression.CompressionMode]::Compress)
                $gzip.Write($tarBytes, 0, $tarBytes.Length)
                $gzip.Dispose()
                [PSCustomObject]@{ DiffId = 'sha256:' + (& $getHex $tarBytes); Path = (& $addBlob $buffer.ToArray()) }
            }

            $base = & $newGzipLayer 'base'
            $images = foreach ($name in 'a', 'b') {
                $app = & $newGzipLayer "app-$name"
                $config = @{ architecture = 'amd64'; os = 'linux'; rootfs = @{ type = 'layers'; diff_ids = @($base.DiffId, $app.DiffId) } } | ConvertTo-Json -Compress
                [PSCustomObject]@{ Tag = "k2s.local/issue3212-docker/${name}:1"; Config = (& $addBlob ([Text.Encoding]::UTF8.GetBytes($config))); Layers = @($base.Path, $app.Path) }
            }
            # Docker does not guarantee manifest.json order, so b precedes a here while index.json lists a first.
            # index.json uses a placeholder digest and has no OCI manifest blobs: it is not a complete OCI image layout.
            $manifestJson = ConvertTo-Json -Compress -Depth 4 @($images[1], $images[0] | ForEach-Object { [ordered]@{ Config = $_.Config; RepoTags = @($_.Tag); Layers = $_.Layers } })
            $indexJson = @{ schemaVersion = 2; mediaType = 'application/vnd.oci.image.index.v1+json'; manifests = @($images | ForEach-Object {
                        @{ mediaType = 'application/vnd.oci.image.manifest.v1+json'; digest = 'sha256:0'; size = 0; annotations = @{ 'io.containerd.image.name' = $_.Tag } } }) } | ConvertTo-Json -Compress -Depth 5
            Set-Content -LiteralPath (Join-Path $sourceDir 'manifest.json') -Value $manifestJson -Encoding Ascii -NoNewline
            Set-Content -LiteralPath (Join-Path $sourceDir 'index.json') -Value $indexJson -Encoding Ascii -NoNewline
            Set-Content -LiteralPath (Join-Path $sourceDir 'oci-layout') -Value '{"imageLayoutVersion":"1.0.0"}' -Encoding Ascii -NoNewline
            $archive = Join-Path $TestDrive 'docker-style.tar'
            & $script:tarExe -cf $archive -C $sourceDir 'blobs' 'index.json' 'manifest.json' 'oci-layout'
            if ($LASTEXITCODE -ne 0) { throw "tar.exe failed to create test archive '$archive'" }

            # Fixture consistency: every manifest path is an archive member and the shared base layer is a gzip blob stored once
            $members = @(& $script:tarExe -tf $archive)
            foreach ($image in $images) { @($image.Config) + $image.Layers | ForEach-Object { $members | Should -Contain $_ } }
            @($members | Where-Object { $_ -eq $base.Path }).Count | Should -Be 1
            ([IO.File]::ReadAllBytes((Join-Path $sourceDir $base.Path)))[0..1] | Should -Be @(0x1f, 0x8b)

            $info = Get-ManifestInfoInModule -Path $archive
            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
            $expectedTags = @(@($info.Entries) | ForEach-Object { @($_.RepoTags)[0] })
            $expectedTags | Should -Be @('k2s.local/issue3212-docker/b:1', 'k2s.local/issue3212-docker/a:1')

            $script:executedCommands = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey {}
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                $script:executedCommands.Add([string]$CmdToExecute)
                [PSCustomObject]@{ Success = $true; Output = '' }
            }

            # No -DockerArchive: index.json and oci-layout must not route a multi-entry archive to oci-archive
            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@(
                    'sudo buildah pull docker-archive:/tmp/import.tar:@0 2>&1'
                    'sudo buildah pull docker-archive:/tmp/import.tar:@1 2>&1'
                    'sudo rm -f /tmp/import.tar'
                ) -join '|')
            for ($i = 0; $i -lt 2; $i++) {
                $expectedMessage = "[Import] Importing archive entry @$i ($($expectedTags[$i])) on 'control-plane'"
                Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $Messages -contains $expectedMessage }
            }
        }
    }

}
