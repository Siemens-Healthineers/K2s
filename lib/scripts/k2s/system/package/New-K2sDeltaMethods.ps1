# Shared helper methods for New-K2sDeltaPackage.ps1
# Extracted to reduce script size and keep orchestration separate.

Add-Type -AssemblyName System.IO.Compression
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

function Stop-Phase {
    param(
        [string] $Name,
        $Stopwatch
    )
    if ($Stopwatch) {
        $Stopwatch.Stop()
        Write-Log ("[Phase] {0} - done in {1:N2}s" -f $Name, $Stopwatch.Elapsed.TotalSeconds) -Console
    }
}

function Start-Phase {
    param(
        [Parameter(Mandatory)] [string] $Name
    )
    Write-Log "[Phase] $Name - start" -Console
    return [System.Diagnostics.Stopwatch]::StartNew()
}

function Format-Size {
    param(
        [uint64] $Bytes
    )
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

function Test-SpecialSkippedFile {
    param(
        [string] $Path,
        [string[]] $List
    )
    $leaf = [IO.Path]::GetFileName($Path)
    foreach ($f in $List) {
        if ($leaf -ieq $f) { return $true }
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

function Get-DebianPackageMapFromStatusFile {
    param(
        [string] $StatusFilePath
    )
    $map = @{}
    if (-not (Test-Path -LiteralPath $StatusFilePath)) { return $map }
    $currentName = $null
    $currentVersion = $null
    Get-Content -LiteralPath $StatusFilePath | ForEach-Object {
        $line = $_
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($currentName) { $map[$currentName] = $currentVersion }
            $currentName = $null
            $currentVersion = $null
            return
        }
        if ($line -like 'Package:*') {
            $currentName = ($line.Substring(8)).Trim()
        }
        elseif ($line -like 'Version:*') {
            $currentVersion = ($line.Substring(8)).Trim()
        }
    }
    if ($currentName) { $map[$currentName] = $currentVersion }
    return $map
}

function Get-DebianPackagesFromVHDX {
    param(
        [string] $VhdxPath,
        [string] $NewExtract,
        [string] $OldExtract,
        [string] $switchNameEnding = '',
        [string[]] $DownloadPackageSpecs,
        [string] $DownloadLocalDir,
        [switch] $DownloadDebs
    )
    $result = [pscustomobject]@{ Packages = $null; Error = $null; Method = 'hyperv-ssh'; DownloadedDebs = @() }
    if (-not (Test-Path -LiteralPath $VhdxPath)) { $result.Error = "VHDX not found: $VhdxPath"; return $result }
    Write-Log "[DebPkg] Starting extraction from VHDX '$VhdxPath' with new extract '$NewExtract' and old extract '$OldExtract'" -Console
    Write-Log "[DebPkg] Switch name: $switchName, Download directory: $DownloadLocalDir, DownloadDebs: $DownloadDebs" -Console
    # Use distinct naming to avoid collisions and make purpose clear
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
        New-VM -Name $vmName -MemoryStartupBytes (2GB) -VHDPath $VhdxPath -SwitchName $switchName -ErrorAction Stop | Out-Null
        $createdVm = $true
        Write-Log "[DebPkg] Starting VM '$vmName'" -Console
        Start-VM -Name $vmName -ErrorAction Stop | Out-Null
        $deadline = (Get-Date).AddMinutes(3)
        $ipFound = $false
        Write-Log "[DebPkg] Waiting for guest IP $guestExpectedIp (timeout 3m)" -Console
        while ((Get-Date) -lt $deadline -and -not $ipFound) { Start-Sleep -Seconds 5; if (Test-Connection -ComputerName $guestExpectedIp -Count 1 -Quiet -ErrorAction SilentlyContinue) { $ipFound = $true } }
        if (-not $ipFound) { throw "Guest IP $guestExpectedIp not reachable within timeout" }
        Write-Log "[DebPkg] Guest reachable at $guestExpectedIp" -Console
        # Prefer native OpenSSH client if available, fallback to plink. Adjust arguments accordingly.
        $sshCandidates = @(
            (Join-Path $NewExtract 'bin\\ssh.exe'),
            (Join-Path $OldExtract 'bin\\ssh.exe'),
            'ssh.exe',
            (Join-Path $NewExtract 'bin\\plink.exe'),
            (Join-Path $OldExtract 'bin\\plink.exe'),
            'plink.exe'
        )
    $sshClient = $sshCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $sshClient) { throw 'No ssh/plink client found (looked for ssh.exe or plink.exe)' }
    $usingPlink = ($sshClient.ToLower().EndsWith('plink.exe'))
    $mode = if ($usingPlink) { 'plink' } else { 'openssh' }
    Write-Log ("[DebPkg] Using SSH client: {0} (mode={1})" -f $sshClient, $mode) -Console

        $plinkHostKey = $null
        if ($usingPlink) {
            try {
                Write-Log '[DebPkg] Performing plink host key probe' -Console
                $probeArgs = @('-noagent','-batch','-P','22',"$sshUser@$guestExpectedIp",'exit')
                $probeOutput = & $sshClient @probeArgs 2>&1
                $joinedProbe = ($probeOutput | Select-Object -First 8) -join ' | '
                if ($probeOutput -match 'host key is not cached' -or $probeOutput -match 'POTENTIAL SECURITY BREACH') {
                    # Attempt to extract an ssh-ed25519 SHA256 fingerprint line
                    $fingerLine = $probeOutput | Where-Object { $_ -match 'ssh-ed25519 255 SHA256:' } | Select-Object -First 1
                    if (-not $fingerLine) { $fingerLine = $probeOutput | Where-Object { $_ -match 'ssh-rsa 2048 SHA256:' } | Select-Object -First 1 }
                    if ($fingerLine -and ($fingerLine -match '(ssh-(ed25519|rsa)\s+\d+\s+SHA256:[A-Za-z0-9+/=]+)')) {
                        $plinkHostKey = $matches[1]
                        Write-Log "[DebPkg] Extracted host key fingerprint: $plinkHostKey" -Console
                    } else {
                        Write-Log "[DebPkg][Warning] Could not parse host key fingerprint from probe output: $joinedProbe" -Console
                    }
                } else {
                    Write-Log '[DebPkg] Host key already trusted (no prompt in probe).' -Console
                }
            } catch {
                Write-Log "[DebPkg][Warning] Host key probe failed: $($_.Exception.Message)" -Console
            }
        }
        # Self-test: verify dpkg-query responds (captures version) with stderr capture
        try {
            Write-Log '[DebPkg] Running dpkg-query self-test' -Console
            $testCmd = 'dpkg-query -V || echo __DPKG_QUERY_FAILED__=$?'
            if ($usingPlink) {
                $testArgs = @('-batch','-noagent','-P','22')
                if ($plinkHostKey) { $testArgs += @('-hostkey', $plinkHostKey) }
                if ($sshKey) { $testArgs += @('-i', $sshKey) } elseif ($sshPwd) { $testArgs += @('-pw', $sshPwd) }
                $testArgs += ("$sshUser@$guestExpectedIp")
            } else {
                $testArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null',"$sshUser@$guestExpectedIp")
                if ($sshKey) { $testArgs += @('-i', $sshKey) }
            }
            $testArgs += $testCmd
            $testOutput = & $sshClient @testArgs 2>&1
            if ($testOutput -and ($testOutput | Where-Object { $_ -match 'dpkg-query' })) {
                $firstLine = $testOutput | Select-Object -First 1
                Write-Log "[DebPkg] dpkg self-test OK: $firstLine" -Console
            } else {
                $joined = ($testOutput | Select-Object -First 5) -join ' | '
                Write-Log "[DebPkg] dpkg self-test inconclusive. Output: $joined" -Console
                if ($usingPlink -and ($testOutput -match 'POTENTIAL SECURITY BREACH')) {
                    $result.Error = 'Host key mismatch detected (plink security warning). Provide correct fingerprint in K2S_DEBIAN_SSH_HOSTKEY or clear cached host key.'
                    return $result
                }
            }
        }
        catch {
            Write-Log "[Warning] dpkg self-test failed: $($_.Exception.Message)" -Console
        }

        # Build dpkg-query command (no sudo; not required for listing)
        $formatLiteral = '${Package}=${Version}\n'
        $baseQuery = "dpkg-query -W -f='$formatLiteral'"
        if ($usingPlink) {
            $baseArgs = @('-batch','-noagent','-P','22')
            if ($plinkHostKey) { $baseArgs += @('-hostkey', $plinkHostKey) }
            if ($sshKey) { $baseArgs += @('-i', $sshKey) } elseif ($sshPwd) { $baseArgs += @('-pw', $sshPwd) }
            $baseArgs += ("$sshUser@$guestExpectedIp")
        } else {
            $baseArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
            if ($sshKey) { $baseArgs += @('-i', $sshKey) }
            $baseArgs += ("$sshUser@$guestExpectedIp")
        }

    # Retry attempts reduced from 8 to 2 for quicker failure feedback
    $maxAttempts = 2
        $attempt = 0
        $pkgOutput = $null
        while ($attempt -lt $maxAttempts -and (-not $pkgOutput)) {
            $attempt++
            $remaining = $maxAttempts - $attempt
            $cmd = $baseQuery
            $fullArgs = $baseArgs + $cmd
            Write-Log ("[DebPkg] Attempt {0}: running package inventory (remaining retries: {1})" -f $attempt, $remaining) -Console
            $raw = & $sshClient @fullArgs 2>&1
            if ($raw) {
                # Filter out any sudo/locale noise lines if present
                $candidate = $raw | Where-Object { $_ -match '.+=.+' }
                if ($candidate.Count -gt 5) { $pkgOutput = $candidate } else { $pkgOutput = $candidate }
            }
            if (-not $pkgOutput) { Start-Sleep -Seconds 5 }
        }
        if (-not $pkgOutput) { throw "Empty dpkg-query output after $maxAttempts attempt(s)" }
        $pkgMap = @{}
        foreach ($line in $pkgOutput) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^(?<n>[^=]+)=(?<v>.+)$') { $pkgMap[$matches['n']] = $matches['v'] }
        }
        if ($pkgMap.Count -eq 0) { throw 'Parsed 0 packages' }
        Write-Log "[DebPkg] Parsed $($pkgMap.Count) packages from VHDX" -Console
        $result.Packages = $pkgMap

        # Optional offline .deb acquisition
        if ($DownloadDebs -and $DownloadPackageSpecs -and $DownloadPackageSpecs.Count -gt 0) {
            Write-Log ("[DebPkg] Starting offline .deb acquisition for {0} package specs" -f $DownloadPackageSpecs.Count) -Console
            if (-not $DownloadLocalDir) { throw 'DownloadLocalDir not specified for offline acquisition' }
            if (-not (Test-Path -LiteralPath $DownloadLocalDir)) { New-Item -ItemType Directory -Path $DownloadLocalDir -Force | Out-Null }
            $remoteDebDir = '/tmp/k2s-delta-debs'
            $downloadScript = @(
                "set -euo pipefail",
                "rm -rf $remoteDebDir; mkdir -p $remoteDebDir",
                "cd $remoteDebDir",
                "apt-get update >/dev/null 2>&1 || true"
            )
            foreach ($spec in $DownloadPackageSpecs) {
                if ([string]::IsNullOrWhiteSpace($spec)) { continue }
                $name = $spec; $ver = ''
                if ($spec -match '^(?<n>[^=]+)=(?<v>.+)$') { $name = $matches['n']; $ver = $matches['v'] }
                if ($ver) {
                    $downloadScript += "echo '[dl] $name=$ver'";
                    $downloadScript += "apt-get download $name=$ver >/dev/null 2>&1 || echo 'WARN: failed $name=$ver'";
                } else {
                    $downloadScript += "echo '[dl] $name (no version specified)'";
                    $downloadScript += "apt-get download $name >/dev/null 2>&1 || echo 'WARN: failed $name'";
                }
            }
            $downloadScript += 'echo __K2S_DEB_LIST_BEGIN__'
            $downloadScript += 'ls -1 *.deb 2>/dev/null || true'
            $downloadScript += 'echo __K2S_DEB_LIST_END__'
            $remoteCmd = ("bash -c '" + ($downloadScript -join '; ') + "'")
            $dlArgs = @()
            if ($usingPlink) {
                $dlArgs = @('-batch','-noagent','-P','22')
                if ($plinkHostKey) { $dlArgs += @('-hostkey', $plinkHostKey) }
                if ($sshKey) { $dlArgs += @('-i', $sshKey) } elseif ($sshPwd) { $dlArgs += @('-pw', $sshPwd) }
                $dlArgs += ("$sshUser@$guestExpectedIp")
                $dlArgs += $remoteCmd
                $dlOutput = & $sshClient @dlArgs 2>&1
            } else {
                $dlArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
                if ($sshKey) { $dlArgs += @('-i', $sshKey) }
                $dlArgs += ("$sshUser@$guestExpectedIp")
                $dlArgs += $remoteCmd
                $dlOutput = & $sshClient @dlArgs 2>&1
            }
            $debFiles = @()
            if ($dlOutput) {
                $debFiles = $dlOutput | Where-Object { $_ -like '*.deb' }
            }
            if ($debFiles.Count -gt 0) {
                Write-Log ("[DebPkg] Retrieved list of {0} .deb files; starting copy" -f $debFiles.Count) -Console
                # copy via pscp or scp
                $scpClient = $null
                $pscpCandidates = @(
                    (Join-Path $NewExtract 'bin\\pscp.exe'),
                    (Join-Path $OldExtract 'bin\\pscp.exe'),
                    'pscp.exe'
                )
                $scpClient = $pscpCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                $usePlinkCopy = $false
                if ($scpClient -and ($scpClient.ToLower().EndsWith('pscp.exe'))) { $usePlinkCopy = $true }
                if (-not $scpClient -and -not $usingPlink) { $scpClient = $sshClient } # use ssh scp mode if available
                foreach ($deb in $debFiles) {
                    try {
                        if ($usePlinkCopy) {
                            $copyArgs = @('-batch','-P','22')
                            if ($plinkHostKey) { $copyArgs += @('-hostkey', $plinkHostKey) }
                            if ($sshKey) { $copyArgs += @('-i', $sshKey) } elseif ($sshPwd) { $copyArgs += @('-pw', $sshPwd) }
                            $copyArgs += ("${sshUser}@${guestExpectedIp}:${remoteDebDir}/$deb")
                            $copyArgs += (Join-Path $DownloadLocalDir $deb)
                            $null = & $scpClient @copyArgs 2>&1
                        } else {
                            # assume scp compatible (OpenSSH)
                            $copyArgs = @('-P','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
                            if ($sshKey) { $copyArgs += @('-i', $sshKey) }
                            $copyArgs += ("${sshUser}@${guestExpectedIp}:${remoteDebDir}/$deb")
                            $copyArgs += $DownloadLocalDir
                            $null = & $scpClient @copyArgs 2>&1
                        }
                        if (Test-Path -LiteralPath (Join-Path $DownloadLocalDir $deb)) {
                            $result.DownloadedDebs += $deb
                        }
                    } catch {
                        Write-Log "[DebPkg][Warning] Failed to copy ${deb}: $($_.Exception.Message)" -Console
                    }
                }
                Write-Log ("[DebPkg] Offline .deb acquisition complete ({0} files)" -f $result.DownloadedDebs.Count) -Console
            } else {
                # Diagnostic: show raw output trimmed around markers
                if ($dlOutput) {
                    $startIdx = ($dlOutput | Select-String -SimpleMatch '__K2S_DEB_LIST_BEGIN__').LineNumber
                    $endIdx = ($dlOutput | Select-String -SimpleMatch '__K2S_DEB_LIST_END__').LineNumber
                    if ($startIdx -and $endIdx -and $endIdx -gt $startIdx) {
                        $between = $dlOutput[($startIdx)..($endIdx)]
                        Write-Log ("[DebPkg][Diag] Remote deb directory listing lines: {0}" -f ($between -join ' | ')) -Console
                    } else {
                        Write-Log ("[DebPkg][Diag] Raw download output head: {0}" -f (($dlOutput | Select-Object -First 20) -join ' || ')) -Console
                    }
                }
                Write-Log '[DebPkg][Warning] No .deb files listed by remote acquisition script' -Console
            }
        }
    }
    catch { $result.Error = "Hyper-V SSH extraction failed: $($_.Exception.Message)" }
    finally {
        Write-Log "[DebPkg] Beginning cleanup (VM, switch, IP)" -Console
        $cleanupErrors = @()
        try {
            if ($createdVm) {
                Stop-VM -Name $vmName -Force -TurnOff -ErrorAction SilentlyContinue | Out-Null
            }
        } catch { $cleanupErrors += "Stop-VM: $($_.Exception.Message)" }
        try {
            if ($createdVm) {
                Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue | Out-Null
            }
        } catch { $cleanupErrors += "Remove-VM: $($_.Exception.Message)" }
        try {
            Remove-VMSwitch -Name $switchName -Force -ErrorAction SilentlyContinue | Out-Null
        } catch { $cleanupErrors += "Remove-VMSwitch: $($_.Exception.Message)" }
        try {
            $existing = Get-NetIPAddress -IPAddress $hostSwitchIp -ErrorAction SilentlyContinue
            if ($existing) {
                $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            }
        } catch { $cleanupErrors += "Remove-NetIPAddress: $($_.Exception.Message)" }

        # Verification & second pass if needed
        $leftVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($leftVm) {
            Write-Log "[DebPkg][Cleanup] VM still present after first attempt; retrying remove." -Console
            try { Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-VM: $($_.Exception.Message)" }
            $leftVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if ($leftVm) { $cleanupErrors += 'VM remains after retry.' }
        }
        $leftSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
        if ($leftSwitch) {
            Write-Log "[DebPkg][Cleanup] Switch still present after first attempt; retrying remove." -Console
            try { Remove-VMSwitch -Name $switchName -Force -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-VMSwitch: $($_.Exception.Message)" }
            $leftSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
            if ($leftSwitch) { $cleanupErrors += 'Switch remains after retry.' }
        }
        $leftIp = Get-NetIPAddress -IPAddress $hostSwitchIp -ErrorAction SilentlyContinue
        if ($leftIp) {
            Write-Log "[DebPkg][Cleanup] Host IP still present; retry removal." -Console
            try { $leftIp | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue } catch { $cleanupErrors += "Retry Remove-NetIPAddress: $($_.Exception.Message)" }
            $leftIp = Get-NetIPAddress -IPAddress $hostSwitchIp -ErrorAction SilentlyContinue
            if ($leftIp) { $cleanupErrors += 'Host switch IP remains after retry.' }
        }

        if ($cleanupErrors.Count -gt 0) {
            Write-Log ("[DebPkg] Cleanup completed with warnings: {0}" -f ($cleanupErrors -join '; ')) -Console
        } else {
            Write-Log "[DebPkg] Cleanup complete" -Console
        }
    }
    return $result
}

function Get-SkippedFileDebianPackageDiff {
    param(
        [string] $OldRoot,
        [string] $NewRoot,
        [string] $FileName
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
    }
    $oldMatch = Get-ChildItem -Path $OldRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    $newMatch = Get-ChildItem -Path $NewRoot -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $oldMatch -or -not $newMatch) {
        $diffResult.Error = 'File missing in one of the packages (search failed)'
        return $diffResult
    }
    $diffResult.OldRelativePath = ($oldMatch.FullName.Substring($OldRoot.Length)) -replace '^[\\/]+' , ''
    $diffResult.NewRelativePath = ($newMatch.FullName.Substring($NewRoot.Length)) -replace '^[\\/]+' , ''
    $oldPkgs = Get-DebianPackagesFromVHDX -VhdxPath $oldMatch.FullName -NewExtract $NewRoot -OldExtract $OldRoot -switchNameEnding 'old'
    $newPkgs = Get-DebianPackagesFromVHDX -VhdxPath $newMatch.FullName -NewExtract $NewRoot -OldExtract $OldRoot -switchNameEnding 'new'
    if ($oldPkgs.Error -or $newPkgs.Error) {
        $diffResult.Error = "OldError=[$($oldPkgs.Error)] NewError=[$($newPkgs.Error)]"
        return $diffResult
    }
    $oldMap = $oldPkgs.Packages
    $newMap = $newPkgs.Packages
    $added   = @()
    $removed = @()
    $changed = @()
    foreach ($k in $newMap.Keys) {
        if (-not $oldMap.ContainsKey($k)) {
            $added += "$k=$($newMap[$k])"
        }
        elseif ($oldMap[$k] -ne $newMap[$k]) {
            $changed += ("{0}: {1} -> {2}" -f $k, $oldMap[$k], $newMap[$k])
        }
    }
    foreach ($k in $oldMap.Keys) {
        if (-not $newMap.ContainsKey($k)) {
            $removed += "$k=$($oldMap[$k])"
        }
    }
    $diffResult.Processed    = $true
    $diffResult.Added        = $added
    $diffResult.Removed      = $removed
    $diffResult.Changed      = $changed
    $diffResult.AddedCount   = $added.Count
    $diffResult.RemovedCount = $removed.Count
    $diffResult.ChangedCount = $changed.Count
    return $diffResult
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
