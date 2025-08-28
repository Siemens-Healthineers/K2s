# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Image backup and restore functionality for K2s cluster upgrades

.DESCRIPTION
This module provides image backup and restore functionality during K2s cluster upgrades.
It backs up user application images before upgrade and restores them after successful upgrade.
#>

Import-Module "$PSScriptRoot\..\..\k2s.infra.module\k2s.infra.module.psm1"

<#
.SYNOPSIS
Gets list of images in the cluster

.DESCRIPTION
By default returns only user application images. Use -IncludeSystemImages to get all images.

.PARAMETER IncludeSystemImages
If set to true, includes system/infrastructure images in the list

.OUTPUTS
Array of image objects with metadata
#>
function Get-K2sImageList {
    param(
        [Parameter(Mandatory = $false)]
        [switch] $IncludeSystemImages
    )
    
    Write-Log "Discovering images in the cluster..." -Console
    
    try {
        # Use the existing Get-Images.ps1 script which already has proper filtering logic
        $getImagesScript = "$PSScriptRoot\..\..\..\..\scripts\k2s\image\Get-Images.ps1"
        
        if (-not (Test-Path $getImagesScript)) {
            Write-Log "Get-Images.ps1 script not found at: $getImagesScript" -Console
            return ,@()
        }
        
        # Build command arguments based on parameter
        $scriptArgs = @()
        if ($IncludeSystemImages) { 
            $scriptArgs += "-IncludeK8sImages" 
            $imageType = "all images including system images"
            $resultType = "total images"
        } else {
            $imageType = "user application images only (excluding system images)"
            $resultType = "user application images"
        }
        
        Write-Log "Getting $imageType" -Console
        
        # Execute script with appropriate arguments
        $imageResult = & $getImagesScript @scriptArgs
        
        # Validate and extract results
        $images = $imageResult.ContainerImages
        if (-not $images) {
            Write-Log "No container images found in cluster" -Console
            return ,@()
        }
        
        # Log results
        Write-Log "Found $($images.Count) $resultType" -Console
        
        return ,$images
    }
    catch {
        Write-Log "Error discovering images: $_" -Console
        return ,@()
    }
}

<#
.SYNOPSIS
Backs up user application images before cluster upgrade

.DESCRIPTION
Exports user application images to tar files and creates a manifest with metadata

.PARAMETER BackupDirectory
Directory where to store the backed up images

.PARAMETER Images
Array of image objects to backup

