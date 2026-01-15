# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
OCI Artifact module for K2s addon export/import operations

.DESCRIPTION
Provides functions for creating and consuming OCI artifacts with layered structure
for addon distribution supporting FluxCD and ArgoCD consumption.

Media Types:
- application/vnd.k2s.addon.config.v1+yaml     - Addon manifest configuration
- application/vnd.k2s.addon.manifests.v1.tar+gzip - Kubernetes manifests
- application/vnd.cncf.helm.chart.content.v1.tar+gzip - Helm charts
- application/vnd.k2s.addon.scripts.v1.tar+gzip - Enable/Disable scripts
- application/vnd.oci.image.layer.v1.tar       - Container images
- application/vnd.k2s.addon.packages.v1.tar+gzip - Offline packages
#>

$infraModule = "$PSScriptRoot/../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
Import-Module $infraModule

# OCI Media Types for K2s addon artifacts
$script:MediaTypes = @{
    Config     = 'application/vnd.k2s.addon.config.v1+yaml'
    Manifests  = 'application/vnd.k2s.addon.manifests.v1.tar+gzip'
    Charts     = 'application/vnd.cncf.helm.chart.content.v1.tar+gzip'
    Scripts    = 'application/vnd.k2s.addon.scripts.v1.tar+gzip'
    ImagesLinux = 'application/vnd.oci.image.layer.v1.tar'
    ImagesWindows = 'application/vnd.oci.image.layer.v1.tar+windows'
    Packages   = 'application/vnd.k2s.addon.packages.v1.tar+gzip'
}

function Get-OrasExePath {
    <#
    .SYNOPSIS
    Gets the path to the ORAS executable
    #>
    $kubeBinPath = Get-KubeBinPath
    $orasExe = Join-Path $kubeBinPath 'oras.exe'
    
    if (-not (Test-Path $orasExe)) {
        throw "ORAS executable not found at '$orasExe'. Please ensure ORAS is installed."
    }
    
    return $orasExe
}

function Get-OciMediaTypes {
    <#
    .SYNOPSIS
    Returns the media types used for OCI artifacts
    #>
    return $script:MediaTypes
}

function New-TarGzArchive {
    <#
    .SYNOPSIS
    Creates a tar.gz archive from a directory or files
    
    .PARAMETER SourcePath
    Source directory or file path
    
    .PARAMETER DestinationPath
    Destination tar.gz file path
    
    .PARAMETER BasePath
    Base path for relative paths in archive (optional)
    
    .PARAMETER ArchiveContents
    If true, archive the contents of the directory, not the directory itself
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $false)]
        [string]$BasePath = $null,
        [Parameter(Mandatory = $false)]
        [switch]$ArchiveContents = $false
    )
    
    if (Test-Path $SourcePath -PathType Container) {
        # Directory - create tar.gz with relative paths
        $currentLocation = Get-Location
        try {
            if ($ArchiveContents) {
                # Archive the contents of the directory (cd into it and tar .)
                Set-Location $SourcePath
                $tarResult = & tar -czf $DestinationPath . 2>&1
            } elseif ($BasePath) {
                Set-Location $BasePath
                $relativePath = Resolve-Path -Path $SourcePath -Relative
                $tarResult = & tar -czf $DestinationPath $relativePath 2>&1
            } else {
                Set-Location (Split-Path $SourcePath -Parent)
                $relativePath = Split-Path $SourcePath -Leaf
                $tarResult = & tar -czf $DestinationPath $relativePath 2>&1
            }
            
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create tar.gz archive: $tarResult"
            }
        }
        finally {
            Set-Location $currentLocation
        }
    }
    else {
        # Single file
        $parentDir = Split-Path $SourcePath -Parent
        $fileName = Split-Path $SourcePath -Leaf
        $currentLocation = Get-Location
        try {
            Set-Location $parentDir
            $tarResult = & tar -czf $DestinationPath $fileName 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create tar.gz archive: $tarResult"
            }
        }
        finally {
            Set-Location $currentLocation
        }
    }
    
    return (Test-Path $DestinationPath)
}

