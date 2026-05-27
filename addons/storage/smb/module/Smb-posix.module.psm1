# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

function Get-FstabVersionOption {
    param ([string]$SmbDialect = 'auto')
    if ($SmbDialect -eq 'auto' -or [string]::IsNullOrEmpty($SmbDialect)) { return '' }
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
    $ver = Get-FstabVersionOption -SmbDialect $Config.SmbDialect
    if ($ver) { $opts.Add($ver) | Out-Null }
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

Export-ModuleMember -Function Get-FstabVersionOption, Get-StorageClassMountOptions, Get-SambaSharePosixConfig