.OUTPUTS
Backup manifest object with image metadata
#>
function Backup-K2sImages {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [array] $Images = @()
    )
    
    Write-Log "Starting image backup to directory: $BackupDirectory" -Console
    
    if ($Images.Count -eq 0) {
        Write-Log "No images to backup" -Console
        return @{
            BackupTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            BackupDirectory = $BackupDirectory
            Images = @()
            Success = $true
        }
    }
    
    try {
        # Create backup directory structure
        if (-not (Test-Path $BackupDirectory)) {
            New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        }
        
        $imagesDir = Join-Path $BackupDirectory "images"
        if (-not (Test-Path $imagesDir)) {
            New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
        }
        
        $k2sExe = Get-K2sExePath
        $backupManifest = @{
            BackupTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            BackupDirectory = $BackupDirectory
            Images = @()
            FailedImages = @()
            Success = $true
        }
        
        $totalImages = $Images.Count
        $currentImage = 0
        
        foreach ($image in $Images) {
            $currentImage++
            
            Write-Log "[$currentImage/$totalImages] Backing up image: $($image.repository):$($image.tag)" -Console
            
            try {
                # Generate safe filename for tar archive
                $safeFileName = "$($image.repository -replace '[/\\:*?"<>|]', '_')-$($image.tag -replace '[/\\:*?"<>|]', '_')"
                $tarPath = Join-Path $imagesDir "$safeFileName.tar"
                
                # Export image using k2s image export
                $exportCommand = "$k2sExe image export --id $($image.imageid) -t `"$tarPath`""
                
                Write-Log "Exporting image with command: $exportCommand" 
                $result = Invoke-Expression $exportCommand 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    # Verify tar file was created and has content
                    if ((Test-Path $tarPath) -and ((Get-Item $tarPath).Length -gt 0)) {
                        $imageBackupInfo = @{
                            ImageId = $image.imageid
                            Repository = $image.repository
                            Tag = $image.tag
                            Node = $image.node
                            Size = $image.size
                            TarFile = $tarPath
                            BackupTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        }
                        $backupManifest.Images += $imageBackupInfo
                        Write-Log "Successfully backed up image: $($image.repository):$($image.tag)"
                    } else {
                        throw "Tar file was not created or is empty"
                    }
                } else {
                    throw "Export command failed with exit code $LASTEXITCODE : $result"
                }
            }
            catch {
                Write-Log "Failed to backup image $($image.repository):$($image.tag) - $_" -Console
                $backupManifest.FailedImages += @{
                    ImageId = $image.imageid
                    Repository = $image.repository
                    Tag = $image.tag
                    Error = $_.ToString()
                }
                $backupManifest.Success = $false
            }
        }
        
        # Save backup manifest
        $manifestPath = Join-Path $BackupDirectory "manifest.json"
        $backupManifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $manifestPath -Encoding UTF8
        
        # Create backup log
        $logPath = Join-Path $BackupDirectory "backup-log.txt"
        $logContent = @"
K2s Image Backup Log
===================
Backup Date: $($backupManifest.BackupTimestamp)
Total Images: $totalImages
Successful Backups: $($backupManifest.Images.Count)
Failed Backups: $($backupManifest.FailedImages.Count)
Backup Directory: $BackupDirectory

Backed Up Images:
"@
        
        foreach ($img in $backupManifest.Images) {
            $logContent += "`n- $($img.Repository):$($img.Tag) (ID: $($img.ImageId))"
        }
        
        if ($backupManifest.FailedImages.Count -gt 0) {
            $logContent += "`n`nFailed Images:"
            foreach ($img in $backupManifest.FailedImages) {
                $logContent += "`n- $($img.Repository):$($img.Tag) (ID: $($img.ImageId)) - Error: $($img.Error)"
            }
        }
        
        $logContent | Out-File -FilePath $logPath -Encoding UTF8
        
        if ($backupManifest.FailedImages.Count -gt 0) {
            Write-Log "Image backup completed with $($backupManifest.FailedImages.Count) failures. See $logPath for details." -Console
        } else {
            Write-Log "Successfully backed up all $($backupManifest.Images.Count) images" -Console
        }
        
        return $backupManifest
    }
    catch {
        Write-Log "Critical error during image backup: $_" -Console
        throw $_
    }
}

<#
.SYNOPSIS
Restores user application images after cluster upgrade

.DESCRIPTION
Imports previously backed up images from tar files using backup manifest

.PARAMETER BackupDirectory
Directory containing the backed up images

.PARAMETER ManifestPath
Path to the backup manifest file (optional, will be auto-detected)