function New-TarArchive {
    <#
    .SYNOPSIS
    Creates a tar archive from files
    
    .PARAMETER SourceFiles
    Array of source file paths
    
    .PARAMETER DestinationPath
    Destination tar file path
    
    .PARAMETER WorkingDirectory
    Working directory for tar command
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$SourceFiles,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory = $null
    )
    
    if ($SourceFiles.Count -eq 0) {
        Write-Log "[OCI] No source files provided for tar archive"
        return $false
    }
    
    $currentLocation = Get-Location
    try {
        if ($WorkingDirectory) {
            Set-Location $WorkingDirectory
        }
        
        # Build relative file list
        $relativeFiles = @()
        foreach ($file in $SourceFiles) {
            if (Test-Path $file) {
                if ($WorkingDirectory) {
                    $relativeFiles += Resolve-Path -Path $file -Relative -ErrorAction SilentlyContinue
                } else {
                    $relativeFiles += $file
                }
            }
        }
        
        if ($relativeFiles.Count -gt 0) {
            $tarResult = & tar -cvf $DestinationPath $relativeFiles 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log "[OCI] Warning: tar command returned non-zero: $tarResult"
            }
        }
    }
    finally {
        Set-Location $currentLocation
    }
    
    return (Test-Path $DestinationPath)
}

function Expand-TarGzArchive {
    <#
    .SYNOPSIS
    Extracts a tar.gz archive to a destination directory
    
    .PARAMETER ArchivePath
    Path to the tar.gz archive
    
    .PARAMETER DestinationPath
    Destination directory for extraction
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )
    
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    
    $currentLocation = Get-Location
    try {
        Set-Location $DestinationPath
        
        $tarResult = & tar -xzf $ArchivePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract tar.gz archive: $tarResult"
        }
    }
    finally {
        Set-Location $currentLocation
    }
    
    return $true
}

function Expand-TarArchive {
    <#
    .SYNOPSIS
    Extracts a tar archive to a destination directory
    
    .PARAMETER ArchivePath
    Path to the tar archive
    
    .PARAMETER DestinationPath
    Destination directory for extraction
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )
    
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    
    $currentLocation = Get-Location
    try {
        Set-Location $DestinationPath
        
        $tarResult = & tar -xf $ArchivePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to extract tar archive: $tarResult"
        }
    }
    finally {
        Set-Location $currentLocation
    }
    
    return $true
}

function Push-OciArtifact {
    <#
    .SYNOPSIS
    Pushes an OCI artifact to a registry using ORAS
    
    .PARAMETER Registry
    OCI registry URL (e.g., k2s-registry.local:30500)
    
    .PARAMETER Repository
    Repository name (e.g., k2s-addons/ingress-nginx)
    
    .PARAMETER Tag
    Artifact tag/version
    
    .PARAMETER ConfigFile
    Path to config file (addon.manifest.yaml)
    
    .PARAMETER Layers
    Hashtable of layer files with their media types
    Example: @{ 'manifests.tar.gz' = 'application/vnd.k2s.addon.manifests.v1.tar+gzip' }
    
    .PARAMETER WorkingDirectory
    Working directory for ORAS push
    
    .PARAMETER Insecure
    Allow insecure (HTTP) registry connections
    
    .PARAMETER PlainHttp
    Use plain HTTP instead of HTTPS
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Registry,
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Tag,
        [Parameter(Mandatory = $false)]
        [string]$ConfigFile,
        [Parameter(Mandatory = $true)]
        [hashtable]$Layers,
        [Parameter(Mandatory = $false)]
        [string]$WorkingDirectory,
        [Parameter(Mandatory = $false)]
        [switch]$Insecure,
        [Parameter(Mandatory = $false)]
        [switch]$PlainHttp
    )
    
    $orasExe = Get-OrasExePath
    $artifactRef = "$Registry/$Repository`:$Tag"
    
    $currentLocation = Get-Location
    try {
        if ($WorkingDirectory) {
            Set-Location $WorkingDirectory
        }
        
        # Build ORAS push command arguments
        $orasArgs = @('push')
        
        if ($Insecure) {
            $orasArgs += '--insecure'
        }
        
        if ($PlainHttp) {
            $orasArgs += '--plain-http'
        }
        
        # Add config if provided
        if ($ConfigFile -and (Test-Path $ConfigFile)) {
            $configMediaType = $script:MediaTypes.Config
            $orasArgs += '--config'
            $orasArgs += "${ConfigFile}:${configMediaType}"
        }
        
        $orasArgs += $artifactRef
        
        # Add layers with media types
        foreach ($layer in $Layers.GetEnumerator()) {
            $layerFile = $layer.Key
            $mediaType = $layer.Value
            
            if (Test-Path $layerFile) {
                $orasArgs += "${layerFile}:${mediaType}"
            } else {
                Write-Log "[OCI] Warning: Layer file not found: $layerFile"
            }
        }
        
        Write-Log "[OCI] Pushing artifact to $artifactRef"
        Write-Log "[OCI] ORAS args: $($orasArgs -join ' ')"
        
        $result = & $orasExe $orasArgs 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            throw "ORAS push failed: $result"
        }
        
        Write-Log "[OCI] Successfully pushed artifact to $artifactRef"
        return $true
    }
    finally {
        Set-Location $currentLocation
    }
}

