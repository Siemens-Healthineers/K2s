# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

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
    [parameter(Mandatory = $false, HelpMessage = 'Password for the certificate file')]
    [string] $Password,
    [parameter(Mandatory = $false, HelpMessage = 'Directories to include wholesale from newer package (no diffing). Relative paths; can be specified multiple times.')]
    [string[]] $WholeDirectories = @()
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$signingModule = "$PSScriptRoot/../../../../modules/k2s/k2s.signing.module/k2s.signing.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $signingModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "- Proxy to be used: $Proxy"
Write-Log "- Target Directory: $TargetDirectory"
Write-Log "- Package file name: $ZipPackageFileName"

Add-type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Helper for timing
function Start-Phase($name) {
    Write-Log "[Phase] $name - start" -Console
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    return $sw
}
function Stop-Phase($name, $sw) {
    if ($sw) { $sw.Stop(); Write-Log ("[Phase] {0} - done in {1:N2}s" -f $name, ($sw.Elapsed.TotalSeconds)) -Console }
}

# Human readable size formatting
function Format-Size {
    param([uint64]$Bytes)
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    $kb = [double]$Bytes / 1KB
    if ($kb -lt 1024) { return ("{0:N2} KB" -f $kb) }
    $mb = $kb / 1024
    if ($mb -lt 1024) { return ("{0:N2} MB" -f $mb) }
    $gb = $mb / 1024
    if ($gb -lt 1024) { return ("{0:N2} GB" -f $gb) }
    $tb = $gb / 1024
    return ("{0:N2} TB" -f $tb)
}

# Custom zip extraction with progress (avoids single long silent ExtractToDirectory)
function Expand-ZipWithProgress {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$true)][string]$Label,
        [switch]$Show
    )
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "Zip not found: $ZipPath" }
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log "Extracting $Label ($ZipPath) -> $Destination" -Console
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entries = $zip.Entries
        $fileEntries = @()
        foreach ($e in $entries) { if (-not [string]::IsNullOrEmpty($e.Name)) { $fileEntries += $e } else { # directory
                $dirPath = Join-Path $Destination ($e.FullName -replace '^[\\/]+','')
                if (-not (Test-Path -LiteralPath $dirPath)) { New-Item -ItemType Directory -Path $dirPath -Force | Out-Null }
            }
        }
        $total = $fileEntries.Count
        Write-Log "  $total files to extract for $Label" -Console
        $lastPct = -1
        for ($i=0; $i -lt $total; $i++) {
            $entry = $fileEntries[$i]
            $relative = $entry.FullName -replace '^[\\/]+',''
            $target = Join-Path $Destination $relative
            $targetDir = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
            $inStream = $entry.Open()
            try {
                $outStream = [System.IO.File]::Open($target, [System.IO.FileMode]::Create)
                try {
                    $buffer = New-Object byte[] 81920
                    while (($read = $inStream.Read($buffer,0,$buffer.Length)) -gt 0) { $outStream.Write($buffer,0,$read) }
                }
                finally { $outStream.Dispose() }
            }
            finally { $inStream.Dispose() }
            if ($Show) {
                $pct = [int](($i+1)*100/$total)
                if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) {
                    Write-Progress -Activity "Extracting $Label" -Status "$(($i+1)) / $total" -PercentComplete $pct
                    $lastPct = $pct
                }
            }
        }
        if ($Show) { Write-Progress -Activity "Extracting $Label" -Completed }
    }
    finally {
        $zip.Dispose()
        $sw.Stop()
        Write-Log ("Extraction of {0} completed in {1:N2}s" -f $Label, $sw.Elapsed.TotalSeconds) -Console
    }
}

