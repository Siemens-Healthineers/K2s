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
        [string] $SshPassword
    )
    $result = [pscustomobject]@{ DebFiles=@(); Failures=@(); Logs=@(); RemoteDir=$RemoteDir; UsedFallback=$false; Diagnostics=@() }
    if (-not $PackageSpecs -or $PackageSpecs.Count -eq 0) { return $result }

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
            'set -euo pipefail',
            "rm -rf $RemoteDir; mkdir -p $RemoteDir",
            "cd $RemoteDir",
            "echo '[dl] $escaped'",
            "if apt-get help 2>&1 | grep -qi download; then apt-get download '$escaped' 2>&1 || echo 'WARN: failed $escaped'; \\\n+             elif command -v apt >/dev/null 2>&1; then apt download '$escaped' 2>&1 || echo 'WARN: failed $escaped'; \\\n+             else echo 'WARN: no download command'; fi",
            'echo "[ls-after]"',
            'ls -1 *.deb 2>/dev/null || true'
        ) -join '; '
        $cmd = "bash -c '" + $cmdScript + "'"
        $args = (_BaseArgs) + $cmd
        $out = & $SshClient @args 2>&1
        Write-Log ("[DebPkg][DL] ({0}/{1})    {2} downloaded to {3}, output: {4}" -f $idx, $total, $pkgSpec, $RemoteDir, $out) -Console
        $result.Logs += $out
        $fail = ($out | Where-Object { $_ -match 'WARN: failed' })
        if ($fail) {
            Write-Log ("[DebPkg][DL] ({0}/{1})    Failed to download {2} with {3}" -f $idx, $total, $pkgSpec, ($fail -join ', ')) -Console
            $result.Failures += $pkgSpec
        } else {
            Write-Log ("[DebPkg][DL] ({0}/{1})    Checking for .deb files in {2}" -f $idx, $total, $RemoteDir) -Console
            $listCmd = "bash -c 'cd $RemoteDir; ls -1 *.deb 2>/dev/null || true'"
            $listOut = & $SshClient @((_BaseArgs) + $listCmd) 2>&1
            Write-Log ("[DebPkg][DL] ({0}/{1})    .deb files found: {2}" -f $idx, $total, ($listOut -join ', ')) -Console
            if ($listOut) {
                $current = $listOut | Where-Object { $_ -like '*.deb' }
                $result.DebFiles = ($current | Sort-Object -Unique)
            }
        }
        Write-Log ("[DebPkg][DL] ({0}/{1}) <-- Completed attempt for {2}; total .deb files now: {3}" -f $idx, $total, $pkgSpec, ($result.DebFiles.Count)) -Console
    }
    Write-Log ("[DebPkg][DL] Completed per-package download attempts; total .deb files now: {0}" -f ($result.DebFiles.Count)) -Console
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
