# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Helper functions for container image layer acquisition in delta packages.

.DESCRIPTION
Provides layer extraction and offline acquisition for delta package creation.
Exports individual layers from changed images to minimize delta size.
#>

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Exports changed image layers for delta package.

.DESCRIPTION
Boots temporary VM with new package VHDX, exports only new/changed layers
from modified images, organizes them in delta structure.

.PARAMETER NewVhdxPath
Path to the new package's VHDX file.

.PARAMETER ChangedImages
Array of changed image objects from Compare-ContainerImages.

.PARAMETER StagingDir
Directory to stage extracted layers.

.PARAMETER ShowLogs
Show detailed logs.

.OUTPUTS
Hashtable with Success flag, ExtractedLayers array, and statistics.
#>
function Export-ChangedImageLayers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NewVhdxPath,
        
        [Parameter(Mandatory = $true)]
        [array]$ChangedImages,
        
        [Parameter(Mandatory = $true)]
        [string]$StagingDir,
        
        [Parameter(Mandatory = $false)]
        [switch]$ShowLogs
    )
    
    $result = @{
        Success         = $false
        ExtractedLayers = @()
        TotalSize       = 0
        ErrorMessage    = ''
        FailedImages    = @()
    }
    
    if ($ChangedImages.Count -eq 0) {
        Write-Log "[ImageAcq] No changed images to process" -Console
        $result.Success = $true
        return $result
    }
    
    Write-Log "[ImageAcq] Processing $($ChangedImages.Count) changed images for layer extraction" -Console
    
    # Create staging directories
    $linuxLayersDir = Join-Path $StagingDir 'image-delta\linux\layers'
    $windowsLayersDir = Join-Path $StagingDir 'image-delta\windows\layers'
    
    New-Item -ItemType Directory -Path $linuxLayersDir -Force | Out-Null
    New-Item -ItemType Directory -Path $windowsLayersDir -Force | Out-Null
    
    $vmName = $null
    
    try {
        # Create temporary VM for Linux image processing
        $linuxImages = $ChangedImages | Where-Object { $_.Platform -eq 'linux' }
        
        if ($linuxImages.Count -gt 0) {
            Write-Log "[ImageAcq] Creating temporary VM for Linux image layer extraction..." -Console
            $vmParams = New-K2sHvTempVm -VhdxPath $NewVhdxPath
            
            if (-not $vmParams -or -not $vmParams.Name) {
                $result.ErrorMessage = "Failed to create temporary VM"
                return $result
            }
            
            $vmName = $vmParams.Name
            Write-Log "[ImageAcq] Temporary VM created: $vmName" -Console
            
            # Process each Linux image
            foreach ($imgChange in $linuxImages) {
                try {
                    Write-Log "[ImageAcq] Processing Linux image: $($imgChange.FullName)" -Console
                    
                    $layerResult = Export-LinuxImageLayers -VmName $vmName `
                                                           -ImageChange $imgChange `
                                                           -LayersDir $linuxLayersDir `
                                                           -ShowLogs:$ShowLogs
                    
                    if ($layerResult.Success) {
                        $result.ExtractedLayers += $layerResult.Layers
                        $result.TotalSize += $layerResult.Size
                        Write-Log "[ImageAcq] Successfully extracted $($layerResult.Layers.Count) layers from $($imgChange.FullName)" -Console
                    } else {
                        Write-Log "[ImageAcq] Warning: Failed to extract layers from $($imgChange.FullName): $($layerResult.ErrorMessage)" -Console
                        $result.FailedImages += $imgChange.FullName
                    }
                    
                } catch {
                    Write-Log "[ImageAcq] Error processing image $($imgChange.FullName): $_" -Console
                    $result.FailedImages += $imgChange.FullName
                }
            }
        }
        
        # Process Windows images (if any)
        $windowsImages = $ChangedImages | Where-Object { $_.Platform -eq 'windows' }
        
        if ($windowsImages.Count -gt 0) {
            Write-Log "[ImageAcq] Processing $($windowsImages.Count) Windows images..." -Console
            Write-Log "[ImageAcq] Note: Windows image delta extraction requires images loaded in local containerd" -Console
            
            foreach ($imgChange in $windowsImages) {
                try {
                    Write-Log "[ImageAcq] Processing Windows image: $($imgChange.FullName)" -Console
                    
                    $layerResult = Export-WindowsImageLayers -ImageChange $imgChange `
                                                             -LayersDir $windowsLayersDir `
                                                             -ShowLogs:$ShowLogs
                    
                    if ($layerResult.Success) {
                        $result.ExtractedLayers += $layerResult.Layers
                        $result.TotalSize += $layerResult.Size
                        Write-Log "[ImageAcq] Successfully extracted Windows image: $($imgChange.FullName)" -Console
                    } else {
                        Write-Log "[ImageAcq] Warning: Failed to extract Windows image $($imgChange.FullName): $($layerResult.ErrorMessage)" -Console
                        $result.FailedImages += $imgChange.FullName
                    }
                    
                } catch {
                    Write-Log "[ImageAcq] Error processing Windows image $($imgChange.FullName): $_" -Console
                    $result.FailedImages += $imgChange.FullName
                }
            }
        }
        
        $result.Success = $true
        $totalSizeMB = [math]::Round($result.TotalSize / 1MB, 2)
        Write-Log "[ImageAcq] Layer extraction complete. Extracted: $($result.ExtractedLayers.Count) layers, Total size: ${totalSizeMB} MB, Failed: $($result.FailedImages.Count)" -Console
        
    } catch {
        $result.ErrorMessage = "Exception during layer extraction: $_"
        Write-Log $result.ErrorMessage -Console
        
    } finally {
        # Cleanup temporary VM
        if ($vmName) {
            Write-Log "[ImageAcq] Cleaning up temporary VM: $vmName" -Console
            Remove-K2sHvEnvironment -VmName $vmName
        }
    }
    
    return $result
}

<#
.SYNOPSIS
Exports layers from a Linux image using buildah in the VM.

.PARAMETER VmName
Name of the temporary VM.

.PARAMETER ImageChange
Image change object containing OldImage and NewImage.

.PARAMETER LayersDir
Directory to store extracted layer tarballs.

.OUTPUTS
Hashtable with Success flag, Layers array, Size, and ErrorMessage.
#>
function Export-LinuxImageLayers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ImageChange,
        
        [Parameter(Mandatory = $true)]
        [string]$LayersDir,
        
        [Parameter(Mandatory = $false)]
        [switch]$ShowLogs
    )
    
    $result = @{
        Success      = $false
        Layers       = @()
        Size         = 0
        ErrorMessage = ''
    }
    
    try {
        # Get layer information for new image
        $newImageId = $ImageChange.NewImage.Id
        $imageName = $ImageChange.FullName
        
        Write-Log "[ImageAcq] Inspecting new image layers: $imageName" -Console
        $cmd = "sudo buildah inspect --type image '$newImageId'"
        $output = Invoke-K2sGuestCmd -VmName $VmName -Command $cmd -Timeout 30
        
        if (-not $output.Success) {
            $result.ErrorMessage = "Failed to inspect image: $($output.ErrorMessage)"
            return $result
        }
        
        $inspectData = $output.Output | ConvertFrom-Json
        $newLayers = @()
        
        if ($inspectData.RootFS -and $inspectData.RootFS.Layers) {
            $newLayers = $inspectData.RootFS.Layers
            Write-Log "[ImageAcq] New image has $($newLayers.Count) layers" -Console
        } else {
            $result.ErrorMessage = "No layers found in image"
            return $result
        }
        
        # Note: Layer-level extraction is complex and not yet implemented
        # For now, export the entire image as a tar archive
        # Future enhancement: extract only new/changed layers by comparing with old image
        Write-Log "[ImageAcq] Exporting full image as OCI archive..." -Console
        
        $sanitizedName = $imageName -replace '[/:]', '-'
        $remoteTarPath = "/tmp/delta-image-$sanitizedName.tar"
        $localTarPath = Join-Path $LayersDir "$sanitizedName.tar"
        
        # Export image to tar (build command carefully to avoid PowerShell variable parsing issues)
        $ociArchivePath = "oci-archive:$remoteTarPath" + ":$imageName"
        $exportCmd = "sudo buildah push '$newImageId' $ociArchivePath 2>&1"
        $exportOutput = Invoke-K2sGuestCmd -VmName $VmName -Command $exportCmd -Timeout 120
        
        if (-not $exportOutput.Success) {
            $result.ErrorMessage = "Failed to export image: $($exportOutput.ErrorMessage)"
            
            # Cleanup remote tar
            Invoke-K2sGuestCmd -VmName $VmName -Command "sudo rm -f $remoteTarPath" -Timeout 10 | Out-Null
            return $result
        }
        
        Write-Log "[ImageAcq] Image exported, copying to host..." -Console
        
        # Copy tar from VM to host
        $copyResult = Copy-K2sGuestFile -VmName $VmName -RemotePath $remoteTarPath -LocalPath $localTarPath
        
        if (-not $copyResult.Success) {
            $result.ErrorMessage = "Failed to copy image tar: $($copyResult.ErrorMessage)"
            
            # Cleanup remote tar
            Invoke-K2sGuestCmd -VmName $VmName -Command "sudo rm -f $remoteTarPath" -Timeout 10 | Out-Null
            return $result
        }
        
        # Cleanup remote tar
        Invoke-K2sGuestCmd -VmName $VmName -Command "sudo rm -f $remoteTarPath" -Timeout 10 | Out-Null
        
        # Get file size
        if (Test-Path $localTarPath) {
            $fileInfo = Get-Item $localTarPath
            $result.Size = $fileInfo.Length
            
            $result.Layers += [PSCustomObject]@{
                ImageName    = $imageName
                Platform     = 'linux'
                FilePath     = $localTarPath
                RelativePath = "image-delta/linux/layers/$sanitizedName.tar"
                Size         = $result.Size
                LayerCount   = $newLayers.Count
            }
            
            $result.Success = $true
            $sizeMB = [math]::Round($result.Size / 1MB, 2)
            Write-Log "[ImageAcq] Image exported successfully: ${sizeMB} MB" -Console
        } else {
            $result.ErrorMessage = "Exported tar not found at expected path"
        }
        
    } catch {
        $result.ErrorMessage = "Exception during Linux layer export: $_"
        Write-Log $result.ErrorMessage -Console
    }
    
    return $result
}

<#
.SYNOPSIS
Exports a Windows image (placeholder for future implementation).

.PARAMETER ImageChange
Image change object.

.PARAMETER LayersDir
Directory to store extracted image.

.OUTPUTS
Hashtable with Success flag and ErrorMessage.
#>
function Export-WindowsImageLayers {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$ImageChange,
        
        [Parameter(Mandatory = $true)]
        [string]$LayersDir,
        
        [Parameter(Mandatory = $false)]
        [switch]$ShowLogs
    )
    
    $result = @{
        Success      = $false
        Layers       = @()
        Size         = 0
        ErrorMessage = ''
    }
    
    # Windows image delta extraction requires nerdctl or ctr on the Windows host
    # For now, mark as not implemented
    
    Write-Log "[ImageAcq] Windows image layer extraction not yet implemented: $($ImageChange.FullName)" -Console
    Write-Log "[ImageAcq] Windows images will be included as full images in the delta package" -Console
    
    # Return success but with no layers extracted
    # Full Windows images will be handled by the regular addon export mechanism
    $result.Success = $true
    $result.ErrorMessage = "Windows layer extraction not implemented - full image export required"
    
    return $result
}
