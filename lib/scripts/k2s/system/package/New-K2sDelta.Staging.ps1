# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Staging and temporary directory helpers

<#
.SYNOPSIS
    Creates temporary directories for delta package creation.

.DESCRIPTION
    Creates a unique temp root with subdirectories for old package extraction,
    new package extraction, and staging area.

.OUTPUTS
    PSCustomObject with properties:
    - TempRoot: Base temp directory path
    - OldExtract: Path for extracting old package
    - NewExtract: Path for extracting new package
    - StageDir: Path for staging delta files
#>
function New-DeltaTempDirectories {
    param()

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("k2s-delta-" + [guid]::NewGuid())
    $oldExtract = Join-Path $tempRoot 'old'
    $newExtract = Join-Path $tempRoot 'new'
    $stageDir = Join-Path $tempRoot 'stage'

    New-Item -ItemType Directory -Force -Path $oldExtract | Out-Null
    New-Item -ItemType Directory -Force -Path $newExtract | Out-Null
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

    return [pscustomobject]@{
        TempRoot   = $tempRoot
        OldExtract = $oldExtract
        NewExtract = $newExtract
        StageDir   = $stageDir
    }
}

<#
.SYNOPSIS
    Removes temporary directories created during delta package creation.

.DESCRIPTION
    Safely removes the temp directory tree, logging any failures.

.PARAMETER TempRoot
    Root temporary directory to remove.
#>
function Remove-DeltaTempDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string] $TempRoot
    )

    if (Test-Path $TempRoot) {
        try {
            Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction Stop
            Write-Log "Cleaned up temp directory '$TempRoot'"
        }
        catch {
            Write-Log "[Warning] Failed to cleanup temp directory '$TempRoot': $($_.Exception.Message)"
        }
    }
}

<#
.SYNOPSIS
    Expands and normalizes wholesale directory list.

.DESCRIPTION
    Takes an array of directory specifications (which may contain comma-separated values)
    and returns a normalized array with forward slashes, no leading/trailing separators.

.PARAMETER WholeDirectories
    Array of directory paths or comma-separated directory lists.

.OUTPUTS
    Array of normalized directory paths.
#>
function Expand-WholeDirList {
    param(
        [Parameter(Mandatory = $false)]
        [string[]] $WholeDirectories = @()
    )

    # Expand potential comma-separated lists
    $expandedWholeDirs = @()
    foreach ($entry in $WholeDirectories) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $segments = $entry -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($segments.Count -gt 0) { $expandedWholeDirs += $segments }
    }

    # Normalize paths (relative, forward slashes, trimmed)
    $normalized = @()
    foreach ($d in $expandedWholeDirs) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        $n = $d -replace '\\', '/'           # backslashes -> forward slashes
        $n = $n -replace '^[\\/]+', ''       # strip leading separators
        $n = $n.TrimEnd('/')                 # remove trailing slash
        if (-not [string]::IsNullOrWhiteSpace($n)) { $normalized += $n }
    }

    if ($normalized.Count -gt 0) {
        $normalized = $normalized | Sort-Object -Unique
    }

    return $normalized
}

<#
.SYNOPSIS
    Copies wholesale directories from source to staging area.

.DESCRIPTION
    Copies entire directories verbatim from the new package extraction to the
    staging directory without performing file-level diff.

.PARAMETER Context
    Hashtable containing: NewExtract, StageDir, WholeDirsNormalized