function Pull-OciArtifact {
    <#
    .SYNOPSIS
    Pulls an OCI artifact from a registry using ORAS
    
    .PARAMETER Registry
    OCI registry URL
    
    .PARAMETER Repository
    Repository name
    
    .PARAMETER Tag
    Artifact tag/version
    
    .PARAMETER DestinationPath
    Destination directory for pulled artifact
    
    .PARAMETER MediaType
    Optional media type filter for specific layer
    
    .PARAMETER Insecure
    Allow insecure (HTTP) registry connections
    
    .PARAMETER PlainHttp
    Use plain HTTP instead of HTTPS
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Registry,
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Tag,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $false)]
        [string]$MediaType,
        [Parameter(Mandatory = $false)]
        [switch]$Insecure,
        [Parameter(Mandatory = $false)]
        [switch]$PlainHttp
    )
    
    $orasExe = Get-OrasExePath
    $artifactRef = "$Registry/$Repository`:$Tag"
    
    if (-not (Test-Path $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    
    # Build ORAS pull command arguments
    $orasArgs = @('pull')
    
    if ($Insecure) {
        $orasArgs += '--insecure'
    }
    
    if ($PlainHttp) {
        $orasArgs += '--plain-http'
    }
    
    $orasArgs += '-o'
    $orasArgs += $DestinationPath
    
    if ($MediaType) {
        $orasArgs += '--include-subject'
        $orasArgs += '--media-type'
        $orasArgs += $MediaType
    }
    
    $orasArgs += $artifactRef
    
    Write-Log "[OCI] Pulling artifact from $artifactRef to $DestinationPath"
    
    $result = & $orasExe $orasArgs 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        throw "ORAS pull failed: $result"
    }
    
    Write-Log "[OCI] Successfully pulled artifact from $artifactRef"
    return $true
}

function Get-OciArtifactManifest {
    <#
    .SYNOPSIS
    Fetches the manifest of an OCI artifact
    
    .PARAMETER Registry
    OCI registry URL
    
    .PARAMETER Repository
    Repository name
    
    .PARAMETER Tag
    Artifact tag/version
    
    .PARAMETER Insecure
    Allow insecure (HTTP) registry connections
    
    .PARAMETER PlainHttp
    Use plain HTTP instead of HTTPS
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Registry,
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Tag,
        [Parameter(Mandatory = $false)]
        [switch]$Insecure,
        [Parameter(Mandatory = $false)]
        [switch]$PlainHttp
    )
    
    $orasExe = Get-OrasExePath
    $artifactRef = "$Registry/$Repository`:$Tag"
    
    $orasArgs = @('manifest', 'fetch')
    
    if ($Insecure) {
        $orasArgs += '--insecure'
    }
    
    if ($PlainHttp) {
        $orasArgs += '--plain-http'
    }
    
    $orasArgs += $artifactRef
    
    $result = & $orasExe $orasArgs 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        throw "ORAS manifest fetch failed: $result"
    }
    
    return $result | ConvertFrom-Json
}

