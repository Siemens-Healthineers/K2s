# SPDX-FileCopyrightText:  © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

BeforeAll {
    $modulePath = "$PSScriptRoot/Image-Common.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name

    # Every import copies the archive to its own '/tmp/k2s-image-import-<guid>.tar'; commands are recorded with that path replaced by '<archive>'
    $script:remotePathPattern = '/tmp/k2s-image-import-[0-9a-f]{32}\.tar'
    $script:cleanupCommand = 'sudo rm -f <archive>'
    $script:legacyDockerCommand = 'sudo buildah pull docker-archive:<archive> 2>&1'
    $script:legacyOciCommand = 'sudo buildah pull oci-archive:<archive> 2>&1'

    function Get-IndexedPullCommand {
        param([int]$Index)
        "sudo buildah pull docker-archive:<archive>:@$Index 2>&1"
    }

    function Initialize-RemoteCommandMocks {
        $script:executedCommands = [System.Collections.Generic.List[string]]::new()
        $script:rawCommands = [System.Collections.Generic.List[string]]::new()
        $script:copyTargets = [System.Collections.Generic.List[string]]::new()
        $script:failingCommands = @()
        $script:cleanupSucceeds = $true
        $script:cleanupThrows = $false

        Mock -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey { $script:copyTargets.Add([string]$Target) }
        Mock -ModuleName $moduleName Copy-ToRemoteComputerViaSshKey { $script:copyTargets.Add([string]$Target) }
        $commandMock = {
            $script:rawCommands.Add([string]$CmdToExecute)
            $command = ([string]$CmdToExecute) -replace $script:remotePathPattern, '<archive>'
            $script:executedCommands.Add($command)
            if ($command -eq $script:cleanupCommand) {
                if ($script:cleanupThrows) {
                    throw 'ssh connection lost'
                }
                return [PSCustomObject]@{ Success = $script:cleanupSucceeds; Output = '' }
            }
            [PSCustomObject]@{ Success = ($script:failingCommands -notcontains $command); Output = '' }
        }
        Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey $commandMock
        Mock -ModuleName $moduleName Invoke-CmdOnVmViaSSHKey $commandMock
    }

    # The archive is copied once to a unique remote path, and every remote command uses exactly that path
    function Assert-SingleRemoteArchivePath {
        $script:copyTargets.Count | Should -Be 1
        $script:copyTargets[0] | Should -Match "^$script:remotePathPattern$"
        foreach ($rawCommand in $script:rawCommands) {
            foreach ($match in [regex]::Matches($rawCommand, '/tmp/\S+\.tar')) {
                $match.Value | Should -BeExactly $script:copyTargets[0]
            }
        }
    }
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

    Context 'ConvertTo-ImageArchiveMemberPath' {
        It 'normalizes <Path> to <Expected>' -ForEach @(
            @{ Path = 'manifest.json'; Expected = 'manifest.json' }
            @{ Path = './manifest.json'; Expected = 'manifest.json' }
            @{ Path = '/manifest.json'; Expected = 'manifest.json' }
            @{ Path = 'blobs//sha256/abc'; Expected = 'blobs/sha256/abc' }
            @{ Path = './blobs/sha256/./abc'; Expected = 'blobs/sha256/abc' }
            @{ Path = 'blobs/sha256/'; Expected = 'blobs/sha256' }
            @{ Path = 'a/../b/layer.tar'; Expected = 'b/layer.tar' }
            @{ Path = '../layer.tar'; Expected = 'layer.tar' }
            @{ Path = 'dir\layer.tar'; Expected = 'dir/layer.tar' }
            @{ Path = './'; Expected = '' }
            @{ Path = ''; Expected = '' }
        ) {
            InModuleScope $moduleName -Parameters @{ Path = $Path; Expected = $Expected } {
                param($Path, $Expected)
                ConvertTo-ImageArchiveMemberPath -Path $Path | Should -BeExactly $Expected
            }
        }
    }

    Context 'Get-DockerArchiveEntryProblem' {
        BeforeAll {
            function Get-EntryProblem {
                param([string]$Json, [string[]]$Members = @())
                InModuleScope $moduleName -Parameters @{ Json = $Json; Members = $Members } {
                    param($Json, $Members)
                    $entry = $Json | ConvertFrom-Json
                    Get-DockerArchiveEntryProblem -Entry $entry -Members $Members
                }
            }
            $script:members = @('manifest.json', 'a.json', 'a', 'a/layer.tar', 'blobs', 'blobs/sha256', 'blobs/sha256/l1')
        }

        It 'accepts a complete entry whose config and layers are archive members' {
            Get-EntryProblem -Json '{"Config":"a.json","RepoTags":["example.local/a:1"],"Layers":["a/layer.tar","blobs/sha256/l1"]}' -Members $script:members | Should -BeNullOrEmpty
        }

        It 'accepts manifest paths that differ from the member names only by a ./ prefix' {
            Get-EntryProblem -Json '{"Config":"./a.json","RepoTags":["example.local/a:1"],"Layers":["./a/layer.tar"]}' -Members $script:members | Should -BeNullOrEmpty
        }

        It 'accepts an untagged entry with RepoTags <Label>' -ForEach @(
            @{ Label = 'null'; Json = '{"Config":"a.json","RepoTags":null,"Layers":["a/layer.tar"]}' }
            @{ Label = 'missing'; Json = '{"Config":"a.json","Layers":["a/layer.tar"]}' }
            @{ Label = 'empty'; Json = '{"Config":"a.json","RepoTags":[],"Layers":["a/layer.tar"]}' }
        ) {
            Get-EntryProblem -Json $Json -Members $script:members | Should -BeNullOrEmpty
        }

        It 'skips the member check when no member list is available' {
            Get-EntryProblem -Json '{"Config":"missing.json","RepoTags":["example.local/a:1"],"Layers":["missing.tar"]}' | Should -BeNullOrEmpty
        }

        It 'rejects an entry with <Label>' -ForEach @(
            @{ Label = 'no Config'; Json = '{"RepoTags":["example.local/a:1"],"Layers":["a/layer.tar"]}'; Pattern = "^'Config' is missing" }
            @{ Label = 'an empty Config'; Json = '{"Config":" ","Layers":["a/layer.tar"]}'; Pattern = "^'Config' is missing" }
            @{ Label = 'a numeric Config'; Json = '{"Config":42,"Layers":["a/layer.tar"]}'; Pattern = "^'Config' is missing" }
            @{ Label = 'no Layers'; Json = '{"Config":"a.json"}'; Pattern = "^'Layers' is missing or not an array" }
            @{ Label = 'a string Layers value'; Json = '{"Config":"a.json","Layers":"a/layer.tar"}'; Pattern = "^'Layers' is missing or not an array" }
            @{ Label = 'an empty layer path'; Json = '{"Config":"a.json","Layers":["a/layer.tar",""]}'; Pattern = "^'Layers' contains an item" }
            @{ Label = 'a numeric layer path'; Json = '{"Config":"a.json","Layers":[1]}'; Pattern = "^'Layers' contains an item" }
            @{ Label = 'a string RepoTags value'; Json = '{"Config":"a.json","RepoTags":"example.local/a:1","Layers":["a/layer.tar"]}'; Pattern = "^'RepoTags' is not an array" }
            @{ Label = 'a numeric tag'; Json = '{"Config":"a.json","RepoTags":[1],"Layers":["a/layer.tar"]}'; Pattern = "^'RepoTags' contains an item" }
            @{ Label = 'a missing config member'; Json = '{"Config":"b.json","Layers":["a/layer.tar"]}'; Pattern = '^archive member\(s\) not found: b\.json$' }
            @{ Label = 'missing layer members'; Json = '{"Config":"a.json","Layers":["a/layer.tar","b/layer.tar","c/layer.tar","b/layer.tar"]}'; Pattern = '^archive member\(s\) not found: b/layer\.tar, c/layer\.tar$' }
        ) {
            Get-EntryProblem -Json $Json -Members $script:members | Should -Match $Pattern
        }

        It 'rejects a value that is not a JSON object' {
            InModuleScope $moduleName {
                Get-DockerArchiveEntryProblem -Entry 'a.json' | Should -Be 'the entry is not a JSON object'
                Get-DockerArchiveEntryProblem -Entry $null | Should -Be 'the entry is not a JSON object'
            }
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
        }

        BeforeEach {
            $script:manifestInfo = [PSCustomObject]@{ State = 'NotFound'; Entries = @(); Members = @() }

            Mock -ModuleName $moduleName Write-Log {}
            Mock -ModuleName $moduleName Get-DockerArchiveManifestInfo { $script:manifestInfo }
            Initialize-RemoteCommandMocks
        }

        It 'keeps the unindexed docker-archive command for a single-entry archive with -DockerArchive' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 1); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter { $Source -eq 'C:\images\single.tar' }
            Assert-SingleRemoteArchivePath
        }

        It 'keeps the unindexed oci-archive command for a single-entry archive without -DockerArchive' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 1); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyOciCommand|$script:cleanupCommand"
            @($script:executedCommands | Where-Object { $_ -match ':@\d' }).Count | Should -Be 0
        }

        It 'does not validate the entry of a single-entry archive and leaves error reporting to Buildah' {
            $entry = [PSCustomObject]@{ Config = 'missing.json'; RepoTags = @('example.local/single:1'); Layers = @('missing.tar') }
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = @($entry); Members = @('manifest.json') }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Write-Log -Times 0 -Exactly -ParameterFilter { "$Messages" -match 'Skipping archive entry' }
        }

        It 'uses the same retry and timeout settings for the import and the cleanup of a single-image archive' {
            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Times 2 -Exactly -ParameterFilter { $Retries -eq 3 -and $Timeout -eq 10 -and $NoLog }
        }

        It 'imports each entry of a two-entry archive once, in order, with an indexed selector' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 1 -Exactly -ParameterFilter { $Source -eq 'C:\images\multi.tar' }
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Times 3 -Exactly -ParameterFilter { $Retries -eq 3 -and $Timeout -eq 10 -and $NoLog }
            Assert-SingleRemoteArchivePath
        }

        It 'logs each indexed pull with the tags and config of the manifest entry at that index' {
            $entries = @(
                [PSCustomObject]@{ Config = 'blobs/sha256/cfg-b'; RepoTags = @('example.local/b:1'); Layers = @('blobs/sha256/l1') }
                [PSCustomObject]@{ Config = 'blobs/sha256/cfg-a'; RepoTags = @('example.local/a:1', 'example.local/a:latest'); Layers = @('blobs/sha256/l1') }
            )
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $Messages -contains "[Import] Importing archive entry @0 (example.local/b:1, config 'blobs/sha256/cfg-b') on 'control-plane'"
            }
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $Messages -contains "[Import] Importing archive entry @1 (example.local/a:1, example.local/a:latest, config 'blobs/sha256/cfg-a') on 'control-plane'"
            }
        }

        It 'automatically uses docker-archive selectors @0..@4 for a five-entry archive without -DockerArchive' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 5); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            $expected = @(0..4 | ForEach-Object { Get-IndexedPullCommand $_ }) + $script:cleanupCommand
            ($script:executedCommands -join '|') | Should -BeExactly ($expected -join '|')
            @($script:executedCommands | Where-Object { $_ -like '*oci-archive*' }).Count | Should -Be 0
        }

        It 'issues a single pull for an entry with multiple RepoTags and no separate tag commands' {
            $entries = New-TestManifestEntries -Count 2
            $entries[0].RepoTags = @('example.local/python:3', 'example.local/python:3.14')
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            $script:executedCommands.Count | Should -Be 3
            @($script:executedCommands | Where-Object { $_ -eq (Get-IndexedPullCommand 0) }).Count | Should -Be 1
            @($script:executedCommands | Where-Object { $_ -match 'buildah tag' }).Count | Should -Be 0
        }

        It 'imports an untagged entry, logs a warning, and does not fail because of the missing tags' {
            $entries = New-TestManifestEntries -Count 2
            $entries[1].RepoTags = $null
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            $script:executedCommands | Should -Contain (Get-IndexedPullCommand 1)
            Should -Invoke -ModuleName $moduleName Write-Log -ParameterFilter { "$Messages" -match 'entry @1 has no RepoTags' }
        }

        It 'attempts every entry after a middle entry fails, reports failure, and does not roll back' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 5); Members = @() }
            $script:failingCommands = @(Get-IndexedPullCommand 2)

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            $expected = @(0..4 | ForEach-Object { Get-IndexedPullCommand $_ }) + $script:cleanupCommand
            ($script:executedCommands -join '|') | Should -BeExactly ($expected -join '|')
            @($script:executedCommands | Where-Object { $_ -match 'rmi' }).Count | Should -Be 0
            Should -Invoke -ModuleName $moduleName Write-Log -ParameterFilter { "$Messages" -match "archive entry @2 \(example\.local/image3:v1\) of 'C:\\images\\multi\.tar'" }
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $_Error -and "$Messages" -match "Imported 4 of 5 images from 'C:\\images\\multi\.tar' on 'control-plane'; failed entries: @2\."
            }
        }

        It 'reports failure when only the <Position> entry fails, so a later success cannot mask it' -ForEach @(
            @{ Position = 'first'; FailingIndex = 0 }
            @{ Position = 'last'; FailingIndex = 2 }
        ) {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 3); Members = @() }
            $script:failingCommands = @(Get-IndexedPullCommand $FailingIndex)

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            @($script:executedCommands | Where-Object { $_ -like 'sudo buildah pull*' }).Count | Should -Be 3
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match "failed entries: @$FailingIndex\." }
        }

        It 'treats a malformed remote result for an entry as a failure' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }
            Mock -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey {
                $script:executedCommands.Add((([string]$CmdToExecute) -replace $script:remotePathPattern, '<archive>'))
                if ($CmdToExecute -like '*:@1 2>&1') {
                    return @('buildah output', $true)
                }
                [PSCustomObject]@{ Success = $true; Output = '' }
            }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
        }

        It 'skips a structurally invalid entry, imports the other entries, and reports failure' {
            $entries = New-TestManifestEntries -Count 3
            $entries[1] = [PSCustomObject]@{ RepoTags = @('example.local/broken:1'); Layers = @('layer2.tar') }
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 2), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                "$Messages" -match "Skipping archive entry @1 \(example\.local/broken:1\) of 'C:\\images\\multi\.tar': invalid manifest\.json entry: 'Config' is missing"
            }
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match 'Imported 2 of 3 images.*failed entries: @1\.' }
        }

        It 'skips an entry whose layer is not an archive member' {
            $entries = New-TestManifestEntries -Count 2
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @('manifest.json', 'config1.json', 'layer1.tar', 'config2.json') }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { "$Messages" -match 'Skipping archive entry @1 .*archive member\(s\) not found: layer2\.tar' }
        }

        It 'runs no pulls but still copies, cleans up, and fails when every entry is invalid' {
            $entries = @([PSCustomObject]@{ Config = 'a.json' }, [PSCustomObject]@{ Layers = @('b.tar') })
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = $entries; Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly $script:cleanupCommand
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match 'Imported 0 of 2 images.*failed entries: @0, @1\.' }
        }

        It 'logs a warning and uses the legacy command for an invalid manifest' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Invalid'; Entries = @(); Members = @('manifest.json') }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\broken.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Write-Log -ParameterFilter { "$Messages" -match 'empty or invalid manifest\.json' }
        }

        It 'uses the legacy oci-archive command for an empty manifest' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Invalid'; Entries = @(); Members = @('manifest.json') }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\empty.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyOciCommand|$script:cleanupCommand"
        }

        It 'keeps the legacy <Label> command without a warning when the archive cannot be inspected' -ForEach @(
            @{ DockerArchive = $true; Label = 'docker-archive' }
            @{ DockerArchive = $false; Label = 'oci-archive' }
        ) {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Unavailable'; Entries = @(); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\unreadable.tar' -NodeInfo $script:controlPlane -DockerArchive:$DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "sudo buildah pull ${Label}:<archive> 2>&1|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Write-Log -Times 0 -Exactly -ParameterFilter { "$Messages" -match 'invalid manifest|contains \d+ images' }
        }

        It 'keeps the legacy oci-archive command for OCI-only (add-on style) archives without manifest.json' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'NotFound'; Entries = @(); Members = @('index.json', 'oci-layout') }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\addon-image.tar' -NodeInfo $script:controlPlane

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyOciCommand|$script:cleanupCommand"
        }

        It 'runs no pulls but still cleans up when copying a multi-image archive fails' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }
            Mock -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey { $script:copyTargets.Add([string]$Target); throw 'copy failed' }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly $script:cleanupCommand
            Assert-SingleRemoteArchivePath
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match "Image import failed on 'control-plane': copy failed" }
        }

        It 'reports failure when cleanup fails after all entries were imported' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }
            $script:cleanupSucceeds = $false

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            $script:executedCommands.Count | Should -Be 3
            $script:executedCommands[2] | Should -BeExactly $script:cleanupCommand
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                $_Error -and "$Messages" -match "^\[Import\] Could not remove temporary image archive '$script:remotePathPattern' from 'control-plane'$"
            }
        }

        It 'reports failure without throwing when the cleanup command throws after a successful import' {
            $script:cleanupThrows = $true

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\single.tar' -NodeInfo $script:controlPlane -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $_Error -and "$Messages" -match 'Could not remove temporary image archive .*: ssh connection lost$' }
        }

        It 'reports both the entry failure and the cleanup failure, in that order' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }
            $script:failingCommands = @(Get-IndexedPullCommand 0)
            $script:cleanupThrows = $true
            $script:errorMessages = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName $moduleName Write-Log { if ($_Error) { $script:errorMessages.Add("$Messages") } }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo $script:controlPlane

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            $script:errorMessages.Count | Should -Be 2
            $script:errorMessages[0] | Should -Match 'Imported 1 of 2 images.*failed entries: @0\.'
            $script:errorMessages[1] | Should -Match 'Could not remove temporary image archive .*: ssh connection lost$'
        }

        It 'uses a different remote archive path for every import' {
            Invoke-LinuxNodeImageImport -ImagePath 'C:\images\first.tar' -NodeInfo $script:controlPlane | Should -BeTrue
            Invoke-LinuxNodeImageImport -ImagePath 'C:\images\second.tar' -NodeInfo $script:controlPlane | Should -BeTrue

            $script:copyTargets.Count | Should -Be 2
            $script:copyTargets | ForEach-Object { $_ | Should -Match "^$script:remotePathPattern$" }
            $script:copyTargets[0] | Should -Not -Be $script:copyTargets[1]
            $script:rawCommands[1] | Should -BeExactly "sudo rm -f $($script:copyTargets[0])"
            $script:rawCommands[3] | Should -BeExactly "sudo rm -f $($script:copyTargets[1])"
        }

        It 'routes a multi-image import to a Linux worker with its IP address and user name' {
            $script:manifestInfo = [PSCustomObject]@{ State = 'Valid'; Entries = (New-TestManifestEntries -Count 2); Members = @() }

            $result = Invoke-LinuxNodeImageImport -ImagePath 'C:\images\multi.tar' -NodeInfo @{
                Kind      = 'LinuxWorker'
                Name      = 'worker-1'
                Username  = 'k2s'
                IpAddress = '192.0.2.1'
            } -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Copy-ToRemoteComputerViaSshKey -Times 1 -Exactly -ParameterFilter {
                $Source -eq 'C:\images\multi.tar' -and $Target -match "^$script:remotePathPattern$" -and $UserName -eq 'k2s' -and $IpAddress -eq '192.0.2.1'
            }
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnVmViaSSHKey -Times 3 -Exactly -ParameterFilter {
                $IpAddress -eq '192.0.2.1' -and $UserName -eq 'k2s' -and $Retries -eq 3 -and $Timeout -eq 10 -and $NoLog
            }
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 0 -Exactly
            Should -Invoke -ModuleName $moduleName Invoke-CmdOnControlPlaneViaSSHKey -Times 0 -Exactly
            Assert-SingleRemoteArchivePath
        }
    }

    Context 'Get-DockerArchiveManifestInfo with generated archives' {
        BeforeAll {
            $script:tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'

            function New-TestArchive {
                param([string]$Name, [hashtable]$Files, [string[]]$MemberNames)
                $sourceDir = Join-Path $TestDrive "$Name-src"
                New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
                foreach ($fileName in $Files.Keys) {
                    $filePath = Join-Path $sourceDir $fileName
                    New-Item -ItemType Directory -Path (Split-Path $filePath -Parent) -Force | Out-Null
                    Set-Content -LiteralPath $filePath -Value $Files[$fileName] -Encoding Ascii -NoNewline
                }
                if (-not $MemberNames) {
                    $MemberNames = @($Files.Keys)
                }
                $archivePath = Join-Path $TestDrive "$Name.tar"
                & $script:tarExe -cf $archivePath -C $sourceDir @MemberNames
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
            $script:twoEntryFiles = @{ 'manifest.json' = $script:twoEntryManifest; 'a.json' = '{}'; 'a/layer.tar' = 'a'; 'b.json' = '{}'; 'b/layer.tar' = 'b' }
        }

        BeforeEach {
            Mock -ModuleName $moduleName Write-Log {}
            Initialize-RemoteCommandMocks
        }

        It 'reports Valid with two entries and the normalized member list for a two-entry manifest' {
            $archive = New-TestArchive -Name 'two-entries' -Files $script:twoEntryFiles

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
            @($info.Entries)[1].RepoTags | Should -Contain 'example.local/b:latest'
            foreach ($member in 'manifest.json', 'a.json', 'a/layer.tar', 'b.json', 'b/layer.tar') {
                $info.Members | Should -Contain $member
            }
        }

        It 'reports Valid for an archive whose members are stored with a ./ prefix' {
            $archive = New-TestArchive -Name 'dot-prefix' -Files $script:twoEntryFiles -MemberNames @('./manifest.json', './a.json', './a/layer.tar', './b.json', './b/layer.tar')
            @(& $script:tarExe -tf $archive) | Should -Contain './manifest.json'

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
            $info.Members | Should -Contain 'b/layer.tar'
            $info.Members | Should -Not -Contain './b/layer.tar'
        }

        It 'detects a one-entry manifest as Valid and keeps the unindexed <Label>-archive pull' -ForEach @(
            @{ DockerArchive = $true; Label = 'docker'; ExpectedCommand = 'sudo buildah pull docker-archive:<archive> 2>&1' }
            @{ DockerArchive = $false; Label = 'oci'; ExpectedCommand = 'sudo buildah pull oci-archive:<archive> 2>&1' }
        ) {
            # A one-element JSON array exercises the PS 5.1 ConvertFrom-Json handling in the real detection helper
            $archive = New-TestArchive -Name "single-entry-$Label" -Files @{
                'manifest.json' = '[{"Config":"a.json","RepoTags":["example.local/single:1","example.local/single:latest"],"Layers":["a/layer.tar"]}]'
                'a.json'        = '{}'
                'a/layer.tar'   = 'a'
            }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 1
            @(@($info.Entries)[0].RepoTags) | Should -Be @('example.local/single:1', 'example.local/single:latest')

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' } -DockerArchive:$DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$ExpectedCommand|sudo rm -f <archive>"
            Should -Invoke -ModuleName $moduleName Copy-ToControlPlaneViaSSHKey -Times 1 -Exactly
            Should -Invoke -ModuleName $moduleName Write-Log -Times 0 -Exactly -ParameterFilter { "$Messages" -match 'invalid manifest|contains \d+ images' }
            Assert-SingleRemoteArchivePath
        }

        It 'reports Valid based on manifest.json when the archive also contains index.json' {
            $files = $script:twoEntryFiles.Clone()
            $files['index.json'] = '{"schemaVersion":2,"manifests":[]}'
            $files['oci-layout'] = '{"imageLayoutVersion":"1.0.0"}'
            $archive = New-TestArchive -Name 'dual-format' -Files $files

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Valid'
            @($info.Entries).Count | Should -Be 2
        }

        It 'reports Invalid for a manifest.json containing <Label>' -ForEach @(
            @{ Label = 'an empty JSON array'; Content = '[]' }
            @{ Label = 'a JSON object instead of an array'; Content = '{"Config":"a.json","RepoTags":["example.local/a:1"]}' }
            @{ Label = 'malformed JSON'; Content = '[{"Config": "a.json", ' }
            @{ Label = 'no data'; Content = '' }
            @{ Label = 'only whitespace'; Content = "  `r`n " }
            @{ Label = 'JSON null'; Content = 'null' }
            @{ Label = 'a JSON string'; Content = '"manifest"' }
            @{ Label = 'an array of numbers'; Content = '[1,2]' }
            @{ Label = 'an array of strings'; Content = '["a.json","b.json"]' }
            @{ Label = 'a nested array'; Content = '[[{"Config":"a.json","Layers":[]}]]' }
            @{ Label = 'an array with a null item'; Content = '[{"Config":"a.json","Layers":[]},null]' }
        ) {
            $archive = New-TestArchive -Name "invalid-$($Label -replace '\W', '-')" -Files @{ 'manifest.json' = $Content }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'Invalid'
            @($info.Entries).Count | Should -Be 0
        }

        It 'reports NotFound for an OCI-only archive without manifest.json' {
            $archive = New-TestArchive -Name 'oci-only' -Files @{
                'index.json' = '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:0","size":1}]}'
                'oci-layout' = '{"imageLayoutVersion":"1.0.0"}'
            }

            $info = Get-ManifestInfoInModule -Path $archive

            $info.State | Should -Be 'NotFound'
            $info.Members | Should -Contain 'index.json'
        }

        It 'does not treat a nested manifest.json as the archive manifest' {
            $archive = New-TestArchive -Name 'nested-manifest' -Files @{ 'sub/manifest.json' = $script:twoEntryManifest }

            (Get-ManifestInfoInModule -Path $archive).State | Should -Be 'NotFound'
        }

        It 'reports Unavailable for a missing archive path' {
            $info = Get-ManifestInfoInModule -Path (Join-Path $TestDrive 'does-not-exist.tar')

            $info.State | Should -Be 'Unavailable'
            @($info.Entries).Count | Should -Be 0
        }

        It 'reports Unavailable for a file that is not a tar archive and keeps the legacy import' {
            $notAnArchive = Join-Path $TestDrive 'not-an-archive.tar'
            Set-Content -LiteralPath $notAnArchive -Value 'this is not a tar archive' -Encoding Ascii

            $info = Get-ManifestInfoInModule -Path $notAnArchive

            $info.State | Should -Be 'Unavailable'
            @($info.Entries).Count | Should -Be 0

            $result = Invoke-LinuxNodeImageImport -ImagePath $notAnArchive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' } -DockerArchive

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly "$script:legacyDockerCommand|$script:cleanupCommand"
        }

        It 'imports a generated two-entry archive entry by entry without mocking manifest detection' {
            $archive = New-TestArchive -Name 'end-to-end' -Files $script:twoEntryFiles

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Assert-SingleRemoteArchivePath
        }

        It 'imports the valid entry and skips an entry whose layer is missing from a generated archive' {
            $files = $script:twoEntryFiles.Clone()
            $files.Remove('b/layer.tar')
            $archive = New-TestArchive -Name 'missing-layer' -Files $files

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' } -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter {
                "$Messages" -match 'Skipping archive entry @1 \(example\.local/b:1, example\.local/b:latest\) .*archive member\(s\) not found: b/layer\.tar$'
            }
        }

        It 'skips an entry whose config is missing from a generated archive' {
            $files = $script:twoEntryFiles.Clone()
            $files.Remove('a.json')
            $archive = New-TestArchive -Name 'missing-config' -Files $files

            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' } -DockerArchive

            $result | Should -BeFalse
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { "$Messages" -match 'Skipping archive entry @0 .*archive member\(s\) not found: a\.json$' }
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

            # No -DockerArchive: index.json and oci-layout must not route a multi-entry archive to oci-archive
            $result = Invoke-LinuxNodeImageImport -ImagePath $archive -NodeInfo @{ Kind = 'ControlPlane'; Name = 'control-plane' }

            $result | Should -BeTrue
            ($script:executedCommands -join '|') | Should -BeExactly (@((Get-IndexedPullCommand 0), (Get-IndexedPullCommand 1), $script:cleanupCommand) -join '|')
            # Each selector index is paired with the tag and config of the manifest.json entry at that index, not with index.json order
            $expectedConfigs = @($images[1].Config, $images[0].Config)
            for ($i = 0; $i -lt 2; $i++) {
                $expectedMessage = "[Import] Importing archive entry @$i ($($expectedTags[$i]), config '$($expectedConfigs[$i])') on 'control-plane'"
                Should -Invoke -ModuleName $moduleName Write-Log -Times 1 -Exactly -ParameterFilter { $Messages -contains $expectedMessage }
            }
        }
    }
}

