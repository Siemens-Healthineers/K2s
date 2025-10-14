# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Phase timing & size formatting utilities for delta packaging

function Start-Phase {
    param(
        [Parameter(Mandatory)] [string] $Name
    )
    Write-Log "[Phase] $Name - start" -Console
    return [System.Diagnostics.Stopwatch]::StartNew()
}

function Stop-Phase {
    param(
        [string] $Name,
        $Stopwatch
    )
    if ($Stopwatch) {
        $Stopwatch.Stop()
        Write-Log ("[Phase] {0} - done in {1:N2}s" -f $Name, $Stopwatch.Elapsed.TotalSeconds) -Console
    }
}

function Format-Size {
    param(
        [uint64] $Bytes
    )
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    $kb = [double]$Bytes / 1KB
    if ($kb -lt 1024) { return ("{0:N2} KB" -f $kb) }
    $mb = $kb / 1024
    if ($mb -lt 1024) { return ("{0:N2} MB" -f $mb) }
    $gb = $mb / 1024
    if ($gb -lt 1024) { return ("{0:N2} GB" -f $gb) }
    $tb = $gb / 1024
    return ("{0:N2} TB" -f $tb)
}
