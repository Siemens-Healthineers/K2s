# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

# Import the leaf vm.module in THIS module's scope so Invoke-CmdOnControlPlaneViaSSHKey resolves (not the admin-gated node aggregator).
$vmModule = "$PSScriptRoot/../../../../lib/modules/k2s/k2s.node.module/linuxnode/vm/vm.module.psm1"
Import-Module $vmModule

# Default fstab SMB dialect (vers=) used when smbDialect is 'auto' or unset.
$script:DefaultSmbFstabDialect = '3.0'

function Get-FstabVersionOption {
    param ([string]$SmbDialect = 'auto')
    if ($SmbDialect -eq 'auto' -or [string]::IsNullOrEmpty($SmbDialect)) {
        return "vers=$script:DefaultSmbFstabDialect"
    }
    return "vers=$SmbDialect"
}

function Get-StorageClassMountOptions {
    param ([pscustomobject]$Config = $(throw 'Config not specified'))
    if ($Config.EnablePosixExtensions) {
        $opts = [System.Collections.ArrayList]@('dir_mode=0777','file_mode=0777','uid=1001','gid=1001','mfsymlinks','cache=strict','handletimeout=60000')
        if (-not $Config.UseServerInode) { $opts.Add('noserverino') | Out-Null }
    } else {
        $opts = [System.Collections.ArrayList]@('dir_mode=0777','file_mode=0777','uid=1001','gid=1001','noperm','mfsymlinks','cache=strict','noserverino')
    }
    # CSI driver negotiates version automatically; only pin vers= for a non-default dialect.
    if ($Config.SmbDialect -and $Config.SmbDialect -ne 'auto') {
        $opts.Add("vers=$($Config.SmbDialect)") | Out-Null
    }
    return $opts
}

function Get-SambaSharePosixConfig {
    param ([pscustomobject]$Config = $(throw 'Config not specified'))
    $lines = @()
    if ($Config.EnablePosixExtensions) {
        $lines += 'vfs objects = streams_xattr'
        $lines += 'store dos attributes = no'
    }
    return $lines
}

function Test-SambaPosixNegotiation {
    <#
    .SYNOPSIS
    Validates at runtime that the Samba host advertises the POSIX (streams_xattr) settings
    required for SMB 3.1.1 POSIX extensions on a configured share.
    .DESCRIPTION
    Runs testparm against the live smb.conf on the Linux control-plane host and verifies the
    given share section declares the streams_xattr vfs object and disables DOS attribute storage.
    Returns $true when both settings are present, otherwise $false. Intended as a warn-not-fail
    post-configuration check; callers log a warning on $false rather than aborting setup.
    #>
    param (
        [Parameter(Mandatory = $true)] [string]$ShareName,
        [int]$Timeout = 2,
        [int]$Retries = 1,
        [int]$RetryDelaySeconds = 3
    )
    $cmd = "sudo testparm -s --section-name '$ShareName' 2>/dev/null"
    # Bounded poll: smbd may have just restarted, so POSIX settings can take seconds to become serviceable.
    $attempt = 0
    while ($true) {
        $result = Invoke-CmdOnControlPlaneViaSSHKey -Timeout $Timeout -CmdToExecute $cmd
        $output = ($result.Output | Out-String)
        if ([string]::IsNullOrWhiteSpace($output)) {
            # Fall back to dumping the whole config if the section query returned nothing.
            $result = Invoke-CmdOnControlPlaneViaSSHKey -Timeout $Timeout -CmdToExecute "sudo testparm -s 2>/dev/null"
            $output = ($result.Output | Out-String)
        }
        $hasStreams = $output -match 'streams_xattr'
        $hasNoDosAttr = $output -match 'store dos attributes\s*=\s*[Nn]o'
        if ($hasStreams -and $hasNoDosAttr) {
            return $true
        }
        $attempt++
        if ($attempt -ge $Retries) {
            return $false
        }
        Start-Sleep -Seconds $RetryDelaySeconds
    }
}
Export-ModuleMember -Function Get-FstabVersionOption, Get-StorageClassMountOptions, Get-SambaSharePosixConfig, Test-SambaPosixNegotiation -Variable DefaultSmbFstabDialect
