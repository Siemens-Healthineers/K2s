# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Creates a delta package between two K2s offline installation packages.

.DESCRIPTION
    New-K2sDeltaPackage.ps1 orchestrates creation of a delta package that contains
    only the differences between two K2s offline packages. This dramatically reduces
    package size for updates.
    
    The delta package includes:
    - Changed and added files (with hash-based comparison)
    - Debian package differences from Kubemaster VM base images
    - Container image layer differences (Linux and Windows)
    - Wholesale directory replacements as specified
    
    Container Image Delta Processing:
    - Discovers images from buildah (Linux) and addon manifests (Windows)
    - Compares image versions between packages by image ID and digest
    - Exports only changed images as OCI archives to minimize delta size
    - Achieves 80-95% size reduction for image-only updates
    - Linux images processed via buildah in temporary VM
    - Windows images marked for full export (layer extraction not yet implemented)
    
    Requirements:
    - Hyper-V enabled for VM-based analysis
    - buildah 1.23+ (present in Kubemaster base image)
    - containerd 1.6+ (for image management)
    - Both input packages must be offline-installation packages with VHDX images
    
    The generated delta manifest (v2.0) includes ContainerImageDiff metadata with
    added, removed, and changed image lists, plus extracted layer paths and sizes.

.PARAMETER InputPackageOne
    Path to the older (base) K2s offline package ZIP file.

.PARAMETER InputPackageTwo
    Path to the newer (target) K2s offline package ZIP file.

.PARAMETER TargetDirectory
    Directory where the delta package ZIP will be created.

.PARAMETER ZipPackageFileName
    Name of the output delta package ZIP file (must end with .zip).

.PARAMETER ShowLogs
    Show detailed logs during delta creation.

.PARAMETER EncodeStructuredOutput
    Encode output as structured data for CLI consumption.

.PARAMETER MessageType
    Message type for structured output (used with EncodeStructuredOutput).

.PARAMETER CertificatePath
    Path to code signing certificate (.pfx file) for signing executables and scripts.

.PARAMETER Password
    Password for the certificate file (plain string).

.PARAMETER WholeDirectories
    Directories to include wholesale from newer package without diffing.
    Relative paths (e.g., 'docs', 'addons/monitoring').

.PARAMETER SkipImageDelta
    Skip container image delta processing. Use this to create delta packages
    without image layer analysis (faster but larger packages).

.EXAMPLE
    .\New-K2sDeltaPackage.ps1 -InputPackageOne 'C:\packages\k2s-1.6.0.zip' `
                               -InputPackageTwo 'C:\packages\k2s-1.7.0.zip' `
                               -TargetDirectory 'C:\output' `
                               -ZipPackageFileName 'k2s-delta-1.6.0-to-1.7.0.zip' `
                               -ShowLogs

.EXAMPLE
    # Create delta with image processing skipped (faster creation)
    .\New-K2sDeltaPackage.ps1 -InputPackageOne 'old.zip' `
                               -InputPackageTwo 'new.zip' `
                               -TargetDirectory 'C:\output' `
                               -ZipPackageFileName 'delta.zip' `
                               -SkipImageDelta