function New-AddonOciArtifact {
    <#
    .SYNOPSIS
    Creates OCI artifact layers for an addon
    
    .PARAMETER AddonPath
    Path to the addon directory
    
    .PARAMETER StagingPath
    Path for staging artifact layers
    
    .PARAMETER AddonName
    Name of the addon
    
    .PARAMETER ImplementationName
    Name of the implementation (for multi-implementation addons)
    
    .PARAMETER LinuxImagesTar
    Path to Linux container images tar file
    
    .PARAMETER WindowsImagesTar
    Path to Windows container images tar file
    
    .PARAMETER PackagesPath
    Path to offline packages directory
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AddonPath,
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,
        [Parameter(Mandatory = $true)]
        [string]$AddonName,
        [Parameter(Mandatory = $false)]
        [string]$ImplementationName,
        [Parameter(Mandatory = $false)]
        [string]$LinuxImagesTar,
        [Parameter(Mandatory = $false)]
        [string]$WindowsImagesTar,
        [Parameter(Mandatory = $false)]
        [string]$PackagesPath
    )
    
    if (-not (Test-Path $StagingPath)) {
        New-Item -ItemType Directory -Path $StagingPath -Force | Out-Null
    }
    
    $layers = @{}
    
    # Layer 1: Manifests
    $manifestsDir = Join-Path $AddonPath 'manifests'
    if (Test-Path $manifestsDir) {
        $manifestsTar = Join-Path $StagingPath 'manifests.tar.gz'
        if (New-TarGzArchive -SourcePath $manifestsDir -DestinationPath $manifestsTar) {
            $layers['manifests.tar.gz'] = $script:MediaTypes.Manifests
            Write-Log "[OCI] Created manifests layer: $manifestsTar"
        }
    }
    
    # Layer 2: Helm Charts (if present)
    $chartsDir = Join-Path $AddonPath 'manifests\chart'
    if (Test-Path $chartsDir) {
        $chartsTar = Join-Path $StagingPath 'charts.tar.gz'
        if (New-TarGzArchive -SourcePath $chartsDir -DestinationPath $chartsTar) {
            $layers['charts.tar.gz'] = $script:MediaTypes.Charts
            Write-Log "[OCI] Created charts layer: $chartsTar"
        }
    }
    
    # Layer 3: Scripts (Enable.ps1, Disable.ps1, Get-Status.ps1, Update.ps1)
    $scriptFiles = @('Enable.ps1', 'Disable.ps1', 'Get-Status.ps1', 'Update.ps1') | ForEach-Object {
        Join-Path $AddonPath $_
    } | Where-Object { Test-Path $_ }
    
    if ($scriptFiles.Count -gt 0) {
        $scriptsDir = Join-Path $StagingPath 'scripts-temp'
        New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
        
        foreach ($script in $scriptFiles) {
            Copy-Item -Path $script -Destination $scriptsDir -Force
        }
        
        # Also copy any module files
        Get-ChildItem -Path $AddonPath -Filter '*.psm1' | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $scriptsDir -Force
        }
        
        $scriptsTar = Join-Path $StagingPath 'scripts.tar.gz'
        if (New-TarGzArchive -SourcePath $scriptsDir -DestinationPath $scriptsTar) {
            $layers['scripts.tar.gz'] = $script:MediaTypes.Scripts
            Write-Log "[OCI] Created scripts layer: $scriptsTar"
        }
        
        Remove-Item -Path $scriptsDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    # Layer 4: Linux Images
    if ($LinuxImagesTar -and (Test-Path $LinuxImagesTar)) {
        $linuxImagesLayer = Join-Path $StagingPath 'images-linux.tar'
        Copy-Item -Path $LinuxImagesTar -Destination $linuxImagesLayer -Force
        $layers['images-linux.tar'] = $script:MediaTypes.ImagesLinux
        Write-Log "[OCI] Added Linux images layer: $linuxImagesLayer"
    }
    
    # Layer 5: Windows Images
    if ($WindowsImagesTar -and (Test-Path $WindowsImagesTar)) {
        $windowsImagesLayer = Join-Path $StagingPath 'images-windows.tar'
        Copy-Item -Path $WindowsImagesTar -Destination $windowsImagesLayer -Force
        $layers['images-windows.tar'] = $script:MediaTypes.ImagesWindows
        Write-Log "[OCI] Added Windows images layer: $windowsImagesLayer"
    }
    
    # Layer 6: Offline Packages
    if ($PackagesPath -and (Test-Path $PackagesPath)) {
        $packagesTar = Join-Path $StagingPath 'packages.tar.gz'
        if (New-TarGzArchive -SourcePath $PackagesPath -DestinationPath $packagesTar) {
            $layers['packages.tar.gz'] = $script:MediaTypes.Packages
            Write-Log "[OCI] Created packages layer: $packagesTar"
        }
    }
    
    return $layers
}

