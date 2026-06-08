# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

# Default SMB protocol version for fstab mounts. Used when smbDialect is 'auto' or unset.
# Change this single value to update the default across all mount points.
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
    # Only add explicit vers= to StorageClass when user specifies a non-default dialect.
    # The CSI driver negotiates version automatically; fstab mounts use Get-FstabVersionOption separately.
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

Export-ModuleMember -Function Get-FstabVersionOption, Get-StorageClassMountOptions, Get-SambaSharePosixConfig -Variable DefaultSmbFstabDialect
