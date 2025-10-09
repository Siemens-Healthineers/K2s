# Debian package parsing & per-package acquisition helpers (guest VM context)

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
        if ($line -like 'Package:*') { $currentName = ($line.Substring(8)).Trim() }
        elseif ($line -like 'Version:*') { $currentVersion = ($line.Substring(8)).Trim() }
    }
    if ($currentName) { $map[$currentName] = $currentVersion }
    return $map
}

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
        # NOTE: Legacy plain-text password to match existing calling pattern; avoid proliferating further. Prefer key auth.
        # PSScriptAnalyzer Suppression: Using string for backward compatibility with existing callers.
    [string] $SshPassword
    )
    $result = [pscustomobject]@{ DebFiles=@(); Failures=@(); Logs=@(); RemoteDir=$RemoteDir; UsedFallback=$false; Diagnostics=@(); SatisfiedMeta=@(); Resolutions=@() }
    if (-not $PackageSpecs -or $PackageSpecs.Count -eq 0) { return $result }

    function _BaseArgs([string]$extra='') {
        if ($UsingPlink) {
            $sshArgs = @('-batch','-noagent','-P','22')
            if ($PlinkHostKey) { $sshArgs += @('-hostkey', $PlinkHostKey) }
            if ($SshKey) { $sshArgs += @('-i', $SshKey) } elseif ($SshPassword) { $sshArgs += @('-pw', $SshPassword) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        } else {
            $sshArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
            if ($SshKey) { $sshArgs += @('-i', $SshKey) }
            $sshArgs += ("$SshUser@$GuestIp")
            return ,$sshArgs
        }
    }

    $initParts = @()
    $initParts += 'set -euo pipefail'
    $initParts += "rm -rf $RemoteDir; mkdir -p $RemoteDir"
    $initParts += "cd $RemoteDir"
    $initParts += 'echo __K2S_DIAG_BEGIN__'
    $initParts += 'ip addr show || true'
    $initParts += 'ip route show || true'
    $initParts += 'grep -v ^# /etc/apt/sources.list 2>/dev/null || true'
    $initParts += 'ls -1 /etc/apt/sources.list.d 2>/dev/null || true'
    $initParts += 'ping -c1 deb.debian.org >/dev/null 2>&1 && echo PING_OK || echo PING_FAIL || true'
    $initParts += 'echo --- RESOLV.CONF ---'
    $initParts += 'cat /etc/resolv.conf 2>/dev/null || true'
    # Curl test without extra parentheses or embedded single quotes
    $initParts += 'if command -v curl >/dev/null 2>&1; then echo "--- CURL TEST deb.debian.org HTTP root ---"; if curl -fsI --connect-timeout 5 http://deb.debian.org/ >/dev/null; then echo CURL_DEB_OK; else echo CURL_DEB_FAIL; fi; else echo CURL_NOT_INSTALLED; fi'
    $initParts += 'echo __K2S_DIAG_END__'
    $initParts += 'apt-get update 2>&1 || true'
    $initScript = ($initParts -join '; ')
    $initCmd = "bash -c '" + $initScript + "'"
    $initArgs = (_BaseArgs) + $initCmd
    $initOut = & $SshClient @initArgs 2>&1
    if ($initOut) { $result.Diagnostics += ($initOut | Select-Object -First 40) }
    Write-Log ("[DebPkg][DL] Init output head: {0}" -f (($initOut | Select-Object -First 20) -join ' | ')) -Console

    $idx = 0; $total = $PackageSpecs.Count
    foreach ($spec in $PackageSpecs) {
        $idx++
        if ([string]::IsNullOrWhiteSpace($spec)) { continue }
        $pkgSpec = $spec.Trim()
        Write-Log ("[DebPkg][DL] ({0}/{1}) --> Downloading {2} to {3}" -f $idx, $total, $pkgSpec, $RemoteDir) -Console
        $escaped = $pkgSpec.Replace("'", "'\\''")
        $cmdScript = @(
            # strict mode
            "set -euo pipefail",
            # ensure directory persists across iterations
            "mkdir -p $RemoteDir",
            "cd $RemoteDir",
            # download attempt
            "echo [dl] $escaped",
            "if apt-get help 2>&1 | grep -qi download; then apt-get download '$escaped' 2>&1 || echo WARN: failed $escaped; elif command -v apt >/dev/null 2>&1; then apt download '$escaped' 2>&1 || echo WARN: failed $escaped; else echo WARN: no download command; fi",
            # diagnostics & listing
            "echo [ls-after]",
            "pwd || true",
            "ls -al 2>/dev/null | head -n 20 || true",
            # robust loop (handle no matches)
            'for f in *.deb; do if [ -f "$f" ]; then echo $f; fi; done || true'
        ) -join '; '
        $cmd = "bash -c '" + $cmdScript + "'"
    $execArgs = (_BaseArgs) + $cmd
    $out = & $SshClient @execArgs 2>&1
        Write-Log ("[DebPkg][DL] ({0}/{1})    {2} downloaded to {3}, output head: {4}" -f $idx, $total, $pkgSpec, $RemoteDir, (($out | Select-Object -First 6) -join ' | ')) -Console
        $result.Logs += $out
        $fail = ($out | Where-Object { $_ -match 'WARN: failed' })
        if ($fail) {
            Write-Log ("[DebPkg][DL] ({0}/{1})    Failed to download {2} with {3}" -f $idx, $total, $pkgSpec, ($fail -join ', ')) -Console
            $result.Failures += $pkgSpec
        } else {
            Write-Log ("[DebPkg][DL] ({0}/{1})    Listing .deb files in {2}" -f $idx, $total, $RemoteDir) -Console
            $listCmd = ('bash -c ''cd {0}; pwd; ls -al 2>/dev/null | head -n 20; for f in *.deb; do if [ -f "$f" ]; then echo $f; fi; done || true''' -f $RemoteDir)
            $listOut = & $SshClient @((_BaseArgs) + $listCmd) 2>&1
            if ($listOut) {
                $current = $listOut | Where-Object { $_ -match '^.+\.deb$' }
                $previous = @($result.DebFiles)
                $newOnes = @()
                if ($current) { $newOnes = $current | Where-Object { $previous -notcontains $_ } }
                if ($current) { $result.DebFiles = @($previous + $current) | Sort-Object -Unique }
                $display = if ($newOnes.Count -gt 0) { $newOnes -join ', ' } else { '(none new)' }
                Write-Log ("[DebPkg][DL] ({0}/{1})    new .deb file(s): {2}" -f $idx, $total, $display) -Console
            } else {
                Write-Log ("[DebPkg][DL][Info] ({0}/{1}) No .deb files listed after download of {2}" -f $idx, $total, $pkgSpec) -Console
            }
        }
        Write-Log ("[DebPkg][DL] ({0}/{1}) <-- Completed attempt for {2}; total .deb files now: {3}" -f $idx, $total, $pkgSpec, ($result.DebFiles.Count)) -Console
    }
    Write-Log ("[DebPkg][DL] Completed per-package download attempts; total .deb files now: {0}" -f ($result.DebFiles.Count)) -Console

    # Meta package satisfaction logic: if a meta (linux-image-cloud-amd64) requested exact version but only the concrete kernel image exists, treat as satisfied.
    if ($result.Failures.Count -gt 0 -and $result.DebFiles.Count -gt 0) {
        $remainingFailures = @()
        foreach ($fSpec in $result.Failures) {
            if ($fSpec -match '^(?<name>linux-image-cloud-amd64)=(?<ver>[^=]+)$') {
                $metaVer = $matches['ver']
                # Look for linux-image-*-cloud-amd64_<version>_*.deb file among downloaded debs (names only)
                $matching = $result.DebFiles | Where-Object { $_ -like "linux-image-*cloud-amd64_${metaVer}_*.deb" }
                if ($matching -and $matching.Count -gt 0) {
                    Write-Log ("[DebPkg][DL] Meta spec {0} satisfied by kernel image(s): {1}" -f $fSpec, ($matching -join ', ')) -Console
                    $result.SatisfiedMeta += [pscustomobject]@{ Spec=$fSpec; Via=$matching }
                    continue
                }
            }
            $remainingFailures += $fSpec
        }
        $result.Failures = $remainingFailures
    }
    if (-not $result.DebFiles -or $result.DebFiles.Count -eq 0) {
        Write-Log '[DebPkg][DL] No deb files after per-package attempts; invoking cache fallback' -Console
        $fallbackCmd = "bash -c 'cd $RemoteDir; cp -a /var/cache/apt/archives/*.deb . 2>/dev/null || true; ls -1 *.deb 2>/dev/null || true'"
        $fallbackOut = & $SshClient @((_BaseArgs) + $fallbackCmd) 2>&1
        $fbDebs = $fallbackOut | Where-Object { $_ -like '*.deb' }
        if ($fbDebs) { $result.DebFiles = ($fbDebs | Sort-Object -Unique); $result.UsedFallback = $true }
        $result.Diagnostics += ($fallbackOut | Select-Object -First 40)
    }

    # Re-run meta satisfaction after fallback if still failing
    if ($result.Failures.Count -gt 0 -and $result.DebFiles.Count -gt 0) {
        $remainingFailures = @()
        foreach ($fSpec in $result.Failures) {
            if ($fSpec -match '^(?<name>linux-image-cloud-amd64)=(?<ver>[^=]+)$') {
                $metaVer = $matches['ver']
                $matching = $result.DebFiles | Where-Object { $_ -like "linux-image-*cloud-amd64_${metaVer}_*.deb" }
                if ($matching -and $matching.Count -gt 0) {
                    Write-Log ("[DebPkg][DL] (fallback) Meta spec {0} satisfied by kernel image(s): {1}" -f $fSpec, ($matching -join ', ')) -Console
                    $result.SatisfiedMeta += [pscustomobject]@{ Spec=$fSpec; Via=$matching; Fallback=$true }
                    continue
                }
            }
            $remainingFailures += $fSpec
        }
        $result.Failures = $remainingFailures
    }

    # Simplified substitution: handle Debian point security revision bumps (~deb12uX)
    if ($result.Failures.Count -gt 0) {
        $still = @()
        foreach ($spec in $result.Failures) {
            if ($spec -notmatch '^(?<name>[^=]+)=(?<ver>.+)$') { $still += $spec; continue }
            $pkgName = $matches['name']; $reqVer = $matches['ver']
            if ($reqVer -notmatch '^(?<base>.+~deb12u)(?<rev>\d+)$') { $still += $spec; continue }
            $basePrefix = $matches['base']; $reqRev = [int]$matches['rev']
            # Iteratively probe higher revision numbers (avoid fragile candidate parsing)
            $maxProbe = 8  # try up to 8 higher revisions
            $foundVersion = $null
            for ($inc = 1; $inc -le $maxProbe; $inc++) {
                $tryRev = $reqRev + $inc
                $tryVer = "$basePrefix$tryRev"
                Write-Log ("[DebPkg][DL][Debug] Probing revision {0} for {1}" -f $tryVer, $pkgName) -Console
                $probeCmd = ('bash -c ''cd {0}; apt-get download {1}={2} 2>&1 || echo PROBE_FAIL: {1}={2}; ls -1 *{1}_{2}_*.deb 2>/dev/null || true''' -f $RemoteDir, $pkgName, $tryVer)
                $probeOut = & $SshClient @((_BaseArgs) + $probeCmd) 2>&1
                $result.Logs += $probeOut
                if ($probeOut -notmatch "PROBE_FAIL: $pkgName=$tryVer") {
                    $debFiles = $probeOut | Where-Object { $_ -like '*.deb' }
                    if ($debFiles) {
                        $foundVersion = $tryVer
                        foreach ($df in $debFiles) { if ($result.DebFiles -notcontains $df) { $result.DebFiles += $df } }
                        break
                    }
                }
            }
            if (-not $foundVersion) {
                # plain fallback (unversioned) then parse revision
                Write-Log ("[DebPkg][DL][Info] Probes failed for {0}; attempting plain download fallback" -f $pkgName) -Console
                $plainCmd = ('bash -c ''cd {0}; apt-get download {1} 2>&1 || echo PLAIN_FAIL: {1}; ls -1 *{1}_*.deb 2>/dev/null || true''' -f $RemoteDir, $pkgName)
                $plainOut = & $SshClient @((_BaseArgs) + $plainCmd) 2>&1
                $result.Logs += $plainOut
                if ($plainOut -notmatch "PLAIN_FAIL: $pkgName") {
                    $plainFiles = $plainOut | Where-Object { $_ -like '*.deb' }
                    if ($plainFiles) {
                        $firstPlain = $plainFiles | Select-Object -First 1
                        if ($firstPlain -match "^${pkgName}_(?<ver>[^_]+)_.+\.deb$") {
                            $parsed = $matches['ver']
                            if ($parsed -match '^(?<cbase>.+~deb12u)(?<crev>\d+)$') {
                                $cBase = $matches['cbase']; $cRev = [int]$matches['crev']
                                if ($cBase -eq $basePrefix -and $cRev -gt $reqRev) {
                                    $foundVersion = $parsed
                                    foreach ($pf in $plainFiles) { if ($result.DebFiles -notcontains $pf) { $result.DebFiles += $pf } }
                                }
                            }
                        }
                    }
                }
            }
            if (-not $foundVersion) { $still += $spec; continue }
            Write-Log ("[DebPkg][DL] Substituting {0} -> {1}" -f $spec, $foundVersion) -Console
            $result.Resolutions += [pscustomobject]@{ Spec=$spec; Action='Deb12Revision'; Requested=$reqRev; Provided=$foundVersion; Files=($result.DebFiles | Where-Object { $_ -like "$pkgName*${foundVersion}_*.deb" }) }
        }
        $result.Failures = $still
    }

    # Summary log
    if ($result.Resolutions.Count -gt 0) {
        $subs = ($result.Resolutions | ForEach-Object { "${($_.Spec)}->${($_.Provided)}" }) -join ', '
        Write-Log ("[DebPkg][DL] Substitutions applied: {0}" -f $subs) -Console
    }
    if ($result.Failures.Count -gt 0) {
        Write-Log ("[DebPkg][DL] Unresolved specs after substitution: {0}" -f ($result.Failures -join ', ')) -Console
    }
    # (Removed interactive Read-Host used for debugging to allow non-interactive execution)

    return $result
}
