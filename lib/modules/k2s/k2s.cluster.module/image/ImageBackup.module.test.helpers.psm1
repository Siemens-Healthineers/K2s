# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Test helpers and mock providers for ImageBackup module testing

.DESCRIPTION
This module provides helper functions and mock providers to facilitate testing
of the ImageBackup module with Pester.
#>

<#
.SYNOPSIS
Creates a mock file system provider for testing

.DESCRIPTION
Returns a hashtable with mock file system operations that can be used in tests

.PARAMETER Behavior
Hashtable defining the behavior of each operation
#>
function New-MockFileSystemProvider {
    param(
        [Parameter(Mandatory = $false)]
        [hashtable] $Behavior = @{}
    )
    
    $defaultBehavior = @{
        TestPath = { param($path) $true }
        NewItem = { param($path, $type) $path }
        JoinPath = { param($parent, $child) "$parent\$child" }
        GetItem = { param($path) @{ Length = 1024 } }
        GetContent = { param($path) "mock content" }
        SetContent = { param($path, $content) $content }
    }
    
    # Merge with custom behavior
    foreach ($key in $Behavior.Keys) {
        $defaultBehavior[$key] = $Behavior[$key]
    }
    
    return $defaultBehavior
}

<#
.SYNOPSIS
Creates mock image data for testing

.DESCRIPTION
Generates realistic test image data for use in unit tests

.PARAMETER Count
Number of images to generate

.PARAMETER IncludeWindowsImages
Include Windows container images in the mock data
#>
function New-MockImageData {
    param(
        [Parameter(Mandatory = $false)]
        [int] $Count = 3,
        
        [Parameter(Mandatory = $false)]
        [switch] $IncludeWindowsImages
    )
    
    $images = @()
    $repos = @("nginx", "redis", "postgres", "mysql", "mongo")
    $tags = @("latest", "alpine", "1.0", "2.1", "stable")
    $sizes = @("100MB", "250MB", "500MB", "1.2GB", "2.5GB")
    
    for ($i = 0; $i -lt $Count; $i++) {
        $repo = $repos[$i % $repos.Count]
        $tag = $tags[$i % $tags.Count]
        $size = $sizes[$i % $sizes.Count]
        $node = if ($IncludeWindowsImages -and ($i % 3 -eq 0)) { "windows-node" } else { "kubemaster" }
        
        $images += @{
            repository = $repo
            tag = $tag
            imageid = "abc123def456$i"
            node = $node
            size = $size
        }
    }
    
    return $images
}

<#
.SYNOPSIS
Creates a mock command executor for testing

.DESCRIPTION
Returns a script block that simulates k2s command execution

.PARAMETER SimulateFailure
If true, simulates command failures

.PARAMETER ExitCode
Exit code to return (default: 0 for success)

.PARAMETER Output
Output to return from command execution
#>
function New-MockCommandExecutor {
    param(
        [Parameter(Mandatory = $false)]
        [switch] $SimulateFailure,
        
        [Parameter(Mandatory = $false)]
        [int] $ExitCode = 0,
        
        [Parameter(Mandatory = $false)]
        [string] $Output = "Command executed successfully"
    )
    
    return {
        param($command)
        
        if ($SimulateFailure) {
            $global:LASTEXITCODE = $ExitCode
            return "Error: Command failed"
        } else {
            $global:LASTEXITCODE = 0
            return $Output
        }
    }
}

<#
.SYNOPSIS
Creates test manifest data

.DESCRIPTION
Generates a realistic backup manifest for testing restore operations

.PARAMETER Images
Array of image data to include in manifest

.PARAMETER BackupTimestamp
Timestamp for the backup

.PARAMETER BackupDirectory
Base backup directory (defaults to TestDrive for testing)
#>
function New-MockManifest {
    param(
        [Parameter(Mandatory = $true)]
        [array] $Images,
        
        [Parameter(Mandatory = $false)]
        [string] $BackupTimestamp = "2024-01-01 12:00:00",
        
        [Parameter(Mandatory = $false)]
        [string] $BackupDirectory = "TestDrive:\backup"
    )
    
    $manifestImages = @()
    foreach ($image in $Images) {
        $manifestImages += @{
            ImageId = $image.imageid
            Repository = $image.repository
            Tag = $image.tag
            Node = $image.node
            Size = $image.size
            TarFile = "$BackupDirectory\images\$($image.repository)-$($image.tag).tar"
            BackupTimestamp = $BackupTimestamp
        }
    }
    
    return @{
        BackupTimestamp = $BackupTimestamp
        BackupDirectory = $BackupDirectory
        Images = $manifestImages
        FailedImages = @()
        Success = $true
    }
}

<#
.SYNOPSIS
Validates test results structure

.DESCRIPTION
Helper function to validate that backup/restore results have the expected structure

.PARAMETER Result
The result object to validate

.PARAMETER Type
Type of result: "Backup" or "Restore"
#>
function Test-ResultStructure {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Result,
        
        [Parameter(Mandatory = $true)]
        [ValidateSet("Backup", "Restore")]
        [string] $Type
    )
    
    $expectedProperties = @("Success", "Images", "FailedImages")
    
    if ($Type -eq "Backup") {
        $expectedProperties += @("BackupTimestamp", "BackupDirectory")
    } else {
        $expectedProperties += @("RestoreTimestamp", "RestoredImages")
    }
    
    $validationResult = @{
        IsValid = $true
        MissingProperties = @()
        UnexpectedProperties = @()
    }
    
    # Check for missing properties
    foreach ($prop in $expectedProperties) {
        if (-not $Result.ContainsKey($prop)) {
            $validationResult.IsValid = $false
            $validationResult.MissingProperties += $prop
        }
    }
    
    # Check for unexpected properties (optional)
    $allowedExtraProperties = @("Message", "Error")
    foreach ($prop in $Result.Keys) {
        if ($prop -notin $expectedProperties -and $prop -notin $allowedExtraProperties) {
            $validationResult.UnexpectedProperties += $prop
        }
    }
    
    return $validationResult
}

Export-ModuleMember -Function New-MockFileSystemProvider, New-MockImageData, New-MockCommandExecutor, New-MockManifest, Test-ResultStructure
