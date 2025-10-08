# Hyper-V based package enumeration & optional offline .deb acquisition

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
        $natExisting = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
        if ($natExisting) { Write-Log "[DebPkg] Reusing existing NAT '$natName'" -Console }
        else { try { New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix "$networkPrefix/$prefixLen" -ErrorAction Stop | Out-Null; Write-Log "[DebPkg] Created NAT '$natName' ($networkPrefix/$prefixLen)" -Console } catch { Write-Log "[DebPkg][Warning] Failed to create NAT '$natName': $($_.Exception.Message)" -Console } }
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
        $sshCandidates = @(
            (Join-Path $NewExtract 'bin\ssh.exe'),
            (Join-Path $OldExtract 'bin\ssh.exe'),
            'ssh.exe',
            (Join-Path $NewExtract 'bin\plink.exe'),
            (Join-Path $OldExtract 'bin\plink.exe'),
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
                    $fingerLine = $probeOutput | Where-Object { $_ -match 'ssh-ed25519 255 SHA256:' } | Select-Object -First 1
                    if (-not $fingerLine) { $fingerLine = $probeOutput | Where-Object { $_ -match 'ssh-rsa 2048 SHA256:' } | Select-Object -First 1 }
                    if ($fingerLine -and ($fingerLine -match '(ssh-(ed25519|rsa)\s+\d+\s+SHA256:[A-Za-z0-9+/=]+)')) {
                        $plinkHostKey = $matches[1]
                        Write-Log "[DebPkg] Extracted host key fingerprint: $plinkHostKey" -Console
                    } else { Write-Log "[DebPkg][Warning] Could not parse host key fingerprint from probe output: $joinedProbe" -Console }
                } else { Write-Log '[DebPkg] Host key already trusted (no prompt in probe).' -Console }
            } catch { Write-Log "[DebPkg][Warning] Host key probe failed: $($_.Exception.Message)" -Console }
        }
        try {
            Write-Log '[DebPkg] Running dpkg-query self-test' -Console
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
            foreach ($line in $testOutput) { if ($line -match '^dpkg-query ') { $hasVersion = $true }; if ($line -match 'unknown option') { $errorUnknown = $true } }
            if ($hasVersion -and -not $errorUnknown) {
                $firstLine = ($testOutput | Where-Object { $_ -match '^dpkg-query ' } | Select-Object -First 1)
                Write-Log "[DebPkg] dpkg self-test OK: $firstLine" -Console
            } else { $joined = ($testOutput | Select-Object -First 8) -join ' | '; Write-Log "[DebPkg] dpkg self-test FAILED/INCONCLUSIVE: $joined" -Console }
            if ($usingPlink -and ($testOutput -match 'POTENTIAL SECURITY BREACH')) { $result.Error = 'Host key mismatch detected (plink security warning). Provide correct fingerprint or clear cached host key.'; return $result }
        } catch { Write-Log "[Warning] dpkg self-test failed: $($_.Exception.Message)" -Console }
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
        try {
            Write-Log '[DebPkg] Querying installed packages via dpkg-query' -Console
            $pkgOutput = & $sshClient @($baseArgs + $baseQuery) 2>&1
            $pkgMap = @{}
            foreach ($ln in $pkgOutput) {
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                if ($ln -match '^[a-z0-9][a-z0-9+\-.]+?=') {
                    $eq = $ln.IndexOf('=')
                    if ($eq -gt 0) {
                        $name = $ln.Substring(0,$eq)
                        $ver  = $ln.Substring($eq+1)
                        if (-not [string]::IsNullOrWhiteSpace($name)) { $pkgMap[$name] = $ver }
                    }
                }
            }
            $result.Packages = $pkgMap
            Write-Log ("[DebPkg] Retrieved {0} packages (head: {1})" -f $pkgMap.Count, ([string]::Join(', ', ($pkgMap.Keys | Select-Object -First 5)))) -Console
            if ($pkgMap.Count -eq 0) { $sample = ($pkgOutput | Select-Object -First 8) -join ' | '; Write-Log ("[DebPkg][Warning] dpkg-query returned no packages; sample output: {0}" -f $sample) -Console }
        } catch { Write-Log ("[DebPkg][Error] Failed to query packages: {0}" -f $_.Exception.Message) -Console }
        if ($DownloadDebs -and $DownloadPackageSpecs -and $DownloadPackageSpecs.Count -gt 0) {
            if (-not $DownloadLocalDir) { throw 'DownloadLocalDir not specified for offline acquisition' }
            if (-not (Test-Path -LiteralPath $DownloadLocalDir)) { New-Item -ItemType Directory -Path $DownloadLocalDir -Force | Out-Null }
            $remoteDebDir = '/tmp/k2s-delta-debs'
            Write-Log ("[DebPkg] Starting per-package offline acquisition ({0} specs)" -f $DownloadPackageSpecs.Count) -Console
            $acq = Invoke-GuestDebAcquisition -RemoteDir $remoteDebDir -PackageSpecs $DownloadPackageSpecs -SshClient $sshClient -UsingPlink:$usingPlink -PlinkHostKey $plinkHostKey -SshUser $sshUser -GuestIp $guestExpectedIp -SshKey $sshKey -SshPassword $sshPwd
            if ($acq.Failures.Count -gt 0) { Write-Log ("[DebPkg][DL][Warning] Failed specs: {0}" -f ($acq.Failures -join ', ')) -Console }
            if ($acq.DebFiles.Count -gt 0) {
                Write-Log ("[DebPkg] Guest has {0} deb file(s) ready for copy" -f $acq.DebFiles.Count) -Console
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
        Write-Log "[DebPkg] Beginning cleanup (VM, switch, IP, NAT)" -Console
        $cleanupErrors = @()
        try { if ($createdVm) { Stop-VM -Name $vmName -Force -TurnOff -ErrorAction SilentlyContinue | Out-Null } } catch { $cleanupErrors += "Stop-VM: $($_.Exception.Message)" }
        try { if ($createdVm) { Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue | Out-Null } } catch { $cleanupErrors += "Remove-VM: $($_.Exception.Message)" }
        try { Remove-VMSwitch -Name $switchName -Force -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Remove-VMSwitch: $($_.Exception.Message)" }
        try { $natObj = Get-NetNat -Name $natName -ErrorAction SilentlyContinue; if ($natObj) { Remove-NetNat -Name $natName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } } catch { $cleanupErrors += "Remove-NetNat: $($_.Exception.Message)" }
        try { $existing = Get-NetIPAddress -IPAddress $hostSwitchIp -ErrorAction SilentlyContinue; if ($existing) { $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue } } catch { $cleanupErrors += "Remove-NetIPAddress: $($_.Exception.Message)" }
        $leftVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if ($leftVm) { try { Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-VM: $($_.Exception.Message)" }; $leftVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue; if ($leftVm) { $cleanupErrors += 'VM remains after retry.' } }
        $leftSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
        if ($leftSwitch) { try { Remove-VMSwitch -Name $switchName -Force -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-VMSwitch: $($_.Exception.Message)" }; $leftSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue; if ($leftSwitch) { $cleanupErrors += 'Switch remains after retry.' } }
        $leftNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
        if ($leftNat) { try { Remove-NetNat -Name $natName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-NetNat: $($_.Exception.Message)" }; $leftNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue; if ($leftNat) { $cleanupErrors += 'NAT remains after retry.' } }
        $leftIp = Get-NetIPAddress -IPAddress $hostSwitchIp -ErrorAction SilentlyContinue
        if ($leftIp) { try { $leftIp | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue } catch { $cleanupErrors += "Retry Remove-NetIPAddress: $($_.Exception.Message)" }; $leftIp = Get-NetIPAddress -IPAddress $hostSwitchIp -ErrorAction SilentlyContinue; if ($leftIp) { $cleanupErrors += 'Host switch IP remains after retry.' } }
        if ($cleanupErrors.Count -gt 0) { Write-Log ("[DebPkg] Cleanup completed with warnings: {0}" -f ($cleanupErrors -join '; ')) -Console } else { Write-Log "[DebPkg] Cleanup complete" -Console }
    }
    return $result
}
