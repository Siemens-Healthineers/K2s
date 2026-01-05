# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Diff helpers for Debian packages inside skipped VHDX

function Get-SkippedFileDebianPackageDiff {
    param(
        [string] $OldRoot,
        [string] $NewRoot,
        [string] $FileName,
        [switch] $QueryImages,
        [switch] $KeepNewVmAlive
    )
    Write-Log "[DebPkgDiff] Starting diff for skipped file '$FileName'" -Console
    $diffResult = [pscustomobject]@{
        Processed        = $false
        Error            = $null
        File             = $FileName
        OldRelativePath  = $null
        NewRelativePath  = $null
        Added            = @()
        Removed          = @()
        Changed          = @()
        AddedCount       = 0
        RemovedCount     = 0
        ChangedCount     = 0
        OldLinuxImages   = @()
        NewLinuxImages   = @()
        NewVmContext     = $null
    }
    $oldMatch = Get-ChildItem -Path $OldRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    $newMatch = Get-ChildItem -Path $NewRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $oldMatch -or -not $newMatch) { $diffResult.Error = 'File missing in one of the packages (search failed)'; return $diffResult }
    $diffResult.OldRelativePath = ($oldMatch.FullName.Substring($OldRoot.Length)) -replace '^[\\/]+' , ''
    $diffResult.NewRelativePath = ($newMatch.FullName.Substring($NewRoot.Length)) -replace '^[\\/]+' , ''
    $oldPkgs = Get-DebianPackagesFromVHDX -VhdxPath $oldMatch.FullName -NewExtract $NewRoot -OldExtract $OldRoot -switchNameEnding 'old' -QueryBuildahImages:$QueryImages
    $newPkgs = Get-DebianPackagesFromVHDX -VhdxPath $newMatch.FullName -NewExtract $NewRoot -OldExtract $OldRoot -switchNameEnding 'new' -QueryBuildahImages:$QueryImages -KeepVmAlive:$KeepNewVmAlive
    if ($oldPkgs.Error -or $newPkgs.Error) { $diffResult.Error = "OldError=[$($oldPkgs.Error)] NewError=[$($newPkgs.Error)]"; return $diffResult }
    $oldMap = $oldPkgs.Packages
    $newMap = $newPkgs.Packages
    $added   = @(); $removed = @(); $changed = @()
    foreach ($k in $newMap.Keys) {
        if (-not $oldMap.ContainsKey($k)) { $added += "$k=$($newMap[$k])" }
        elseif ($oldMap[$k] -ne $newMap[$k]) { $changed += ("{0}: {1} -> {2}" -f $k, $oldMap[$k], $newMap[$k]) }
    }
    foreach ($k in $oldMap.Keys) { if (-not $newMap.ContainsKey($k)) { $removed += "$k=$($oldMap[$k])" } }
    $diffResult.Processed    = $true
    $diffResult.Added        = $added
    $diffResult.Removed      = $removed
    $diffResult.Changed      = $changed
    $diffResult.AddedCount   = $added.Count
    $diffResult.RemovedCount = $removed.Count
    $diffResult.ChangedCount = $changed.Count
    
    # Store Linux images if queried
    if ($QueryImages) {
        $diffResult.OldLinuxImages = $oldPkgs.BuildahImages
        $diffResult.NewLinuxImages = $newPkgs.BuildahImages
        Write-Log "[ImageDiff] Linux images discovered: Old=$($oldPkgs.BuildahImages.Count), New=$($newPkgs.BuildahImages.Count)" -Console
    }
    
    # Store new VM context if kept alive for reuse
    if ($KeepNewVmAlive -and $newPkgs.VmContext) {
        $diffResult.NewVmContext = $newPkgs.VmContext
        Write-Log "[DebPkgDiff] New VM kept alive for reuse: $($newPkgs.VmContext.VmName)" -Console
    }
    
    return $diffResult
}
