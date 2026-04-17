# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

#Requires -Modules Pester

BeforeAll {
    # Import required modules
    Import-Module "$PSScriptRoot\..\..\k2s.infra.module\k2s.infra.module.psm1" -Force
    $modulePath = "$PSScriptRoot\ImageBackup.module.psm1"
    $script:moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe "ImageBackup Module Tests" -Tag 'unit', 'ci' {
    
    Describe "New-EmptyBackupResult" -Tag 'unit', 'ci' {
        Context 'default datetime' {
            It 'returns correct structure with default datetime' {
            $backupDir = "C:\Test\Backup"
            $result = New-EmptyBackupResult -BackupDirectory $backupDir

            $result.BackupDirectory | Should -Be $backupDir
            $result.Images.Count | Should -Be 0
            $result.Success | Should -Be $true
            $result.BackupTimestamp | Should -Match "^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"
        }
        }
        
        Context 'custom datetime provider' {
            It 'uses custom datetime provider' {
            $testDate = "2024-01-01 12:00:00"
            $customProvider = { $testDate }
        
            $result = New-EmptyBackupResult -BackupDirectory "C:\Test" -DateTimeProvider $customProvider
            $result.BackupTimestamp | Should -Be $testDate
            }
        }
    }
    
    Describe "New-BackupDirectoryStructure" -Tag 'unit', 'ci' {
        BeforeEach {
            $testDir = "TestDrive:\backup"
            $imagesDir = "TestDrive:\backup\images"
        }
        
        Context 'main directory does not exist' {
            It 'creates main directory' {
            $mockProvider = @{
                TestPath = { param($path) $false }
                NewItem = { param($path, $type) 
                    New-Item -ItemType Directory -Path $path -Force | Out-Null 
                }
                JoinPath = { param($parent, $child) Join-Path $parent $child }
            }             
            { New-BackupDirectoryStructure -BackupDirectory $testDir -FileSystemProvider $mockProvider } | Should -Not -Throw
            }
        }
        
        Context 'images subdirectory requested' {
            It 'creates images subdirectory' {
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
    }   
    
    Describe "Write-ProcessingProgress" -Tag 'unit', 'ci' {
        Context 'valid parameters' {
            It 'does not throw' {
            $mockImage = @{
                repository = "nginx"
                tag = "latest"
            }
            
            { Write-ProcessingProgress -Current 1 -Total 1 -Action "Testing" -Image $mockImage } | Should -Not -Throw
            }
        }
    }
    
    Describe "Test-ImageOperationParameters" -Tag 'unit', 'ci' {
        Context 'valid parameters' {
            It 'validates parameters successfully' {
            $images = @(
                @{ repository = "nginx"; tag = "latest"; imageid = "123" }
                @{ repository = "redis"; tag = "6"; imageid = "456" }
            )
            
            $result = Test-ImageOperationParameters -BackupDirectory "C:\Valid\Path" -Images $images -RequiredSpaceGB 10
            
            $result.IsValid | Should -Be $true
            $result.Errors.Count | Should -Be 0
            }
        }
        
        Context 'invalid parameters' {
            It 'detects invalid backup directory' {
            $result = Test-ImageOperationParameters -BackupDirectory ""
            
            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "BackupDirectory cannot be empty or whitespace"
        }
        
            It 'detects invalid images' {
            $invalidImages = @(
                @{ repository = "nginx" }  # Missing tag and imageid
            )
            
            $result = Test-ImageOperationParameters -Images $invalidImages
            
            $result.IsValid | Should -Be $false
            $result.Errors | Should -Contain "Image at index 0 is missing required properties (repository, tag, imageid)"
        }
        
            It 'detects negative space requirement' {
                $result = Test-ImageOperationParameters -RequiredSpaceGB -5
                
                $result.IsValid | Should -Be $false
                $result.Errors | Should -Contain "RequiredSpaceGB must be a positive number"
            }
        }
    }
    
    Describe "New-ImageProcessingLog" -Tag 'unit', 'ci' {
        Context 'backup log creation' {
            It 'creates backup log with correct format' {
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
        }
        
        Context 'restore log with failures' {
            It 'includes failed images in log' {
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

    Describe "Get-K2sImageList" -Tag 'unit', 'ci' {
        Context 'script not found' {
            It 'returns empty array when Get-Images.ps1 does not exist' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock Test-Path { $false }

                    $result = Get-K2sImageList -CrictlExePath 'C:\k\bin\crictl.exe' -CrictlConfigPath 'C:\k\bin\crictl.yaml'

                    $result.Count | Should -Be 0
                }
            }
        }

        Context 'resolves crictl paths from installed cluster folder' {
            It 'accepts explicit crictl paths and returns empty array when script not found' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock Test-Path { $false }

                    $result = Get-K2sImageList -CrictlExePath 'C:\k\bin\crictl.exe' -CrictlConfigPath 'C:\k\bin\crictl.yaml'

                    $result.Count | Should -Be 0
                }
            }

            It 'accepts a non-default install folder path' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock Test-Path { $false }

                    $result = Get-K2sImageList -CrictlExePath 'D:\custom-k2s\bin\crictl.exe' -CrictlConfigPath 'D:\custom-k2s\bin\crictl.yaml'

                    $result.Count | Should -Be 0
                }
            }
        }
    }

    Describe "Backup-K2sImages" -Tag 'unit', 'ci' {
        Context 'empty images list' {
            It 'returns empty backup result without invoking Export-Image.ps1' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock New-EmptyBackupResult { @{ BackupDirectory = 'C:\backup'; Images = @(); Success = $true } }

                    $result = Backup-K2sImages -BackupDirectory 'C:\backup' -Images @()

                    $result.Success | Should -Be $true
                    $result.Images.Count | Should -Be 0
                    Should -Invoke New-EmptyBackupResult -Exactly 1
                }
            }
        }

        Context 'explicit crictl paths bypass default resolution' {
            It 'does not call Get-CrictlExePath when CrictlExePath is supplied' {
                InModuleScope $script:moduleName {
                    Mock Write-Log {}
                    Mock New-BackupDirectoryStructure {}
                    Mock Get-CrictlExePath { 'C:\default\bin\crictl.exe' }
                    Mock Get-KubeBinPath { 'C:\default\bin' }
                    Mock Test-Path { $true }
                    Mock Invoke-Expression {}
                    Mock Out-File {}
                    Mock New-ImageProcessingLog {}

                    $images = @(@{ repository = 'nginx'; tag = 'latest'; imageid = 'abc123'; node = 'win'; size = '100MB' })

                    Backup-K2sImages `
                        -BackupDirectory 'TestDrive:\backup' `
                        -Images $images `
                        -CrictlExePath 'C:\old\bin\crictl.exe' `
                        -CrictlConfigPath 'C:\old\bin\crictl.yaml'

                    Should -Invoke Get-CrictlExePath -Exactly 0
                }
            }
        }
    }
}

AfterAll {
    Remove-Module $script:moduleName -Force -ErrorAction SilentlyContinue
}