#>
function Copy-WholesaleDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    foreach ($wd in $Context.WholeDirsNormalized) {
        $srcDir = Join-Path $Context.NewExtract $wd
        if (-not (Test-Path -LiteralPath $srcDir)) {
            Write-Log "[Warning] Wholesale directory '$wd' not found in new package"
            continue
        }
        $dstDir = Join-Path $Context.StageDir $wd
        if (-not (Test-Path -LiteralPath $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        # Copy directory CONTENTS (not the directory itself) to avoid nested structure
        # e.g., copy bin/kube/* to staging/bin/kube/, not bin/kube to staging/bin/kube/kube/
        Copy-Item -Path "$srcDir\*" -Destination $dstDir -Recurse -Force
        Write-Log "[Staging] Copied wholesale directory: $wd"
    }
}

<#
.SYNOPSIS
    Copies changed and added files to the staging directory with progress.

.DESCRIPTION
    Takes a list of relative file paths and copies them from the new package
    extraction to the staging directory, showing progress if enabled.

.PARAMETER Context
    Hashtable containing: NewExtract, StageDir, DeltaFileList, ShowLogs
#>
function Copy-DeltaFilesToStaging {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    $deltaTotal = $Context.DeltaFileList.Count
    Write-Log "Staging $deltaTotal changed/added files" -Console

    $lastPct = -1
    for ($i = 0; $i -lt $deltaTotal; $i++) {
        $rel = $Context.DeltaFileList[$i]
        $source = Join-Path $Context.NewExtract $rel
        $dest = Join-Path $Context.StageDir $rel
        $destDir = Split-Path $dest -Parent

        if (-not (Test-Path $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $dest -Force

        if ($Context.ShowLogs -and $deltaTotal -gt 0) {
            $pct = [int](($i + 1) * 100 / $deltaTotal)
            if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) {
                Write-Progress -Activity 'Staging delta files' -Status "$(($i + 1)) / $deltaTotal" -PercentComplete $pct
                $lastPct = $pct
            }
        }
    }

    if ($Context.ShowLogs) {
        Write-Progress -Activity 'Staging delta files' -Completed
    }
}

<#
.SYNOPSIS
    Writes staging summary log message.

.DESCRIPTION
    Logs the count of staged files and breakdown by category.

.PARAMETER Context
    Hashtable containing: StageDir, WholeDirsNormalized, Added, Changed
#>
function Write-StagingSummary {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    $stagedFileCount = (Get-ChildItem -Path $Context.StageDir -Recurse -File | Measure-Object).Count
    Write-Log ("Staging summary: total staged files={0} (wholesale dirs={1}, added={2}, changed={3})" -f `
            $stagedFileCount, $Context.WholeDirsNormalized.Count, $Context.Added.Count, $Context.Changed.Count) -Console
}

<#
.SYNOPSIS
    Extracts Windows binaries from WindowsNodeArtifacts.zip to staging directory.

.DESCRIPTION
    The K2s offline package contains WindowsNodeArtifacts.zip which holds Windows Kubernetes
    binaries. During installation, these are extracted to bin/kube/, bin/docker/, etc.
    
    For delta packages, we need to extract these binaries and stage them so that the delta
    update can replace the Windows node binaries. Without this, Windows nodes would keep
    old Kubernetes versions after a delta upgrade.
    
    Mapping from WindowsNodeArtifacts.zip folders to installed paths:
    - kubetools/ -> bin/kube/ (kubelet.exe, kubectl.exe, kubeadm.exe, kube-proxy.exe)
    - docker/    -> bin/docker/ (docker.exe, dockerd.exe)

.PARAMETER Context
    Hashtable containing:
    - NewExtract: Path to extracted new package
    - StageDir: Path to staging directory

.OUTPUTS
    PSCustomObject with:
    - Success: Boolean indicating if extraction succeeded
    - ExtractedDirs: Array of directory names that were extracted
    - ErrorMessage: Error message if failed
#>
function Copy-WindowsNodeArtifactsToStaging {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    $result = [pscustomobject]@{
        Success       = $false
        ExtractedDirs = @()
        ErrorMessage  = ''
    }

    # Mapping from ZIP folder names to target bin/ folder names
    $folderMappings = @{
        'kubetools' = 'bin/kube'      # kubelet, kubectl, kubeadm, kube-proxy
        'docker'    = 'bin/docker'    # docker, dockerd
    }

    $winArtifactsZip = Join-Path $Context.NewExtract 'bin\WindowsNodeArtifacts.zip'
    
    if (-not (Test-Path $winArtifactsZip)) {
        $result.ErrorMessage = "WindowsNodeArtifacts.zip not found at: $winArtifactsZip"
        Write-Log "[WinArtifacts] $($result.ErrorMessage)" -Console
        # Not a fatal error - package may not have Windows artifacts
        $result.Success = $true
        return $result
    }

    Write-Log "[WinArtifacts] Extracting Windows binaries from WindowsNodeArtifacts.zip..." -Console

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($winArtifactsZip)

        try {
            foreach ($sourceFolder in $folderMappings.Keys) {
                $targetFolder = $folderMappings[$sourceFolder]
                $targetPath = Join-Path $Context.StageDir $targetFolder

                # Find all entries in this source folder
                $entries = $zip.Entries | Where-Object { 
                    $_.FullName -match "^$sourceFolder[/\\]" -and $_.FullName -ne "$sourceFolder/" 
                }

                if ($entries.Count -eq 0) {
                    Write-Log "[WinArtifacts] Folder '$sourceFolder' not found in WindowsNodeArtifacts.zip" -Console
                    continue
                }

                # Create target directory
                if (-not (Test-Path $targetPath)) {
                    New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                }

                $extractedCount = 0
                foreach ($entry in $entries) {
                    # Get relative path within source folder and build target path
                    $relativePath = $entry.FullName -replace "^$sourceFolder[/\\]", ''
                    
                    # Skip if it's just a directory entry
                    if ([string]::IsNullOrEmpty($relativePath) -or $entry.FullName.EndsWith('/')) {
                        continue
                    }

                    $destFile = Join-Path $targetPath $relativePath
                    $destDir = Split-Path $destFile -Parent

                    if (-not (Test-Path $destDir)) {
                        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                    }

                    # Extract file
                    $stream = $entry.Open()
                    try {
                        $fileStream = [System.IO.File]::Create($destFile)
                        try {
                            $stream.CopyTo($fileStream)
                            $extractedCount++
                        } finally {
                            $fileStream.Dispose()
                        }
                    } finally {
                        $stream.Dispose()
                    }
                }

                if ($extractedCount -gt 0) {
                    Write-Log "[WinArtifacts] Extracted $extractedCount files from '$sourceFolder' to '$targetFolder'" -Console
                    $result.ExtractedDirs += $targetFolder
                }
            }

            $result.Success = $true
            Write-Log "[WinArtifacts] Windows binaries extraction complete" -Console

        } finally {
            $zip.Dispose()
        }
    }
    catch {
        $result.ErrorMessage = "Failed to extract WindowsNodeArtifacts.zip: $($_.Exception.Message)"
        Write-Log "[WinArtifacts][Error] $($result.ErrorMessage)" -Console
    }

    return $result
}
