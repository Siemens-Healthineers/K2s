# Hyper-V based package enumeration & optional offline .deb acquisition

<#
Refactored: The original monolithic Get-DebianPackagesFromVHDX function is now split into
focused helpers for readability, testability, and future reuse. Public behavior & return
contract are preserved: returns PSCustomObject { Packages; Error; Method='hyperv-ssh'; DownloadedDebs[] }.

Helper overview (all internal to this file):
  New-K2sHvNetwork            -> Creates internal switch + (re)uses or creates NAT, assigns host IP
  New-K2sHvTempVm             -> Creates & starts ephemeral VM
  Wait-K2sHvGuestIp           -> Polls for guest IP reachability
  Get-K2sHvSshClient          -> Locates ssh/plink client
  Get-K2sPlinkHostKey         -> Optional host key probe for plink
  Test-K2sDpkgQuery           -> dpkg-query self test (logs diagnostics)
  Get-K2sDpkgPackageMap       -> Retrieves dpkg package map
  Invoke-K2sGuestDebCopy      -> Copies acquired .deb files from guest
  Invoke-K2sGuestLocalDebFallback -> Local extract fallback for debs
  Remove-K2sHvEnvironment     -> Cleanup (VM, switch, NAT, IP)
External (already defined in Debian helpers): Invoke-GuestDebAcquisition
--#>

function New-K2sHvNetwork {
    param(
        [string] $SwitchName,
        [string] $NatName,
        [string] $HostSwitchIp,
        [string] $NetworkPrefix,
        [int]    $PrefixLen
    )
    Write-Log ("[DebPkg] Creating internal switch '{0}' with host IP {1}/{2}" -f $SwitchName, $HostSwitchIp, $PrefixLen) -Console
    $existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
    if ($existingSwitch) {
        try { Remove-VMSwitch -Name $SwitchName -Force -ErrorAction Stop } catch { throw "Failed to remove existing switch: $($_.Exception.Message)" }
    }
    New-VMSwitch -Name $SwitchName -SwitchType Internal -ErrorAction Stop | Out-Null
    $adapter = Get-NetAdapter | Where-Object { $_.Name -like "*$SwitchName*" }
    if (-not $adapter) { throw 'Internal vSwitch adapter not found after creation' }
    New-NetIPAddress -InterfaceAlias $adapter.Name -IPAddress $HostSwitchIp -PrefixLength $PrefixLen -ErrorAction Stop | Out-Null
    $natExisting = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
    if ($natExisting) { Write-Log "[DebPkg] Reusing existing NAT '$NatName'" -Console }
    else {
        try {
            New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix "$NetworkPrefix/$PrefixLen" -ErrorAction Stop | Out-Null
            Write-Log ("[DebPkg] Created NAT '{0}' ({1}/{2})" -f $NatName, $NetworkPrefix, $PrefixLen) -Console
        } catch {
            Write-Log ("[DebPkg][Warning] Failed to create NAT '{0}': {1}" -f $NatName, $_.Exception.Message) -Console
        }
    }
    return [pscustomobject]@{ SwitchName=$SwitchName; NatName=$NatName; AdapterName=$adapter.Name; HostSwitchIp=$HostSwitchIp; PrefixLen=$PrefixLen; NetworkPrefix=$NetworkPrefix }
}

function New-K2sHvTempVm {
    param(
        [string] $VmName,
        [string] $VhdxPath,
        [string] $SwitchName
    )
    Write-Log ("[DebPkg] Creating temporary VM '{0}' attached to '{1}'" -f $VmName, $SwitchName) -Console
    New-VM -Name $VmName -MemoryStartupBytes (2GB) -VHDPath $VhdxPath -SwitchName $SwitchName -ErrorAction Stop | Out-Null
    Start-VM -Name $VmName -ErrorAction Stop | Out-Null
    Write-Log ("[DebPkg] VM '{0}' started" -f $VmName) -Console
}