.OUTPUTS
Restore result object with success/failure information
#>
function Restore-K2sImages {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [string] $ManifestPath
    )
    
    Write-Log "Starting image restore from directory: $BackupDirectory" -Console
    
    try {
        # Load backup manifest
        if (-not $ManifestPath) {
            $ManifestPath = Join-Path $BackupDirectory "manifest.json"
        }
        
        if (-not (Test-Path $ManifestPath)) {
            Write-Log "Backup manifest not found at: $ManifestPath" -Console
            return @{
                Success = $false
                Error = "Backup manifest not found"
                RestoredImages = @()
                FailedImages = @()
            }
        }
        
        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        
        if ($manifest.Images.Count -eq 0) {
            Write-Log "No images found in backup manifest" -Console
            return @{
                Success = $true
                RestoredImages = @()
                FailedImages = @()
                Message = "No images to restore"
            }
        }
        
        $k2sExe = Get-K2sExePath
        $restoreResult = @{
            RestoreTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            RestoredImages = @()
            FailedImages = @()
            Success = $true
        }
        
        $totalImages = $manifest.Images.Count
        $currentImage = 0
        
        foreach ($imageInfo in $manifest.Images) {
            $currentImage++
            
            Write-Log "[$currentImage/$totalImages] Restoring image: $($imageInfo.Repository):$($imageInfo.Tag)" -Console
            
            try {
                $tarPath = $imageInfo.TarFile
                
                if (-not (Test-Path $tarPath)) {
                    throw "Tar file not found: $tarPath"
                }
                
                # Import image using k2s image import
                $importCommand = "$k2sExe image import -t `"$tarPath`""
                
                # Check if this is a Windows image (add -w flag if needed)
                if ($imageInfo.Node -and $imageInfo.Node -like "*windows*") {
                    $importCommand += " -w"
                }
                
                Write-Log "Importing image with command: $importCommand"
                $result = Invoke-Expression $importCommand 2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    $restoreResult.RestoredImages += @{
                        ImageId = $imageInfo.ImageId
                        Repository = $imageInfo.Repository
                        Tag = $imageInfo.Tag
                        TarFile = $tarPath
                        RestoreTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    }
                    Write-Log "Successfully restored image: $($imageInfo.Repository):$($imageInfo.Tag)"
                } else {
                    throw "Import command failed with exit code $LASTEXITCODE : $result"
                }
            }
            catch {
                Write-Log "Failed to restore image $($imageInfo.Repository):$($imageInfo.Tag) - $_" -Console
                $restoreResult.FailedImages += @{
                    ImageId = $imageInfo.ImageId
                    Repository = $imageInfo.Repository
                    Tag = $imageInfo.Tag
                    TarFile = $imageInfo.TarFile
                    Error = $_.ToString()
                }
                $restoreResult.Success = $false
            }
        }
        
        # Create restore log
        if (-not (Test-Path $BackupDirectory)) {
            New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        }
        
        $logPath = Join-Path $BackupDirectory "restore-log.txt"
        $logContent = @"
K2s Image Restore Log
====================
Restore Date: $($restoreResult.RestoreTimestamp)
Original Backup Date: $($manifest.BackupTimestamp)
Total Images to Restore: $totalImages
Successful Restores: $($restoreResult.RestoredImages.Count)
Failed Restores: $($restoreResult.FailedImages.Count)

Restored Images:
"@
        
        foreach ($img in $restoreResult.RestoredImages) {
            $logContent += "`n- $($img.Repository):$($img.Tag) (ID: $($img.ImageId))"
        }
        
        if ($restoreResult.FailedImages.Count -gt 0) {
            $logContent += "`n`nFailed Images:"
            foreach ($img in $restoreResult.FailedImages) {
                $logContent += "`n- $($img.Repository):$($img.Tag) (ID: $($img.ImageId)) - Error: $($img.Error)"
            }
        }
        
        $logContent | Out-File -FilePath $logPath -Encoding UTF8
        
        if ($restoreResult.FailedImages.Count -gt 0) {
            Write-Log "Image restore completed with $($restoreResult.FailedImages.Count) failures. See $logPath for details." -Console
        } else {
            Write-Log "Successfully restored all $($restoreResult.RestoredImages.Count) images" -Console
        }
        
        return $restoreResult
    }
    catch {
        Write-Log "Critical error during image restore: $_" -Console
        throw $_
    }
}

<#
.SYNOPSIS
Validates available disk space for image backup

.DESCRIPTION
Checks if there's sufficient disk space for backing up images

.PARAMETER BackupDirectory
Directory where images will be backed up

.PARAMETER RequiredSpaceGB
Required space in GB (optional, calculated from images if not provided)

.PARAMETER Images
Array of images to backup (used for space calculation)