Describe 'Import-Image.ps1' -Tag 'unit', 'ci', 'image' {
    BeforeAll {
        # Run the script as a dynamic scriptblock with '#Requires' and module imports removed; the module functions it calls are mocked below
        $scriptContent = (Get-Content -Path "$PSScriptRoot\Import-Image.ps1" | Where-Object {
                $_ -notmatch '^#Requires\b' -and $_ -notmatch '^\s*Import-Module\b'
            }) -join [Environment]::NewLine

        function Invoke-ImportImageScript {
            param([hashtable]$Parameters)
            & ([scriptblock]::Create($scriptContent)) @Parameters
        }

        # The real New-Error needs the [Severity] enum of the infra module, which is not loaded here
        function New-Error {
            param($Severity, $Code, $Message)
            $script:newErrorCodes.Add($Code)
            [PSCustomObject]@{ Code = $Code; Message = $Message }
        }
    }

    BeforeEach {
        $script:importCalls = [System.Collections.Generic.List[object]]::new()
        $script:failingImages = @()
        $script:cliMessages = [System.Collections.Generic.List[object]]::new()

        Mock -CommandName Import-Module {}
        Mock -CommandName Write-Log {}
        Mock -CommandName Initialize-ImageScriptContext { $true }
        Mock -CommandName Resolve-NodeList { @() }
        $script:newErrorCodes = [System.Collections.Generic.List[string]]::new()
        Mock -CommandName Send-ToCli { $script:cliMessages.Add($Message) }
        Mock -CommandName Invoke-LinuxNodeImageImport {
            $script:importCalls.Add([PSCustomObject]@{ ImagePath = $ImagePath; Kind = $NodeInfo.Kind; DockerArchive = [bool]$DockerArchive })
            $script:failingImages -notcontains $ImagePath
        }
    }

    It 'forwards -DockerArchive:<DockerArchive> to the Linux control-plane import and returns <Expected> in return-status mode' -ForEach @(
        @{ DockerArchive = $true; Failing = $false; Expected = $true }
        @{ DockerArchive = $false; Failing = $false; Expected = $true }
        @{ DockerArchive = $true; Failing = $true; Expected = $false }
    ) {
        if ($Failing) { $script:failingImages = @('C:\images\multi.tar') }

        $result = Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\multi.tar'; DockerArchive = $DockerArchive; ReturnStatus = $true }

        $result | Should -Be $Expected
        $script:importCalls.Count | Should -Be 1
        $script:importCalls[0].ImagePath | Should -BeExactly 'C:\images\multi.tar'
        $script:importCalls[0].Kind | Should -BeExactly 'ControlPlane'
        $script:importCalls[0].DockerArchive | Should -Be $DockerArchive
    }

    It 'sends the image-import-failed error to the CLI when an import fails' {
        $script:failingImages = @('C:\images\multi.tar')

        Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\multi.tar'; EncodeStructuredOutput = $true; MessageType = 'import' }

        $script:cliMessages.Count | Should -Be 1
        $script:cliMessages[0].Error.Code | Should -BeExactly 'image-import-failed'
        @($script:newErrorCodes) | Should -Be @('image-import-failed')
    }

    It 'sends no error to the CLI when the import succeeds' {
        Invoke-ImportImageScript -Parameters @{ ImagePath = 'C:\images\multi.tar'; EncodeStructuredOutput = $true; MessageType = 'import' }

        $script:cliMessages.Count | Should -Be 1
        $script:cliMessages[0].Error | Should -BeNullOrEmpty
        $script:newErrorCodes.Count | Should -Be 0
    }

    It 'imports every archive of a directory and fails overall when one of them fails' {
        $imageDir = Join-Path $TestDrive 'images'
        New-Item -ItemType Directory -Path $imageDir -Force | Out-Null
        'multi.tar', 'single.tar' | ForEach-Object { Set-Content -LiteralPath (Join-Path $imageDir $_) -Value 'x' }
        $script:failingImages = @((Join-Path $imageDir 'multi.tar'))

        $result = Invoke-ImportImageScript -Parameters @{ ImageDir = $imageDir; ReturnStatus = $true }

        $result | Should -BeFalse
        @($script:importCalls | ForEach-Object { Split-Path $_.ImagePath -Leaf } | Sort-Object) | Should -Be @('multi.tar', 'single.tar')
    }
}
