# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

# Import.ps1


Param (
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Path to OCI artifact tar file')]
    [string] $ArtifactFile,
    [parameter(Mandatory = $false, HelpMessage = 'Name of Addons to import')]
    [string[]] $Names,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
$infraModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\addons.module.psm1"
$ociModule = "$PSScriptRoot\oci.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule, $ociModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

$setupInfo = Get-SetupInfo

$tmpDir = "$env:TEMP\$(Get-Date -Format ddMMyyyy-HHmmss)-tmp-extracted-addons"
$extractionFolder = "$tmpDir\artifacts"

if ($ArtifactFile) {
    Write-Log "[OCI] Extracting artifact from $ArtifactFile" -Console
    Write-Log '---' -Console
    
    Remove-Item -Force $extractionFolder -Recurse -Confirm:$False -ErrorAction SilentlyContinue
    
    # Check disk space
    $artifactSize = (Get-Item $ArtifactFile).length
    $drive = (Get-Item $env:TEMP).PSDrive.Name
    $freeSpace = (Get-PSDrive -Name $drive).Free
    $freeSpaceGB = [math]::Round($freeSpace / 1GB, 2)
    $artifactSizeGB = [math]::Round($artifactSize / 1GB, 2)
    $additionalSpace = 2 * 1024 * 1024 * 1024 # 2 GB
    
    Write-Log "Free space $freeSpaceGB GB, size of artifact file: $artifactSizeGB GB" -Console
    
    if ($artifactSize -gt ($freeSpace + $additionalSpace)) {
        $errMsg = "Not enough space on drive $drive to extract the artifact. Required space: $artifactSize bytes, Free space: $freeSpace bytes."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-space-insufficient' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
    
    # Detect format and extract
    if ($ArtifactFile -match '\.oci\.tar$') {
        # OCI tar artifact
        Write-Log "[OCI] Detected OCI artifact format" -Console
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        
        $currentLocation = Get-Location
        try {
            Set-Location $tmpDir
            $tarResult = & tar -xf $ArtifactFile 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to extract OCI tar: $tarResult"
            }
        }
        finally {
            Set-Location $currentLocation
        }
    }
    else {
        $errMsg = "Unknown artifact format. Supported formats: .oci.tar"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-format-invalid' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}
else {
    $errMsg = "No artifact source specified. Provide -ArtifactFile parameter."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-source-missing' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Process OCI artifact
$addonsToImport = @()

# OCI Artifact format processing
Write-Log "[OCI] Processing OCI artifact structure" -Console

# Verify OCI Image Layout compliance
$ociLayoutPath = Join-Path $extractionFolder 'oci-layout'
if (-not (Test-Path $ociLayoutPath)) {
    $errMsg = 'Invalid OCI artifact format: oci-layout file not found.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$ociLayout = Get-Content $ociLayoutPath | ConvertFrom-Json
Write-Log "[OCI] OCI Layout version: $($ociLayout.imageLayoutVersion)" -Console

# Verify blobs directory exists
$blobsDir = Join-Path $extractionFolder 'blobs\sha256'
if (-not (Test-Path $blobsDir)) {
    $errMsg = 'Invalid OCI artifact format: blobs/sha256 directory not found.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Read index.json to get addon list from OCI-compliant structure
$indexJsonPath = Join-Path $extractionFolder 'index.json'
if (-not (Test-Path $indexJsonPath)) {
    $errMsg = 'Invalid OCI artifact format: index.json not found.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$indexManifest = Get-Content $indexJsonPath | Out-String | ConvertFrom-Json
$exportedAddons = @()
foreach ($manifest in $indexManifest.manifests) {
    $exportedAddons += @{
        name = $manifest.annotations.'vnd.k2s.addon.name'
        implementation = $manifest.annotations.'vnd.k2s.addon.implementation'
        version = $manifest.annotations.'vnd.k2s.addon.version'
        manifestDigest = $manifest.digest
        manifestSize = $manifest.size
    }
}

if ($null -eq $exportedAddons -or $exportedAddons.Count -lt 1) {
    $errMsg = 'Invalid OCI artifact format: no addons found.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

# Filter by names if specified
if ($Names.Count -gt 0) {
    foreach ($name in $Names) {
        $foundAddons = $exportedAddons | Where-Object { $_.name -match $name }
        if ($null -eq $foundAddons) {
            Remove-Item -Force $tmpDir -Recurse -Confirm:$False -ErrorAction SilentlyContinue
            $errMsg = "Addon '$name' not found in OCI artifact for import!"
            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code (Get-ErrCodeAddonNotFound) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }
            Write-Log $errMsg -Error
            exit 1
        }
        $addonsToImport += $foundAddons
    }
}
else {
    $addonsToImport = $exportedAddons
}

foreach ($addon in $addonsToImport) {
    Write-Log "[OCI] Importing addon: $($addon.name)" -Console
    
    # Read manifest from blobs using digest
    $ociManifest = $null
    if ($addon.manifestDigest) {
            $ociManifest = Get-JsonBlobByDigest -BlobsDir $blobsDir -Digest $addon.manifestDigest
            Write-Log "[OCI] -> Manifest digest: $($addon.manifestDigest)"
            Write-Log "[OCI] -> Version: $($ociManifest.annotations.'org.opencontainers.image.version')"
            Write-Log "[OCI] -> K2s Version: $($ociManifest.annotations.'vnd.k2s.version')"
            Write-Log "[OCI] -> Export Date: $($ociManifest.annotations.'vnd.k2s.export.date')"
        } else {
            Write-Log "[OCI] Warning: No manifest digest for addon $($addon.name)" -Console
            continue
        }
        
        # Extract base addon name and implementation name for multi-implementation addons
        # Directory name format: addonname_implementation (e.g., ingress_traefik)
        $implementationName = $null
        $baseAddonName = if ($addon.name -match '^([^_]+)_(.+)$') {
            $implementationName = $matches[2]  # Get the part after the underscore (e.g., "traefik")
            $matches[1]  # Get the part before the first underscore (e.g., "ingress")
        } else {
            $addon.name  # Single implementation addon
        }
        
        # Build destination path: addons/<base-addon-name>
        $folderParts = $baseAddonName -split '\s+'
        $destinationPath = $PSScriptRoot
        foreach ($part in $folderParts) {
            $destinationPath = Join-Path -Path $destinationPath -ChildPath $part
        }
        
        # For multi-implementation addons, create implementation subdirectory
        # e.g., addons/ingress/traefik/ for ingress_traefik
        $implementationPath = $destinationPath
        if ($implementationName) {
            $implementationPath = Join-Path $destinationPath $implementationName
            Write-Log "[OCI] Destination: $implementationPath (base addon: $baseAddonName, implementation: $implementationName)"
        } else {
            Write-Log "[OCI] Destination: $destinationPath (addon: $baseAddonName)"
        }
        
        # Ensure base destination path exists
        if (-not (Test-Path $destinationPath)) {
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        }
        
        # For multi-implementation addons, create the implementation subdirectory
        if ($implementationName -and -not (Test-Path $implementationPath)) {
            New-Item -ItemType Directory -Path $implementationPath -Force | Out-Null
        }
        
        # Create temp directory for extracting layers from blobs
        $tempLayerDir = Join-Path $tmpDir "layer-temp-$($addon.name)"
        New-Item -ItemType Directory -Path $tempLayerDir -Force | Out-Null
        
        # Process each layer from manifest by resolving from blobs
        foreach ($layer in $ociManifest.layers) {
            $layerTitle = $layer.annotations.'org.opencontainers.image.title'
            $layerDigest = $layer.digest
            $layerMediaType = $layer.mediaType
            
            Write-Log "[OCI] Processing layer: $layerTitle ($layerDigest)"
            
            # Get the blob path for this layer
            $blobPath = Get-BlobByDigest -BlobsDir $blobsDir -Digest $layerDigest
            
            switch -Wildcard ($layerMediaType) {
                '*configfiles*' {
                    # Layer 0: Configuration files (addon.manifest.yaml, values.yaml, settings.json, etc.)
                    Write-Log "[OCI] Extracting config files layer from blob"
                    $tempConfigDir = Join-Path $tempLayerDir 'config'
                    New-Item -ItemType Directory -Path $tempConfigDir -Force | Out-Null
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $tempConfigDir
                    Write-Log "[OCI] Staged config files layer for processing"
                    break
                }
                '*manifests*' {
                    # Layer 1: Manifests - extract to implementation path for multi-impl addons
                    Write-Log "[OCI] Extracting manifests layer from blob"
                    $manifestsDestDir = Join-Path $implementationPath 'manifests'
                    New-Item -ItemType Directory -Path $manifestsDestDir -Force | Out-Null
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $manifestsDestDir
                    break
                }
                '*helm.chart*' {
                    # Layer 2: Charts - extract to implementation path for multi-impl addons
                    Write-Log "[OCI] Extracting charts layer from blob"
                    $chartsDestDir = Join-Path $implementationPath 'manifests\chart'
                    New-Item -ItemType Directory -Path $chartsDestDir -Force | Out-Null
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $chartsDestDir
                    break
                }
                '*scripts*' {
                    # Layer 3: Scripts - extract to implementation path for multi-impl addons
                    Write-Log "[OCI] Extracting scripts layer from blob"
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $implementationPath
                    break
                }
                '*image.layer*windows*' {
                    # Layer 5: Windows Images - copy to temp for later processing
                    $tempWindowsImages = Join-Path $tempLayerDir 'images-windows.tar'
                    Copy-Item -Path $blobPath -Destination $tempWindowsImages -Force
                    Write-Log "[OCI] Staged Windows images layer for import"
                    break
                }
                '*image.layer*' {
                    # Layer 4: Linux Images - copy to temp for later processing
                    $tempLinuxImages = Join-Path $tempLayerDir 'images-linux.tar'
                    Copy-Item -Path $blobPath -Destination $tempLinuxImages -Force
                    Write-Log "[OCI] Staged Linux images layer for import"
                    break
                }
                '*packages*' {
                    # Layer 6: Packages - extract to temp for processing
                    $tempPackagesDir = Join-Path $tempLayerDir 'packages'
                    New-Item -ItemType Directory -Path $tempPackagesDir -Force | Out-Null
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $tempPackagesDir
                    Write-Log "[OCI] Staged packages layer for import"
                    break
                }
            }
        }
        
        # Handle config files from the config layer (Layer 0)
        $tempConfigDir = Join-Path $tempLayerDir 'config'
        $configManifestPath = $null
        if (Test-Path $tempConfigDir) {
            # Look for addon.manifest.yaml in the config layer
            $configManifestPath = Join-Path $tempConfigDir 'addon.manifest.yaml'
            if (-not (Test-Path $configManifestPath)) {
                $configManifestPath = $null
            }
            
            # Handle addon.manifest.yaml merging for multi-implementation addons
            if ($configManifestPath -and (Test-Path $configManifestPath)) {
                $destManifestPath = Join-Path $destinationPath 'addon.manifest.yaml'
                if (Test-Path $destManifestPath) {
                    # Existing manifest - need to merge implementations
                    Write-Log "[OCI] Merging addon.manifest.yaml implementations" -Console
                    
                    $existingManifest = Get-FromYamlFile -Path $destManifestPath
                    $importedManifest = Get-FromYamlFile -Path $configManifestPath
                    $existingImplNames = $existingManifest.spec.implementations | ForEach-Object { $_.name }
                    
                    Write-Log "[OCI] Existing implementations: $($existingImplNames -join ', ')"
                    $importedImplNames = $importedManifest.spec.implementations | ForEach-Object { $_.name }
                    Write-Log "[OCI] Imported implementations: $($importedImplNames -join ', ')"
                    
                    foreach ($importedImpl in $importedManifest.spec.implementations) {
                        if ($importedImpl.name -notin $existingImplNames) {
                            Write-Log "[OCI] Adding new implementation: $($importedImpl.name)" -Console
                            $existingManifest.spec.implementations += $importedImpl
                        } else {
                            Write-Log "[OCI] Implementation '$($importedImpl.name)' already exists, skipping" -Console
                        }
                    }
                    
                    $kubeBinPath = Get-KubeBinPath
                    $yqExe = Join-Path $kubeBinPath "windowsnode\yaml\yq.exe"
                    
                    if (Test-Path $yqExe) {
                        $tempJsonFile = New-TemporaryFile
                        try {
                            $originalContent = Get-Content -Path $destManifestPath -Raw -Encoding UTF8
                            $headerLines = @()
                            foreach ($line in ($originalContent -split "`r?`n")) {
                                if ($line.StartsWith("#") -or $line.Trim() -eq "") {
                                    $headerLines += $line
                                } else {
                                    break
                                }
                            }
                            
                            $mergedJson = $existingManifest | ConvertTo-Json -Depth 100
                            Set-Content -Path $tempJsonFile.FullName -Value $mergedJson -Encoding UTF8
                            
                            $yamlOutput = & $yqExe eval -P '.' $tempJsonFile
                            if ($yamlOutput -is [array]) {
                                $yamlContent = $yamlOutput -join "`n"
                            } else {
                                $yamlContent = $yamlOutput.ToString()
                            }
                            
                            $finalContent = ($headerLines -join "`n") + "`n" + $yamlContent
                            Set-Content -Path $destManifestPath -Value $finalContent -Encoding UTF8
                            Write-Log "[OCI] Merged manifest saved to: $destManifestPath" -Console
                        } finally {
                            Remove-Item -Path $tempJsonFile -Force -ErrorAction SilentlyContinue
                        }
                    } else {
                        Write-Log "[OCI] Warning: yq.exe not found, copying manifest as-is"
                        Copy-Item -Path $configManifestPath -Destination $destManifestPath -Force
                    }
                } else {
                    # No existing manifest - just copy
                    Copy-Item -Path $configManifestPath -Destination $destManifestPath -Force
                }
            }
            
            # Copy any additional config files to the destination (values.yaml, settings.json, etc.)
            Get-ChildItem -Path $tempConfigDir -File -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -ne 'addon.manifest.yaml' } | ForEach-Object {
                    Copy-Item -Path $_.FullName -Destination $destinationPath -Force
                    Write-Log "[OCI] Copied config file: $($_.Name)"
                }
            
            # Copy config subdirectory if present
            $configSubDir = Join-Path $tempConfigDir 'config'
            if (Test-Path $configSubDir) {
                $destConfigSubDir = Join-Path $destinationPath 'config'
                New-Item -ItemType Directory -Path $destConfigSubDir -Force | Out-Null
                Copy-Item -Path (Join-Path $configSubDir '*') -Destination $destConfigSubDir -Recurse -Force
                Write-Log "[OCI] Copied config subdirectory"
            }
        }
        

        
        Write-Log "[OCI] Looking for manifest at: $configManifestPath"
        if ($configManifestPath -and (Test-Path $configManifestPath)) {
            $importedManifest = Get-FromYamlFile -Path $configManifestPath
            
            if ($implementationName) {
                # Just log and skip - the yq-based merging has already handled this
                Write-Log "[OCI] Multi-implementation addon '$baseAddonName/$implementationName' - manifest merging already completed"
                
                # Remove stray manifest in implementation folder if it exists
                $manifestAtImpl = Join-Path $implementationPath "addon.manifest.yaml"
                if (Test-Path $manifestAtImpl) {
                    Remove-Item -Path $manifestAtImpl -Force
                    Write-Log "[OCI] Removed stray manifest from implementation folder"
                }
            }
            elseif ($folderParts.Count -gt 1) {
                # Space-separated addon name (e.g., "gpu node"): merge with parent manifest
                $parentAddonFolder = Split-Path -Path $destinationPath -Parent
                $parentManifestPath = Join-Path $parentAddonFolder "addon.manifest.yaml"

                if (-not (Test-Path $parentAddonFolder)) {
                    New-Item -ItemType Directory -Path $parentAddonFolder -Force | Out-Null
                }

                if (Test-Path $parentManifestPath) {
                    Write-Log "[OCI] Merging with existing manifest at: $parentManifestPath" -Console
                    $existingManifest = Get-FromYamlFile -Path $parentManifestPath
                    $existingImplNames = $existingManifest.spec.implementations | ForEach-Object { $_.name }
                    
                    foreach ($importedImpl in $importedManifest.spec.implementations) {
                        if ($importedImpl.name -notin $existingImplNames) {
                            Write-Log "[OCI] Adding new implementation: $($importedImpl.name)" -Console
                            $existingManifest.spec.implementations += $importedImpl
                        } else {
                            Write-Log "[OCI] Implementation '$($importedImpl.name)' already exists, updating" -Console
                            for ($i = 0; $i -lt $existingManifest.spec.implementations.Count; $i++) {
                                if ($existingManifest.spec.implementations[$i].name -eq $importedImpl.name) {
                                    $existingManifest.spec.implementations[$i] = $importedImpl
                                    break
                                }
                            }
                        }
                    }
                    
                    $kubeBinPath = Get-KubeBinPath
                    $yqExe = Join-Path $kubeBinPath "windowsnode\yaml\yq.exe"
                    
                    if (Test-Path $yqExe) {
                        $tempJsonFile = New-TemporaryFile
                        try {
                            $originalContent = Get-Content -Path $parentManifestPath -Raw -Encoding UTF8
                            $headerLines = @()
                            foreach ($line in ($originalContent -split "`r?`n")) {
                                if ($line.StartsWith("#") -or $line.Trim() -eq "") {
                                    $headerLines += $line
                                } else {
                                    break
                                }
                            }
                            
                            $mergedJson = $existingManifest | ConvertTo-Json -Depth 100
                            Set-Content -Path $tempJsonFile.FullName -Value $mergedJson -Encoding UTF8
                            
                            $yamlOutput = & $yqExe eval -P '.' $tempJsonFile
                            if ($yamlOutput -is [array]) {
                                $yamlContent = $yamlOutput -join "`n"
                            } else {
                                $yamlContent = $yamlOutput.ToString()
                            }
                            
                            $finalContent = ($headerLines -join "`n") + "`n" + $yamlContent
                            Set-Content -Path $parentManifestPath -Value $finalContent -Encoding UTF8
                            Write-Log "[OCI] Merged manifest saved to: $parentManifestPath" -Console
                        } finally {
                            Remove-Item -Path $tempJsonFile -Force -ErrorAction SilentlyContinue
                        }
                    } else {
                        Write-Log "[OCI] Warning: yq.exe not found, copying manifest as-is"
                        Copy-Item -Path $configManifestPath -Destination $parentManifestPath -Force
                    }
                } else {
                    Copy-Item -Path $configManifestPath -Destination $parentManifestPath -Force
                    Write-Log "[OCI] New manifest created at: $parentManifestPath" -Console
                }
                
                # Remove stray manifest in implementation folder
                $manifestAtImpl = Join-Path $destinationPath "addon.manifest.yaml"
                if (Test-Path $manifestAtImpl) {
                    Remove-Item -Path $manifestAtImpl -Force
                }
            }
            else {
                # Single-level addon
                $finalManifestPath = Join-Path $destinationPath "addon.manifest.yaml"
                Copy-Item -Path $configManifestPath -Destination $finalManifestPath -Force
                Write-Log "[OCI] Single-level addon manifest copied to: $finalManifestPath"
            }
        }
        else {
            Write-Log "[OCI] Warning: addon.manifest.yaml not found for $($addon.name)" -Console
        }
        
        # Import Layer 4: Linux Images (from staged temp location)
        $linuxImagesLayer = Join-Path $tempLayerDir 'images-linux.tar'
        if (Test-Path $linuxImagesLayer) {
            Write-Log "[OCI] Importing Linux images layer from blob" -Console
            
            # Check if this is a consolidated tar (tar of tars) or single image tar
            $tempImagesDir = Join-Path $tempLayerDir 'images-linux-extracted'
            if (-not (Test-Path $tempImagesDir)) {
                New-Item -ItemType Directory -Path $tempImagesDir -Force | Out-Null
            }
            
            # Extract the tar file
            $currentLocation = Get-Location
            try {
                Set-Location $tempImagesDir
                $extractResult = & tar -xf $linuxImagesLayer 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "[OCI] Warning: Failed to extract Linux images tar: $extractResult" -Console
                }
            }
            finally {
                Set-Location $currentLocation
            }
            
            # Check if we extracted individual image tars or a single image
            $extractedTars = Get-ChildItem -Path $tempImagesDir -Filter '*.tar' -File
            
            Write-Log "[OCI] Extracted files in $tempImagesDir`: $($extractedTars.Count) tars" -Console
            if ($extractedTars.Count -gt 0) {
                foreach ($tar in $extractedTars) {
                    Write-Log "[OCI]   - $($tar.Name) ($([math]::Round($tar.Length / 1MB, 2)) MB)" -Console
                }
            }
            
            $importImageScript = "$PSScriptRoot\..\lib\scripts\k2s\image\Import-Image.ps1"
            if ($extractedTars.Count -gt 0) {
                # Multiple image tars extracted - use directory import
                Write-Log "[OCI] Found $($extractedTars.Count) image tar(s), importing from directory" -Console
                &$importImageScript -ImageDir $tempImagesDir -ShowLogs:$ShowLogs
                $importExitCode = $LASTEXITCODE
            } else {
                # Single image tar - check if extraction created image files directly
                $imageFiles = Get-ChildItem -Path $tempImagesDir -Recurse -File
                if ($imageFiles.Count -gt 0) {
                    Write-Log "[OCI] Importing extracted image files from directory" -Console
                    &$importImageScript -ImageDir $tempImagesDir -ShowLogs:$ShowLogs
                    $importExitCode = $LASTEXITCODE
                } else {
                    Write-Log "[OCI] Warning: No image files found after extraction" -Console
                    $importExitCode = 1
                }
            }
            
            if ($importExitCode -ne 0) {
                Write-Log "[OCI] Warning: Linux images import failed for $($addon.name) with exit code $importExitCode" -Console
            } else {
                Write-Log "[OCI] Linux images imported successfully for $($addon.name)" -Console
            }
            
            # Cleanup extracted images
            Remove-Item -Path $tempImagesDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "[OCI] No Linux images layer found for $($addon.name)"
        }
        
        # Import Layer 5: Windows Images (from staged temp location)
        $windowsImagesLayer = Join-Path $tempLayerDir 'images-windows.tar'
        if ((Test-Path $windowsImagesLayer) -and (-not $setupInfo.LinuxOnly)) {
            Write-Log "[OCI] Importing Windows images layer from blob" -Console
            
            # Check if this is a consolidated tar (tar of tars) or single image tar
            $tempImagesDir = Join-Path $tempLayerDir 'images-windows-extracted'
            if (-not (Test-Path $tempImagesDir)) {
                New-Item -ItemType Directory -Path $tempImagesDir -Force | Out-Null
            }
            
            # Extract the tar file
            $currentLocation = Get-Location
            try {
                Set-Location $tempImagesDir
                $extractResult = & tar -xf $windowsImagesLayer 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "[OCI] Warning: Failed to extract Windows images tar: $extractResult" -Console
                }
            }
            finally {
                Set-Location $currentLocation
            }
            
            # Check if we extracted individual image tars
            $extractedTars = Get-ChildItem -Path $tempImagesDir -Filter '*.tar' -File
            
            Write-Log "[OCI] Extracted files in $tempImagesDir`: $($extractedTars.Count) tars" -Console
            if ($extractedTars.Count -gt 0) {
                foreach ($tar in $extractedTars) {
                    Write-Log "[OCI]   - $($tar.Name) ($([math]::Round($tar.Length / 1MB, 2)) MB)" -Console
                }
            }
            
            $importImageScript = "$PSScriptRoot\..\lib\scripts\k2s\image\Import-Image.ps1"
            if ($extractedTars.Count -gt 0) {
                Write-Log "[OCI] Found $($extractedTars.Count) Windows image tar(s), importing from directory" -Console
                &$importImageScript -ImageDir $tempImagesDir -Windows -ShowLogs:$ShowLogs
                $importExitCode = $LASTEXITCODE
            } else {
                $imageFiles = Get-ChildItem -Path $tempImagesDir -Recurse -File
                if ($imageFiles.Count -gt 0) {
                    Write-Log "[OCI] Importing extracted Windows image files from directory" -Console
                    &$importImageScript -ImageDir $tempImagesDir -Windows -ShowLogs:$ShowLogs
                    $importExitCode = $LASTEXITCODE
                } else {
                    Write-Log "[OCI] Warning: No Windows image files found after extraction" -Console
                    $importExitCode = 1
                }
            }
            
            if ($importExitCode -ne 0) {
                Write-Log "[OCI] Warning: Windows images import failed for $($addon.name) with exit code $importExitCode" -Console
            } else {
                Write-Log "[OCI] Windows images imported successfully for $($addon.name)" -Console
            }
            
            # Cleanup extracted images
            Remove-Item -Path $tempImagesDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "[OCI] No Windows images layer found for $($addon.name) or Linux-only setup"
        }
        
        # Process Layer 6: Packages (already extracted to temp location)
        $packagesExtractDir = Join-Path $tempLayerDir 'packages'
        if (Test-Path $packagesExtractDir) {
            if ($null -ne $addon.offline_usage) {
                Write-Log "[OCI] Installing packages for addon $($addon.name)" -Console
                $linuxPackages = $addon.offline_usage.linux
                $linuxCurlPackages = $linuxPackages.curl
                $windowsPackages = $addon.offline_usage.windows
                $windowsCurlPackages = $windowsPackages.curl
                
                # Import debian packages
                $debianPkgDir = Join-Path $packagesExtractDir 'debianpackages'
                if (Test-Path $debianPkgDir) {
                    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf .$($addon.name)").Output | Write-Log
                    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .$($addon.name)").Output | Write-Log
                    Copy-ToControlPlaneViaSSHKey -Source "$debianPkgDir\*" -Target ".$($addon.name)"
                }
                
                # Import Linux packages
                $linuxPkgDir = Join-Path $packagesExtractDir 'linuxpackages'
                if (Test-Path $linuxPkgDir) {
                    foreach ($package in $linuxCurlPackages) {
                        $filename = ([uri]$package.url).Segments[-1]
                        $destination = $package.destination
                        $sourcePath = Join-Path $linuxPkgDir $filename
                        if (Test-Path $sourcePath) {
                            Copy-ToControlPlaneViaSSHKey -Source $sourcePath -Target '/tmp'
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo cp /tmp/${filename} ${destination}").Output | Write-Log
                            (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf /tmp/${filename}").Output | Write-Log
                        }
                    }
                }
                
            # Import Windows packages
            $windowsPkgDir = Join-Path $packagesExtractDir 'windowspackages'
            if (Test-Path $windowsPkgDir) {
                foreach ($package in $windowsCurlPackages) {
                    $filename = ([uri]$package.url).Segments[-1]
                    $destination = $package.destination
                    $sourcePath = Join-Path $windowsPkgDir $filename
                    $destinationFolder = Split-Path -Path "$PSScriptRoot\..\$destination"
                    if (Test-Path $sourcePath) {
                        mkdir -Force $destinationFolder | Out-Null
                        Copy-Item -Path $sourcePath -Destination "$PSScriptRoot\..\$destination" -Force
                    }
                }
            }
        }
    }
    
    # Cleanup temp layer directory
    Remove-Item -Path $tempLayerDir -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Log '---' -Console
}


Remove-Item -Force "$tmpDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

Write-Log '---'
$importedNames = ($addonsToImport | ForEach-Object { $_.name }) -join ', '
Write-Log "[OCI] Addons '$importedNames' imported successfully from OCI artifact!" -Console
Write-Log "[OCI] Artifact layers processed:" -Console
Write-Log "  Config:  metadata.json       (addon metadata)" -Console
Write-Log "  Layer 0: config.tar.gz       (addon.manifest.yaml, addon configs etc.)" -Console
Write-Log "  Layer 1: manifests.tar.gz    (Kubernetes manifests)" -Console
Write-Log "  Layer 2: charts.tar.gz       (Helm charts)" -Console
Write-Log "  Layer 3: scripts.tar.gz      (Enable/Disable scripts)" -Console
Write-Log "  Layer 4: images-linux.tar    (Linux container images)" -Console
Write-Log "  Layer 5: images-windows.tar  (Windows container images)" -Console
Write-Log "  Layer 6: packages.tar.gz     (Offline packages)" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}