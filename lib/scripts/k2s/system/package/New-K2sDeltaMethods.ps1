# Shared helper methods for New-K2sDeltaPackage.ps1
# Extracted to reduce script size and keep orchestration separate.

Add-type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Expand-ZipWithProgress {
    param(
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [Parameter(Mandatory=$true)][string]$Destination,
        [string]$Label = 'zip',
        [switch]$Show
    )
    Write-Log "[Expand] Starting extraction of '$ZipPath' to '$Destination' (Label=$Label)" -Console
    if (-not (Test-Path -LiteralPath $ZipPath)) { throw "Zip not found: $ZipPath" }
    if (-not (Test-Path -LiteralPath $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $entries = @()
    [IO.Compression.ZipFile]::OpenRead($ZipPath).Entries | ForEach-Object { $entries += $_ }
    $total = $entries.Count
    Write-Log "[Expand] Zip has $total extractable entries" -Console
    $lastPct = -1
    $idx = 0
    foreach ($e in $entries) {
        $idx++
        if ([string]::IsNullOrEmpty($e.Name)) { continue }
        $targetPath = Join-Path $Destination $e.FullName
        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
        $eStream = $e.Open(); $outStream = [IO.File]::Create($targetPath)
        try {
            $buffer = New-Object byte[] 131072
            while (($read = $eStream.Read($buffer,0,$buffer.Length)) -gt 0) { $outStream.Write($buffer,0,$read) }
        } finally { $eStream.Dispose(); $outStream.Dispose() }
        if ($Show -and $total -gt 0) {
            $pct = [int]($idx*100/$total)
            if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) {
                Write-Progress -Activity "Extracting $Label" -Status "$idx / $total" -PercentComplete $pct
                $lastPct = $pct
            }
        }
    }
    if ($Show) { Write-Progress -Activity "Extracting $Label" -Completed }
    $sw.Stop(); Write-Log ("Expanded {0} entries from {1} in {2:N2}s" -f $total, (Split-Path -Leaf $ZipPath), $sw.Elapsed.TotalSeconds) -Console
}

function New-ZipWithProgress {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$ZipPath,
        [switch]$Show
    )
    Write-Log "[Zip] Creating archive '$ZipPath' from source '$SourceDir'" -Console
    if (-not (Test-Path -LiteralPath $SourceDir)) { throw "Source dir not found: $SourceDir" }
    $files = Get-ChildItem -Path $SourceDir -Recurse -File
    $total = $files.Count
    Write-Log "[Zip] Found $total files to add" -Console
    $fileStream = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $zipArchive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        $lastPct = -1
        for ($i = 0; $i -lt $total; $i++) {
            $f = $files[$i]
            $rel = $f.FullName.Substring($SourceDir.Length)
            $rel = $rel -replace '^[\\/]+' , ''
            $rel = $rel -replace '\\','/'
            $entry = $zipArchive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $inStream = [System.IO.File]::OpenRead($f.FullName)
                try {
                    $buffer = New-Object byte[] 131072
                    while (($read = $inStream.Read($buffer,0,$buffer.Length)) -gt 0) { $entryStream.Write($buffer,0,$read) }
                } finally { $inStream.Dispose() }
            } finally { $entryStream.Dispose() }
            if ($Show -and $total -gt 0) {
                $pct = [int](($i+1)*100/$total)
                if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) {
                    Write-Progress -Activity 'Zipping delta' -Status "$($i+1) / $total" -PercentComplete $pct
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
            Write-Log '[Warning] Zip creation failed (file not present after process)' -Console
        }
    }
}