function Export-AddonAsOciArtifact {
    <#
    .SYNOPSIS
    Exports an addon as a local OCI artifact (directory structure)
    
    .PARAMETER AddonPath
    Path to the addon directory
    
    .PARAMETER ExportPath
    Path where the OCI artifact structure will be created
    
    .PARAMETER AddonName
    Name of the addon
    
    .PARAMETER ImplementationName
    Name of the implementation
    
    .PARAMETER Version
    Addon version
    
    .PARAMETER LinuxImagesTar
    Path to exported Linux images tar
    
    .PARAMETER WindowsImagesTar
    Path to exported Windows images tar
    
    .PARAMETER PackagesPath
    Path to offline packages
    
    .PARAMETER K2sVersion
    K2s version for metadata
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$AddonPath,
        [Parameter(Mandatory = $true)]
        [string]$ExportPath,
        [Parameter(Mandatory = $true)]
        [string]$AddonName,
        [Parameter(Mandatory = $false)]
        [string]$ImplementationName,
        [Parameter(Mandatory = $false)]
        [string]$Version = '1.0.0',
        [Parameter(Mandatory = $false)]
        [string]$LinuxImagesTar,
        [Parameter(Mandatory = $false)]
        [string]$WindowsImagesTar,
        [Parameter(Mandatory = $false)]
        [string]$PackagesPath,
        [Parameter(Mandatory = $false)]
        [string]$K2sVersion
    )
    
    # Create artifact directory name
    $artifactName = $AddonName
    if ($ImplementationName -and $ImplementationName -ne $AddonName) {
        $artifactName = "${AddonName}_${ImplementationName}"
    }
    
    $artifactDir = Join-Path $ExportPath $artifactName
    
    if (-not (Test-Path $artifactDir)) {
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    }
    
    Write-Log "[OCI] Creating OCI artifact structure at $artifactDir"
    
    # Copy addon.manifest.yaml as config
    $parentAddonFolder = Split-Path -Path $AddonPath -Parent
    $manifestFile = Join-Path $parentAddonFolder 'addon.manifest.yaml'
    if (-not (Test-Path $manifestFile)) {
        $manifestFile = Join-Path $AddonPath 'addon.manifest.yaml'
    }
    
    if (Test-Path $manifestFile) {
        Copy-Item -Path $manifestFile -Destination (Join-Path $artifactDir 'addon.manifest.yaml') -Force
    }
    
    # Create layers
    $layers = New-AddonOciArtifact `
        -AddonPath $AddonPath `
        -StagingPath $artifactDir `
        -AddonName $AddonName `
        -ImplementationName $ImplementationName `
        -LinuxImagesTar $LinuxImagesTar `
        -WindowsImagesTar $WindowsImagesTar `
        -PackagesPath $PackagesPath
    
    # Create artifact metadata
    $metadata = @{
        schemaVersion = 2
        mediaType = 'application/vnd.oci.image.manifest.v1+json'
        artifactType = 'application/vnd.k2s.addon.v1'
        config = @{
            mediaType = $script:MediaTypes.Config
            size = 0
            digest = ''
        }
        layers = @()
        annotations = @{
            'org.opencontainers.image.title' = $AddonName
            'org.opencontainers.image.version' = $Version
            'vnd.k2s.addon.name' = $AddonName
            'vnd.k2s.addon.implementation' = if ($ImplementationName) { $ImplementationName } else { $AddonName }
            'vnd.k2s.version' = if ($K2sVersion) { $K2sVersion } else { 'unknown' }
            'vnd.k2s.export.date' = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }
    
    foreach ($layer in $layers.GetEnumerator()) {
        $layerPath = Join-Path $artifactDir $layer.Key
        if (Test-Path $layerPath) {
            $metadata.layers += @{
                mediaType = $layer.Value
                size = (Get-Item $layerPath).Length
                digest = "sha256:$(Get-FileHash -Path $layerPath -Algorithm SHA256 | Select-Object -ExpandProperty Hash)"
                annotations = @{
                    'org.opencontainers.image.title' = $layer.Key
                }
            }
        }
    }
    
    # Save manifest.json
    $metadata | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $artifactDir 'oci-manifest.json') -Force
    
    Write-Log "[OCI] OCI artifact structure created with $($layers.Count) layers"
    
    return @{
        Path = $artifactDir
        Layers = $layers
        Metadata = $metadata
    }
}

function Import-OciArtifactToAddon {
    <#
    .SYNOPSIS
    Imports an OCI artifact to the addons directory
    
    .PARAMETER ArtifactPath
    Path to the OCI artifact directory
    
    .PARAMETER AddonsRoot
    Root path of addons directory
    
    .PARAMETER ShowLogs
    Show verbose logs
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactPath,
        [Parameter(Mandatory = $true)]
        [string]$AddonsRoot,
        [Parameter(Mandatory = $false)]
        [switch]$ShowLogs
    )
    
    Write-Log "[OCI] Importing OCI artifact from $ArtifactPath"
    
    # Read manifest
    $manifestPath = Join-Path $ArtifactPath 'oci-manifest.json'
    if (-not (Test-Path $manifestPath)) {
        throw "OCI manifest not found at $manifestPath"
    }
    
    $manifest = Get-Content $manifestPath | ConvertFrom-Json
    
    $addonName = $manifest.annotations.'vnd.k2s.addon.name'
    $implementationName = $manifest.annotations.'vnd.k2s.addon.implementation'
    
    if (-not $addonName) {
        throw "Addon name not found in OCI manifest annotations"
    }
    
    Write-Log "[OCI] Importing addon: $addonName, implementation: $implementationName"
    
    # Determine destination path
    $destinationPath = Join-Path $AddonsRoot $addonName
    if ($implementationName -and $implementationName -ne $addonName) {
        $destinationPath = Join-Path $destinationPath $implementationName
    }
    
    if (-not (Test-Path $destinationPath)) {
        New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    }
    
    $result = @{
        AddonName = $addonName
        ImplementationName = $implementationName
        DestinationPath = $destinationPath
        LinuxImages = @()
        WindowsImages = @()
    }
    
    # Process layers
    foreach ($layer in $manifest.layers) {
        $layerFile = $layer.annotations.'org.opencontainers.image.title'
        $layerPath = Join-Path $ArtifactPath $layerFile
        $mediaType = $layer.mediaType
        
        if (-not (Test-Path $layerPath)) {
            Write-Log "[OCI] Warning: Layer file not found: $layerPath"
            continue
        }
        
        switch -Wildcard ($mediaType) {
            '*manifests*' {
                Write-Log "[OCI] Extracting manifests layer"
                $manifestsDir = Join-Path $destinationPath 'manifests'
                Expand-TarGzArchive -ArchivePath $layerPath -DestinationPath $manifestsDir
            }
            '*helm.chart*' {
                Write-Log "[OCI] Extracting charts layer"
                $chartsDir = Join-Path $destinationPath 'manifests\chart'
                Expand-TarGzArchive -ArchivePath $layerPath -DestinationPath $chartsDir
            }
            '*scripts*' {
                Write-Log "[OCI] Extracting scripts layer"
                Expand-TarGzArchive -ArchivePath $layerPath -DestinationPath $destinationPath
            }
            '*image.layer*windows*' {
                Write-Log "[OCI] Found Windows images layer"
                $result.WindowsImages += $layerPath
            }
            '*image.layer*' {
                Write-Log "[OCI] Found Linux images layer"
                $result.LinuxImages += $layerPath
            }
            '*packages*' {
                Write-Log "[OCI] Extracting packages layer"
                $packagesDir = Join-Path $ArtifactPath 'packages-extracted'
                Expand-TarGzArchive -ArchivePath $layerPath -DestinationPath $packagesDir
                $result.PackagesPath = $packagesDir
            }
        }
    }
    
    # Copy addon.manifest.yaml
    $configPath = Join-Path $ArtifactPath 'addon.manifest.yaml'
    if (Test-Path $configPath) {
        $parentAddonFolder = Split-Path -Path $destinationPath -Parent
        if ($implementationName -and $implementationName -ne $addonName) {
            # Multi-implementation: manifest goes to parent
            Copy-Item -Path $configPath -Destination (Join-Path $parentAddonFolder 'addon.manifest.yaml') -Force
        } else {
            Copy-Item -Path $configPath -Destination (Join-Path $destinationPath 'addon.manifest.yaml') -Force
        }
    }
    
    Write-Log "[OCI] OCI artifact imported to $destinationPath"
    
    return $result
}

Export-ModuleMember -Function Get-OrasExePath, Get-OciMediaTypes,
    New-TarGzArchive, New-TarArchive, Expand-TarGzArchive, Expand-TarArchive,
    Push-OciArtifact, Pull-OciArtifact, Get-OciArtifactManifest,
    New-AddonOciArtifact, Export-AddonAsOciArtifact, Import-OciArtifactToAddon