function Wait-K2sHvGuestIp {
    param(
        [string] $Ip,
        [int] $TimeoutSeconds = 180,
        [int] $IntervalSeconds = 5
    )
    Write-Log ("[DebPkg] Waiting for guest IP {0} (timeout {1}s)" -f $Ip, $TimeoutSeconds) -Console
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Connection -ComputerName $Ip -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $true }
        Start-Sleep -Seconds $IntervalSeconds
    }
    return $false
}

function Get-K2sHvSshClient {
    param(
        [string] $NewExtract,
        [string] $OldExtract
    )
    $candidates = @(
        (Join-Path $NewExtract 'bin\ssh.exe'),
        (Join-Path $OldExtract 'bin\ssh.exe'),
        'ssh.exe',
        (Join-Path $NewExtract 'bin\plink.exe'),
        (Join-Path $OldExtract 'bin\plink.exe'),
        'plink.exe'
    )
    $client = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $client) { throw 'No ssh/plink client found (looked for ssh.exe or plink.exe)' }
    $usingPlink = $client.ToLower().EndsWith('plink.exe')
    $mode = if ($usingPlink) { 'plink' } else { 'openssh' }
    Write-Log ("[DebPkg] Using SSH client: {0} (mode={1})" -f $client, $mode) -Console
    return [pscustomobject]@{ Path=$client; UsingPlink=$usingPlink }
}

function Get-K2sPlinkHostKey {
    param(
        [string] $SshClient,
        [string] $SshUser,
        [string] $GuestIp
    )
    try {
        Write-Log '[DebPkg] Performing plink host key probe' -Console
        $probeArgs = @('-noagent','-batch','-P','22',"$SshUser@$GuestIp",'exit')
        $probeOutput = & $SshClient @probeArgs 2>&1
        $joinedProbe = ($probeOutput | Select-Object -First 8) -join ' | '
        if ($probeOutput -match 'host key is not cached' -or $probeOutput -match 'POTENTIAL SECURITY BREACH') {
            $fingerLine = $probeOutput | Where-Object { $_ -match 'ssh-ed25519 255 SHA256:' } | Select-Object -First 1
            if (-not $fingerLine) { $fingerLine = $probeOutput | Where-Object { $_ -match 'ssh-rsa 2048 SHA256:' } | Select-Object -First 1 }
            if ($fingerLine -and ($fingerLine -match '(ssh-(ed25519|rsa)\s+\d+\s+SHA256:[A-Za-z0-9+/=]+)')) {
                $hk = $matches[1]
                Write-Log ("[DebPkg] Extracted host key fingerprint: {0}" -f $hk) -Console
                return $hk
            } else {
                Write-Log ("[DebPkg][Warning] Could not parse host key fingerprint from probe output: {0}" -f $joinedProbe) -Console
            }
        } else { Write-Log '[DebPkg] Host key already trusted (no prompt in probe).' -Console }
    } catch { Write-Log ("[DebPkg][Warning] Host key probe failed: {0}" -f $_.Exception.Message) -Console }
    return $null
}