# Create zip with progress (mirrors staging output granularity)
function New-ZipWithProgress {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [switch]$Show
    )
    if (-not (Test-Path -LiteralPath $SourceDir)) { throw "Source directory not found: $SourceDir" }
    $files = Get-ChildItem -Path $SourceDir -Recurse -File
    $total = $files.Count
    Write-Log "Preparing zip ($total files) -> $ZipPath" -Console
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $fileStream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create)
    try {
        $zipArchive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        $lastPct = -1
        for ($i = 0; $i -lt $total; $i++) {
            $f = $files[$i]
            $rel = $f.FullName.Substring($SourceDir.Length)
            $rel = $rel -replace '^[\\/]+' , ''
            $rel = $rel -replace '\\','/'  # Normalize entry path
            $entry = $zipArchive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $inStream = [System.IO.File]::OpenRead($f.FullName)
                try {
                    $buffer = New-Object byte[] 131072  # 128 KiB buffer for faster large file copy
                    while (($read = $inStream.Read($buffer,0,$buffer.Length)) -gt 0) { $entryStream.Write($buffer,0,$read) }
                }
                finally { $inStream.Dispose() }
            }
            finally { $entryStream.Dispose() }
            if ($Show -and $total -gt 0) {
                $pct = [int](($i+1)*100/$total)
                if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) {
                    Write-Progress -Activity 'Zipping delta' -Status "$(($i+1)) / $total" -PercentComplete $pct
                    $lastPct = $pct
                }
            }
        }
        if ($Show) { Write-Progress -Activity 'Zipping delta' -Completed }
    }
    finally {
        if ($zipArchive) { $zipArchive.Dispose() }
        $fileStream.Dispose()
        $sw.Stop()
        if (Test-Path -LiteralPath $ZipPath) {
            $sz = (Get-Item -LiteralPath $ZipPath).Length
            $hr = Format-Size $sz
            Write-Log ("Zip completed in {0:N2}s (size={1} / {2:N0} bytes)" -f $sw.Elapsed.TotalSeconds, $hr, $sz) -Console
        } else {
            Write-Log "[Warning] Zip creation failed (file not present after process)" -Console
        }
    }
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

    Write-Log $errMsg -Error
    exit 1
}

$zipPackagePath = Join-Path "$TargetDirectory" "$ZipPackageFileName"

if (Test-Path $zipPackagePath) {
    Write-Log "Removing already existing file '$zipPackagePath'" -Console
    Remove-Item $zipPackagePath -Force
}

Write-Log "Zip package available at '$zipPackagePath'." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}

# --- Delta Package Construction -------------------------------------------------

if ([string]::IsNullOrWhiteSpace($InputPackageOne) -or -not (Test-Path -LiteralPath $InputPackageOne)) {
    Write-Log "InputPackageOne missing or not found: '$InputPackageOne'" -Error
    exit 2
}
if ([string]::IsNullOrWhiteSpace($InputPackageTwo) -or -not (Test-Path -LiteralPath $InputPackageTwo)) {
    Write-Log "InputPackageTwo missing or not found: '$InputPackageTwo'" -Error
    exit 3
}

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

function Get-FileMap {
    param($root, [string]$label)
    $map = @{}
    $files = Get-ChildItem -Path $root -Recurse -File
    $total = $files.Count
    Write-Log "Hashing $total files in $label" -Console
    if ($total -eq 0) { return $map }
    $lastPct = -1
    for ($i = 0; $i -lt $total; $i++) {
        $f = $files[$i]
        $rel = $f.FullName.Substring($root.Length)
        $rel = $rel -replace '^[\\/]+' , ''
        $rel = $rel -replace '\\','/'
        try {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLowerInvariant()
        }
        catch {
            Write-Log "[Warning] Hash failed for '$($f.FullName)': $($_.Exception.Message)"; $hash = ''
        }
        $map[$rel] = [pscustomobject]@{ Hash = $hash; Size = $f.Length }
        if ($ShowLogs) {
            $pct = [int](($i+1) * 100 / $total)
            if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) {
                Write-Progress -Activity "Hashing $label" -Status "$(($i+1)) / $total files" -PercentComplete $pct
                $lastPct = $pct
            }
        }
    }
    if ($ShowLogs) { Write-Progress -Activity "Hashing $label" -Completed }
    return $map
}

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
$SpecialSkippedFiles = @('Kubemaster-Base.vhdx', 'trivy.exe', 'virtctl.exe', 'virt-viewer-x64-11.0-1.0.msi', 'k2s-bom.json', 'k2s-bom.xml')
Write-Log "Special skipped files: $($SpecialSkippedFiles -join ', ')" -Console
function Test-SpecialSkippedFile { param($path,$list) $leaf = [IO.Path]::GetFileName($path); foreach($f in $list){ if ($leaf -ieq $f) { return $true } } return $false }

