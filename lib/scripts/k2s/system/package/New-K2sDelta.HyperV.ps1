# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

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
    $created = $false; $attempt = 0; $baseName = $SwitchName
    while (-not $created -and $attempt -lt 3) {
        try {
            New-VMSwitch -Name $SwitchName -SwitchType Internal -ErrorAction Stop | Out-Null
            $created = $true
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match '0x800700B7' -or $msg -match 'already exists') {
                Write-Log ("[DebPkg][Warning] Switch name collision or miniport reuse detected for '{0}' (attempt {1}): {2}" -f $SwitchName, ($attempt+1), $msg) -Console
                $SwitchName = "$baseName-$([guid]::NewGuid().ToString('N').Substring(0,6))"
                Write-Log ("[DebPkg] Retrying with alternate switch name '{0}'" -f $SwitchName) -Console
            } else { throw }
        }
        $attempt++
    }
    if (-not $created) { throw "Failed to create VMSwitch after retries (last name '$SwitchName')" }
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
    Write-Log ("[DebPkg] Creating temporary VM '{0}' attached to '{1}' from path '{2}'" -f $VmName, $SwitchName, $VhdxPath) -Console
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
        if ($PlinkHostKey) {
            $testArgs += @('-hostkey', $PlinkHostKey)
         }
        if ($SshKey) { $testArgs += @('-i', $SshKey) } elseif ($SshPassword) { $testArgs += @('-pw', $SshPassword) }
        $testArgs += ("$SshUser@$GuestIp")
    } else {
        $testArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null',"$SshUser@$GuestIp")
        if ($SshKey) { $testArgs += @('-i', $SshKey) }
    }
    $testArgs += $testCmd
    $testOutput = & $SshClient @testArgs 2>&1
    $hasVersion = $false; $errorUnknown = $false
    foreach ($line in $testOutput) { if ($line -match 'dpkg-query ') { $hasVersion = $true }; if ($line -match 'unknown option') { $errorUnknown = $true } }
    if ($UsingPlink -and ($testOutput -match 'POTENTIAL SECURITY BREACH')) { return [pscustomobject]@{ Ok=$false; HostKeyMismatch=$true; Output=$testOutput } }
    $ok = ($hasVersion -and -not $errorUnknown)
    if ($ok) {
        $firstLine = ($testOutput | Where-Object { $_ -match 'dpkg-query ' } | Select-Object -First 1)
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

<#
.SYNOPSIS
Executes a command in the guest VM via SSH.

.PARAMETER VmName
Name of the VM.

.PARAMETER Command
Command to execute.

.PARAMETER Timeout
Timeout in seconds (default: 30).

.OUTPUTS
Hashtable with Success flag, Output, ExitCode, and ErrorMessage.
#>
function Invoke-K2sGuestCmd {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        
        [Parameter(Mandatory = $true)]
        [string]$Command,
        
        [Parameter(Mandatory = $false)]
        [int]$Timeout = 30
    )
    
    $result = @{
        Success      = $false
        Output       = $null
        ExitCode     = -1
        ErrorMessage = ''
    }
    
    try {
        # Get VM context
        $vm = Get-VM -Name $VmName -ErrorAction Stop
        if ($vm.State -ne 'Running') {
            $result.ErrorMessage = "VM is not running (State: $($vm.State))"
            return $result
        }
        
        # Get IP address
        $guestIp = Wait-K2sHvGuestIp -VmName $VmName
        if (-not $guestIp) {
            $result.ErrorMessage = "Failed to get VM IP address"
            return $result
        }
        
        # Get SSH client
        $sshClientInfo = Get-K2sHvSshClient
        $sshClient = $sshClientInfo.Path
        $usingPlink = $sshClientInfo.IsPlink
        
        # SSH credentials (hardcoded for K2s VMs)
        $sshUser = 'remote'
        $sshPwd = 'admin'
        
        # Build SSH args
        if ($usingPlink) {
            $plinkHostKey = Get-K2sPlinkHostKey -GuestIp $guestIp -SshClient $sshClient -SshUser $sshUser -SshPassword $sshPwd
            $sshArgs = @('-batch','-noagent','-P','22')
            if ($plinkHostKey) {
                $sshArgs += @('-hostkey', $plinkHostKey)
            }
            $sshArgs += @('-pw', $sshPwd)
            $sshArgs += ("$sshUser@$guestIp")
            $sshArgs += $Command
        } else {
            $sshArgs = @('-p','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null',"$sshUser@$guestIp")
            $sshArgs += $Command
        }
        
        # Execute command with timeout
        $job = Start-Job -ScriptBlock {
            param($sshClient, $sshArgs)
            & $sshClient @sshArgs 2>&1
        } -ArgumentList $sshClient, $sshArgs
        
        $completed = Wait-Job -Job $job -Timeout $Timeout
        if ($completed) {
            $result.Output = Receive-Job -Job $job
            $result.ExitCode = $job.JobStateInfo.Reason.ExitCode
            if ($null -eq $result.ExitCode) { $result.ExitCode = 0 }
            $result.Success = $true
        } else {
            Stop-Job -Job $job
            $result.ErrorMessage = "Command timed out after $Timeout seconds"
        }
        
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        
    } catch {
        $result.ErrorMessage = "Exception: $($_.Exception.Message)"
    }
    
    return $result
}