.OUTPUTS
Boolean indicating if sufficient space is available
#>
function Test-BackupDiskSpace {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [int] $RequiredSpaceGB,
        
        [Parameter(Mandatory = $false)]
        [array] $Images
    )
    
    try {
        # Validate input - prevent dangerous defaults
        if (-not $RequiredSpaceGB -and (-not $Images -or $Images.Count -eq 0)) {
            throw "Either RequiredSpaceGB must be specified or Images array must be provided for space calculation."
        }
        
        $drive = Split-Path $BackupDirectory -Qualifier
        if (-not $drive) {
            $drive = "C:"
        }
        
        $driveInfo = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { $_.DeviceID -eq $drive }
        if (-not $driveInfo) {
            throw "Could not get disk information for drive: $drive"
        }
        
        $freeSpaceGB = [math]::Round($driveInfo.FreeSpace / 1GB, 2)
        
        if ($RequiredSpaceGB) {
            $requiredSpace = $RequiredSpaceGB
        } else {
            # Calculate size from images
            $totalSizeGB = 0
            foreach ($image in $Images) {
                if ($image.size -match "(\d+(?:\.\d+)?)\s*(KB|MB|GB|TB)") {
                    $size = [double]$Matches[1]
                    $unit = $Matches[2].ToUpper()
                    
                    switch ($unit) {
                        "KB" { $totalSizeGB += $size / (1024 * 1024) }
                        "MB" { $totalSizeGB += $size / 1024 }
                        "GB" { $totalSizeGB += $size }
                        "TB" { $totalSizeGB += $size * 1024 }
                    }
                }
            }
            
            # Add just 5% buffer (1.05 multiplier)
            $requiredSpace = [math]::Ceiling($totalSizeGB * 1.05)
        }
        
        Write-Log "Disk space check: Available: ${freeSpaceGB}GB, Required: ${requiredSpace}GB" -Console
        
        if ($freeSpaceGB -ge $requiredSpace) {
            Write-Log "✅ Sufficient disk space available for backup" -Console
            return $true
        } else {
            $shortfall = $requiredSpace - $freeSpaceGB
            Write-Log "❌ Insufficient disk space for image backup. Available: ${freeSpaceGB}GB, Required: ${requiredSpace}GB (Shortfall: ${shortfall}GB)" -Console
            return $false
        }
    }
    catch {
        Write-Log "Error checking disk space: $_" -Console
        return $false
    }
}

<#
.SYNOPSIS
Cleans up backup files based on retention policy

.DESCRIPTION
Removes old backup files to free up disk space

.PARAMETER BackupDirectory
Directory containing backup files

.PARAMETER RetentionDays
Number of days to retain backup files (default: 7)

.PARAMETER DryRun
If true, only shows what would be deleted without actually deleting
#>
function Remove-OldImageBackups {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BackupDirectory,
        
        [Parameter(Mandatory = $false)]
        [int] $RetentionDays = 7,
        
        [Parameter(Mandatory = $false)]
        [switch] $DryRun
    )
    
    try {
        $cutoffDate = (Get-Date).AddDays(-$RetentionDays)
        $oldBackups = Get-ChildItem -Path $BackupDirectory -Directory | Where-Object { $_.CreationTime -lt $cutoffDate }
        
        if ($oldBackups.Count -eq 0) {
            Write-Log "No old backup directories found to clean up" -Console
            return
        }
        
        foreach ($backup in $oldBackups) {
            if ($DryRun) {
                Write-Log "Would delete backup directory: $($backup.FullName) (Created: $($backup.CreationTime))" -Console
            } else {
                Write-Log "Deleting old backup directory: $($backup.FullName) (Created: $($backup.CreationTime))" -Console
                Remove-Item -Path $backup.FullName -Recurse -Force
            }
        }
        
        if (-not $DryRun) {
            Write-Log "Cleanup completed. Removed $($oldBackups.Count) old backup directories" -Console
        }
    }
    catch {
        Write-Log "Error during backup cleanup: $_" -Console
    }
}

Export-ModuleMember -Function Get-K2sImageList, Backup-K2sImages, Restore-K2sImages, Test-BackupDiskSpace, Remove-OldImageBackups