.EXAMPLE
    # Create delta with code signing
    .\New-K2sDeltaPackage.ps1 -InputPackageOne 'old.zip' `
                               -InputPackageTwo 'new.zip' `
                               -TargetDirectory 'C:\output' `
                               -ZipPackageFileName 'delta.zip' `
                               -CertificatePath 'cert.pfx' `
                               -Password 'certpass'

.NOTES
    Container image delta processing adds 5-15 minutes to delta creation time
    but can reduce delta package size by 500MB-2GB for image-heavy updates.
    
    Temporary VMs are created and cleaned up automatically during processing.
    Ensure sufficient disk space for temporary extraction directories.
#>

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Input package one (the older version)')]
    [string] $InputPackageOne,
    [parameter(Mandatory = $false, HelpMessage = 'Input package two (the newer version)')]
    [string] $InputPackageTwo,
    [parameter(Mandatory = $false, HelpMessage = 'Target directory')]
    [string] $TargetDirectory,
    [parameter(Mandatory = $false, HelpMessage = 'The name of the zip package (it must have the extension .zip)')]
    [string] $ZipPackageFileName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Path to code signing certificate (.pfx file)')]
    [string] $CertificatePath,
    [parameter(Mandatory = $false, HelpMessage = 'Password for the certificate file (plain string; consider SecureString in future)')]
    [string] $Password,
    [parameter(Mandatory = $false, HelpMessage = 'Directories to include wholesale from newer package (no diffing). Relative paths; can be specified multiple times.')]
    [string[]] $WholeDirectories = @(),
    [parameter(Mandatory = $false, HelpMessage = 'Skip container image delta processing')]
    [switch] $SkipImageDelta = $false
)

# Internal flag to suppress duplicate terminal error logs
$script:SuppressFinalErrorLog = $false

### Import modules required for logging and signing
$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$signingModule = "$PSScriptRoot/../../../../modules/k2s/k2s.signing.module/k2s.signing.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $signingModule

# CRITICAL: When encoding structured output, suppress ALL console output to prevent base64 contamination
if ($EncodeStructuredOutput) {
    Initialize-Logging -ShowLogs:$false
} else {
    Initialize-Logging -ShowLogs:$ShowLogs
}

### Dot-source helper methods
$script:DeltaHelperParts = @(
    'New-K2sDelta.Phase.ps1',
    'New-K2sDelta.IO.ps1',
    'New-K2sDelta.Hash.ps1',
    'New-K2sDelta.Skip.ps1',
    'New-K2sDelta.Debian.ps1',
    'New-K2sDelta.HyperV.ps1',
    'New-K2sDelta.Diff.ps1',
    'New-K2sDelta.ImageDiff.ps1',
    'New-K2sDelta.ImageAcquisition.ps1'
)

foreach ($part in $script:DeltaHelperParts) {
    $path = Join-Path $PSScriptRoot $part
    if (Test-Path -LiteralPath $path) {
        . $path
    } else {
        Write-Log "[DeltaHelpers][Warning] Part missing: $part (expected at $path)" -Console
    }
}

Write-Log "- Target Directory: $TargetDirectory"
Write-Log "- Package file name: $ZipPackageFileName"

# Validate input packages BEFORE any resource allocation (SSH keys, temp dirs, etc.)
if ([string]::IsNullOrWhiteSpace($InputPackageOne) -or -not (Test-Path -LiteralPath $InputPackageOne)) {
    $errorMsg = "InputPackageOne missing or not found: '$InputPackageOne'"
    Write-Log $errorMsg -Error
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'delta-package-input-not-found' -Message $errorMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
    }
    exit 2
}
if ([string]::IsNullOrWhiteSpace($InputPackageTwo) -or -not (Test-Path -LiteralPath $InputPackageTwo)) {
    $errorMsg = "InputPackageTwo missing or not found: '$InputPackageTwo'"
    Write-Log $errorMsg -Error
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'delta-package-input-not-found' -Message $errorMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
    }
    exit 3
}

$errMsg = ''
if ('' -eq $TargetDirectory) {
    $errMsg = 'The passed target directory is empty'
}
elseif (!(Test-Path -Path $TargetDirectory)) {
    $errMsg = "The passed target directory '$TargetDirectory' could not be found"
}
elseif ('' -eq $ZipPackageFileName) {
    $errMsg = 'The passed zip package name is empty'
}
elseif ($ZipPackageFileName.EndsWith('.zip') -eq $false) {
    $errMsg = "The passed zip package name '$ZipPackageFileName' does not have the extension '.zip'"
}

if ($errMsg -ne '') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'build-package-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error -Console
    exit 1
}

$zipPackagePath = Join-Path "$TargetDirectory" "$ZipPackageFileName"

if (Test-Path $zipPackagePath) {
    Write-Log "Removing already existing file '$zipPackagePath'" -Console
    Remove-Item $zipPackagePath -Force
}

Write-Log "Zip package available at '$zipPackagePath'." -Console

# --- Delta Package Construction -------------------------------------------------
# Input packages already validated at script start (before SSH key generation)

Write-Log "Building delta between:'$InputPackageOne' -> '$InputPackageTwo'" -Console

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("k2s-delta-" + [guid]::NewGuid())
$oldExtract = Join-Path $tempRoot 'old'
$newExtract = Join-Path $tempRoot 'new'
$stageDir   = Join-Path $tempRoot 'stage'
New-Item -ItemType Directory -Force -Path $oldExtract | Out-Null
New-Item -ItemType Directory -Force -Path $newExtract | Out-Null
New-Item -ItemType Directory -Force -Path $stageDir   | Out-Null

$overallError = $null
try {
    try {
    Expand-ZipWithProgress -ZipPath $InputPackageOne -Destination $oldExtract -Label 'old package' -Show:$ShowLogs
    Expand-ZipWithProgress -ZipPath $InputPackageTwo -Destination $newExtract -Label 'new package' -Show:$ShowLogs
    }
    catch {
        Write-Log "Extraction failed: $($_.Exception.Message)" -Error
        throw
    }

 # (Get-FileMap provided via methods file)

# Expand potential comma-separated lists provided as a single argument
$expandedWholeDirs = @()
foreach ($entry in $WholeDirectories) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    # If user passed "dir1,dir2,dir3" as one string, split it
    $segments = $entry -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($segments.Count -gt 0) { $expandedWholeDirs += $segments }
}

# Normalize whole directory list (relative, forward slashes, trimmed)
$wholeDirsNormalized = @()
foreach ($d in $expandedWholeDirs) {
    if ([string]::IsNullOrWhiteSpace($d)) { continue }
    $n = $d -replace '\\','/'            # backslashes -> forward slashes
    $n = $n -replace '^[\\/]+' , ''      # strip leading separators
    $n = $n.TrimEnd('/')                   # remove trailing slash
    if (-not [string]::IsNullOrWhiteSpace($n)) { $wholeDirsNormalized += $n }
}
if ($wholeDirsNormalized.Count -gt 0) {
    $wholeDirsNormalized = $wholeDirsNormalized | Sort-Object -Unique
    Write-Log "Whole directories (no diffing): $($wholeDirsNormalized -join ', ')" -Console
}

# Internal list of special files that should be excluded from diff/staging and handled separately if needed.
$SpecialSkippedFiles = @('Kubemaster-Base.vhdx', 'trivy.exe', 'virtctl.exe', 'virt-viewer-x64-11.0-1.0.msi', 'k2s-bom.json', 'k2s-bom.xml', 'Kubemaster-Base.rootfs.tar.gz', 'WindowsNodeArtifacts.zip')
Write-Log "Special skipped files: $($SpecialSkippedFiles -join ', ')" -Console
 # (Test-SpecialSkippedFile / Test-InWholeDir provided via methods file)

# ---- Special Handling: Analyze Debian packages inside Kubemaster-Base.vhdx (best effort) ---------
# This avoids fully booting a VM by attempting offline extraction of /var/lib/dpkg/status using 7zip.
# If 7z.exe is not available or the dpkg status file cannot be located, the analysis is skipped gracefully.

 # (Get-DebianPackageMapFromStatusFile provided)

 # (Get-DebianPackagesFromVHDX provided)


 # (Get-SkippedFileDebianPackageDiff provided)

$hashPhase = Start-Phase "Hashing"
$oldMap = Get-FileMap -root $oldExtract -label 'old package'
$newMap = Get-FileMap -root $newExtract -label 'new package'
Stop-Phase "Hashing" $hashPhase

$added    = @()
$removed  = @()
$changed  = @()

# Added & changed (exclude files beneath wholesale directories)
foreach ($p in $newMap.Keys) {
    if (Test-InWholeDir -path $p -dirs $wholeDirsNormalized) { continue }
    if (Test-SpecialSkippedFile -path $p -list $SpecialSkippedFiles) { continue }
    if (-not $oldMap.ContainsKey($p)) { $added += $p; continue }
    if ($oldMap[$p].Hash -ne $newMap[$p].Hash) { $changed += $p }
}
# Removed (exclude files beneath wholesale directories)
foreach ($p in $oldMap.Keys) {
    if (Test-InWholeDir -path $p -dirs $wholeDirsNormalized) { continue }
    if (Test-SpecialSkippedFile -path $p -list $SpecialSkippedFiles) { continue }
    if (-not $newMap.ContainsKey($p)) { $removed += $p }
}

Write-Log "Added: $($added.Count)  Changed: $($changed.Count)  Removed: $($removed.Count)" -Console

# Stage wholesale directories verbatim
$stagePhase = Start-Phase "Staging"
foreach ($wd in $wholeDirsNormalized) {
    $srcDir = Join-Path $newExtract $wd
    if (-not (Test-Path -LiteralPath $srcDir)) { Write-Log "[Warning] Wholesale directory '$wd' not found in new package"; continue }
    $dstDir = Join-Path $stageDir $wd
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath $srcDir -Destination $dstDir -Recurse -Force
}

# Helper to purge any special skipped files that were copied indirectly (e.g. via wholesale directories)
 # (Remove-SpecialSkippedFilesFromStage provided)

# Initial purge after wholesale copy
Remove-SpecialSkippedFilesFromStage -StagePath $stageDir -Skipped $SpecialSkippedFiles

# Stage added + changed files
$deltaFileList = $added + $changed | Where-Object { -not (Test-SpecialSkippedFile -path $_ -list $SpecialSkippedFiles) }
# Final purge to ensure no special skipped files remain (handles files among added/changed set)
Remove-SpecialSkippedFilesFromStage -StagePath $stageDir -Skipped $SpecialSkippedFiles
$deltaTotal = $deltaFileList.Count
Write-Log "Staging $deltaTotal changed/added files" -Console
$lastPct = -1
for ($i = 0; $i -lt $deltaTotal; $i++) {
    $rel = $deltaFileList[$i]
    $source = Join-Path $newExtract $rel
    $dest   = Join-Path $stageDir   $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $dest -Force
    if ($ShowLogs -and $deltaTotal -gt 0) {
        $pct = [int](($i+1) * 100 / $deltaTotal)
        if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) {
            Write-Progress -Activity 'Staging delta files' -Status "$(($i+1)) / $deltaTotal" -PercentComplete $pct
            $lastPct = $pct
        }
    }
}
if ($ShowLogs) { Write-Progress -Activity 'Staging delta files' -Completed }
Stop-Phase "Staging" $stagePhase

# --- MANDATORY: Ensure k2s.exe is always included (for update execution from delta package) ---
$k2sExePath = 'k2s.exe'
$k2sExeSource = Join-Path $newExtract $k2sExePath
$k2sExeDest = Join-Path $stageDir $k2sExePath
if (Test-Path -LiteralPath $k2sExeSource) {
    if (-not (Test-Path -LiteralPath $k2sExeDest)) {
        Write-Log "[Mandatory] Adding k2s.exe to delta package (not in diff but required for update execution)" -Console
        Copy-Item -LiteralPath $k2sExeSource -Destination $k2sExeDest -Force
        # Add to changed list if not already present
        if ($k2sExePath -notin $added -and $k2sExePath -notin $changed) {
            $changed += $k2sExePath
        }
    } else {
        Write-Log "[Mandatory] k2s.exe already staged" -Console
    }
} else {
    Write-Log "[Warning] k2s.exe not found in new package - delta update may fail!" -Console
}

# --- MANDATORY: Copy update module to delta package for standalone execution ---
# Note: The update module will dynamically load other required modules (infra, runningstate, etc.) 
# from the target installation folder, so we only need to include update.module.psm1 itself.
$updateModuleName = 'update.module.psm1'
$updateModuleRelPath = "lib/modules/k2s/k2s.cluster.module/update/$updateModuleName"
$updateModuleSource = Join-Path $newExtract $updateModuleRelPath
$updateModuleDest = Join-Path $stageDir $updateModuleRelPath
if (Test-Path -LiteralPath $updateModuleSource) {
    $updateModuleDestDir = Split-Path $updateModuleDest -Parent
    if (-not (Test-Path -LiteralPath $updateModuleDestDir)) {
        New-Item -ItemType Directory -Path $updateModuleDestDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $updateModuleDest)) {
        Write-Log "[Mandatory] Adding update module to delta package (required for update execution)" -Console
        Copy-Item -LiteralPath $updateModuleSource -Destination $updateModuleDest -Force
        # Add to changed list if not already present
        if ($updateModuleRelPath -notin $added -and $updateModuleRelPath -notin $changed) {
            $changed += $updateModuleRelPath
        }
    } else {
        Write-Log "[Mandatory] Update module already staged" -Console
    }
} else {
    Write-Log "[Warning] Update module not found in new package - delta update may fail!" -Console
}

# --- MANDATORY: Create Apply-Delta.ps1 wrapper script for easy execution ---
$applyScriptContent = @'
# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Applies the K2s delta update package.
.DESCRIPTION
    This script provides a convenient wrapper to apply the delta update using the
    update.module.psm1 included in this delta package. It must be executed from
    the extracted delta package directory.
.PARAMETER ShowLogs
    Display detailed log output during the update process.
.PARAMETER ShowProgress
    Show progress indicators during the update phases.
#>

#Requires -RunAsAdministrator

Param(
    [Parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,
    [Parameter(Mandatory = $false)]
    [switch] $ShowProgress = $false
)

$ErrorActionPreference = 'Stop'

# Determine the delta package path (this script's directory contains the extracted delta)
$scriptRoot = $PSScriptRoot
$deltaManifestPath = Join-Path $scriptRoot 'delta-manifest.json'

if (-not (Test-Path -LiteralPath $deltaManifestPath)) {
    Write-Host "[ERROR] delta-manifest.json not found in $scriptRoot" -ForegroundColor Red
    Write-Host "[ERROR] This script must be run from the root of the extracted delta package directory." -ForegroundColor Red
    exit 1
}

# Load the update module from the delta package
$updateModulePath = Join-Path $scriptRoot 'lib\modules\k2s\k2s.cluster.module\update\update.module.psm1'
if (-not (Test-Path -LiteralPath $updateModulePath)) {
    Write-Host "[ERROR] Update module not found at: $updateModulePath" -ForegroundColor Red
    Write-Host "[ERROR] The delta package may be incomplete or corrupted." -ForegroundColor Red
    exit 2
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "K2s Delta Update" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Importing update module..." -ForegroundColor Yellow

try {
    Import-Module $updateModulePath -Force
} catch {
    Write-Host "[ERROR] Failed to import update module: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}

Write-Host "Starting delta update process..." -ForegroundColor Yellow
Write-Host ""

# Test the update by executing from the current directory (delta root)
# No need to repackage - PerformClusterUpdate now expects to run from extracted delta directory
Write-Host "Testing delta update from current directory..." -ForegroundColor Yellow
Write-Host "Delta root: $scriptRoot" -ForegroundColor Gray

try {
    # Change to the script root directory (where delta-manifest.json is)
    Push-Location $scriptRoot
    
    # Execute the update - it will detect delta-manifest.json in current directory
    $result = PerformClusterUpdate -ShowLogs:$ShowLogs -ShowProgress:$ShowProgress
    
    Pop-Location
    
    if ($result) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Delta update completed successfully!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host "Delta update failed!" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        exit 4
    }
} catch {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "Delta update encountered an error:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    exit 5
} finally {
    # No temporary zip to cleanup - we execute directly from the directory
}
'@

$applyScriptPath = Join-Path $stageDir 'Apply-Delta.ps1'
$applyScriptContent | Out-File -FilePath $applyScriptPath -Encoding UTF8 -Force
Write-Log "[Mandatory] Created Apply-Delta.ps1 wrapper script" -Console

# Staging summary
$stagedFileCount = (Get-ChildItem -Path $stageDir -Recurse -File | Measure-Object).Count
Write-Log "Staging summary: total staged files=$stagedFileCount (wholesale dirs=$($wholeDirsNormalized.Count), added=$($added.Count), changed=$($changed.Count))" -Console

# Special diff for Debian packages inside Kubemaster-Base.vhdx (if present and analyzable)
$debianPackageDiff = $null
$offlineDebInfo = $null
$imageDiffResult = $null
if ($SpecialSkippedFiles -contains 'Kubemaster-Base.vhdx') {
        Write-Log 'Analyzing Debian packages in Kubemaster-Base.vhdx ...' -Console
                $debianPackageDiff = Get-SkippedFileDebianPackageDiff -OldRoot $oldExtract -NewRoot $newExtract -FileName 'Kubemaster-Base.vhdx' -QueryImages:(-not $SkipImageDelta) -KeepNewVmAlive:(-not $SkipImageDelta)
        if ($debianPackageDiff.Processed) {
            Write-Log ("Debian package diff: Added={0} Changed={1} Removed={2}" -f $debianPackageDiff.AddedCount, $debianPackageDiff.ChangedCount, $debianPackageDiff.RemovedCount) -Console
            
            # Process image delta if enabled
            if (-not $SkipImageDelta) {
                Write-Log '[ImageDiff] Processing container image delta...' -Console
                $imagePhase = Start-Phase 'Image Delta'
                
                try {
                    # Get Windows images from both packages
                    Write-Log '[ImageDiff] Extracting Windows images from packages...' -Console
                    $oldWinImages = Get-WindowsImagesFromPackage -PackageRoot $oldExtract
                    $newWinImages = Get-WindowsImagesFromPackage -PackageRoot $newExtract
                    
                    # Compare all images
                    $imageDiffResult = Compare-ContainerImages -OldLinuxImages $debianPackageDiff.OldLinuxImages `
                                                                -NewLinuxImages $debianPackageDiff.NewLinuxImages `
                                                                -OldWindowsImages $oldWinImages.Images `
                                                                -NewWindowsImages $newWinImages.Images
                    
                    Write-Log "[ImageDiff] Image comparison complete: Added=$($imageDiffResult.Added.Count), Removed=$($imageDiffResult.Removed.Count), Changed=$($imageDiffResult.Changed.Count)" -Console
                    
                    # Extract layers for changed images (Added + Changed)
                    $imagesToProcess = @()
                    if ($imageDiffResult.Added) { $imagesToProcess += $imageDiffResult.Added }
                    if ($imageDiffResult.Changed) { $imagesToProcess += $imageDiffResult.Changed }
                    
                    if ($imagesToProcess.Count -gt 0) {
                        Write-Log "[ImageAcq] Starting image export for $($imagesToProcess.Count) images..." -Console
                        
                        # Debug: show platforms of all images
                        foreach ($img in $imagesToProcess) {
                            Write-Log "[ImageAcq] DEBUG: Image '$($img.FullName)' has Platform='$($img.Platform)'" -Console
                        }
                        
                        # Separate Windows and Linux images (ensure array output)
                        $windowsImagesToProcess = @($imagesToProcess | Where-Object { $_.Platform -eq 'windows' })
                        $linuxImagesToProcess = @($imagesToProcess | Where-Object { $_.Platform -eq 'linux' })
                        
                        Write-Log "[ImageAcq] Images to process: $($windowsImagesToProcess.Count) Windows, $($linuxImagesToProcess.Count) Linux" -Console
                        
                        # Get path to new VHDX
                        $newVhdxPath = Join-Path $newExtract 'bin\Kubemaster-Base.vhdx'
                        
                        # Always process Windows images (they don't need a VM)
                        # Process Linux images only if we have a VM context
                        $imagesToExport = @()
                        $imagesToExport += $windowsImagesToProcess
                        
                        if ((Test-Path $newVhdxPath) -and $debianPackageDiff.NewVmContext) {
                            $imagesToExport += $linuxImagesToProcess
                            $vmContext = $debianPackageDiff.NewVmContext
                        } else {
                            if ($linuxImagesToProcess.Count -gt 0) {
                                Write-Log "[ImageAcq] Warning: Cannot export Linux images - VHDX not found or VM context missing" -Console
                            }
                            $vmContext = $null
                        }
                        
                        if ($imagesToExport.Count -gt 0) {
                            $layerExtractionResult = Export-ChangedImageLayers -NewPackageRoot $newExtract `
                                                                                -NewVhdxPath $newVhdxPath `
                                                                                -ChangedImages $imagesToExport `
                                                                                -StagingDir $stageDir `
                                                                                -ExistingVmContext $vmContext `
                                                                                -ShowLogs:$false
                            
                            if ($layerExtractionResult.Success) {
                                Write-Log "[ImageAcq] Image export successful: Exported $($layerExtractionResult.ExtractedLayers.Count) image archives, Total size: $([math]::Round($layerExtractionResult.TotalSize / 1MB, 2)) MB" -Console
                                
                                if ($layerExtractionResult.FailedImages.Count -gt 0) {
                                    Write-Log "[ImageAcq] Warning: $($layerExtractionResult.FailedImages.Count) images failed extraction: $($layerExtractionResult.FailedImages -join ', ')" -Console
                                }
                            } else {
                                Write-Log "[ImageAcq] Warning: Image export failed: $($layerExtractionResult.ErrorMessage)" -Console
                            }
                        }
                        
                        # Clean up the VM if we had one
                        if ($debianPackageDiff.NewVmContext) {
                            Write-Log "[ImageAcq] Cleaning up reused VM: $($debianPackageDiff.NewVmContext.VmName)" -Console
                            Remove-K2sHvEnvironment -Context $debianPackageDiff.NewVmContext
                        }
                    } else {
                        Write-Log "[ImageAcq] No images to process for layer extraction" -Console
                        # Still need to clean up VM if it exists
                        if ($debianPackageDiff.NewVmContext) {
                            Write-Log "[ImageAcq] Cleaning up VM (no images to process): $($debianPackageDiff.NewVmContext.VmName)" -Console
                            Remove-K2sHvEnvironment -Context $debianPackageDiff.NewVmContext
                        }
                    }
                    
                } catch {
                    Write-Log "[ImageDiff] Warning: Image delta processing failed: $($_.Exception.Message)" -Console
                } finally {
                    Stop-Phase 'Image Delta' $imagePhase
                }
            }
            
                        # --- Generate Debian delta artifact directory (lists + scripts) -----------------
            try {
                $debianDeltaDir = Join-Path $stageDir 'debian-delta'
                if (-not (Test-Path -LiteralPath $debianDeltaDir)) { New-Item -ItemType Directory -Path $debianDeltaDir | Out-Null }

                # Collect offline package specs (added + upgraded new versions)
                $offlineSpecs = @()
                if ($debianPackageDiff.Added) { $offlineSpecs += $debianPackageDiff.Added }
                if ($debianPackageDiff.Changed) {
                    foreach ($c in $debianPackageDiff.Changed) {
                        if ($c -match '^(?<n>[^:]+):\s+[^ ]+\s+->\s+(?<nv>.+)$') { $offlineSpecs += ("{0}={1}" -f $matches['n'], $matches['nv']) }
                    }
                }
                $offlineSpecs = $offlineSpecs | Sort-Object -Unique

                # Added packages list (keep full pkg=version form)
                $addedPkgs = $debianPackageDiff.Added
                if ($addedPkgs) { $addedPkgs | Sort-Object | Out-File -FilePath (Join-Path $debianDeltaDir 'packages.added') -Encoding ASCII -Force }

                # Removed packages list (strip versions to just names)
                $removedNames = @()
                foreach ($r in ($debianPackageDiff.Removed)) { if ($r -match '^(?<n>[^=]+)=(?<v>.+)$') { $removedNames += $matches['n'] } }
                if ($removedNames) { $removedNames | Sort-Object -Unique | Out-File -FilePath (Join-Path $debianDeltaDir 'packages.removed') -Encoding ASCII -Force }

                # Upgraded packages (Changed list lines formatted: name: old -> new)
                $upgradedLines = @()
                foreach ($c in ($debianPackageDiff.Changed)) { if ($c -match '^(?<n>[^:]+):\s+(?<o>[^ ]+)\s+->\s+(?<nv>.+)$') { $upgradedLines += ("{0} {1} {2}" -f $matches['n'], $matches['o'], $matches['nv']) } }
                if ($upgradedLines) { $upgradedLines | Sort-Object | Out-File -FilePath (Join-Path $debianDeltaDir 'packages.upgraded') -Encoding ASCII -Force }

                # Debian delta manifest (JSON)
                $debDeltaManifest = [pscustomobject]@{
                    SourceVhdxOld       = $debianPackageDiff.OldRelativePath
                    SourceVhdxNew       = $debianPackageDiff.NewRelativePath
                    Added               = $addedPkgs
                    Removed             = $removedNames
                    Upgraded            = $upgradedLines
                    AddedCount          = $debianPackageDiff.AddedCount
                    RemovedCount        = $debianPackageDiff.RemovedCount
                    UpgradedCount       = $upgradedLines.Count
                    OfflinePackages     = $offlineSpecs
                    OfflinePackagesCount = $offlineSpecs.Count
                    GeneratedUtc        = [DateTime]::UtcNow.ToString('o')
                }
                $debDeltaManifest | ConvertTo-Json -Depth 4 | Out-File -FilePath (Join-Path $debianDeltaDir 'debian-delta-manifest.json') -Encoding UTF8 -Force

                # Apply script (bash) - installs added + upgraded with explicit versions, removes removed
                $applyScript = @('#!/usr/bin/env bash',
                'set -euo pipefail',
                'echo "[debian-delta] Apply start"',
                'if [[ $EUID -ne 0 ]]; then echo "Run as root" >&2; exit 1; fi',
                'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
                'cd "$SCRIPT_DIR"',
                'ADDED_FILE=packages.added',
                'REMOVED_FILE=packages.removed',
                'UPGRADED_FILE=packages.upgraded',
                'PKG_DIR=packages',
                'INSTALL_SPECS=()',
                'if [[ -f "$REMOVED_FILE" ]]; then echo "[debian-delta] Purging removed packages"; xargs -r dpkg --purge < "$REMOVED_FILE" || true; fi',
                'if [[ -f "$ADDED_FILE" ]]; then while IFS= read -r l; do [[ -z "$l" ]] && continue; INSTALL_SPECS+=("$l"); done < "$ADDED_FILE"; fi',
                'if [[ -f "$UPGRADED_FILE" ]]; then while IFS= read -r l; do [[ -z "$l" ]] && continue; PKG=$(echo "$l" | awk "{print $1}"); NEWV=$(echo "$l" | awk "{print $3}"); INSTALL_SPECS+=("${PKG}=${NEWV}"); done < "$UPGRADED_FILE"; fi',
                'if [[ -d "$PKG_DIR" ]]; then',
                '  shopt -s nullglob',
                '  DEBS=($PKG_DIR/*.deb)',
                '  if [[ ${#DEBS[@]} -gt 0 ]]; then',
                '    echo "[debian-delta] Installing local .deb files (${#DEBS[@]})"',
                '    dpkg -i ${DEBS[@]} || true',
                '    # Attempt to fix missing dependencies without network if possible',
                '    if command -v apt-get >/dev/null 2>&1; then apt-get -y --no-install-recommends install -f || true; fi',
                '  else',
                '    echo "[debian-delta] No local .deb files present"',
                '  fi',
                'fi',
                'if [[ ${#INSTALL_SPECS[@]} -gt 0 ]]; then',
                '  echo "[debian-delta] Ensuring target versions for ${#INSTALL_SPECS[@]} packages"',
                '  # Attempt version enforcement using dpkg (requires local .debs); fallback echo warnings',
                '  for spec in "${INSTALL_SPECS[@]}"; do',
                '     P=${spec%%=*}; V=${spec#*=};',
                '     CUR=$(dpkg-query -W -f="${Version}" "$P" 2>/dev/null || echo missing)',
                '     if [[ "$CUR" != "$V" ]]; then echo "[debian-delta][warn] Version mismatch for $P expected $V got $CUR"; fi',
                '  done',
                'else',
                '  echo "[debian-delta] No packages specified for install/upgrade"',
                'fi',
                    'echo "[debian-delta] Apply complete"'
                ) -join "`n"
                $applyPath = Join-Path $debianDeltaDir 'apply-debian-delta.sh'
                $applyScript | Out-File -FilePath $applyPath -Encoding ASCII -Force
                # Verification script
                $verifyScript = @('#!/usr/bin/env bash',
                'set -euo pipefail',
                'if [[ $EUID -ne 0 ]]; then echo "Run as root" >&2; exit 1; fi',
                'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"',
                'cd "$SCRIPT_DIR"',
                'MJSON=debian-delta-manifest.json',
                'command -v jq >/dev/null 2>&1 || { echo "jq required for verification" >&2; exit 2; }',
                'ADDED=$(jq -r ".Added[]?" "$MJSON" || true)',
                'UPG=$(jq -r ".Upgraded[]?" "$MJSON" || true)',
                'FAIL=0',
                'for entry in $ADDED; do P=${entry%%=*}; V=${entry#*=}; CV=$(dpkg-query -W -f="${Version}" "$P" 2>/dev/null || echo missing); if [[ "$CV" != "$V" ]]; then echo "[verify] Added pkg mismatch: $P expected $V got $CV"; FAIL=1; fi; done',
                'while read -r line; do [[ -z "$line" ]] && continue; PKG=$(echo "$line" | awk "{print $1}"); OV=$(echo "$line" | awk "{print $2}"); NV=$(echo "$line" | awk "{print $3}"); CV=$(dpkg-query -W -f="${Version}" "$PKG" 2>/dev/null || echo missing); if [[ "$CV" != "$NV" ]]; then echo "[verify] Upgraded pkg mismatch: $PKG expected $NV got $CV"; FAIL=1; fi; done <<< "$UPG"',
                'if [[ $FAIL -eq 0 ]]; then echo "[verify] Debian delta verification PASSED"; else echo "[verify] Debian delta verification FAILED"; fi',
                    'exit $FAIL'
                ) -join "`n"
                $verifyPath = Join-Path $debianDeltaDir 'verify-debian-delta.sh'
                $verifyScript | Out-File -FilePath $verifyPath -Encoding ASCII -Force
                
                # Attempt offline .deb acquisition using a second VHDX scan pass (best effort)
                try {
                    if ($offlineSpecs.Count -gt 0) {
                        $debDownloadDir = Join-Path $debianDeltaDir 'packages'
                        if (-not (Test-Path -LiteralPath $debDownloadDir)) { New-Item -ItemType Directory -Path $debDownloadDir | Out-Null }
                        Write-Log ("Attempting offline .deb acquisition for {0} packages" -f $offlineSpecs.Count) -Console
                        $kubemasterNewRel = $debianPackageDiff.NewRelativePath
                        $kubemasterNewAbs = Join-Path $newExtract $kubemasterNewRel
                        if (Test-Path -LiteralPath $kubemasterNewAbs) {
                            $dlResult = Get-DebianPackagesFromVHDX -VhdxPath $kubemasterNewAbs -NewExtract $newExtract -OldExtract $oldExtract -switchNameEnding 'delta' -DownloadPackageSpecs $offlineSpecs -DownloadLocalDir $debDownloadDir -DownloadDebs -AllowPartialAcquisition
                            if ($dlResult.Error) {
                                Write-Log ("[Warning] Offline package acquisition error: {0}" -f $dlResult.Error) -Console
                                 throw "Offline deb acquisition failed: $($dlResult.Error)"    # mandatory failure
                            }
                            elseif ($dlResult.DownloadedDebs.Count -gt 0) {
                                $debMeta = [pscustomobject]@{
                                    Downloaded = $dlResult.DownloadedDebs
                                    DownloadedCount = $dlResult.DownloadedDebs.Count
                                    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
                                }
                                $debMeta | ConvertTo-Json -Depth 3 | Out-File -FilePath (Join-Path $debDownloadDir 'download-manifest.json') -Encoding UTF8 -Force
                                Write-Log ("Offline .deb acquisition completed: {0} files" -f $dlResult.DownloadedDebs.Count) -Console
                                # FailureDetails removed; no failed-packages.json emitted
                                $offlineDebInfo = [pscustomobject]@{
                                    Specs = $offlineSpecs
                                    Downloaded = $dlResult.DownloadedDebs | ForEach-Object { Join-Path 'debian-delta/packages' $_ }
                                }
                            } else {
                                Write-Log '[Warning] No .deb files downloaded (empty list)' -Console
                                throw 'Offline deb acquisition produced zero files (mandatory)'
                            }
                        } else {
                            Write-Log ("[Warning] Expected VHDX for offline acquisition not found: {0}" -f $kubemasterNewAbs) -Console
                            throw 'Offline deb acquisition VHDX missing (mandatory)'
                        }
                    }
                } catch {
                    Write-Log ("[Warning] Offline acquisition attempt failed: {0}" -f $_.Exception.Message) -Console
                    throw
                }
                Write-Log "Created Debian delta artifact at '$debianDeltaDir'" -Console
            }
            catch {
                Write-Log "[Error] Failed to generate Debian delta artifact: $($_.Exception.Message)"
                if ($EncodeStructuredOutput -eq $true) {
                    $err = New-Error -Severity Warning -Code '[Error] Failed to generate Debian delta artifact' -Message $_.Exception.Message
                    Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                    return
                }
                else {
                    throw $_
                }        
            }
    } else {
        $err = "Debian package diff not processed: $($debianPackageDiff.Error)"
        # Attempt a quick verification that no temp Hyper-V artifacts remain (best effort)
        try {
            if (Get-Module -ListAvailable -Name Hyper-V) {
                $leftVMs = Get-VM -Name 'k2s-kubemaster-*' -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Off' -or $_ }
                $leftSwitches = Get-VMSwitch -Name 'k2s-switch-*' -ErrorAction SilentlyContinue
                if ($leftVMs) { Write-Log ("[Warning] Residual VM objects after diff failure: {0}" -f ($leftVMs.Name -join ', ')) -Console }
                if ($leftSwitches) { Write-Log ("[Warning] Residual VMSwitch objects after diff failure: {0}" -f ($leftSwitches.Name -join ', ')) -Console }
            }
        } catch { Write-Log "[Warning] Cleanup verification failed: $($_.Exception.Message)" -Console }        
        Write-Log $err -Error
        $script:SuppressFinalErrorLog = $true
        throw $err
    }
}

