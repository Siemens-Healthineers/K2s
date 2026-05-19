<#
.SYNOPSIS
    Installs RTK (Rust Token Killer) for the K2s PoC evaluation.

.DESCRIPTION
    Downloads and installs RTK binary, creates configuration directories,
    and verifies the installation. Designed for Windows native development.

.NOTES
    SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
    SPDX-License-Identifier: MIT
#>

[CmdletBinding()]
param(
    [string]$Version = "0.34.3",
    [string]$InstallDir = "$env:USERPROFILE\.local\bin",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ── Constants ──
$RtkReleasesUrl = "https://github.com/rtk-ai/rtk/releases/download/v$Version"
$BinaryName = "rtk.exe"
$ZipName = "rtk-x86_64-pc-windows-msvc.zip"
$ConfigDir = "$env:APPDATA\rtk"

Write-Host "[RTK-PoC] Installing RTK v$Version for K2s PoC evaluation" -ForegroundColor Cyan
Write-Host ""

# ── Pre-flight checks ──
if ((Get-Command rtk -ErrorAction SilentlyContinue) -and -not $Force) {
    $existing = & rtk --version 2>&1
    Write-Host "[RTK-PoC] RTK already installed: $existing" -ForegroundColor Yellow
    Write-Host "[RTK-PoC] Use -Force to reinstall" -ForegroundColor Yellow
    return
}

# ── Create install directory ──
if (-not (Test-Path $InstallDir)) {
    Write-Host "[RTK-PoC] Creating install directory: $InstallDir"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

# ── Download ──
$zipPath = Join-Path $env:TEMP $ZipName
Write-Host "[RTK-PoC] Downloading RTK v$Version..."
try {
    Invoke-WebRequest -Uri "$RtkReleasesUrl/$ZipName" -OutFile $zipPath -UseBasicParsing
    Write-Host "[RTK-PoC] Downloaded: $zipPath" -ForegroundColor Green
}
catch {
    Write-Host "[RTK-PoC] ERROR: Failed to download RTK" -ForegroundColor Red
    Write-Host "[RTK-PoC] Manual download: https://github.com/rtk-ai/rtk/releases" -ForegroundColor Yellow
    Write-Host "[RTK-PoC] Place rtk.exe in: $InstallDir" -ForegroundColor Yellow
    throw
}

# ── Extract ──
Write-Host "[RTK-PoC] Extracting..."
$extractDir = Join-Path $env:TEMP "rtk-extract"
if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

$rtkExe = Get-ChildItem -Path $extractDir -Filter "rtk.exe" -Recurse | Select-Object -First 1
if (-not $rtkExe) {
    throw "[RTK-PoC] ERROR: rtk.exe not found in archive"
}

Copy-Item -Path $rtkExe.FullName -Destination (Join-Path $InstallDir $BinaryName) -Force
Write-Host "[RTK-PoC] Installed to: $InstallDir\$BinaryName" -ForegroundColor Green

# ── Cleanup ──
Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue

# ── PATH check ──
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$InstallDir*") {
    Write-Host "[RTK-PoC] Adding $InstallDir to user PATH..."
    [Environment]::SetEnvironmentVariable("PATH", "$InstallDir;$currentPath", "User")
    $env:PATH = "$InstallDir;$env:PATH"
    Write-Host "[RTK-PoC] PATH updated (restart terminal for full effect)" -ForegroundColor Yellow
}

# ── Create config directory ──
if (-not (Test-Path $ConfigDir)) {
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
}

# ── Create user-global config ──
$configFile = Join-Path $ConfigDir "config.toml"
if (-not (Test-Path $configFile)) {
    $configContent = @"
# RTK configuration for K2s PoC
# Docs: https://github.com/rtk-ai/rtk#configuration

[hooks]
# Commands to skip rewriting (passthrough unchanged)
exclude_commands = []

[tee]
# Save raw output on command failures for debugging
enabled = true
mode = "failures"    # "failures", "always", or "never"
"@
    Set-Content -Path $configFile -Value $configContent -Encoding UTF8
    Write-Host "[RTK-PoC] Created config: $configFile"
}

# ── Verify installation ──
Write-Host ""
Write-Host "[RTK-PoC] Verifying installation..." -ForegroundColor Cyan
try {
    $version = & "$InstallDir\$BinaryName" --version 2>&1
    Write-Host "[RTK-PoC] ✓ RTK installed successfully: $version" -ForegroundColor Green
}
catch {
    Write-Host "[RTK-PoC] ✗ Installation verification failed" -ForegroundColor Red
    throw
}

# ── Summary ──
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " RTK PoC Installation Complete" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host " Binary:    $InstallDir\$BinaryName"
Write-Host " Config:    $configFile"
Write-Host " Filters:   $(Resolve-Path "$PSScriptRoot\..\..\..\.rtk\filters.toml" -ErrorAction SilentlyContinue)"
Write-Host " Tracking:  $env:APPDATA\rtk\tracking.db (created on first use)"
Write-Host ""
Write-Host " Usage:"
Write-Host "   rtk go test ./k2s/...    # Go tests with 90% token reduction"
Write-Host "   rtk git status           # Compact git status"
Write-Host "   rtk kubectl pods         # Problem-focused pod list"
Write-Host "   rtk gain                 # View token savings"
Write-Host ""
Write-Host " Disable:  `$env:RTK_DISABLED = '1'"
Write-Host " Raw mode: rtk -vvv <command>"
Write-Host " Bypass:   Run command without rtk prefix"
Write-Host ""