function Stop-Phase($name, $sw) { if ($sw) { $sw.Stop(); Write-Log ("[Phase] {0} - done in {1:N2}s" -f $name, ($sw.Elapsed.TotalSeconds)) -Console } }
function Start-Phase { param([string]$Name) Write-Log "[Phase] $Name - start" -Console; return [System.Diagnostics.Stopwatch]::StartNew() }
function Format-Size { param([uint64]$Bytes) if ($Bytes -lt 1KB) { return "$Bytes B" }; $kb = [double]$Bytes / 1KB; if ($kb -lt 1024) { return ("{0:N2} KB" -f $kb) }; $mb = $kb / 1024; if ($mb -lt 1024) { return ("{0:N2} MB" -f $mb) }; $gb = $mb / 1024; if ($gb -lt 1024) { return ("{0:N2} GB" -f $gb) }; $tb = $gb / 1024; return ("{0:N2} TB" -f $tb) }

function Get-FileMap {
    param($root, [string]$label, [switch]$ShowLogs)
    $map = @{}
    $files = Get-ChildItem -Path $root -Recurse -File
    $total = $files.Count
    Write-Log "[Hash] Starting hashing of $total files in '$label' (root='$root')" -Console
    if ($total -eq 0) { return $map }
    $lastPct = -1
    for ($i = 0; $i -lt $total; $i++) {
        $f = $files[$i]
        $rel = $f.FullName.Substring($root.Length) -replace '^[\\/]+' , '' -replace '\\','/'
        try { $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLowerInvariant() } catch { Write-Log "[Warning] Hash failed for '$($f.FullName)': $($_.Exception.Message)"; $hash = '' }
        $map[$rel] = [pscustomobject]@{ Hash = $hash; Size = $f.Length }
        if ($ShowLogs) {
            $pct = [int](($i+1) * 100 / $total)
            if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) { Write-Progress -Activity "Hashing $label" -Status "$($i+1) / $total files" -PercentComplete $pct; $lastPct = $pct }
        }
    }
    if ($ShowLogs) { Write-Progress -Activity "Hashing $label" -Completed }
    Write-Log "[Hash] Completed hashing of $total files in '$label'" -Console
    return $map
}

function Test-SpecialSkippedFile { param($path,$list) $leaf = [IO.Path]::GetFileName($path); foreach($f in $list){ if ($leaf -ieq $f) { return $true } } return $false }
function Test-InWholeDir { param($path, $dirs) foreach($d in $dirs){ if($path.StartsWith($d + '/')){ return $true } } return $false }

function Get-DebianPackageMapFromStatusFile {
    param([string]$StatusFilePath)
    $map = @{}
    if (-not (Test-Path -LiteralPath $StatusFilePath)) { return $map }
    $currentName = $null; $currentVersion = $null
    Get-Content -LiteralPath $StatusFilePath | ForEach-Object {
        $line = $_
        if ([string]::IsNullOrWhiteSpace($line)) { if ($currentName) { $map[$currentName] = $currentVersion }; $currentName = $null; $currentVersion = $null; return }
        if ($line -like 'Package:*') { $currentName = ($line.Substring(8)).Trim() }
        elseif ($line -like 'Version:*') { $currentVersion = ($line.Substring(8)).Trim() }
    }
    if ($currentName) { $map[$currentName] = $currentVersion }
    return $map
}