function Test-K2sDpkgQuery {
    param(
        [string] $SshClient,
        [bool] $UsingPlink,
        [string] $PlinkHostKey,
        [string] $SshUser,
        [string] $GuestIp,
        [string] $SshKey,
        [string] $SshPassword
    )
    Write-Log '[DebPkg] Running dpkg-query self-test' -Console
    $testCmd = 'dpkg-query --version 2>&1 || echo __DPKG_QUERY_FAILED__=$?'
    if ($UsingPlink) {
        $testArgs = @('-batch','-noagent','-P','22')
        if ($PlinkHostKey) { $testArgs += @('-hostkey', $PlinkHostKey) }
        if ($SshKey) { $testArgs += @('-i', $SshKey) } elseif ($SshPassword) { $testArgs += @('-pw', $SshPassword) }
        $testArgs += ("$SshUser@$GuestIp")
    } else {
        $testArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null',"$SshUser@$GuestIp")
        if ($SshKey) { $testArgs += @('-i', $SshKey) }
    }
    $testArgs += $testCmd
    $testOutput = & $SshClient @testArgs 2>&1
    $hasVersion = $false; $errorUnknown = $false
    foreach ($line in $testOutput) { if ($line -match '^dpkg-query ') { $hasVersion = $true }; if ($line -match 'unknown option') { $errorUnknown = $true } }
    if ($UsingPlink -and ($testOutput -match 'POTENTIAL SECURITY BREACH')) { return [pscustomobject]@{ Ok=$false; HostKeyMismatch=$true; Output=$testOutput } }
    $ok = ($hasVersion -and -not $errorUnknown)
    if ($ok) {
        $firstLine = ($testOutput | Where-Object { $_ -match '^dpkg-query ' } | Select-Object -First 1)
        Write-Log ("[DebPkg] dpkg self-test OK: {0}" -f $firstLine) -Console
    } else {
        $joined = ($testOutput | Select-Object -First 8) -join ' | '
        Write-Log ("[DebPkg] dpkg self-test FAILED/INCONCLUSIVE: {0}" -f $joined) -Console
    }
    return [pscustomobject]@{ Ok=$ok; HostKeyMismatch=$false; Output=$testOutput }
}

function Get-K2sDpkgPackageMap {
    param(
        [string] $SshClient,
        [bool] $UsingPlink,
        [string] $PlinkHostKey,
        [string] $SshUser,
        [string] $GuestIp,
        [string] $SshKey,
        [string] $SshPassword
    )
    $formatLiteral = '${Package}=${Version}\n'
    $baseQuery = "dpkg-query -W -f='$formatLiteral'"
    if ($UsingPlink) {
        $baseArgs = @('-batch','-noagent','-P','22')
        if ($PlinkHostKey) { $baseArgs += @('-hostkey', $PlinkHostKey) }
        if ($SshKey) { $baseArgs += @('-i', $SshKey) } elseif ($SshPassword) { $baseArgs += @('-pw', $SshPassword) }
        $baseArgs += ("$SshUser@$GuestIp")
    } else {
        $baseArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
        if ($SshKey) { $baseArgs += @('-i', $SshKey) }
        $baseArgs += ("$SshUser@$GuestIp")
    }
    Write-Log '[DebPkg] Querying installed packages via dpkg-query' -Console
    $pkgOutput = & $SshClient @($baseArgs + $baseQuery) 2>&1
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
    if ($pkgMap.Count -eq 0) { $sample = ($pkgOutput | Select-Object -First 8) -join ' | '; Write-Log ("[DebPkg][Warning] dpkg-query returned no packages; sample output: {0}" -f $sample) -Console }
    return $pkgMap
}

