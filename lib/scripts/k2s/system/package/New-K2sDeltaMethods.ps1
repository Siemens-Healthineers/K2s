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

# Performs per-package download attempts inside the guest VM to simplify debugging.
# Returns object: @{ DebFiles = <string[]>; Failures = <string[]>; Logs = <string[]>; RemoteDir = <string>; UsedFallback = <bool>; Diagnostics = <string[]> }
function Invoke-GuestDebAcquisition {
    param(
        [Parameter(Mandatory)][string] $RemoteDir,
        [Parameter(Mandatory)][string[]] $PackageSpecs,
        [Parameter(Mandatory)][string] $SshClient,
        [Parameter(Mandatory)][bool] $UsingPlink,
        [string] $PlinkHostKey,
        [string] $SshUser,
        [string] $GuestIp,
        [string] $SshKey,
        [string] $SshPassword
    )
    $result = [pscustomobject]@{ DebFiles=@(); Failures=@(); Logs=@(); RemoteDir=$RemoteDir; UsedFallback=$false; Diagnostics=@() }
    if (-not $PackageSpecs -or $PackageSpecs.Count -eq 0) { return $result }

    # Helper to build base SSH argument list (without remote command)
    function _BaseArgs([string]$extra='') {
        if ($UsingPlink) {
            $args = @('-batch','-noagent','-P','22')
            if ($PlinkHostKey) { $args += @('-hostkey', $PlinkHostKey) }
            if ($SshKey) { $args += @('-i', $SshKey) } elseif ($SshPassword) { $args += @('-pw', $SshPassword) }
            $args += ("$SshUser@$GuestIp")
            return ,$args
        } else {
            $args = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
            if ($SshKey) { $args += @('-i', $SshKey) }
            $args += ("$SshUser@$GuestIp")
            return ,$args
        }
    }

    # Prepare remote directory & diagnostics once
    $initScript = @(
        'set -euo pipefail',
        "rm -rf $RemoteDir; mkdir -p $RemoteDir",
        "cd $RemoteDir",
        'echo __K2S_DIAG_BEGIN__',
        'ip addr show || true','ip route show || true',
        'grep -v "^#" /etc/apt/sources.list 2>/dev/null || true',
        'ls -1 /etc/apt/sources.list.d 2>/dev/null || true',
        'ping -c1 deb.debian.org >/dev/null 2>&1 && echo PING_OK || echo PING_FAIL || true',
        'echo --- RESOLV.CONF ---','cat /etc/resolv.conf 2>/dev/null || true',
        'echo --- CURL TEST deb.debian.org (HTTP root) ---','command -v curl >/dev/null 2>&1 && (curl -fsI --connect-timeout 5 http://deb.debian.org/ >/dev/null && echo CURL_DEB_OK || echo CURL_DEB_FAIL) || echo CURL_NOT_INSTALLED',
        'echo __K2S_DIAG_END__',
        'apt-get update 2>&1 || true'
    ) -join '; '
    $initCmd = "bash -c '" + $initScript + "'"
    $initArgs = (_BaseArgs) + $initCmd
    $initOut = & $SshClient @initArgs 2>&1
    if ($initOut) { $result.Diagnostics += ($initOut | Select-Object -First 40) }
    Write-Log ("[DebPkg][DL] Init output head: {0}" -f (($initOut | Select-Object -First 10) -join ' | ')) -Console

    $idx = 0; $total = $PackageSpecs.Count
    foreach ($spec in $PackageSpecs) {
        $idx++
        if ([string]::IsNullOrWhiteSpace($spec)) { continue }
        $pkgSpec = $spec.Trim()
        Write-Log ("[DebPkg][DL] ({0}/{1}) downloading {2}" -f $idx, $total, $pkgSpec) -Console
        $escaped = $pkgSpec.Replace("'", "'\\''")
        $cmdScript = @(
            'set -euo pipefail',
            "cd $RemoteDir",
            "echo '[dl] $escaped'",
            "if apt-get help 2>&1 | grep -qi download; then apt-get download '$escaped' 2>&1 || echo 'WARN: failed $escaped'; \
             elif command -v apt >/dev/null 2>&1; then apt download '$escaped' 2>&1 || echo 'WARN: failed $escaped'; \
             else echo 'WARN: no download command'; fi",
            'echo "[ls-after]"',
            'ls -1 *.deb 2>/dev/null || true'
        ) -join '; '
        $cmd = "bash -c '" + $cmdScript + "'"
        $args = (_BaseArgs) + $cmd
        $out = & $SshClient @args 2>&1
        $result.Logs += $out
        $fail = ($out | Where-Object { $_ -match 'WARN: failed' })
        if ($fail) {
            $result.Failures += $pkgSpec
        } else {
            # Collect new deb names after this attempt
            $listCmd = "bash -c 'cd $RemoteDir; ls -1 *.deb 2>/dev/null || true'"
            $listOut = & $SshClient @((_BaseArgs) + $listCmd) 2>&1
            if ($listOut) {
                $current = $listOut | Where-Object { $_ -like '*.deb' }
                $result.DebFiles = ($current | Sort-Object -Unique)
            }
        }
    }
    # Fallback: if no files at all, copy apt cache content
    if (-not $result.DebFiles -or $result.DebFiles.Count -eq 0) {
        Write-Log '[DebPkg][DL] No deb files after per-package attempts; invoking cache fallback' -Console
        $fallbackCmd = "bash -c 'cd $RemoteDir; cp -a /var/cache/apt/archives/*.deb . 2>/dev/null || true; ls -1 *.deb 2>/dev/null || true'"
        $fallbackOut = & $SshClient @((_BaseArgs) + $fallbackCmd) 2>&1
        $fbDebs = $fallbackOut | Where-Object { $_ -like '*.deb' }
        if ($fbDebs) { $result.DebFiles = ($fbDebs | Sort-Object -Unique); $result.UsedFallback = $true }
        $result.Diagnostics += ($fallbackOut | Select-Object -First 40)
    }
    return $result
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
    # Derive consistent resource names early
    $switchName = "k2s-switch-$switchNameEnding"
    $natName    = "k2s-nat-$switchNameEnding"
    Write-Log "[DebPkg] Switch name: $switchName, NAT name: $natName, Download directory: $DownloadLocalDir, DownloadDebs: $DownloadDebs" -Console
    $hostSwitchIp = '172.19.1.1'
    $networkPrefix = '172.19.1.0'
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
        # Ensure NAT exists (best effort)
        $natExisting = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
        if ($natExisting) {
            Write-Log "[DebPkg] Reusing existing NAT '$natName'" -Console
        } else {
            try {
                New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix "$networkPrefix/$prefixLen" -ErrorAction Stop | Out-Null
                Write-Log "[DebPkg] Created NAT '$natName' ($networkPrefix/$prefixLen)" -Console
            } catch { Write-Log "[DebPkg][Warning] Failed to create NAT '$natName': $($_.Exception.Message)" -Console }
        }
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
            # Use --version (supported) instead of -V (unsupported on some builds)
            $testCmd = 'dpkg-query --version 2>&1 || echo __DPKG_QUERY_FAILED__=$?'
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
            $hasVersion = $false
            $errorUnknown = $false
            foreach ($line in $testOutput) {
                if ($line -match '^dpkg-query ') { $hasVersion = $true }
                if ($line -match 'unknown option') { $errorUnknown = $true }
            }
            if ($hasVersion -and -not $errorUnknown) {
                $firstLine = ($testOutput | Where-Object { $_ -match '^dpkg-query ' } | Select-Object -First 1)
                Write-Log "[DebPkg] dpkg self-test OK: $firstLine" -Console
            } else {
                $joined = ($testOutput | Select-Object -First 8) -join ' | '
                Write-Log "[DebPkg] dpkg self-test FAILED/INCONCLUSIVE: $joined" -Console
            }
            if ($usingPlink -and ($testOutput -match 'POTENTIAL SECURITY BREACH')) {
                $result.Error = 'Host key mismatch detected (plink security warning). Provide correct fingerprint or clear cached host key.'
                return $result
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

        # Execute package listing and build map (this was missing causing empty diffs)
        try {
            Write-Log '[DebPkg] Querying installed packages via dpkg-query' -Console
            $pkgOutput = & $sshClient @($baseArgs + $baseQuery) 2>&1
            $pkgMap = @{}
            $lineCount = 0
            foreach ($ln in $pkgOutput) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                # Expect lines like name=version; ignore other diagnostic lines
                if ($ln -match '^[a-z0-9][a-z0-9+\-.]+?=') {
                    $eq = $ln.IndexOf('=')
                    if ($eq -gt 0) {
                        $name = $ln.Substring(0,$eq)
                        $ver  = $ln.Substring($eq+1)
                        if (-not [string]::IsNullOrWhiteSpace($name)) { $pkgMap[$name] = $ver }
                        $lineCount++
                    }
                }
            }
            $result.Packages = $pkgMap
            Write-Log ("[DebPkg] Retrieved {0} packages (head: {1})" -f $pkgMap.Count, ([string]::Join(', ', ($pkgMap.Keys | Select-Object -First 5)))) -Console
            if ($pkgMap.Count -eq 0) {
                $sample = ($pkgOutput | Select-Object -First 8) -join ' | '
                Write-Log ("[DebPkg][Warning] dpkg-query returned no packages; sample output: {0}" -f $sample) -Console
            }
        } catch {
            Write-Log ("[DebPkg][Error] Failed to query packages: {0}" -f $_.Exception.Message) -Console
        }

    # Optional offline .deb acquisition (refactored to per-package calls). Only attempt if we have at least one spec.
        if ($DownloadDebs -and $DownloadPackageSpecs -and $DownloadPackageSpecs.Count -gt 0) {
            if (-not $DownloadLocalDir) { throw 'DownloadLocalDir not specified for offline acquisition' }
            if (-not (Test-Path -LiteralPath $DownloadLocalDir)) { New-Item -ItemType Directory -Path $DownloadLocalDir -Force | Out-Null }
            $remoteDebDir = '/tmp/k2s-delta-debs'
            Write-Log ("[DebPkg] Starting per-package offline acquisition ({0} specs)" -f $DownloadPackageSpecs.Count) -Console
            $acq = Invoke-GuestDebAcquisition -RemoteDir $remoteDebDir -PackageSpecs $DownloadPackageSpecs -SshClient $sshClient -UsingPlink:$usingPlink -PlinkHostKey $plinkHostKey -SshUser $sshUser -GuestIp $guestExpectedIp -SshKey $sshKey -SshPassword $sshPwd
            if ($acq.Failures.Count -gt 0) { Write-Log ("[DebPkg][DL][Warning] Failed specs: {0}" -f ($acq.Failures -join ', ')) -Console }
            if ($acq.DebFiles.Count -gt 0) {
                Write-Log ("[DebPkg] Guest has {0} deb file(s) ready for copy" -f $acq.DebFiles.Count) -Console
                # Copy files
                $scpClient = $null
                $pscpCandidates = @(
                    (Join-Path $NewExtract 'bin\\pscp.exe'),
                    (Join-Path $OldExtract 'bin\\pscp.exe'),
                    'pscp.exe'
                )
                $scpClient = $pscpCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                $usePlinkCopy = ($scpClient -and ($scpClient.ToLower().EndsWith('pscp.exe')))
                if (-not $scpClient -and -not $usingPlink) { $scpClient = $sshClient }
                foreach ($deb in $acq.DebFiles) {
                    try {
                        if ($usePlinkCopy) {
                            $copyArgs = @('-batch','-P','22')
                            if ($plinkHostKey) { $copyArgs += @('-hostkey', $plinkHostKey) }
                            if ($sshKey) { $copyArgs += @('-i', $sshKey) } elseif ($sshPwd) { $copyArgs += @('-pw', $sshPwd) }
                            $copyArgs += ("${sshUser}@${guestExpectedIp}:${remoteDebDir}/$deb")
                            $copyArgs += (Join-Path $DownloadLocalDir $deb)
                            $null = & $scpClient @copyArgs 2>&1
                        } else {
                            $copyArgs = @('-P','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
                            if ($sshKey) { $copyArgs += @('-i', $sshKey) }
                            $copyArgs += ("${sshUser}@${guestExpectedIp}:${remoteDebDir}/$deb")
                            $copyArgs += $DownloadLocalDir
                            $null = & $scpClient @copyArgs 2>&1
                        }
                        if (Test-Path -LiteralPath (Join-Path $DownloadLocalDir $deb)) { $result.DownloadedDebs += $deb }
                    } catch { Write-Log "[DebPkg][DL][Warning] Copy failed for ${deb}: $($_.Exception.Message)" -Console }
                }
                Write-Log ("[DebPkg] Offline acquisition complete (downloaded {0} files)" -f $result.DownloadedDebs.Count) -Console
            } else {
                Write-Log '[DebPkg][DL][Warning] No deb files produced by acquisition; attempting local fallback search' -Console
                try {
                    $localDebs = Get-ChildItem -Path $NewExtract -Recurse -Filter *.deb -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
                    if ($localDebs) {
                        $specMap = @{}
                        foreach ($s in $DownloadPackageSpecs) { if ($s -match '^(?<n>[^=]+)=(?<v>.+)$') { $specMap[$matches['n']] = $matches['v'] } }
                        foreach ($full in $localDebs) {
                            $file = Split-Path -Leaf $full
                            if ($file -match '^(?<pkg>.+?)_(?<ver>[^_]+)_[^_]+\.deb$') {
                                $pkg = $matches['pkg']; $ver = $matches['ver']
                                if ($specMap.ContainsKey($pkg) -and $specMap[$pkg] -eq $ver) {
                                    $dest = Join-Path $DownloadLocalDir $file
                                    Copy-Item -LiteralPath $full -Destination $dest -Force -ErrorAction SilentlyContinue
                                    if (Test-Path -LiteralPath $dest) { $result.DownloadedDebs += $file }
                                }
                            }
                        }
                        if ($result.DownloadedDebs.Count -gt 0) { Write-Log ("[DebPkg][Fallback] Staged {0} deb files from local extract" -f $result.DownloadedDebs.Count) -Console }
                        else { Write-Log '[DebPkg][Fallback] No matching deb versions in local extract' -Console }
                    } else { Write-Log '[DebPkg][Fallback] No deb files found in local extract tree' -Console }
                } catch { Write-Log "[DebPkg][Fallback][Warning] Local search failed: $($_.Exception.Message)" -Console }
            }
        }
    }
    catch { $result.Error = "Hyper-V SSH extraction failed: $($_.Exception.Message)" }
    finally {
        # Non-interactive cleanup (removed Read-Host prompt to allow automation)

    Write-Log "[DebPkg] Beginning cleanup (VM, switch, IP, NAT)" -Console
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
            $natObj = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
            if ($natObj) { Remove-NetNat -Name $natName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
        } catch { $cleanupErrors += "Remove-NetNat: $($_.Exception.Message)" }
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
    $leftNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
        if ($leftSwitch) {
            Write-Log "[DebPkg][Cleanup] Switch still present after first attempt; retrying remove." -Console
            try { Remove-VMSwitch -Name $switchName -Force -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-VMSwitch: $($_.Exception.Message)" }
            $leftSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
            if ($leftSwitch) { $cleanupErrors += 'Switch remains after retry.' }
        }
        if ($leftNat) {
            Write-Log "[DebPkg][Cleanup] NAT still present after first attempt; retrying remove." -Console
            try { Remove-NetNat -Name $natName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-NetNat: $($_.Exception.Message)" }
            $leftNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
            if ($leftNat) { $cleanupErrors += 'NAT remains after retry.' }
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