function Get-DebianPackagesFromVHDX {
    param([string]$VhdxPath, [string]$NewExtract, [string]$OldExtract, [string]$switchNameEnding='')
    $result = [pscustomobject]@{ Packages = $null; Error = $null; Method = 'hyperv-ssh' }
    if (-not (Test-Path -LiteralPath $VhdxPath)) { $result.Error = "VHDX not found: $VhdxPath"; return $result }
    Write-Log "[DebPkg] Starting extraction from VHDX '$VhdxPath' with new extract '$NewExtract' and old extract '$OldExtract'" -Console
    $switchName = "k2s-switch-$switchNameEnding"
    $hostSwitchIp = '172.19.1.1'
    $guestExpectedIp = '172.19.1.100'
    $prefixLen = 24
    $sshUser = 'remote'
    $sshPwd  = 'admin'
    $sshKey  = ''
    if (-not $sshUser) { $result.Error = 'K2S_DEBIAN_SSH_USER not set'; return $result }
    if (-not $sshPwd -and -not $sshKey) { $result.Error = 'Set K2S_DEBIAN_SSH_PASSWORD or K2S_DEBIAN_SSH_KEY'; return $result }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) { $result.Error = 'Hyper-V module unavailable'; return $result }
    $existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($existingSwitch) { try { Remove-VMSwitch -Name $switchName -Force -ErrorAction Stop } catch { $result.Error = "Failed to remove existing switch: $($_.Exception.Message)"; return $result } }
    try {
        Write-Log "[DebPkg] Creating internal switch '$switchName' with host IP $hostSwitchIp/$prefixLen" -Console
        New-VMSwitch -Name $switchName -SwitchType Internal -ErrorAction Stop | Out-Null
        $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$switchName*" }
        if (-not $adapter) { throw 'Internal vSwitch adapter not found after creation' }
        New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $hostSwitchIp -PrefixLength $prefixLen -ErrorAction Stop | Out-Null
    }
    catch { $result.Error = "Failed to create/configure switch: $($_.Exception.Message)"; return $result }
    $vmName = "k2s-kubemaster-" + $switchNameEnding 
    $createdVm = $false
    try {
        Write-Log "[DebPkg] Creating temporary VM '$vmName' attached to '$switchName'" -Console
        New-VM -Name $vmName -MemoryStartupBytes (2GB) -VHDPath $VhdxPath -Generation 2 -SwitchName $switchName -ErrorAction Stop | Out-Null
        $createdVm = $true
        Write-Log "[DebPkg] Starting VM '$vmName'" -Console
        Start-VM -Name $vmName -ErrorAction Stop | Out-Null
        $deadline = (Get-Date).AddMinutes(3)
        $ipFound = $false
        Write-Log "[DebPkg] Waiting for guest IP $guestExpectedIp (timeout 3m)" -Console
        while ((Get-Date) -lt $deadline -and -not $ipFound) { Start-Sleep -Seconds 5; if (Test-Connection -ComputerName $guestExpectedIp -Count 1 -Quiet -ErrorAction SilentlyContinue) { $ipFound = $true } }
        if (-not $ipFound) { throw "Guest IP $guestExpectedIp not reachable within timeout" }
        Write-Log "[DebPkg] Guest reachable at $guestExpectedIp" -Console
        $plinkCandidates = @(
            (Join-Path $NewExtract 'bin\\plink.exe'),
            (Join-Path $OldExtract 'bin\\plink.exe'),
            'plink.exe'
        )
        $plink = $plinkCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $plink) { throw 'plink.exe not found' }
        Write-Log "[DebPkg] Using plink executable: $plink" -Console
        $sshCmd = "dpkg-query -W -f='${Package}=${Version}\n'".Replace('`','``')
        $plinkArgs = @('-batch','-noagent','-ssh',"$sshUser@$guestExpectedIp",'-P','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
        if ($sshKey) { $plinkArgs += @('-i', $sshKey) } elseif ($sshPwd) { $plinkArgs += @('-pw', $sshPwd) }
        $plinkArgs += $sshCmd
        Write-Log "[DebPkg] Executing dpkg-query via SSH" -Console
        $pkgOutput = & $plink @plinkArgs 2>$null
        if (-not $pkgOutput) { throw 'Empty dpkg-query output' }
        $pkgMap = @{}
        foreach ($line in $pkgOutput) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^(?<n>[^=]+)=(?<v>.+)$') { $pkgMap[$matches['n']] = $matches['v'] }
        }
        if ($pkgMap.Count -eq 0) { throw 'Parsed 0 packages' }
        Write-Log "[DebPkg] Parsed $($pkgMap.Count) packages from VHDX" -Console
        $result.Packages = $pkgMap
    }
    catch { $result.Error = "Hyper-V SSH extraction failed: $($_.Exception.Message)" }
    finally {
        Write-Log "[DebPkg] Beginning cleanup (VM, switch, IP)" -Console
        try { if ($createdVm) { Stop-VM -Name $vmName -Force -TurnOff -ErrorAction SilentlyContinue | Out-Null } } catch {}
        try { if ($createdVm) { Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue | Out-Null } } catch {}
        try { Remove-VMSwitch -Name $switchName -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { $existing = Get-NetIPAddress -IPAddress $hostSwitchIp -ErrorAction SilentlyContinue; if ($existing) { $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue } } catch {}
        Write-Log "[DebPkg] Cleanup complete" -Console
    }
    return $result
}