function Test-InWholeDir { param($path, $dirs) foreach($d in $dirs){ if($path.StartsWith($d + '/')){ return $true } } return $false }

# ---- Special Handling: Analyze Debian packages inside Kubemaster-Base.vhdx (best effort) ---------
# This avoids fully booting a VM by attempting offline extraction of /var/lib/dpkg/status using 7zip.
# If 7z.exe is not available or the dpkg status file cannot be located, the analysis is skipped gracefully.

function Get-DebianPackageMapFromStatusFile {
    param([string]$StatusFilePath)
    $map = @{}
    if (-not (Test-Path -LiteralPath $StatusFilePath)) { return $map }
    $currentName = $null; $currentVersion = $null
    Get-Content -LiteralPath $StatusFilePath | ForEach-Object {
        $line = $_
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($currentName) { $map[$currentName] = $currentVersion }
            $currentName = $null; $currentVersion = $null
            return
        }
        if ($line -like 'Package:*') { $currentName = ($line.Substring(8)).Trim() }
        elseif ($line -like 'Version:*') { $currentVersion = ($line.Substring(8)).Trim() }
    }
    if ($currentName) { $map[$currentName] = $currentVersion }
    return $map
}

function Get-DebianPackagesFromVHDX {
    param([string]$VhdxPath)
    $result = [pscustomobject]@{ Packages = $null; Error = $null; Method = $null }
    if (-not (Test-Path -LiteralPath $VhdxPath)) { $result.Error = "VHDX not found: $VhdxPath"; return $result }

    # Strategy 1: Use 7zip (fast, no mounting/VM)
    $sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($sevenZip) {
        try {
            $listOutput = & $sevenZip.Path l -ba -- "$VhdxPath" 2>$null
            if (-not $listOutput) { throw 'No listing output from 7z' }
            $statusLine = $listOutput | Where-Object { $_ -match 'var/lib/dpkg/status$' } | Select-Object -First 1
            if (-not $statusLine) { throw 'dpkg status file not found inside VHDX (7z listing)' }
            $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("k2s-dpkg-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                $candidates = @('var/lib/dpkg/status','0/var/lib/dpkg/status','1/var/lib/dpkg/status')
                $extracted = $false
                foreach ($c in $candidates) {
                    if ($extracted) { break }
                    & $sevenZip.Path e -y -- "$VhdxPath" "$c" -o"$tempDir" > $null 2>&1
                    if (Test-Path (Join-Path $tempDir 'status')) { $extracted = $true }
                }
                if (-not $extracted) { throw 'Failed to extract dpkg status (candidates not found with 7z)' }
                $statusFile = Join-Path $tempDir 'status'
                $pkgMap = Get-DebianPackageMapFromStatusFile -StatusFilePath $statusFile
                $result.Packages = $pkgMap
                $result.Method = '7zip'
                return $result
            }
            finally {
                try { if (Test-Path $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
            }
        }
        catch {
            Write-Log "[Warning] 7zip extraction path failed for '$VhdxPath': $($_.Exception.Message). Will attempt mount fallback." -Console
        }
    } else {
        Write-Log '[Info] 7z.exe not found; attempting mount fallback for Debian package extraction.' -Console
    }

    # Strategy 2: Mount the VHDX (works only if Windows can read filesystem; ext4 usually not readable -> may fail)
    try {
        $volsBefore = Get-Volume | ForEach-Object { $_.DriveLetter } | Where-Object { $_ }
        $mount = Mount-DiskImage -ImagePath $VhdxPath -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        $volsAfter = Get-Volume | ForEach-Object { $_.DriveLetter } | Where-Object { $_ }
        $newLetters = @($volsAfter | Where-Object { $volsBefore -notcontains $_ })
        if (-not $newLetters -or $newLetters.Count -eq 0) { throw 'No new accessible volumes after mounting (likely unsupported filesystem such as ext4)' }
        $statusFound = $false; $pkgMap = @{}
        foreach ($ltr in $newLetters) {
            # Build candidate path to dpkg status file on the mounted volume
            $candidate = ("{0}:\var\lib\dpkg\status" -f $ltr)
            if (Test-Path -LiteralPath $candidate) {
                $pkgMap = Get-DebianPackageMapFromStatusFile -StatusFilePath $candidate
                $statusFound = $true; break
            }
        }
        if (-not $statusFound) { throw 'dpkg status file not found on mounted volumes' }
        $result.Packages = $pkgMap
        $result.Method = 'mount'
    }
    catch {
        if (-not $result.Packages) { $result.Error = "Mount fallback failed: $($_.Exception.Message)" }
    }
    finally {
        try { Dismount-DiskImage -ImagePath $VhdxPath -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    # Strategy 3: WSL mount (for ext4) if still not successful
    if (-not $result.Packages) {
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if ($wsl) {
            Write-Log "[Info] Attempting WSL fallback to read dpkg status from '$VhdxPath'" -Console
            $tempStatusHost = Join-Path ([IO.Path]::GetTempPath()) ("k2s-dpkg-wsl-" + [guid]::NewGuid() + '.status')
            try {
                # Mount all partitions automatically (omit --bare for auto-mount)
                & $wsl.Path --mount "$VhdxPath" 2>$null
                Start-Sleep -Seconds 2
                # Find candidate status file inside /mnt/wsl/* paths (WSL auto-mount root) then export to host path
                $script = @'
set -e
FOUND=""
for f in /mnt/wsl/*/var/lib/dpkg/status; do
  if [ -f "$f" ]; then
    FOUND="$f"; break
  fi
done
if [ -n "$FOUND" ]; then
  cat "$FOUND"
fi
'@
                $content = & $wsl.Path -e sh -c $script
                if ($content -and $content.Length -gt 0) {
                    $content | Out-File -FilePath $tempStatusHost -Encoding UTF8 -Force
                    $pkgMap = Get-DebianPackageMapFromStatusFile -StatusFilePath $tempStatusHost
                    if ($pkgMap.Count -gt 0) {
                        $result.Packages = $pkgMap
                        $result.Method = 'wsl'
                        $result.Error = $null
                    } else {
                        Write-Log '[Warning] WSL fallback found status file but no packages parsed' -Console
                    }
                } else {
                    Write-Log '[Warning] WSL fallback did not locate a dpkg status file' -Console
                }
            }
            catch {
                Write-Log "[Warning] WSL fallback failed: $($_.Exception.Message)" -Console
            }
            finally {
                try { & $wsl.Path --unmount "$VhdxPath" 2>$null } catch {}
                try { if (Test-Path -LiteralPath $tempStatusHost) { Remove-Item -LiteralPath $tempStatusHost -Force -ErrorAction SilentlyContinue } } catch {}
            }
        }
    }
    return $result
}

function Get-SkippedFileDebianPackageDiff {
    param(
        [string]$OldRoot,
        [string]$NewRoot,
        [string]$FileName
    )
    $diffResult = [pscustomobject]@{
        Processed      = $false
        Error          = $null
        File           = $FileName
        OldRelativePath= $null
        NewRelativePath= $null
        Added          = @()
        Removed        = @()
        Changed        = @()
        AddedCount     = 0
        RemovedCount   = 0
        ChangedCount   = 0
    }
    $oldMatch = Get-ChildItem -Path $OldRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    $newMatch = Get-ChildItem -Path $NewRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $oldMatch -or -not $newMatch) { $diffResult.Error = 'File missing in one of the packages (search failed)'; return $diffResult }
    $diffResult.OldRelativePath = ($oldMatch.FullName.Substring($OldRoot.Length)) -replace '^[\\/]+' , ''
    $diffResult.NewRelativePath = ($newMatch.FullName.Substring($NewRoot.Length)) -replace '^[\\/]+' , ''
    $oldPkgs = Get-DebianPackagesFromVHDX -VhdxPath $oldMatch.FullName
    $newPkgs = Get-DebianPackagesFromVHDX -VhdxPath $newMatch.FullName
    if ($oldPkgs.Error -or $newPkgs.Error) { $diffResult.Error = "OldError=[$($oldPkgs.Error)] NewError=[$($newPkgs.Error)]"; return $diffResult }
    $oldMap = $oldPkgs.Packages; $newMap = $newPkgs.Packages
    $added = @(); $removed = @(); $changed = @()
    foreach ($k in $newMap.Keys) {
        if (-not $oldMap.ContainsKey($k)) { $added += "$k=$($newMap[$k])" }
        elseif ($oldMap[$k] -ne $newMap[$k]) { $changed += ("{0}: {1} -> {2}" -f $k,$oldMap[$k],$newMap[$k]) }
    }
    foreach ($k in $oldMap.Keys) { if (-not $newMap.ContainsKey($k)) { $removed += "$k=$($oldMap[$k])" } }
    $diffResult.Processed = $true
    $diffResult.Added = $added
    $diffResult.Removed = $removed
    $diffResult.Changed = $changed
    $diffResult.AddedCount = $added.Count
    $diffResult.RemovedCount = $removed.Count
    $diffResult.ChangedCount = $changed.Count
    return $diffResult
}

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
function Remove-SpecialSkippedFilesFromStage {
    param([string]$StagePath,[string[]]$Skipped)
    foreach ($sf in $Skipped) {
        $matches = Get-ChildItem -Path $StagePath -Recurse -File -Filter $sf -ErrorAction SilentlyContinue
        foreach ($m in $matches) {
            try { Remove-Item -LiteralPath $m.FullName -Force -ErrorAction Stop; Write-Log "Removed special skipped file from stage: $($m.FullName)" -Console }
            catch { Write-Log "[Warning] Failed to remove special skipped file '$($m.FullName)': $($_.Exception.Message)" -Console }
        }
    }
}

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

# Staging summary
$stagedFileCount = (Get-ChildItem -Path $stageDir -Recurse -File | Measure-Object).Count
Write-Log "Staging summary: total staged files=$stagedFileCount (wholesale dirs=$($wholeDirsNormalized.Count), added=$($added.Count), changed=$($changed.Count))" -Console

# Special diff for Debian packages inside Kubemaster-Base.vhdx (if present and analyzable)
$debianPackageDiff = $null
if ($SpecialSkippedFiles -contains 'Kubemaster-Base.vhdx') {
    Write-Log 'Analyzing Debian packages in Kubemaster-Base.vhdx ...' -Console
    $debianPackageDiff = Get-SkippedFileDebianPackageDiff -OldRoot $oldExtract -NewRoot $newExtract -FileName 'Kubemaster-Base.vhdx'
    if ($debianPackageDiff.Processed) {
        Write-Log ("Debian package diff: Added={0} Changed={1} Removed={2}" -f $debianPackageDiff.AddedCount, $debianPackageDiff.ChangedCount, $debianPackageDiff.RemovedCount) -Console
    } else {
        Write-Log "[Warning] Debian package diff not processed: $($debianPackageDiff.Error)" -Console
    }
}

# Build manifest
$manifest = [pscustomobject]@{
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
    Write-Log "Delta creation encountered an error: $($overallError.Exception.Message)" -Error
    exit 5
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ 
        Error = $null;
    Delta = @{ WholeDirectories = $wholeDirsNormalized; SpecialSkippedFiles = $SpecialSkippedFiles; Added = $added; Changed = $changed; Removed = $removed; Manifest = 'delta-manifest.json'; DebianPackageDiff = $debianPackageDiff }
    }
}

Write-Log "DONE" -Console