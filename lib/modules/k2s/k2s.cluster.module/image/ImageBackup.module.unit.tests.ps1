# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -Modules Pester

BeforeAll {
    # Import required modules
    Import-Module "$PSScriptRoot\..\..\k2s.infra.module\k2s.infra.module.psm1" -Force
    $modulePath = "$PSScriptRoot\ImageBackup.module.psm1"
    Import-Module $modulePath -Force
}

Describe "ImageBackup Module Tests" {
    
    Describe "New-EmptyBackupResult" {
        It "Should return correct structure with default datetime" {
            $backupDir = "C:\Test\Backup"
            $result = New-EmptyBackupResult -BackupDirectory $backupDir
            
            $result.BackupDirectory | Should -Be $backupDir
            $result.Images.Count | Should -Be 0
            $result.Success | Should -Be $true
            $result.BackupTimestamp | Should -Match "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"
        }
        
        It "Should use custom datetime provider" {
            $testDate = "2024-01-01 12:00:00"
            $customProvider = { $testDate }
            
            $result = New-EmptyBackupResult -BackupDirectory "C:\Test" -DateTimeProvider $customProvider
            $result.BackupTimestamp | Should -Be $testDate
        }
    }
    
    Describe "New-BackupDirectoryStructure" {
        BeforeEach {
            $testDir = "TestDrive:\backup"
            $imagesDir = "TestDrive:\backup\images"
        }
        
        It "Should create main directory when it doesn't exist" {
            $mockProvider = @{
                TestPath = { param($path) $false }
                NewItem = { param($path, $type) 
                    New-Item -ItemType Directory -Path $path -Force | Out-Null 
                }
                JoinPath = { param($parent, $child) Join-Path $parent $child }
            }
            
            { New-BackupDirectoryStructure -BackupDirectory $testDir -FileSystemProvider $mockProvider } | Should -Not -Throw
        }
        
        It "Should create images subdirectory when requested" {
            $testDir = "TestDrive:\backup"
            $imagesDir = "TestDrive:\backup\images"
            $createCalls = [System.Collections.ArrayList]::new()
            $mockProvider = @{
                TestPath = { param($path) $false }
                NewItem = { param($path, $type) 
                    $createCalls.Add($path) | Out-Null
                }
                JoinPath = { param($parent, $child) Join-Path $parent $child }
            }
            
            New-BackupDirectoryStructure -BackupDirectory $testDir -CreateImagesSubdir -FileSystemProvider $mockProvider
            
            $createCalls | Should -Contain $testDir
            $createCalls | Should -Contain $imagesDir
        }
    }
    
    Describe "Invoke-K2sImageCommand" {
        It "Should execute command successfully" {
            $testCommand = "echo test"
            $mockExecutor = { param($cmd) "success output" }
            
            $global:LASTEXITCODE = 0
            # Function no longer returns command output to avoid pipeline pollution
            { Invoke-K2sImageCommand -Command $testCommand -ImageName "test:latest" -CommandExecutor $mockExecutor } | Should -Not -Throw
        }
        
        It "Should throw on command failure" {
            $testCommand = "failing command"
            $mockExecutor = { param($cmd) "error output" }
            
            $global:LASTEXITCODE = 1
            
            { Invoke-K2sImageCommand -Command $testCommand -ImageName "test:latest" -CommandExecutor $mockExecutor } | 
                Should -Throw "*Command failed with exit code 1*"
        }
        
        It "Should validate expected file exists" {
            $testFile = "TestDrive:\test.tar"
            New-Item -Path $testFile -ItemType File -Value "test content"
            
            $mockExecutor = { param($cmd) "success" }
            $global:LASTEXITCODE = 0
            
            { Invoke-K2sImageCommand -Command "test" -ImageName "test:latest" -ExpectedFile $testFile -CommandExecutor $mockExecutor } | 
                Should -Not -Throw
        }
        
        It "Should throw if expected file is empty" {
            $testFile = "TestDrive:\empty.tar"
            New-Item -Path $testFile -ItemType File
            
            $mockExecutor = { param($cmd) "success" }
            $global:LASTEXITCODE = 0
            
            { Invoke-K2sImageCommand -Command "test" -ImageName "test:latest" -ExpectedFile $testFile -CommandExecutor $mockExecutor } | 
                Should -Throw "*Created file is empty*"
        }
    }
    
    Describe "Write-ProcessingProgress" {
        It "Should not throw when called with valid parameters" {
            $mockImage = @{
                repository = "nginx"
                tag = "latest"
            }
            
            { Write-ProcessingProgress -Current 1 -Total 5 -Action "Testing" -Image $mockImage } | Should -Not -Throw
        }
    }
    
    Describe "Test-ImageOperationParameters" {
        It "Should validate valid parameters" {
            $images = @(
                @{ repository = "nginx"; tag = "latest"; imageid = "123" }
                @{ repository = "redis"; tag = "6"; imageid = "456" }
            )
            
            $result = Test-ImageOperationParameters -BackupDirectory "C:\Valid\Path" -Images $images -RequiredSpaceGB 10
            
            $result.IsValid | Should -Be $true
            $result.Errors.Count | Should -Be 0
        }
        
        It "Should detect invalid backup directory" {
            $result = Test-ImageOperationParameters -BackupDirectory ""
            
            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "BackupDirectory cannot be empty or whitespace"
        }
        
        It "Should detect invalid images" {
            $invalidImages = @(
                @{ repository = "nginx" }  # Missing tag and imageid
            )
            
            $result = Test-ImageOperationParameters -Images $invalidImages
            
            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "Image at index 0 is missing required properties (repository, tag, imageid)"
        }
        
        It "Should detect negative space requirement" {
            $result = Test-ImageOperationParameters -RequiredSpaceGB -5
            
            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "RequiredSpaceGB must be a positive number"
        }
    }
    
    Describe "New-ImageProcessingLog" {
        It "Should create backup log with correct format" {
            $logPath = "TestDrive:\backup.log"
            $testResult = @{
                BackupTimestamp = "2024-01-01 12:00:00"
                Images = @(
                    @{ Repository = "nginx"; Tag = "latest"; ImageId = "123" }
                )
                FailedImages = @()
            }
            
            New-ImageProcessingLog -LogPath $logPath -LogType "Backup" -Result $testResult
            
            $logContent = Get-Content $logPath -Raw
            $logContent | Should -Match "K2s Image Backup Log"
            $logContent | Should -Match "Backup Date: 2024-01-01 12:00:00"
            $logContent | Should -Match "nginx:latest"
        }
        
        It "Should include failed images in log" {
            $logPath = "TestDrive:\restore.log"
            $testResult = @{
                RestoreTimestamp = "2024-01-01 13:00:00"
                Images = @()
                FailedImages = @(
                    @{ Repository = "redis"; Tag = "6"; ImageId = "456"; Error = "Connection failed" }
                )
            }
            
            New-ImageProcessingLog -LogPath $logPath -LogType "Restore" -Result $testResult -OriginalTimestamp "2024-01-01 12:00:00"
            
            $logContent = Get-Content $logPath -Raw
            $logContent | Should -Match "Failed Images:"
            $logContent | Should -Match "redis:6.*Connection failed"
            $logContent | Should -Match "Original Backup Date: 2024-01-01 12:00:00"
        }
    } 
}

AfterAll {
    Remove-Module ImageBackup -Force -ErrorAction SilentlyContinue
}
