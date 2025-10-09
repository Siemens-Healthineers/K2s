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
        [string] $SshPassword,
        [switch] $ClassifyFailures
    )
    $result = [pscustomobject]@{ DebFiles=@(); Failures=@(); Logs=@(); RemoteDir=$RemoteDir; UsedFallback=$false; Diagnostics=@(); SatisfiedMeta=@(); FailureDetails=@() }
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

    if ($ClassifyFailures -and $result.Failures.Count -gt 0) {
        Write-Log ("[DebPkg][DL] Classifying {0} failure(s)" -f $result.Failures.Count) -Console
        foreach ($fSpec in @($result.Failures)) {
            if ($fSpec -notmatch '^(?<name>[^=]+)=(?<ver>.+)$') { continue }
            $pkgName = $matches['name']; $pkgVer = $matches['ver']
            $madCmd = ('bash -c ''apt-cache madison {0} 2>/dev/null || true''' -f $pkgName)
            $madOut = & $SshClient @((_BaseArgs) + $madCmd) 2>&1
            $versions = @()
            foreach ($ln in $madOut) {
                if ($ln -match "^$pkgName\s*\|\s*(?<v>[^\s|]+)") { $versions += $matches['v'] }
            }
            $reason = 'DownloadFailed'
            if ($versions.Count -gt 0 -and ($versions -notcontains $pkgVer)) { $reason = 'MissingVersionInRepos' }
            elseif ($versions.Count -eq 0) { $reason = 'NoVersionsListed' }
            $result.FailureDetails += [pscustomobject]@{ Name=$pkgName; Requested=$pkgVer; Reason=$reason; Available=@($versions); MadisonSample= ($madOut | Select-Object -First 6) }
        }
    }

    # (Removed interactive Read-Host used for debugging to allow non-interactive execution)

    return $result
}