function Invoke-K2sGuestDebCopy {
    param(
        [object] $AcquisitionResult,
        [string] $NewExtract,
        [string] $OldExtract,
        [bool] $UsingPlink,
        [string] $PlinkHostKey,
        [string] $SshUser,
        [string] $GuestIp,
        [string] $SshKey,
        [string] $SshPassword,
        [string] $RemoteDir,
        [string] $DownloadLocalDir
    )
    $downloaded = @()
    if ($AcquisitionResult.DebFiles.Count -le 0) { return $downloaded }
    Write-Log ("[DebPkg] Guest has {0} deb file(s) ready for copy" -f $AcquisitionResult.DebFiles.Count) -Console
    $pscpCandidates = @(
        (Join-Path $NewExtract 'bin\pscp.exe'),
        (Join-Path $OldExtract 'bin\pscp.exe'),
        'pscp.exe'
    )
    $scpClient = $pscpCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $usePlinkCopy = ($scpClient -and ($scpClient.ToLower().EndsWith('pscp.exe')))
    if (-not $scpClient -and -not $UsingPlink) { $scpClient = (Get-K2sHvSshClient -NewExtract $NewExtract -OldExtract $OldExtract).Path }
    foreach ($deb in $AcquisitionResult.DebFiles) {
        try {
            if ($usePlinkCopy) {
                $copyArgs = @('-batch','-P','22')
                if ($PlinkHostKey) { $copyArgs += @('-hostkey', $PlinkHostKey) }
                if ($SshKey) { $copyArgs += @('-i', $SshKey) } elseif ($SshPassword) { $copyArgs += @('-pw', $SshPassword) }
                $copyArgs += ("${SshUser}@${GuestIp}:${RemoteDir}/$deb")
                $copyArgs += (Join-Path $DownloadLocalDir $deb)
                $null = & $scpClient @copyArgs 2>&1
            } else {
                $copyArgs = @('-P','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
                if ($SshKey) { $copyArgs += @('-i', $SshKey) }
                $copyArgs += ("${SshUser}@${GuestIp}:${RemoteDir}/$deb")
                $copyArgs += $DownloadLocalDir
                $null = & $scpClient @copyArgs 2>&1
            }
            if (Test-Path -LiteralPath (Join-Path $DownloadLocalDir $deb)) { $downloaded += $deb }
        } catch { Write-Log ("[DebPkg][DL][Warning] Copy failed for {0}: {1}" -f $deb, $_.Exception.Message) -Console }
    }
    Write-Log ("[DebPkg] Offline acquisition copy phase complete (downloaded {0} files)" -f $downloaded.Count) -Console
    return $downloaded
}

function Invoke-K2sGuestLocalDebFallback {
    param(
        [string[]] $DownloadPackageSpecs,
        [string] $NewExtract,
        [string] $DownloadLocalDir
    )
    Write-Log '[DebPkg][DL][Warning] No deb files produced by acquisition; attempting local fallback search' -Console
    $staged = @()
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
                        if (Test-Path -LiteralPath $dest) { $staged += $file }
                    }
                }
            }
            if ($staged.Count -gt 0) { Write-Log ("[DebPkg][Fallback] Staged {0} deb files from local extract" -f $staged.Count) -Console }
            else { Write-Log '[DebPkg][Fallback] No matching deb versions in local extract' -Console }
        } else { Write-Log '[DebPkg][Fallback] No deb files found in local extract tree' -Console }
    } catch { Write-Log ("[DebPkg][Fallback][Warning] Local search failed: {0}" -f $_.Exception.Message) -Console }
    return $staged
}