<#
.SYNOPSIS
Copies a file from the guest VM to the host.

.PARAMETER VmName
Name of the VM.

.PARAMETER RemotePath
Path in the guest.

.PARAMETER LocalPath
Destination path on the host.

.OUTPUTS
Hashtable with Success flag and ErrorMessage.
#>
function Copy-K2sGuestFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,
        
        [Parameter(Mandatory = $true)]
        [string]$RemotePath,
        
        [Parameter(Mandatory = $true)]
        [string]$LocalPath
    )
    
    $result = @{
        Success      = $false
        ErrorMessage = ''
    }
    
    try {
        # Get VM context
        $vm = Get-VM -Name $VmName -ErrorAction Stop
        if ($vm.State -ne 'Running') {
            $result.ErrorMessage = "VM is not running (State: $($vm.State))"
            return $result
        }
        
        # Get IP address
        $guestIp = Wait-K2sHvGuestIp -VmName $VmName
        if (-not $guestIp) {
            $result.ErrorMessage = "Failed to get VM IP address"
            return $result
        }
        
        # SSH credentials
        $sshUser = 'remote'
        $sshPwd = 'admin'
        
        # Use pscp (PuTTY's scp) if available, otherwise scp
        $pscpPath = Join-Path $PSScriptRoot '..\..\..\..\bin\pscp.exe'
        if (Test-Path $pscpPath) {
            $plinkPath = Join-Path $PSScriptRoot '..\..\..\..\bin\plink.exe'
            $plinkHostKey = Get-K2sPlinkHostKey -GuestIp $guestIp -SshClient $plinkPath -SshUser $sshUser -SshPassword $sshPwd
            
            $scpArgs = @('-batch','-P','22')
            if ($plinkHostKey) {
                $scpArgs += @('-hostkey', $plinkHostKey)
            }
            $scpArgs += @('-pw', $sshPwd)
            $scpArgs += "$sshUser@${guestIp}:$RemotePath"
            $scpArgs += $LocalPath
            
            $scpOutput = & $pscpPath @scpArgs 2>&1
        } else {
            # Fallback to scp
            $scpArgs = @('-P','22','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null')
            $scpArgs += "$sshUser@${guestIp}:$RemotePath"
            $scpArgs += $LocalPath
            
            $scpOutput = & scp @scpArgs 2>&1
        }
        
        if ($LASTEXITCODE -eq 0 -and (Test-Path $LocalPath)) {
            $result.Success = $true
        } else {
            $result.ErrorMessage = "Copy failed with exit code $LASTEXITCODE. Output: $($scpOutput -join ' ')"
        }
        
    } catch {
        $result.ErrorMessage = "Exception: $($_.Exception.Message)"
    }
    
    return $result
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
        [switch] $DownloadDebs,
        [switch] $AllowPartialAcquisition,
        [switch] $QueryBuildahImages,
        [switch] $KeepVmAlive
    )
    $result = [pscustomobject]@{ Packages=$null; Error=$null; Method='hyperv-ssh'; DownloadedDebs=@(); Resolutions=@(); BuildahImages=@(); VmContext=$null }
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
        # Network (capture object in case switch name was auto-adjusted due to collision)
        $netCtx = New-K2sHvNetwork -SwitchName $switchName -NatName $natName -HostSwitchIp $hostSwitchIp -NetworkPrefix $networkPrefix -PrefixLen $prefixLen
        if ($netCtx.SwitchName -ne $switchName) {
            Write-Log ("[DebPkg] Switch name adjusted to '{0}' after collision handling" -f $netCtx.SwitchName) -Console
            $switchName = $netCtx.SwitchName
            $ctx.SwitchName = $switchName
        }
        # VM
        New-K2sHvTempVm -VmName $vmName -VhdxPath $VhdxPath -SwitchName $switchName
        $ctx.CreatedVm = $true
        # Wait IP
        if (-not (Wait-K2sHvGuestIp -Ip $guestIp -TimeoutSeconds 180)) { throw "Guest IP $guestIp not reachable within timeout" }
        Write-Log ("[DebPkg] Guest reachable at {0}" -f $guestIp) -Console
        # SSH client
        $sshInfo = Get-K2sHvSshClient -NewExtract $NewExtract -OldExtract $OldExtract
        $sshClient = $sshInfo.Path; $usingPlink = $sshInfo.UsingPlink; $plinkHostKey = $null

        Write-Log ("[DebPkg] Wait 1 minute until the SSH server is running") -Console
        Start-Sleep -Seconds 60

        # wait on console for user input (just for now for debugging)
        # Read-Host "Press Enter to continue after verifying SSH server is running"

        # SSH login test
        # Poll SSH login with dpkg self-test (every 10s up to 120s) - VM needs time to fully boot  
        Write-Log "[DebPkg] Polling SSH login readiness (polling every 10s, timeout 120s)..." -Console
        $loginReadyDeadline = (Get-Date).AddSeconds(120)
        $dpkgTest = $null
        $loginSucceeded = $false
        while ((Get-Date) -lt $loginReadyDeadline) {         
            if ($usingPlink) { $plinkHostKey = Get-K2sPlinkHostKey -SshClient $sshClient -SshUser $sshUser -GuestIp $guestIp }
            $dpkgTest = Test-K2sDpkgQuery -SshClient $sshClient -UsingPlink:$usingPlink -PlinkHostKey $plinkHostKey -SshUser $sshUser -GuestIp $guestIp -SshKey '' -SshPassword $sshPwd
            if ($dpkgTest.HostKeyMismatch) { 
                $result.Error = 'Host key mismatch detected (plink security warning). Provide correct fingerprint or clear cached host key.'
                return $result 
            }
            if ($dpkgTest.Ok) { 
                $loginSucceeded = $true
                Write-Log "[DebPkg] SSH login successful with password, dpkg-query available" -Console
                break 
            }
            $sampleOutput = ($dpkgTest.Output | Select-Object -First 3) -join ' | '
            # Retry on transient SSH/auth errors that will resolve as VM boots
            if ($sampleOutput -match 'Permission denied' -or 
                $sampleOutput -match 'Connection refused' -or 
                $sampleOutput -match 'Connection timed out' -or
                $sampleOutput -match 'No supported authentication methods' -or
                $sampleOutput -match 'server sent: publickey') {
                # SSH not ready yet during boot, wait and retry
                Write-Log "[DebPkg] SSH not ready yet (will retry): $sampleOutput" -Console
                Start-Sleep -Seconds 10
            } else {
                # Non-SSH/non-timeout error; break early as it won't resolve with waiting
                Write-Log ("[DebPkg][Warning] Unexpected error during SSH test: {0}" -f $sampleOutput) -Console
                break
            }
        }
        if (-not $loginSucceeded) {
            $sampleOutput = ($dpkgTest.Output | Select-Object -First 3) -join ' | '
            $authMethod = "password authentication"
            if ($sampleOutput -match 'Permission denied' -or $sampleOutput -match 'authentication') {
                $result.Error = "SSH $authMethod failed after 120s. Diagnostic output: $sampleOutput"
                return $result
            } else {
                $result.Error = "SSH login not ready within 120s timeout. Diagnostic output: $sampleOutput"
                return $result
            }
        }
        
        # Query packages (use the auth method that worked)
        $pkgMap = Get-K2sDpkgPackageMap -SshClient $sshClient -UsingPlink:$usingPlink -PlinkHostKey $plinkHostKey -SshUser $sshUser -GuestIp $guestIp -SshKey $sshKey -SshPassword $sshPwd
        $result.Packages = $pkgMap

        # Query buildah images (optional)
        if ($QueryBuildahImages) {
            Write-Log '[ImageDiff] Querying buildah images from VM...' -Console
            # Use single quotes and escape for proper shell passing
            $buildahCmd = "sudo buildah images --format '{{.Name}}:{{.Tag}}|{{.ID}}|{{.Size}}'"
            
            if ($usingPlink) {
                Write-Log "[ImageDiff] Executing via plink: $sshUser@$guestIp" -Console
                # Build plink args array the same way as dpkg query
                $plinkArgs = @('-batch', '-noagent', '-P', '22')
                if ($plinkHostKey) { $plinkArgs += @('-hostkey', $plinkHostKey) }
                if ($sshKey) { $plinkArgs += @('-i', $sshKey) } elseif ($sshPwd) { $plinkArgs += @('-pw', $sshPwd) }
                $plinkArgs += ("$sshUser@$guestIp")
                $buildahOut = & $sshClient @($plinkArgs + $buildahCmd) 2>&1
            } else {
                Write-Log "[ImageDiff] Executing via ssh: $sshUser@$guestIp" -Console
                $sshArgs = @('-p', '22', '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null')
                if ($sshKey) { $sshArgs += @('-i', $sshKey) }
                $sshArgs += ("$sshUser@$guestIp")
                $buildahOut = & $sshClient @($sshArgs + $buildahCmd) 2>&1
            }
            
            Write-Log "[ImageDiff] Buildah command exit code: $LASTEXITCODE" -Console
            
            if ($buildahOut -and $buildahOut.Count -gt 0) {
                Write-Log "[ImageDiff] Buildah returned $($buildahOut.Count) lines of output" -Console
                $outputSample = ($buildahOut | Select-Object -First 3) -join ' | '
                Write-Log "[ImageDiff] Output sample: $outputSample" -Console
            } else {
                Write-Log "[ImageDiff] Buildah output is empty" -Console
            }
            
            if ($LASTEXITCODE -eq 0) {
                if (-not $buildahOut -or $buildahOut.Count -eq 0) {
                    Write-Log "[ImageDiff] Exit code 0 but no output - checking buildah store..." -Console
                    
                    # Try simple buildah images command without format
                    $simpleCmd = "sudo buildah images"
                    if ($usingPlink) {
                        $simpleOut = & $sshClient @($plinkArgs[0..($plinkArgs.Count-2)] + $simpleCmd) 2>&1
                    } else {
                        $simpleOut = & $sshClient @($sshArgs + $simpleCmd) 2>&1
                    }
                    Write-Log "[ImageDiff] Simple 'sudo buildah images' output (exit=$LASTEXITCODE): $($simpleOut -join ' | ')" -Console
                    
                    # Check if buildah is using root vs user store
                    $storeCmd = "ls -la ~/.local/share/containers/storage/overlay-images 2>&1 || echo 'User store not found'; sudo ls -la /var/lib/containers/storage/overlay-images 2>&1 || echo 'Root store not found'"
                    if ($usingPlink) {
                        $storeOut = & $sshClient @($plinkArgs[0..($plinkArgs.Count-2)] + $storeCmd) 2>&1
                    } else {
                        $storeOut = & $sshClient @($sshArgs + $storeCmd) 2>&1
                    }
                    Write-Log "[ImageDiff] Buildah storage check: $($storeOut -join ' | ')" -Console
                    
                    $result.BuildahImages = @()
                } else {
                    $images = @()
                    foreach ($line in $buildahOut) {
                        if ([string]::IsNullOrWhiteSpace($line)) { continue }
                        if ($line -match '^(.+?)\|(.+?)\|(.+?)$') {
                            $images += [PSCustomObject]@{
                                FullName = $matches[1]
                                ImageId  = $matches[2]
                                Size     = $matches[3]
                            }
                        }
                    }
                    $result.BuildahImages = $images
                    Write-Log "[ImageDiff] Successfully parsed $($images.Count) buildah images from VM" -Console
                }
            } else {
                Write-Log "[ImageDiff] Warning: buildah query failed (exit=$LASTEXITCODE)" -Console
                if ($buildahOut) {
                    $errorSample = ($buildahOut | Select-Object -First 3) -join ' | '
                    Write-Log "[ImageDiff] Error output: $errorSample" -Console
                }
                $result.BuildahImages = @()
            }
        }

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
            $result.Resolutions = $acq.Resolutions
            if ($acq.Failures.Count -gt 0 -or $downloaded.Count -eq 0) {
                if ($AllowPartialAcquisition -and $downloaded.Count -gt 0) {
                    Write-Log ("[DebPkg][DL][Warning] Partial acquisition accepted (downloaded={0}, failures={1})" -f $downloaded.Count, ($acq.Failures -join ', ')) -Console
                } else {
                    throw "Offline deb acquisition incomplete (failures=${($acq.Failures -join '; ')}, downloaded=$($downloaded.Count))"
                }
            }
            $result.DownloadedDebs = $downloaded
        }
    } catch {
        $result.Error = "Hyper-V SSH extraction failed: $($_.Exception.Message)"
    } finally {
        if ($KeepVmAlive -and -not $result.Error) {
            Write-Log "[DebPkg] Keeping VM alive for reuse: $vmName" -Console
            $result.VmContext = $ctx
        } else {
            Remove-K2sHvEnvironment -Context $ctx
        }
    }
    return $result
}
