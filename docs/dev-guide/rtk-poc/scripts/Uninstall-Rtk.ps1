<#
.SYNOPSIS
    Uninstalls RTK and cleans up all PoC artifacts.

.DESCRIPTION
    Removes RTK binary, configuration, tracking database, and PATH entry.
    Complete rollback to pre-PoC state.

.NOTES
    SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
    SPDX-License-Identifier: MIT
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:USERPROFILE\.local\bin",
    [switch]$KeepData
)

$ErrorActionPreference = 'Stop'

Write-Host "[RTK-PoC] Uninstalling RTK..." -ForegroundColor Cyan
Write-Host ""

# ── Remove binary ──
$rtkPath = Join-Path $InstallDir "rtk.exe"
if (Test-Path $rtkPath) {
    Remove-Item -Path $rtkPath -Force
    Write-Host "[RTK-PoC] ✓ Removed binary: $rtkPath" -ForegroundColor Green
} else {
    Write-Host "[RTK-PoC] Binary not found at: $rtkPath" -ForegroundColor Yellow
}

# ── Remove config ──
$configDir = "$env:APPDATA\rtk"
if (Test-Path $configDir) {
    if ($KeepData) {
        # Keep tracking data, remove only config
        Remove-Item -Path (Join-Path $configDir "config.toml") -Force -ErrorAction SilentlyContinue
        Write-Host "[RTK-PoC] ✓ Removed config (kept tracking data)" -ForegroundColor Green
    } else {
        Remove-Item -Path $configDir -Recurse -Force
        Write-Host "[RTK-PoC] ✓ Removed config directory: $configDir" -ForegroundColor Green
    }
}

# ── Remove local data (SQLite, tee logs) ──
if (-not $KeepData) {
    $dataDir = "$env:LOCALAPPDATA\rtk"
    if (Test-Path $dataDir) {
        Remove-Item -Path $dataDir -Recurse -Force
        Write-Host "[RTK-PoC] ✓ Removed data directory: $dataDir" -ForegroundColor Green
    }
}

# ── Clean PATH ──
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -like "*$InstallDir*") {
    $newPath = ($currentPath -split ';' | Where-Object { $_ -ne $InstallDir }) -join ';'
    [Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
    Write-Host "[RTK-PoC] ✓ Removed $InstallDir from user PATH" -ForegroundColor Green
}

# ── Note about .rtk/filters.toml ──
Write-Host ""
Write-Host "[RTK-PoC] Note: .rtk/filters.toml in the K2s repo is NOT removed." -ForegroundColor Yellow
Write-Host "[RTK-PoC] It is inert without RTK installed (no side effects)." -ForegroundColor Yellow
Write-Host "[RTK-PoC] To remove: git rm .rtk/filters.toml" -ForegroundColor Yellow

Write-Host ""
Write-Host "[RTK-PoC] ✓ RTK uninstalled. No workflow changes required." -ForegroundColor Green
Write-Host "[RTK-PoC]   All commands work normally without the rtk prefix." -ForegroundColor Green