function Remove-K2sHvEnvironment {
    param(
        [pscustomobject] $Context
    )
    Write-Log '[DebPkg] Beginning cleanup (VM, switch, IP, NAT)' -Console
    $cleanupErrors = @()
    $vmName = $Context.VmName
    try { if ($Context.CreatedVm) { Stop-VM -Name $vmName -Force -TurnOff -ErrorAction SilentlyContinue | Out-Null } } catch { $cleanupErrors += "Stop-VM: $($_.Exception.Message)" }
    try { if ($Context.CreatedVm) { Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue | Out-Null } } catch { $cleanupErrors += "Remove-VM: $($_.Exception.Message)" }
    try { Remove-VMSwitch -Name $Context.SwitchName -Force -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Remove-VMSwitch: $($_.Exception.Message)" }
    try { $natObj = Get-NetNat -Name $Context.NatName -ErrorAction SilentlyContinue; if ($natObj) { Remove-NetNat -Name $Context.NatName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } } catch { $cleanupErrors += "Remove-NetNat: $($_.Exception.Message)" }
    try { $existing = Get-NetIPAddress -IPAddress $Context.HostSwitchIp -ErrorAction SilentlyContinue; if ($existing) { $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue } } catch { $cleanupErrors += "Remove-NetIPAddress: $($_.Exception.Message)" }
    $leftVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($leftVm) { try { Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-VM: $($_.Exception.Message)" }; $leftVm = Get-VM -Name $vmName -ErrorAction SilentlyContinue; if ($leftVm) { $cleanupErrors += 'VM remains after retry.' } }
    $leftSwitch = Get-VMSwitch -Name $Context.SwitchName -ErrorAction SilentlyContinue
    if ($leftSwitch) { try { Remove-VMSwitch -Name $Context.SwitchName -Force -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-VMSwitch: $($_.Exception.Message)" }; $leftSwitch = Get-VMSwitch -Name $Context.SwitchName -ErrorAction SilentlyContinue; if ($leftSwitch) { $cleanupErrors += 'Switch remains after retry.' } }
    $leftNat = Get-NetNat -Name $Context.NatName -ErrorAction SilentlyContinue
    if ($leftNat) { try { Remove-NetNat -Name $Context.NatName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } catch { $cleanupErrors += "Retry Remove-NetNat: $($_.Exception.Message)" }; $leftNat = Get-NetNat -Name $Context.NatName -ErrorAction SilentlyContinue; if ($leftNat) { $cleanupErrors += 'NAT remains after retry.' } }
    $leftIp = Get-NetIPAddress -IPAddress $Context.HostSwitchIp -ErrorAction SilentlyContinue
    if ($leftIp) { try { $leftIp | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue } catch { $cleanupErrors += "Retry Remove-NetIPAddress: $($_.Exception.Message)" }; $leftIp = Get-NetIPAddress -IPAddress $Context.HostSwitchIp -ErrorAction SilentlyContinue; if ($leftIp) { $cleanupErrors += 'Host switch IP remains after retry.' } }
    if ($cleanupErrors.Count -gt 0) { Write-Log ("[DebPkg] Cleanup completed with warnings: {0}" -f ($cleanupErrors -join '; ')) -Console } else { Write-Log '[DebPkg] Cleanup complete' -Console }
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
    $result = [pscustomobject]@{ Packages=$null; Error=$null; Method='hyperv-ssh'; DownloadedDebs=@() }
    if (-not (Test-Path -LiteralPath $VhdxPath)) { $result.Error = "VHDX not found: $VhdxPath"; return $result }
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) { $result.Error = 'Hyper-V module unavailable'; return $result }
    $sshUser = 'remote'; $sshPwd = 'admin'; $sshKey = ''  # TODO: parameterize via caller / env if needed
    if (-not $sshUser) { $result.Error = 'K2S_DEBIAN_SSH_USER not set'; return $result }
    if (-not $sshPwd -and -not $sshKey) { $result.Error = 'Set K2S_DEBIAN_SSH_PASSWORD or K2S_DEBIAN_SSH_KEY'; return $result }
    Write-Log ("[DebPkg] Starting extraction from VHDX '{0}' with new extract '{1}' and old extract '{2}'" -f $VhdxPath, $NewExtract, $OldExtract) -Console

    # Static network (could be made configurable later)
    $hostSwitchIp = '172.19.1.1'
    $networkPrefix = '172.19.1.0'
    $guestIp = '172.19.1.100'
    $prefixLen = 24
    $switchName = "k2s-switch-$switchNameEnding"
    $natName    = "k2s-nat-$switchNameEnding"
    $vmName     = "k2s-kubemaster-$switchNameEnding"
    Write-Log ("[DebPkg] Switch={0} NAT={1} GuestIP={2} DownloadDir={3} DownloadDebs={4}" -f $switchName, $natName, $guestIp, $DownloadLocalDir, $DownloadDebs) -Console

    $ctx = [pscustomobject]@{ SwitchName=$switchName; NatName=$natName; HostSwitchIp=$hostSwitchIp; NetworkPrefix=$networkPrefix; PrefixLen=$prefixLen; GuestIp=$guestIp; VmName=$vmName; CreatedVm=$false }

    try {
        # Network
        $null = New-K2sHvNetwork -SwitchName $switchName -NatName $natName -HostSwitchIp $hostSwitchIp -NetworkPrefix $networkPrefix -PrefixLen $prefixLen
        # VM
        New-K2sHvTempVm -VmName $vmName -VhdxPath $VhdxPath -SwitchName $switchName
        $ctx.CreatedVm = $true
        # Wait IP
        if (-not (Wait-K2sHvGuestIp -Ip $guestIp -TimeoutSeconds 180)) { throw "Guest IP $guestIp not reachable within timeout" }
        Write-Log ("[DebPkg] Guest reachable at {0}" -f $guestIp) -Console
        # SSH client
        $sshInfo = Get-K2sHvSshClient -NewExtract $NewExtract -OldExtract $OldExtract
        $sshClient = $sshInfo.Path; $usingPlink = $sshInfo.UsingPlink; $plinkHostKey = $null
        if ($usingPlink) { $plinkHostKey = Get-K2sPlinkHostKey -SshClient $sshClient -SshUser $sshUser -GuestIp $guestIp }
        # dpkg self test
        $dpkgTest = Test-K2sDpkgQuery -SshClient $sshClient -UsingPlink:$usingPlink -PlinkHostKey $plinkHostKey -SshUser $sshUser -GuestIp $guestIp -SshKey $sshKey -SshPassword $sshPwd
        if ($dpkgTest.HostKeyMismatch) { $result.Error = 'Host key mismatch detected (plink security warning). Provide correct fingerprint or clear cached host key.'; return $result }
        # Query packages
        $pkgMap = Get-K2sDpkgPackageMap -SshClient $sshClient -UsingPlink:$usingPlink -PlinkHostKey $plinkHostKey -SshUser $sshUser -GuestIp $guestIp -SshKey $sshKey -SshPassword $sshPwd
        $result.Packages = $pkgMap

        # Offline acquisition (optional)
        if ($DownloadDebs -and $DownloadPackageSpecs -and $DownloadPackageSpecs.Count -gt 0) {
            if (-not $DownloadLocalDir) { throw 'DownloadLocalDir not specified for offline acquisition' }
            if (-not (Test-Path -LiteralPath $DownloadLocalDir)) { New-Item -ItemType Directory -Path $DownloadLocalDir -Force | Out-Null }
            $remoteDebDir = '/tmp/k2s-delta-debs'
            Write-Log ("[DebPkg] Starting per-package offline acquisition ({0} specs)" -f $DownloadPackageSpecs.Count) -Console
            $acq = Invoke-GuestDebAcquisition -RemoteDir $remoteDebDir -PackageSpecs $DownloadPackageSpecs -SshClient $sshClient -UsingPlink:$usingPlink -PlinkHostKey $plinkHostKey -SshUser $sshUser -GuestIp $guestIp -SshKey $sshKey -SshPassword $sshPwd
            if ($acq.Failures.Count -gt 0) { Write-Log ("[DebPkg][DL][Warning] Failed specs: {0}" -f ($acq.Failures -join ', ')) -Console }
            $downloaded = Invoke-K2sGuestDebCopy -AcquisitionResult $acq -NewExtract $NewExtract -OldExtract $OldExtract -UsingPlink:$usingPlink -PlinkHostKey $plinkHostKey -SshUser $sshUser -GuestIp $guestIp -SshKey $sshKey -SshPassword $sshPwd -RemoteDir $remoteDebDir -DownloadLocalDir $DownloadLocalDir
            if ($downloaded.Count -eq 0) {
                $fallback = Invoke-K2sGuestLocalDebFallback -DownloadPackageSpecs $DownloadPackageSpecs -NewExtract $NewExtract -DownloadLocalDir $DownloadLocalDir
                $downloaded = $fallback
            }
            $result.DownloadedDebs = $downloaded
        }
    } catch {
        $result.Error = "Hyper-V SSH extraction failed: $($_.Exception.Message)"
    } finally {
        Remove-K2sHvEnvironment -Context $ctx
    }
    return $result
}