# Build manifest
$manifest = [pscustomobject]@{
    ManifestVersion       = '2.0'
    GeneratedUtc          = [DateTime]::UtcNow.ToString('o')
    BasePackage           = (Split-Path -Leaf $InputPackageOne)
    TargetPackage         = (Split-Path -Leaf $InputPackageTwo)
    WholeDirectories      = $wholeDirsNormalized
    WholeDirectoriesCount = $wholeDirsNormalized.Count
    SpecialSkippedFiles   = $SpecialSkippedFiles
    SpecialSkippedFilesCount = $SpecialSkippedFiles.Count
    Added                 = $added
    Changed               = $changed
    Removed               = $removed
    AddedCount            = $added.Count
    ChangedCount          = $changed.Count
    RemovedCount          = $removed.Count
    HashAlgorithm         = 'SHA256'
    DebianPackageDiff     = $debianPackageDiff
    DebianDeltaRelativePath = $(if (Test-Path -LiteralPath (Join-Path $stageDir 'debian-delta')) { 'debian-delta' } else { $null })
    DebianOfflinePackages = $(if ($offlineDebInfo) { $offlineDebInfo.Specs } else { @() })
    DebianOfflinePackagesCount = $(if ($offlineDebInfo) { $offlineDebInfo.Specs.Count } else { 0 })
    DebianOfflineDownloaded = $(if ($offlineDebInfo) { $offlineDebInfo.Downloaded } else { @() })
    DebianOfflineDownloadedCount = $(if ($offlineDebInfo) { $offlineDebInfo.Downloaded.Count } else { 0 })
    ContainerImageDiff    = $(if ($imageDiffResult) { 
        [pscustomobject]@{
            AddedImages = $imageDiffResult.Added | ForEach-Object { 
                [pscustomobject]@{
                    FullName = $_.FullName
                    Platform = $_.Platform
                }
            }
            RemovedImages = $imageDiffResult.Removed | ForEach-Object { 
                [pscustomobject]@{
                    FullName = $_.FullName
                    Platform = $_.Platform
                }
            }
            ChangedImages = $imageDiffResult.Changed | ForEach-Object { 
                [pscustomobject]@{
                    FullName = $_.FullName
                    Platform = $_.Platform
                }
            }
            AddedCount = $imageDiffResult.Added.Count
            RemovedCount = $imageDiffResult.Removed.Count
            ChangedCount = $imageDiffResult.Changed.Count
        }
    } else { $null })
}
$manifestPath = Join-Path $stageDir 'delta-manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

    # --- Code Signing (optional) -------------------------------------------------
    if ($CertificatePath -and $Password) {
        Write-Log "Attempting code signing using certificate '$CertificatePath'" -Console
        try {
            if (-not (Test-Path -LiteralPath $CertificatePath)) { throw "Certificate file not found." }
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath, $Password, 'Exportable,MachineKeySet')
            if (-not $cert.HasPrivateKey) { throw "Certificate does not contain a private key." }
            $signExtensions = @('*.exe','*.dll','*.ps1','*.psm1','*.psd1')
            $filesToSign = foreach ($pat in $signExtensions) { Get-ChildItem -Path $stageDir -Recurse -Include $pat -File }
            foreach ($f in $filesToSign) {
                try {
                    $sig = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -TimestampServer "http://timestamp.digicert.com" -ErrorAction Stop
                    if ($sig.Status -ne 'Valid') {
                        Write-Log "[Warning] Signing issue for $($f.FullName): Status=$($sig.Status)"
                    } else {
                        Write-Log "Signed: $($f.FullName)" 
                    }
                }
                catch {
                    Write-Log "[Warning] Failed to sign '$($f.FullName)': $($_.Exception.Message)"
                }
            }
        }
        catch {
            Write-Log "[Warning] Code signing setup failed: $($_.Exception.Message)"
        }
    }
    elseif ($CertificatePath -or $Password) {
        Write-Log "[Warning] Both -CertificatePath and -Password must be specified for signing; skipping signing."
    }

    # --- Create delta zip after (optional) signing ------------------------------
    $zipPhase = Start-Phase "Zipping"
    try {
        New-ZipWithProgress -SourceDir $stageDir -ZipPath $zipPackagePath -Show:$ShowLogs
        Write-Log "Delta package created: $zipPackagePath" -Console
    }
    catch {
        Write-Log "Failed to create delta zip: $($_.Exception.Message)" -Error
        throw
    }
    Stop-Phase "Zipping" $zipPhase
}
catch {
    $overallError = $_
}
finally {
    # Cleanup temp extraction directories
    if (Test-Path $tempRoot) {
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
            Write-Log "Cleaned up temp directory '$tempRoot'" 
        }
        catch {
            Write-Log "[Warning] Failed to cleanup temp directory '$tempRoot': $($_.Exception.Message)"
        }
    }
}

if ($overallError) {
    if (-not $script:SuppressFinalErrorLog) {
        Write-Log "Delta creation encountered an error: $($overallError.Exception.Message)" -Error
    }
    exit 5
}

if ($EncodeStructuredOutput -eq $true) {
    # Send CmdResult structure expected by Go CLI (lowercase 'error' field)
    Send-ToCli -MessageType $MessageType -Message @{ 
        error = $null
    }
} else {
    Write-Log "DONE" -Console
}