function Get-SkippedFileDebianPackageDiff {
    param(
        [string]$OldRoot,
        [string]$NewRoot,
        [string]$FileName
    )
    Write-Log "[DebPkgDiff] Starting diff for skipped file '$FileName'" -Console
    $diffResult = [pscustomobject]@{ Processed=$false; Error=$null; File=$FileName; OldRelativePath=$null; NewRelativePath=$null; Added=@(); Removed=@(); Changed=@(); AddedCount=0; RemovedCount=0; ChangedCount=0 }
    $oldMatch = Get-ChildItem -Path $OldRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    $newMatch = Get-ChildItem -Path $NewRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $oldMatch -or -not $newMatch) { $diffResult.Error = 'File missing in one of the packages (search failed)'; return $diffResult }
    $diffResult.OldRelativePath = ($oldMatch.FullName.Substring($OldRoot.Length)) -replace '^[\\/]+' , ''
    $diffResult.NewRelativePath = ($newMatch.FullName.Substring($NewRoot.Length)) -replace '^[\\/]+' , ''
    $oldPkgs = Get-DebianPackagesFromVHDX -VhdxPath $oldMatch.FullName -NewExtract $NewRoot -OldExtract $OldRoot -switchNameEnding 'old'
    $newPkgs = Get-DebianPackagesFromVHDX -VhdxPath $newMatch.FullName -NewExtract $NewRoot -OldExtract $OldRoot -switchNameEnding 'new'
    if ($oldPkgs.Error -or $newPkgs.Error) { $diffResult.Error = "OldError=[$($oldPkgs.Error)] NewError=[$($newPkgs.Error)]"; return $diffResult }
    $oldMap = $oldPkgs.Packages; $newMap = $newPkgs.Packages
    $added=@(); $removed=@(); $changed=@()
    foreach ($k in $newMap.Keys) { if (-not $oldMap.ContainsKey($k)) { $added += "$k=$($newMap[$k])" } elseif ($oldMap[$k] -ne $newMap[$k]) { $changed += ("{0}: {1} -> {2}" -f $k,$oldMap[$k],$newMap[$k]) } }
    foreach ($k in $oldMap.Keys) { if (-not $newMap.ContainsKey($k)) { $removed += "$k=$($oldMap[$k])" } }
    $diffResult.Processed=$true; $diffResult.Added=$added; $diffResult.Removed=$removed; $diffResult.Changed=$changed; $diffResult.AddedCount=$added.Count; $diffResult.RemovedCount=$removed.Count; $diffResult.ChangedCount=$changed.Count; return $diffResult
}

function Remove-SpecialSkippedFilesFromStage {
    param(
        [Parameter(Mandatory=$true)][string]$StagePath,
        [Parameter(Mandatory=$true)][string[]]$Skipped
    )

    Write-Log "[StageCleanup] Starting removal of special skipped files from '$StagePath' (Patterns: $([string]::Join(', ', $Skipped)))" -Console
    $totalRemoved = 0
    foreach ($sf in $Skipped) {
        $foundFiles = Get-ChildItem -Path $StagePath -Recurse -File -Filter $sf -ErrorAction SilentlyContinue
        if ($foundFiles) { Write-Log "[StageCleanup] Found $($foundFiles.Count) candidate(s) for pattern '$sf'" -Console }
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
