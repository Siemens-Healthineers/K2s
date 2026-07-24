# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# File hashing utilities

function Get-Sha256HexLower {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LiteralPath
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($LiteralPath)
        try {
            $hashBytes = $sha256.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha256.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant())
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
        # Evidence: this script previously used SHA256 at this call site; keep SHA256 and lowercase hex output.
        try { $hash = Get-Sha256HexLower -LiteralPath $f.FullName } catch { Write-Log "[Warning] Hash failed for '$($f.FullName)': $($_.Exception.Message)"; $hash = '' }
        $map[$rel] = [pscustomobject]@{ Hash = $hash; Sha256 = $hash; Size = $f.Length }
        if ($ShowLogs) {
            $pct = [int](($i+1) * 100 / $total)
            if ($pct -ne $lastPct -and (($pct % 5) -eq 0 -or $pct -eq 100)) { Write-Progress -Activity "Hashing $label" -Status "$(($i+1)) / $total files" -PercentComplete $pct; $lastPct = $pct }
        }
    }
    if ($ShowLogs) { Write-Progress -Activity "Hashing $label" -Completed }
    Write-Log "[Hash] Completed hashing of $total files in '$label'" -Console
    return $map
}
