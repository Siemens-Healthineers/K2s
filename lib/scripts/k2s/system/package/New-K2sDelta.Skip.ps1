# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Skip list & staging cleanup helpers

function Test-SpecialSkippedFile {
    param(
        [string] $Path,
        [string[]] $List
    )
    $leaf = [IO.Path]::GetFileName($Path)
    
    # Check explicit skip list
    foreach ($f in $List) {
        if ($leaf -ieq $f) { return $true }
    }
    
    # Check for addon image tarballs (handled by image delta logic, not file diff)
    # Pattern: addons/<addon-name>/*.tar or addons/<addon-name>/*_win.tar
    if ($Path -match '^addons/[^/]+/[^/]+\.tar$' -or $Path -match '^addons/[^/]+/[^/]+_win\.tar$') {
        Write-Log "[SkipList] Excluding addon image tarball from file diff: $Path (handled by image delta)" -Console
        return $true
    }
    
    return $false
}

<#
.SYNOPSIS
    Tests if a file path matches any of the cluster config skip patterns.

.DESCRIPTION
    Checks if the given relative path matches any of the patterns in the cluster config
    skip list. These patterns protect cluster-specific files (certificates, kubeconfig,
    kubelet config) from being overwritten during delta updates.

.PARAMETER Path
    The relative file path to check (forward slashes, no leading slash).

.PARAMETER Patterns
    Array of path patterns to match against. Supports wildcards (*).

.OUTPUTS
    $true if the path matches a pattern and should be skipped, $false otherwise.
#>
function Test-ClusterConfigSkippedPath {
    param(
        [string] $Path,
        [string[]] $Patterns
    )
    
    if (-not $Patterns -or $Patterns.Count -eq 0) { return $false }
    
    # Normalize path to forward slashes
    $normalizedPath = $Path -replace '\\', '/'
    $normalizedPath = $normalizedPath -replace '^/', ''  # Remove leading slash if present
    
    foreach ($pattern in $Patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        
        # Normalize pattern
        $normalizedPattern = $pattern -replace '\\', '/'
        $normalizedPattern = $normalizedPattern -replace '^/', ''
        
        # Use -like for wildcard matching
        if ($normalizedPath -like $normalizedPattern) {
            Write-Log "[SkipList] Excluding cluster config file from diff: $Path (matches pattern: $pattern)" -Console
            return $true
        }
    }
    
    return $false
}

function Test-InWholeDir {
    param(
        [string] $Path,
        [string[]] $Dirs
    )
    foreach ($d in $Dirs) {
        if ($Path.StartsWith($d + '/')) { return $true }
    }
    return $false
}

function Remove-SpecialSkippedFilesFromStage {
    param(
        [Parameter(Mandatory = $true)] [string]  $StagePath,
        [Parameter(Mandatory = $true)] [string[]] $Skipped
    )
    Write-Log "[StageCleanup] Starting removal of special skipped files from '$StagePath' (Patterns: $([string]::Join(', ', $Skipped)))" -Console
    $totalRemoved = 0
    foreach ($sf in $Skipped) {
        $foundFiles = Get-ChildItem -Path $StagePath -Recurse -File -Filter $sf -ErrorAction SilentlyContinue
        if ($foundFiles) {
            Write-Log "[StageCleanup] Found $($foundFiles.Count) candidate(s) for pattern '$sf'" -Console
        }
        foreach ($m in $foundFiles) {
            try {
                Remove-Item -LiteralPath $m.FullName -Force -ErrorAction Stop
                Write-Log "Removed special skipped file from stage: $($m.FullName)" -Console
                $totalRemoved++
            }
            catch {
                Write-Log "[Warning] Failed to remove special skipped file '$($m.FullName)': $($_.Exception.Message)" -Console
            }
        }
    }
    Write-Log "[StageCleanup] Completed special skip removal. Total removed: $totalRemoved" -Console
}
