# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

# Import.ps1 — CLI-based addon import from OCI artifact tar files.


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
$extractionFolder = $tmpDir

if ($ArtifactFile) {
    Write-Log "[OCI] Extracting artifact from $ArtifactFile" -Console
    Write-Log '---' -Console
    
    Remove-Item -Force $extractionFolder -Recurse -Confirm:$False -ErrorAction SilentlyContinue
    
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
    
    if ($ArtifactFile -match '\.oci\.tar$') {
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

$addonsToImport = @()

Write-Log "[OCI] Processing OCI artifact structure" -Console

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

# Validate OCI Image Layout version per spec (MUST be "1.0.0")
if ($ociLayout.imageLayoutVersion -ne '1.0.0') {
    $errMsg = "Unsupported OCI Image Layout version: '$($ociLayout.imageLayoutVersion)' (expected '1.0.0')"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

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

# Validate OCI Image Index required fields per spec
if ($indexManifest.schemaVersion -ne 2) {
    $errMsg = "Invalid OCI image index: schemaVersion must be 2, got '$($indexManifest.schemaVersion)'"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'image-format-invalid' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($indexManifest.mediaType -and $indexManifest.mediaType -ne 'application/vnd.oci.image.index.v1+json') {
    Write-Log "[OCI] Warning: Unexpected index.json mediaType: '$($indexManifest.mediaType)' (expected 'application/vnd.oci.image.index.v1+json')" -Console
}

$exportedAddons = @()
foreach ($manifest in $indexManifest.manifests) {
    $exportedAddons += @{
        name = $manifest.annotations.'vnd.k2s.addon.name'
        implementation = $manifest.annotations.'vnd.k2s.addon.implementation'
        version = $manifest.annotations.'org.opencontainers.image.version'
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
    
    $ociManifest = $null
    if ($addon.manifestDigest) {
            $ociManifest = Get-JsonBlobByDigest -BlobsDir $blobsDir -Digest $addon.manifestDigest
            
            # Validate manifest schemaVersion per OCI Image Manifest spec
            if ($ociManifest.schemaVersion -ne 2) {
                Write-Log "[OCI] Warning: Unexpected manifest schemaVersion '$($ociManifest.schemaVersion)' for $($addon.name) (expected 2)" -Console
            }
            
            Write-Log "[OCI] -> Manifest digest: $($addon.manifestDigest)"
            Write-Log "[OCI] -> Version: $($ociManifest.annotations.'org.opencontainers.image.version')"
            Write-Log "[OCI] -> K2s Version: $($ociManifest.annotations.'vnd.k2s.version')"
            Write-Log "[OCI] -> Export Date: $($ociManifest.annotations.'org.opencontainers.image.created')"
        } else {
            Write-Log "[OCI] Warning: No manifest digest for addon $($addon.name)" -Console
            continue
        }
        
        $implementationName = $null
        $baseAddonName = if ($addon.name -match '^([^_]+)_(.+)$') {
            $implementationName = $matches[2]  # Get the part after the underscore (e.g., "traefik")
            $matches[1]  # Get the part before the first underscore (e.g., "ingress")
        } else {
            $addon.name  # Single implementation addon
        }
        
        $folderParts = $baseAddonName -split '\s+'
        $destinationPath = $PSScriptRoot
        foreach ($part in $folderParts) {
            $destinationPath = Join-Path -Path $destinationPath -ChildPath $part
        }
        
        $implementationPath = $destinationPath
        if ($implementationName) {
            $implementationPath = Join-Path $destinationPath $implementationName
            Write-Log "[OCI] Destination: $implementationPath (base addon: $baseAddonName, implementation: $implementationName)"
        } else {
            Write-Log "[OCI] Destination: $destinationPath (addon: $baseAddonName)"
        }
        
        if (-not (Test-Path $destinationPath)) {
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        }
        
        if ($implementationName -and -not (Test-Path $implementationPath)) {
            New-Item -ItemType Directory -Path $implementationPath -Force | Out-Null
        }
        
        $tempLayerDir = Join-Path $tmpDir "layer-temp-$($addon.name)"
        New-Item -ItemType Directory -Path $tempLayerDir -Force | Out-Null
        
        foreach ($layer in $ociManifest.layers) {
            $layerTitle = $layer.annotations.'org.opencontainers.image.title'
            $layerDigest = $layer.digest
            $layerMediaType = $layer.mediaType
            
            # Skip OCI empty descriptors (used as fallback for addons with no content layers)
            if ($layerMediaType -eq 'application/vnd.oci.empty.v1+json') {
                Write-Log "[OCI] Skipping OCI empty descriptor layer"
                continue
            }
            
            Write-Log "[OCI] Processing layer: $layerTitle ($layerDigest)"
            
            # Get the blob path for this layer (includes digest verification)
            $blobPath = Get-BlobByDigest -BlobsDir $blobsDir -Digest $layerDigest
            
            # Verify blob size matches descriptor size per OCI spec
            $actualSize = (Get-Item $blobPath).Length
            if ($layer.size -and $actualSize -ne $layer.size) {
                Write-Log "[OCI] Warning: Size mismatch for layer $layerTitle - descriptor: $($layer.size), actual: $actualSize" -Console
            }
            
            switch -Wildcard ($layerMediaType) {
                '*configfiles*' {
                    Write-Log "[OCI] Extracting config files layer from blob"
                    $tempConfigDir = Join-Path $tempLayerDir 'config'
                    New-Item -ItemType Directory -Path $tempConfigDir -Force | Out-Null
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $tempConfigDir
                    Write-Log "[OCI] Staged config files layer for processing"
                    break
                }
                '*manifests*' {
                    Write-Log "[OCI] Extracting manifests layer from blob"
                    $manifestsDestDir = Join-Path $implementationPath 'manifests'
                    New-Item -ItemType Directory -Path $manifestsDestDir -Force | Out-Null
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $manifestsDestDir
                    break
                }
                '*helm.chart*' {
                    Write-Log "[OCI] Extracting charts layer from blob"
                    $chartsDestDir = Join-Path $implementationPath 'manifests\chart'
                    New-Item -ItemType Directory -Path $chartsDestDir -Force | Out-Null
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $chartsDestDir
                    break
                }
                '*scripts*' {
                    Write-Log "[OCI] Extracting scripts layer from blob"
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $implementationPath
                    break
                }
                '*images-windows*' {
                    # Layer 5: Windows Images - copy to temp for later processing
                    $tempWindowsImages = Join-Path $tempLayerDir 'images-windows.tar'
                    Copy-Item -Path $blobPath -Destination $tempWindowsImages -Force
                    Write-Log "[OCI] Staged Windows images layer for import"
                    break
                }
                '*image.layer*' {
                    $tempLinuxImages = Join-Path $tempLayerDir 'images-linux.tar'
                    Copy-Item -Path $blobPath -Destination $tempLinuxImages -Force
                    Write-Log "[OCI] Staged Linux images layer for import"
                    break
                }
                '*packages*' {
                    $tempPackagesDir = Join-Path $tempLayerDir 'packages'
                    New-Item -ItemType Directory -Path $tempPackagesDir -Force | Out-Null
                    Expand-TarGzArchive -ArchivePath $blobPath -DestinationPath $tempPackagesDir
                    Write-Log "[OCI] Staged packages layer for import"
                    break
                }
            }
        }
        
        $tempConfigDir = Join-Path $tempLayerDir 'config'
        $configManifestPath = $null
        if (Test-Path $tempConfigDir) {
            $configManifestPath = Join-Path $tempConfigDir 'addon.manifest.yaml'
            if (-not (Test-Path $configManifestPath)) {
                $configManifestPath = $null
            }
            
            if ($configManifestPath -and (Test-Path $configManifestPath)) {
                $destManifestPath = Join-Path $destinationPath 'addon.manifest.yaml'
                if (Test-Path $destManifestPath) {
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
                    Copy-Item -Path $configManifestPath -Destination $destManifestPath -Force
                }
            }
            
            # Copy any additional config files to the implementation path (values.yaml, settings.json, etc.)
            Get-ChildItem -Path $tempConfigDir -File -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -ne 'addon.manifest.yaml' } | ForEach-Object {
                    Copy-Item -Path $_.FullName -Destination $implementationPath -Force
                    Write-Log "[OCI] Copied config file: $($_.Name)"
                }
            
            $configSubDir = Join-Path $tempConfigDir 'config'
            if (Test-Path $configSubDir) {
                $destConfigSubDir = Join-Path $implementationPath 'config'
                New-Item -ItemType Directory -Path $destConfigSubDir -Force | Out-Null
                Copy-Item -Path (Join-Path $configSubDir '*') -Destination $destConfigSubDir -Recurse -Force
                Write-Log "[OCI] Copied config subdirectory"
            }
        }
        

        
        Write-Log "[OCI] Looking for manifest at: $configManifestPath"
        if ($configManifestPath -and (Test-Path $configManifestPath)) {
            $importedManifest = Get-FromYamlFile -Path $configManifestPath
            
            if ($implementationName) {
                Write-Log "[OCI] Multi-implementation addon '$baseAddonName/$implementationName' - manifest merging already completed"
                
                $manifestAtImpl = Join-Path $implementationPath "addon.manifest.yaml"
                if (Test-Path $manifestAtImpl) {
                    Remove-Item -Path $manifestAtImpl -Force
                    Write-Log "[OCI] Removed stray manifest from implementation folder"
                }
            }
            elseif ($folderParts.Count -gt 1) {
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
                
                $manifestAtImpl = Join-Path $destinationPath "addon.manifest.yaml"
                if (Test-Path $manifestAtImpl) {
                    Remove-Item -Path $manifestAtImpl -Force
                }
            }
            else {
                $finalManifestPath = Join-Path $destinationPath "addon.manifest.yaml"
                Copy-Item -Path $configManifestPath -Destination $finalManifestPath -Force
                Write-Log "[OCI] Single-level addon manifest copied to: $finalManifestPath"
            }
        }
        else {
            Write-Log "[OCI] Warning: addon.manifest.yaml not found for $($addon.name)" -Console
        }
        
        $linuxImagesLayer = Join-Path $tempLayerDir 'images-linux.tar'
        $tempImagesDir = Join-Path $tempLayerDir 'images-linux-extracted'
        
        if (Test-Path $linuxImagesLayer) {
            Write-Log "[OCI] Extracting Linux images from consolidated tar" -Console
            if (-not (Test-Path $tempImagesDir)) {
                New-Item -ItemType Directory -Path $tempImagesDir -Force | Out-Null
            }
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
        }
        
        if (Test-Path $tempImagesDir) {
            $extractedTars = Get-ChildItem -Path $tempImagesDir -Filter '*.tar' -File
            Write-Log "[OCI] Found $($extractedTars.Count) Linux image tar(s) for import" -Console
            foreach ($tar in $extractedTars) {
                Write-Log "[OCI]   - $($tar.Name) ($([math]::Round($tar.Length / 1MB, 2)) MB)" -Console
            }
            
            if ($extractedTars.Count -gt 0) {
                $importImageScript = "$PSScriptRoot\..\lib\scripts\k2s\image\Import-Image.ps1"
                Write-Log "[OCI] Importing $($extractedTars.Count) Linux image tar(s)" -Console
                &$importImageScript -ImageDir $tempImagesDir -ShowLogs:$ShowLogs
                $importExitCode = $LASTEXITCODE
                
                if ($importExitCode -ne 0) {
                    Write-Log "[OCI] Warning: Linux images import failed for $($addon.name) with exit code $importExitCode" -Console
                } else {
                    Write-Log "[OCI] Linux images imported successfully for $($addon.name)" -Console
                }
            }
            
            Remove-Item -Path $tempImagesDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "[OCI] No Linux images to import for $($addon.name)"
        }
        
        $windowsImagesLayer = Join-Path $tempLayerDir 'images-windows.tar'
        $tempWinImagesDir = Join-Path $tempLayerDir 'images-windows-extracted'
        
        if ((Test-Path $windowsImagesLayer) -and (-not $setupInfo.LinuxOnly)) {
            Write-Log "[OCI] Extracting Windows images from consolidated tar" -Console
            if (-not (Test-Path $tempWinImagesDir)) {
                New-Item -ItemType Directory -Path $tempWinImagesDir -Force | Out-Null
            }
            $currentLocation = Get-Location
            try {
                Set-Location $tempWinImagesDir
                $extractResult = & tar -xf $windowsImagesLayer 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "[OCI] Warning: Failed to extract Windows images tar: $extractResult" -Console
                }
            }
            finally {
                Set-Location $currentLocation
            }
        }
        
        if ((Test-Path $tempWinImagesDir) -and (-not $setupInfo.LinuxOnly)) {
            $extractedTars = Get-ChildItem -Path $tempWinImagesDir -Filter '*.tar' -File
            Write-Log "[OCI] Found $($extractedTars.Count) Windows image tar(s) for import" -Console
            foreach ($tar in $extractedTars) {
                Write-Log "[OCI]   - $($tar.Name) ($([math]::Round($tar.Length / 1MB, 2)) MB)" -Console
            }
            
            if ($extractedTars.Count -gt 0) {
                $importImageScript = "$PSScriptRoot\..\lib\scripts\k2s\image\Import-Image.ps1"
                Write-Log "[OCI] Importing $($extractedTars.Count) Windows image tar(s)" -Console
                &$importImageScript -ImageDir $tempWinImagesDir -Windows -ShowLogs:$ShowLogs
                $importExitCode = $LASTEXITCODE
                
                if ($importExitCode -ne 0) {
                    Write-Log "[OCI] Warning: Windows images import failed for $($addon.name) with exit code $importExitCode" -Console
                } else {
                    Write-Log "[OCI] Windows images imported successfully for $($addon.name)" -Console
                }
            }
            
            Remove-Item -Path $tempWinImagesDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log "[OCI] No Windows images to import for $($addon.name) or Linux-only setup"
        }
        
        $packagesExtractDir = Join-Path $tempLayerDir 'packages'
        if (Test-Path $packagesExtractDir) {
            $tempConfigDir = Join-Path $tempLayerDir 'config'
            $configManifestPath = Join-Path $tempConfigDir 'addon.manifest.yaml'
            if (Test-Path $configManifestPath) {
                $importedManifest = Get-FromYamlFile -Path $configManifestPath
                
                $matchingImpl = $null
                if ($addon.implementation) {
                    $matchingImpl = $importedManifest.spec.implementations | Where-Object { $_.name -eq $addon.implementation } | Select-Object -First 1
                } else {
                    $matchingImpl = $importedManifest.spec.implementations | Select-Object -First 1
                }
                
                if ($null -ne $matchingImpl -and $null -ne $matchingImpl.offline_usage) {
                    Write-Log "[OCI] Installing packages for addon $($addon.name)" -Console
                    $linuxPackages = $matchingImpl.offline_usage.linux
                    $linuxCurlPackages = $linuxPackages.curl
                    $windowsPackages = $matchingImpl.offline_usage.windows
                    $windowsCurlPackages = $windowsPackages.curl
                    
                    $debianPkgDir = Join-Path $packagesExtractDir 'debianpackages'
                    if (Test-Path $debianPkgDir) {
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf .$($addon.name)").Output | Write-Log
                        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .$($addon.name)").Output | Write-Log
                        Copy-ToControlPlaneViaSSHKey -Source "$debianPkgDir\*" -Target ".$($addon.name)"
                    }
                    
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
        }
    
    Remove-Item -Path $tempLayerDir -Recurse -Force -ErrorAction SilentlyContinue
    
    Write-Log '---' -Console
}


Remove-Item -Force "$tmpDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

Write-Log '---'
$importedNames = ($addonsToImport | ForEach-Object { $_.name }) -join ', '
Write-Log "[OCI] Addons '$importedNames' imported successfully" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}