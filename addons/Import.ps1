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
$isOciArtifact = $false

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
        
        $isOciArtifact = $true
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

# Process addons based on format
$addonsToImport = @()

if ($isOciArtifact) {
    # OCI Artifact format processing
    Write-Log "[OCI] Processing OCI artifact structure" -Console
    
    $addonsJsonPath = Join-Path $extractionFolder 'addons.json'
    if (-not (Test-Path $addonsJsonPath)) {
        $errMsg = 'Invalid OCI artifact format: addons.json not found.'
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code 'image-format-invalid' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
    
    $exportedAddons = (Get-Content $addonsJsonPath | Out-String | ConvertFrom-Json).addons
    
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
        
        $artifactDir = Join-Path $extractionFolder $addon.dirName
        
        if (-not (Test-Path $artifactDir)) {
            Write-Log "[OCI] Warning: Artifact directory not found: $artifactDir" -Console
            continue
        }
        
        $ociManifestPath = Join-Path $artifactDir 'oci-manifest.json'
        $ociManifest = $null
        if (Test-Path $ociManifestPath) {
            $ociManifest = Get-Content $ociManifestPath | ConvertFrom-Json
            Write-Log "[OCI] -> Version: $($ociManifest.annotations.'org.opencontainers.image.version')"
            Write-Log "[OCI] -> K2s Version: $($ociManifest.annotations.'vnd.k2s.version')"
            Write-Log "[OCI] -> Export Date: $($ociManifest.annotations.'vnd.k2s.export.date')"
        }
        
        $folderParts = $addon.name -split '\s+'
        $destinationPath = $PSScriptRoot
        foreach ($part in $folderParts) {
            $destinationPath = Join-Path -Path $destinationPath -ChildPath $part
        }
        
        Write-Log "[OCI] Destination: $destinationPath"
        
        if (-not (Test-Path $destinationPath)) {
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
        }
        
        # Extract Layer 1: Manifests
        $manifestsLayer = Join-Path $artifactDir 'manifests.tar.gz'
        if (Test-Path $manifestsLayer) {
            Write-Log "[OCI] Extracting manifests layer"
            $manifestsDestDir = Join-Path $destinationPath 'manifests'
            New-Item -ItemType Directory -Path $manifestsDestDir -Force | Out-Null
            Expand-TarGzArchive -ArchivePath $manifestsLayer -DestinationPath $manifestsDestDir
        }
        
        # Extract Layer 2: Charts (if present)
        $chartsLayer = Join-Path $artifactDir 'charts.tar.gz'
        if (Test-Path $chartsLayer) {
            Write-Log "[OCI] Extracting charts layer"
            $chartsDestDir = Join-Path $destinationPath 'manifests\chart'
            New-Item -ItemType Directory -Path $chartsDestDir -Force | Out-Null
            Expand-TarGzArchive -ArchivePath $chartsLayer -DestinationPath $chartsDestDir
        }
        
        # Extract Layer 3: Scripts
        $scriptsLayer = Join-Path $artifactDir 'scripts.tar.gz'
        if (Test-Path $scriptsLayer) {
            Write-Log "[OCI] Extracting scripts layer"
            Expand-TarGzArchive -ArchivePath $scriptsLayer -DestinationPath $destinationPath
        }
        
        # Handle addon.manifest.yaml (Config)
        $configManifestPath = Join-Path $artifactDir 'addon.manifest.yaml'
        Write-Log "[OCI] Looking for manifest at: $configManifestPath"
        if (Test-Path $configManifestPath) {
            $importedManifest = Get-FromYamlFile -Path $configManifestPath
            
            if ($folderParts.Count -gt 1) {
                # Multi-implementation addon: merge with parent manifest
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
        
        # Import Layer 4: Linux Images
        $linuxImagesLayer = Join-Path $artifactDir 'images-linux.tar'
        if (Test-Path $linuxImagesLayer) {
            Write-Log "[OCI] Importing Linux images layer from: $linuxImagesLayer" -Console
            
            # Check if this is a consolidated tar (tar of tars) or single image tar
            $tempImagesDir = Join-Path $artifactDir 'images-linux-extracted'
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
        
        # Import Layer 5: Windows Images
        $windowsImagesLayer = Join-Path $artifactDir 'images-windows.tar'
        if ((Test-Path $windowsImagesLayer) -and (-not $setupInfo.LinuxOnly)) {
            Write-Log "[OCI] Importing Windows images layer from: $windowsImagesLayer" -Console
            
            # Check if this is a consolidated tar (tar of tars) or single image tar
            $tempImagesDir = Join-Path $artifactDir 'images-windows-extracted'
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
        
        # Extract Layer 6: Packages
        $packagesLayer = Join-Path $artifactDir 'packages.tar.gz'
        if (Test-Path $packagesLayer) {
            Write-Log "[OCI] Extracting packages layer" -Console
            $packagesExtractDir = Join-Path $artifactDir 'packages-extracted'
            Expand-TarGzArchive -ArchivePath $packagesLayer -DestinationPath $packagesExtractDir
            
            if ($null -ne $addon.offline_usage) {
                Write-Log "[OCI] Installing packages for addon $($addon.name)" -Console
                $linuxPackages = $addon.offline_usage.linux
                $linuxCurlPackages = $linuxPackages.curl
                $windowsPackages = $addon.offline_usage.windows
                $windowsCurlPackages = $windowsPackages.curl
                
                # Import debian packages
                $debianPkgDir = Join-Path $packagesExtractDir 'debianpackages'
                if (Test-Path $debianPkgDir) {
                    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo rm -rf .$($addon.dirName)").Output | Write-Log
                    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "mkdir -p .$($addon.dirName)").Output | Write-Log
                    Copy-ToControlPlaneViaSSHKey -Source "$debianPkgDir\*" -Target ".$($addon.dirName)"
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
        
        Write-Log '---' -Console
    }
}

Remove-Item -Force "$tmpDir" -Recurse -Confirm:$False -ErrorAction SilentlyContinue

Write-Log '---'
$importedNames = ($addonsToImport | ForEach-Object { $_.name }) -join ', '
if ($isOciArtifact) {
    Write-Log "[OCI] Addons '$importedNames' imported successfully from OCI artifact!" -Console
    Write-Log "[OCI] Artifact layers processed:" -Console
    Write-Log "  Config:  addon.manifest.yaml" -Console
    Write-Log "  Layer 1: manifests.tar.gz    (Kubernetes manifests)" -Console
    Write-Log "  Layer 2: charts.tar.gz       (Helm charts)" -Console
    Write-Log "  Layer 3: scripts.tar.gz      (Enable/Disable scripts)" -Console
    Write-Log "  Layer 4: images-linux.tar    (Linux container images)" -Console
    Write-Log "  Layer 5: images-windows.tar  (Windows container images)" -Console
    Write-Log "  Layer 6: packages.tar.gz     (Offline packages)" -Console
} else {
    Write-Log "Addons '$importedNames' imported successfully!" -Console
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}