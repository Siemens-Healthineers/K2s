# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule   = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule  = "$PSScriptRoot\..\..\addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

$fluxVersion     = '2.8.1'
$fluxExeRelPath  = 'bin\flux.exe'
$fluxZipName     = "flux_${fluxVersion}_windows_amd64.zip"
$fluxDownloadUrl = "https://github.com/fluxcd/flux2/releases/download/v${fluxVersion}/${fluxZipName}"

function Get-FluxConfig {
    <#
    .SYNOPSIS
    Return path to the flux-system manifests for this addon.
    .OUTPUTS
    System.String
    #>
    return (Join-Path $PSScriptRoot 'manifests\flux-system')
}

# Private: resolve a K2s-root-relative path and guard against path traversal.
function Resolve-K2sPath([string]$RelPath) {
    $root  = [IO.Path]::GetFullPath((Get-ClusterInstalledFolder))
    $rootS = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full  = [IO.Path]::GetFullPath((Join-Path $rootS $RelPath))
    if (-not $full.StartsWith($rootS, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$RelPath' resolves outside K2s root '$root'."
    }
    return $full
}

function Install-FluxCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string] $Proxy,

        [Parameter(Mandatory = $false)]
        [switch] $AllowOnlineDownload
    )

    $dest = Resolve-K2sPath $fluxExeRelPath

    # Tier 1: already installed at destination — nothing to do
    if (Test-Path -LiteralPath $dest) {
        Write-Log "Flux CLI already present at '$dest'." -Console
        return
    }

    # Tier 2: online download (dev / online environments)
    if (-not $AllowOnlineDownload) {
        throw "Flux CLI not available at '$dest' and online download is not allowed."
    }

    Write-Log "Downloading Flux CLI v$fluxVersion from GitHub..." -Console
    if (Get-Command -Name Start-Phase -ErrorAction SilentlyContinue) { Start-Phase "FluxCliOnlineInstall" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("k2s-flux-{0}" -f [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $tmpZip = Join-Path $tmp $fluxZipName

        Invoke-DownloadFile $tmpZip $fluxDownloadUrl $true -ProxyToUse $Proxy
        Write-Log 'Download complete. Extracting...'

        if (Get-Command -Name Expand-ZipWithProgress -ErrorAction SilentlyContinue) {
            Expand-ZipWithProgress -ZipPath $tmpZip -Destination $tmp
        }
        else {
            Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmp -Force
        }

        $exe = Get-ChildItem -Path $tmp -Filter 'flux.exe' -Recurse -File | Select-Object -First 1
        if (-not $exe) { throw "flux.exe not found in '$fluxZipName'." }

        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

        Copy-Item -LiteralPath $exe.FullName -Destination $dest -Force
        Write-Log "Flux CLI v$fluxVersion installed to '$dest'." -Console
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -Recurse -ErrorAction SilentlyContinue
        if (Get-Command -Name Stop-Phase -ErrorAction SilentlyContinue) { Stop-Phase "FluxCliOnlineInstall" }
    }
}

function Remove-FluxCli {
    [CmdletBinding()]
    param()

    $dest   = Resolve-K2sPath $fluxExeRelPath

    if (-not (Test-Path -LiteralPath $dest)) {
        Write-Log "Flux CLI not present at '$dest'. Nothing to remove." -Console
        return
    }

    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    Write-Log "Flux CLI removed from '$dest'." -Console
}

Export-ModuleMember -Function Get-FluxConfig, Install-FluxCli, Remove-FluxCli
