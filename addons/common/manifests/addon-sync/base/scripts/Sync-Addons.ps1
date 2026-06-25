# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
Syncs addons from an OCI registry to the K2s addons directory on the Windows host.

.DESCRIPTION
This script runs inside a HostProcess container on the Windows node. It discovers
per-addon OCI repositories at <RegistryUrl>/addons/<name>, checks per-addon digests,
and pulls only changed addon artifacts using oras. For each pulled artifact it
extracts layers 0-3 (config, manifests, helm charts, scripts) into the K2s addons
directory.

Registry layout expected by this script:
  <registry>/addons/monitoring:<version>   one OCI artifact per addon
  <registry>/addons/security:<version>
  <registry>/addons/<name>:<version>       ...

Image layers (4/5) and package layers (6) are intentionally skipped - in the GitOps
flow, container images are pulled directly from the registry at enable time.

After extraction, addons appear in `k2s addons ls` and can be enabled normally via
`k2s addons enable <addon>`.

This script replicates the layer-processing logic of Import.ps1 but operates:
- Without a .oci.tar file (pulls directly from registry via oras)
- Without image/package import (layers 4-6 skipped)
- Inside a HostProcess container (direct Windows host filesystem access)
#>

Param(
    [Parameter(Mandatory = $true, HelpMessage = 'OCI base registry URL without /addons suffix (e.g., oci://k2s.registry.local:30500)')]
    [string]$RegistryUrl,

    [Parameter(Mandatory = $true, HelpMessage = 'K2s installation directory on the Windows host')]
    [string]$K2sInstallDir,

    [Parameter(Mandatory = $false, HelpMessage = 'Path to oras executable')]
    [string]$OrasExe = 'oras',

    [Parameter(Mandatory = $false, HelpMessage = 'Allow insecure (HTTP) registry connections')]
    [string]$Insecure = 'false',

    [Parameter(Mandatory = $false, HelpMessage = 'Check registry digest before pulling; skip sync if unchanged')]
    [string]$CheckDigest = 'false',

    [Parameter(Mandatory = $false, HelpMessage = 'Sync only a specific addon by name; if empty, discovers all addons via oras repo ls')]
    [string]$AddonName = '',

    [Parameter(Mandatory = $false, HelpMessage = 'If true, also runs Update.ps1 for addons that are currently enabled after each sync')]
    [string]$ApplyIfEnabled = 'false'
)

$ErrorActionPreference = 'Stop'

# Convert string parameters to booleans (Kubernetes env substitution passes strings like "true"/"false")
$InsecureBool = $Insecure -eq 'true' -or $Insecure -eq '$true' -or $Insecure -eq '1'
$CheckDigestBool = $CheckDigest -eq 'true' -or $CheckDigest -eq '$true' -or $CheckDigest -eq '1'
$ApplyIfEnabledBool = $ApplyIfEnabled -eq 'true' -or $ApplyIfEnabled -eq '$true' -or $ApplyIfEnabled -eq '1'

# Resolve oras executable path - only allow controlled fallback to K2s bin directory
if (-not (Test-Path $OrasExe)) {
    # Try controlled fallback location: $K2sInstallDir/bin/oras.exe
    $controlledOrasPath = Join-Path -Path $K2sInstallDir -ChildPath 'bin' | Join-Path -ChildPath 'oras.exe'
    if (Test-Path $controlledOrasPath) {
        $OrasExe = $controlledOrasPath
    } else {
        # Fail explicitly rather than falling back to unchecked PATH lookup (PATH hijacking prevention)
        throw "oras executable not found at '$OrasExe' and not available in controlled location '$controlledOrasPath'. Please provide a valid oras executable path or ensure oras.exe exists in K2s bin directory."
    }
}

# ---------------------------------------------------------------------------
# Logging helper - Write-Log may not be available inside the container, so we
# provide a lightweight fallback that writes timestamped lines to stdout.
# ---------------------------------------------------------------------------
function Write-SyncLog {
    param(
        [string]$Message,
        [switch]$IsError,
        [switch]$Warning
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = '[AddonSync]'
    if ($IsError)   { $prefix = '[AddonSync][ERROR]' }
    if ($Warning) { $prefix = '[AddonSync][WARN]' }
    # Write-Host is intentional: this script runs inside a HostProcess container where
    # k2s.infra.module (and Write-Log) are not available. Stdout is the only log channel.
    Write-Host "$ts $prefix $Message"
}

function Get-SanitizedRegistryUrl {
    param([string]$Url)

    if ($Url -match '@') {
        return $Url -replace '^.*@', '<credentials>@'
    }

    return $Url
}

# ---------------------------------------------------------------------------
# OCI helper functions - inlined from oci.module.psm1 so the script is
# self-contained and can run without importing PS modules from the host.
# ---------------------------------------------------------------------------

function Get-BlobPathByDigest {
    param(
        [Parameter(Mandatory)] [string]$BlobsDir,
        [Parameter(Mandatory)] [string]$Digest
    )
    if ($Digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw "Invalid digest format: $Digest"
    }
    $hash = $Digest -replace '^sha256:', ''
    $blobPath = Join-Path $BlobsDir $hash
    if (-not (Test-Path $blobPath)) {
        throw "Blob not found for digest: $Digest"
    }
    # Integrity check
    $computed = (Get-FileHash -Path $blobPath -Algorithm SHA256).Hash.ToLower()
    if ($computed -ne $hash) {
        throw "Blob integrity check failed for $Digest (computed sha256:$computed)"
    }
    return $blobPath
}

function Get-JsonBlobContent {
    param(
        [Parameter(Mandatory)] [string]$BlobsDir,
        [Parameter(Mandatory)] [string]$Digest
    )
    $path = Get-BlobPathByDigest -BlobsDir $BlobsDir -Digest $Digest
    return (Get-Content -Path $path -Raw | ConvertFrom-Json)
}

function Expand-TarGz {
    param(
        [Parameter(Mandatory)] [string]$Archive,
        [Parameter(Mandatory)] [string]$Destination
    )
    function Test-IsSafeTarEntryPath {
        param(
            [Parameter(Mandatory)] [string]$EntryPath,
            [Parameter(Mandatory)] [string]$DestinationRoot
        )

        if ([string]::IsNullOrWhiteSpace($EntryPath)) { return $false }

        $trimmed = $EntryPath.Trim()
        if ($trimmed.StartsWith('/') -or $trimmed.StartsWith('\\')) { return $false }
        if ($trimmed -match '^[A-Za-z]:') { return $false }

        $entrySegments = $trimmed -split '[\\/]'
        if ($entrySegments -contains '..') { return $false }

        $relative = $trimmed -replace '/', '\\'
        try {
            $candidatePath = [System.IO.Path]::GetFullPath((Join-Path $DestinationRoot $relative))
            $normalizedRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
            if (-not $normalizedRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
                $normalizedRoot += [System.IO.Path]::DirectorySeparatorChar
            }
            return $candidatePath.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
        } catch {
            return $false
        }
    }

    function Test-TarArchiveSafeForExtraction {
        param(
            [Parameter(Mandatory)] [string]$ArchivePath,
            [Parameter(Mandatory)] [string]$DestinationRoot
        )

        $listResult = & tar -tvzf $ArchivePath 2>&1
        if ($LASTEXITCODE -ne 0) { throw "tar list failed: $listResult" }

        foreach ($rawLine in $listResult) {
            $line = $rawLine.ToString()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            if ($line.Length -lt 1) { throw "Invalid tar entry metadata: '$line'" }
            $entryType = $line.Substring(0, 1)

            if ($entryType -eq 'l' -or $entryType -eq 'h') {
                throw "Unsafe tar entry type '$entryType' rejected (link entries are not allowed): $line"
            }

            # Parse common tar -tv output and validate the extracted path stays under destination.
            $entryMatch = [regex]::Match($line, '^[^\s]+\s+\d+\s+\S+\s+\S+\s+\d+\s+\w+\s+\d+\s+[\d:]+\s+(?<path>.+)$')
            if (-not $entryMatch.Success) {
                throw "Unable to parse tar entry metadata: $line"
            }

            $entryPath = $entryMatch.Groups['path'].Value
            if ($entryPath.Contains(' -> ')) {
                $entryPath = $entryPath.Split(@(' -> '), 2, [System.StringSplitOptions]::None)[0]
            }

            if (-not (Test-IsSafeTarEntryPath -EntryPath $entryPath -DestinationRoot $DestinationRoot)) {
                throw "Unsafe tar entry path rejected: $entryPath"
            }
        }
    }

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    Test-TarArchiveSafeForExtraction -ArchivePath $Archive -DestinationRoot $Destination

    $saved = Get-Location
    try {
        Set-Location $Destination
        $result = & tar -xzf $Archive 2>&1
        if ($LASTEXITCODE -ne 0) { throw "tar extract failed: $result" }
    } finally {
        Set-Location $saved
    }
}

function Get-KubeBinPath {
    # Mirrors the module function from k2s.infra.module\path\path.module.psm1:
    # returns <K2sInstallDir>\bin - the single authoritative bin path used across k2s.
    return Join-Path $K2sInstallDir 'bin'
}

function Get-YamlContent {
    <#
    .SYNOPSIS
    Parses a YAML file into a PowerShell object using yq (JSON round-trip).
    #>
    param([Parameter(Mandatory)] [string]$Path)

    $kubeBinPath = Get-KubeBinPath
    $yqExe = Join-Path $kubeBinPath 'windowsnode\yaml\yq.exe'
    if (Test-Path $yqExe) {
        $json = & $yqExe eval -o=json '.' $Path 2>&1
        if ($LASTEXITCODE -eq 0) {
            return ($json | Out-String | ConvertFrom-Json)
        }
    }

    # yq not available - return $null so callers can fall back to a plain copy.
    Write-SyncLog "yq.exe not found (tried $yqExe) - YAML merge unavailable" -Warning
    return $null
}

function Get-SemVerTag {
    param(
        [Parameter(Mandatory)] [string]$Tag
    )

    $match = [regex]::Match($Tag, '^[vV]?(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)$')
    if (-not $match.Success) {
        return $null
    }

    return [PSCustomObject]@{
        Tag = $Tag
        Major = [int]$match.Groups['major'].Value
        Minor = [int]$match.Groups['minor'].Value
        Patch = [int]$match.Groups['patch'].Value
    }
}

function Select-AddonTag {
    param(
        [Parameter(Mandatory)] [string]$AddonRepoName,
        [Parameter(Mandatory)] [string[]]$Tags
    )

    $normalizedTags = @(
        $Tags |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ -ne '' }
    )

    if ($normalizedTags.Count -eq 0) {
        return $null
    }

    $latestTag = $normalizedTags | Where-Object { $_ -ieq 'latest' } | Select-Object -First 1
    if ($latestTag) {
        Write-SyncLog "  [TagSelect] '$AddonRepoName': using 'latest' tag"
        return $latestTag
    }

    $semVerCandidates = @()
    foreach ($tag in $normalizedTags) {
        $parsed = Get-SemVerTag -Tag $tag
        if ($parsed) {
            $semVerCandidates += $parsed
        }
    }

    if ($semVerCandidates.Count -gt 0) {
        $selectedSemVer = $semVerCandidates |
            Sort-Object -Property @{ Expression = 'Major'; Descending = $true }, @{ Expression = 'Minor'; Descending = $true }, @{ Expression = 'Patch'; Descending = $true }, @{ Expression = 'Tag'; Descending = $true } |
            Select-Object -First 1
        Write-SyncLog "  [TagSelect] '$AddonRepoName': using semver-desc tag '$($selectedSemVer.Tag)'"
        return $selectedSemVer.Tag
    }

    $lexicalTag = $normalizedTags | Sort-Object -Descending | Select-Object -First 1
    Write-SyncLog "  [TagSelect] '$AddonRepoName': semver unavailable, using lexical-desc tag '$lexicalTag'"
    return $lexicalTag
}

function Test-HostAddonPresentForRepo {
    param(
        [Parameter(Mandatory)] [string]$AddonsDir,
        [Parameter(Mandatory)] [string]$RepoName
    )

    # Evidence: repository names are already validated with this token policy before
    # composing registry refs/paths in the main loop; reuse the same guard for host-path checks.
    if (-not (Test-IsValidAddonNameToken -Token $RepoName)) {
        return $false
    }

    function Test-HostAddonContentPresent {
        param([Parameter(Mandatory)] [string]$AddonPath)

        if (-not (Test-Path $AddonPath -PathType Container)) {
            return $false
        }

        if (Test-Path (Join-Path $AddonPath 'addon.manifest.yaml') -PathType Leaf) {
            return $true
        }

        if (Test-Path (Join-Path $AddonPath 'manifests') -PathType Container) {
            return $true
        }

        return (Get-ChildItem -Path $AddonPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null
    }

    $directPath = Join-Path $AddonsDir $RepoName
    if (Test-HostAddonContentPresent -AddonPath $directPath) {
        return $true
    }

    if ($RepoName -like '*-*') {
        $splitParts = $RepoName.Split('-', 2)
        if ($splitParts.Count -eq 2) {
            $splitPath = Join-Path (Join-Path $AddonsDir $splitParts[0]) $splitParts[1]
            if (Test-HostAddonContentPresent -AddonPath $splitPath) {
                return $true
            }
        }
    }

    return $false
}

# ===========================================================================
# Helper: Validate an OCI Image Layout directory and extract addon layers 0-3
# into the K2s addons directory. Mirrors Import.ps1 layer-processing logic.
# ===========================================================================
function Sync-AddonFromOciLayout {
    param(
        [Parameter(Mandatory)] [string]$OciLayoutDir,
        [Parameter(Mandatory)] [string]$AddonsDir
    )

    # Validate OCI Image Layout structure
    $ociLayoutPath = Join-Path $OciLayoutDir 'oci-layout'
    if (-not (Test-Path $ociLayoutPath)) { throw 'Invalid OCI artifact: oci-layout file not found' }
    $ociLayout = Get-Content $ociLayoutPath | ConvertFrom-Json
    if ($ociLayout.imageLayoutVersion -ne '1.0.0') {
        throw "Unsupported OCI layout version: $($ociLayout.imageLayoutVersion)"
    }

    $blobsDir = Join-Path $OciLayoutDir 'blobs\sha256'
    if (-not (Test-Path $blobsDir)) { throw 'Invalid OCI artifact: blobs/sha256 directory not found' }

    $indexPath = Join-Path $OciLayoutDir 'index.json'
    if (-not (Test-Path $indexPath)) { throw 'Invalid OCI artifact: index.json not found' }
    $index = Get-Content $indexPath -Raw | ConvertFrom-Json
    if ($index.schemaVersion -ne 2) {
        throw "Invalid OCI index: schemaVersion must be 2, got $($index.schemaVersion)"
    }

    # Enumerate addons from index
    # Index entries may lack addon annotations when coming via oras copy (registry round-trip);
    # in that case read the manifest blob directly to get vnd.k2s.addon.* annotations.
    $exportedAddons = @()
    foreach ($m in $index.manifests) {
        $addonName = $m.annotations.'vnd.k2s.addon.name'
        $addonImpl = $m.annotations.'vnd.k2s.addon.implementation'
        $addonVer  = $m.annotations.'org.opencontainers.image.version'

        if (-not $addonName) {
            $innerManifest = Get-JsonBlobContent -BlobsDir $blobsDir -Digest $m.digest
            if ($innerManifest.annotations) {
                $addonName = $innerManifest.annotations.'vnd.k2s.addon.name'
                $addonImpl = $innerManifest.annotations.'vnd.k2s.addon.implementation'
                $addonVer  = $innerManifest.annotations.'org.opencontainers.image.version'
            }
        }

        if (-not $addonName) {
            Write-SyncLog "  Skipping index entry $($m.digest) - no addon name annotation" -Warning
            continue
        }
        $exportedAddons += [PSCustomObject]@{ Name = $addonName; Implementation = $addonImpl; Version = $addonVer; Digest = $m.digest }
    }

    if ($exportedAddons.Count -eq 0) { throw 'No addons found in OCI artifact index' }

    function Test-IsValidPathToken {
        param([string]$Token)

        # Evidence: annotation values are composed into filesystem paths below in this function;
        # only allow a strict token character set to prevent path traversal/special path segments.
        return -not [string]::IsNullOrWhiteSpace($Token) -and ($Token -cmatch '^[a-z0-9][a-z0-9._-]*$')
    }

    function Test-IsContainedPath {
        param(
            [Parameter(Mandatory)] [string]$BaseRoot,
            [Parameter(Mandatory)] [string]$CandidatePath
        )

        function Normalize-PathForContainment {
            param([Parameter(Mandatory)] [string]$Path)

            $fullPath = [System.IO.Path]::GetFullPath($Path)
            $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
            $normalizedPath = $fullPath

            # Keep drive/volume root intact (e.g., C:\), but trim trailing separators elsewhere.
            while (
                $normalizedPath.Length -gt $pathRoot.Length -and
                ($normalizedPath.EndsWith([string][System.IO.Path]::DirectorySeparatorChar) -or
                 $normalizedPath.EndsWith([string][System.IO.Path]::AltDirectorySeparatorChar))
            ) {
                $normalizedPath = $normalizedPath.Substring(0, $normalizedPath.Length - 1)
            }

            return $normalizedPath
        }

        try {
            $normalizedRoot = Normalize-PathForContainment -Path $BaseRoot
            $normalizedCandidate = Normalize-PathForContainment -Path $CandidatePath

            # Evidence: single-implementation addons resolve implementationPath to the addon root
            # itself, so the containment check must accept exact path equality before descendant checks.
            if ($normalizedCandidate.Equals($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }

            if (-not $normalizedRoot.EndsWith([string][System.IO.Path]::DirectorySeparatorChar)) {
                $normalizedRoot += [System.IO.Path]::DirectorySeparatorChar
            }
            return $normalizedCandidate.StartsWith($normalizedRoot, [System.StringComparison]::OrdinalIgnoreCase)
        } catch {
            return $false
        }
    }

    foreach ($addon in $exportedAddons) {
        Write-SyncLog "  Processing addon: $($addon.Name)"
        $ociManifest = Get-JsonBlobContent -BlobsDir $blobsDir -Digest $addon.Digest

        # Determine destination paths - mirrors Import.ps1 logic.
        # Use the vnd.k2s.addon.implementation annotation directly (set by Export.ps1).
        # This is more reliable than parsing the addon name for a '-' separator:
        #   - single-impl: Name='monitoring', Implementation='monitoring'  → dest: addons\monitoring
        #   - multi-impl:  Name='ingress',    Implementation='nginx'        → dest: addons\ingress\nginx
        $baseAddonName = $addon.Name
        if (-not (Test-IsValidPathToken -Token $baseAddonName)) {
            throw "Invalid addon name annotation '$baseAddonName' for digest $($addon.Digest). Allowed pattern: ^[a-z0-9][a-z0-9._-]*$"
        }

        $implementationName = $null
        if ($addon.Implementation -and $addon.Implementation -ne $addon.Name) {
            if (-not (Test-IsValidPathToken -Token $addon.Implementation)) {
                throw "Invalid addon implementation annotation '$($addon.Implementation)' for addon '$baseAddonName'. Allowed pattern: ^[a-z0-9][a-z0-9._-]*$"
            }
            $implementationName = $addon.Implementation
        }

        $destinationPath = Join-Path $AddonsDir $baseAddonName
        if (-not (Test-IsContainedPath -BaseRoot $AddonsDir -CandidatePath $destinationPath)) {
            throw "Computed addon destination '$destinationPath' is outside addons root '$AddonsDir' for addon '$baseAddonName'"
        }

        $implementationPath = if ($implementationName) { Join-Path $destinationPath $implementationName } else { $destinationPath }
        if (-not (Test-IsContainedPath -BaseRoot $destinationPath -CandidatePath $implementationPath)) {
            throw "Computed implementation destination '$implementationPath' is outside addon root '$destinationPath' for addon '$baseAddonName'"
        }

        if (-not (Test-Path $destinationPath)) { New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null }
        if ($implementationName -and -not (Test-Path $implementationPath)) {
            New-Item -ItemType Directory -Path $implementationPath -Force | Out-Null
        }
        Write-SyncLog "    Destination: $implementationPath"

        $layerTmpDir = Join-Path $OciLayoutDir "layer-$($addon.Name)"
        New-Item -ItemType Directory -Path $layerTmpDir -Force | Out-Null

        foreach ($layer in $ociManifest.layers) {
            if ($layer.mediaType -eq 'application/vnd.oci.empty.v1+json') { continue }
            $blobPath = Get-BlobPathByDigest -BlobsDir $blobsDir -Digest $layer.digest

            switch -Wildcard ($layer.mediaType) {
                '*configfiles*' {
                    Write-SyncLog "    Extracting config files layer"
                    $tempConfigDir = Join-Path $layerTmpDir 'config'
                    New-Item -ItemType Directory -Path $tempConfigDir -Force | Out-Null
                    Expand-TarGz -Archive $blobPath -Destination $tempConfigDir; break
                }
                '*manifests*' {
                    Write-SyncLog "    Extracting manifests layer"
                    $manifestsDest = Join-Path $implementationPath 'manifests'
                    New-Item -ItemType Directory -Path $manifestsDest -Force | Out-Null
                    Expand-TarGz -Archive $blobPath -Destination $manifestsDest; break
                }
                '*helm.chart*' {
                    Write-SyncLog "    Extracting helm charts layer"
                    $chartsDest = Join-Path $implementationPath 'manifests\chart'
                    New-Item -ItemType Directory -Path $chartsDest -Force | Out-Null
                    Expand-TarGz -Archive $blobPath -Destination $chartsDest; break
                }
                '*scripts*' {
                    Write-SyncLog "    Extracting scripts layer"
                    Expand-TarGz -Archive $blobPath -Destination $implementationPath; break
                }
                '*image.layer*'    { Write-SyncLog "    Skipping Linux images layer (pulled from registry at enable time)"; break }
                '*images-windows*' { Write-SyncLog "    Skipping Windows images layer (pulled from registry at enable time)"; break }
                '*packages*'       { Write-SyncLog "    Skipping packages layer (not used in GitOps flow)"; break }
                default            { Write-SyncLog "    Skipping unknown layer type: $($layer.mediaType)" -Warning }
            }
        }

        # Handle addon.manifest.yaml from config layer (Layer 0)
        # Mirrors Import.ps1: merge for multi-impl addons; overwrite for single-impl.
        $tempConfigDir = Join-Path $layerTmpDir 'config'
        if (Test-Path $tempConfigDir) {
            $configManifestSrc = Join-Path $tempConfigDir 'addon.manifest.yaml'
            if (Test-Path $configManifestSrc) {
                $destManifestPath = Join-Path $destinationPath 'addon.manifest.yaml'
                if ($implementationName -and (Test-Path $destManifestPath)) {
                    Write-SyncLog "    Merging addon.manifest.yaml implementations"
                    $existingManifest = Get-YamlContent -Path $destManifestPath
                    $importedManifest = Get-YamlContent -Path $configManifestSrc
                    if ($existingManifest -and $importedManifest) {
                        $existingImplNames = @($existingManifest.spec.implementations | ForEach-Object { $_.name })
                        foreach ($impl in $importedManifest.spec.implementations) {
                            if ($impl.name -notin $existingImplNames) {
                                Write-SyncLog "      Adding new implementation: $($impl.name)"
                                $existingManifest.spec.implementations += $impl
                            } else {
                                Write-SyncLog "      Implementation '$($impl.name)' already exists, skipping"
                            }
                        }
                        $kubeBinPath = Get-KubeBinPath
                        $yqExe = Join-Path $kubeBinPath 'windowsnode\yaml\yq.exe'
                        if (Test-Path $yqExe) {
                            $originalContent = Get-Content -Path $destManifestPath -Raw -Encoding UTF8
                            $headerLines = @()
                            foreach ($line in ($originalContent -split "`r?`n")) {
                                if ($line.StartsWith('#') -or $line.Trim() -eq '') { $headerLines += $line } else { break }
                            }
                            $tempJson = New-TemporaryFile
                            try {
                                $existingManifest | ConvertTo-Json -Depth 100 | Set-Content -Path $tempJson.FullName -Encoding UTF8
                                $yamlOutput = & $yqExe eval -P '.' $tempJson.FullName
                                $yamlContent = if ($yamlOutput -is [array]) { $yamlOutput -join "`n" } else { $yamlOutput.ToString() }
                                [System.IO.File]::WriteAllText($destManifestPath, (($headerLines -join "`n") + "`n" + $yamlContent), [System.Text.UTF8Encoding]::new($false))
                                Write-SyncLog "    Merged manifest saved"
                            } finally { Remove-Item -Path $tempJson -Force -ErrorAction SilentlyContinue }
                        } else {
                            Write-SyncLog "    yq.exe not found, copying manifest as-is" -Warning
                            Copy-Item -Path $configManifestSrc -Destination $destManifestPath -Force
                        }
                    } else {
                        Write-SyncLog "    yq unavailable for merge, overwriting manifest from registry" -Warning
                        Copy-Item -Path $configManifestSrc -Destination $destManifestPath -Force
                    }
                } else {
                    Copy-Item -Path $configManifestSrc -Destination $destManifestPath -Force
                    Write-SyncLog "    Copied addon.manifest.yaml"
                }
                if ($implementationName) {
                    $strayManifest = Join-Path $implementationPath 'addon.manifest.yaml'
                    if (Test-Path $strayManifest) { Remove-Item -Path $strayManifest -Force }
                }
            }

            Get-ChildItem -Path $tempConfigDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'addon.manifest.yaml' } |
                ForEach-Object { Copy-Item -Path $_.FullName -Destination $implementationPath -Force; Write-SyncLog "    Copied config: $($_.Name)" }

            $configSubDir = Join-Path $tempConfigDir 'config'
            if (Test-Path $configSubDir) {
                $destConfigSub = Join-Path $implementationPath 'config'
                New-Item -ItemType Directory -Path $destConfigSub -Force | Out-Null
                Copy-Item -Path (Join-Path $configSubDir '*') -Destination $destConfigSub -Recurse -Force
                Write-SyncLog "    Copied config subdirectory"
            }
        }

        Remove-Item -Path $layerTmpDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-SyncLog "    Addon '$($addon.Name)' extracted successfully"
    }
}

# ===========================================================================
# Helper: Run update lifecycle for an addon that is already enabled.
# Returns $true on success or non-fatal skip; $false on update failure.
# ===========================================================================
function Invoke-AddonUpdateLifecycle {
    param(
        [Parameter(Mandatory)] [string]$LocalAddonName,
        [Parameter(Mandatory)] [string]$AddonVersion
    )

    Write-SyncLog "[ApplyIfEnabled] Running update lifecycle for '$LocalAddonName' v$AddonVersion"

    $infraModulePath   = Join-Path $K2sInstallDir 'lib\modules\k2s\k2s.infra.module\k2s.infra.module.psm1'
    $clusterModulePath = Join-Path $K2sInstallDir 'lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1'
    $addonsModulePath  = Join-Path $addonsDir 'addons.module.psm1'

    foreach ($modulePath in @($infraModulePath, $clusterModulePath, $addonsModulePath)) {
        if (-not (Test-Path $modulePath)) {
            Write-SyncLog "[ApplyIfEnabled] Required module not found: $modulePath - skipping lifecycle" -Warning
            return $true
        }
        try {
            Import-Module $modulePath -Force -DisableNameChecking
        } catch {
            Write-SyncLog "[ApplyIfEnabled] Failed to import module '$modulePath': $_ - skipping lifecycle" -Warning
            return $true
        }
    }

    $addonObj = [PSCustomObject]@{ Name = $LocalAddonName }
    if (-not (Test-IsAddonEnabled -Addon $addonObj)) {
        Write-SyncLog "[ApplyIfEnabled] '$LocalAddonName' is not enabled - skipping update"
        return $true
    }

    $addonDir = Join-Path $addonsDir $LocalAddonName
    $updateScript = Join-Path $addonDir 'Update.ps1'
    if (-not (Test-Path $updateScript)) {
        Write-SyncLog "[ApplyIfEnabled] Update.ps1 not found for '$LocalAddonName' - skipping update"
        return $true
    }

    $backupScript  = Join-Path $addonDir 'Backup.ps1'
    $restoreScript = Join-Path $addonDir 'Restore.ps1'
    $backupDir     = $null
    $hasBackup     = Test-Path $backupScript
    $shouldRetainBackup = $false

    if ($hasBackup) {
        $backupDir = Join-Path $env:TEMP "addon-backup-${LocalAddonName}-$(Get-Date -Format 'HHmmss')"
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Write-SyncLog "[ApplyIfEnabled] Running Backup.ps1 for '$LocalAddonName'"
        try {
            & $backupScript -BackupDir $backupDir
        } catch {
            # Data-loss guard: a declared Backup.ps1 that fails leaves no recovery
            # point. Abort BEFORE running Update.ps1 so the addon enters backoff and
            # retries next cycle instead of updating unprotected data.
            Write-SyncLog "[ApplyIfEnabled] Backup failed for '$LocalAddonName': $_ - aborting update (no recovery point)" -IsError
            Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
            return $false
        }
    }

    Write-SyncLog "[ApplyIfEnabled] Running Update.ps1 for '$LocalAddonName'"
    try {
        & $updateScript
        Update-AddonVersionInSetupJson -Name $LocalAddonName -Version $AddonVersion
        Write-SyncLog "[ApplyIfEnabled] '$LocalAddonName' updated to v$AddonVersion"
        return $true
    } catch {
        Write-SyncLog "[ApplyIfEnabled] Update failed for '$LocalAddonName': $_" -IsError
        
        # Decide whether to retain backup: retain if Update failed AND no Restore.ps1 exists
        if ($hasBackup -and -not (Test-Path $restoreScript)) {
            $shouldRetainBackup = $true
        }
        
        if ($hasBackup -and $backupDir -and (Test-Path $restoreScript)) {
            Write-SyncLog "[ApplyIfEnabled] Attempting restore for '$LocalAddonName'"
            try {
                & $restoreScript -BackupDir $backupDir
                Write-SyncLog "[ApplyIfEnabled] Restore completed for '$LocalAddonName'"
            } catch {
                Write-SyncLog "[ApplyIfEnabled] Restore failed for '$LocalAddonName': $_" -IsError
            }
        }
        return $false
    } finally {
        if ($backupDir) {
            if ($shouldRetainBackup) {
                # Backup retention: move to .addon-sync-backups/<AddonName>/<timestamp>/
                $backupsDir = Join-Path $addonsDir '.addon-sync-backups'
                if (-not (Test-Path $backupsDir)) {
                    New-Item -ItemType Directory -Path $backupsDir -Force | Out-Null
                }

                $addonBackupDir = Join-Path $backupsDir $LocalAddonName
                if (-not (Test-Path $addonBackupDir)) {
                    New-Item -ItemType Directory -Path $addonBackupDir -Force | Out-Null
                }

                $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
                $retainedBackupPath = Join-Path $addonBackupDir $timestamp
                try {
                    Move-Item -Path $backupDir -Destination $retainedBackupPath -Force
                    Write-SyncLog "[addon-sync] Backup retained for $LocalAddonName (no Restore.ps1 available)"
                } catch {
                    Write-SyncLog "[addon-sync] Failed to retain backup for '$LocalAddonName': $_" -Warning
                    Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            } else {
                Remove-Item -Path $backupDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ===========================================================================
# ConfigMap status helpers
# ===========================================================================

function Get-KubectlPath {
    # Returns the path to kubectl.exe. Isolated as a plain function so Pester can mock it.
    return Join-Path (Get-KubeBinPath) 'kube\kubectl.exe'
}

function Get-SanitizedMessage {
    param([string]$Message)
    # Redact token-like values (base64-ish, >=40 chars) before writing to logs.
    return $Message -replace '[A-Za-z0-9+/]{40,}={0,2}', '<redacted>'
}

function Test-IsValidAddonNameToken {
    param([string]$Token)

    # Evidence: addon/repository names are composed into registry refs, filesystem paths,
    # digest filenames, and status keys throughout this script. Require full-token match.
    # Pattern keeps existing repo conventions (lowercase alnum with dot/underscore/hyphen).
    return -not [string]::IsNullOrWhiteSpace($Token) -and ($Token -cmatch '^[a-z0-9][a-z0-9._-]*$')
}

function Set-AddonStatusConfigMap {
    param(
        [Parameter(Mandatory)] [string]$StateKey,
        [Parameter(Mandatory)] [string]$Phase
    )
    # Best-effort: status reporting must never abort the main sync loop.
    try {
        $kubectl     = Get-KubectlPath
        if (-not (Test-IsValidAddonNameToken -Token $StateKey)) {
            Write-SyncLog "[Status] Skipping ConfigMap patch for invalid state key token" -Warning
            return
        }

        $patchObj = @{ data = @{} }
        $patchObj.data[$StateKey] = $Phase
        $patchJson = $patchObj | ConvertTo-Json -Compress
        $maxAttempts = 5

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $output = & $kubectl patch configmap addon-sync-status `
                --namespace k2s-addon-sync `
                --type merge `
                --patch $patchJson 2>&1
            if ($LASTEXITCODE -eq 0) { return }

            $outputStr = ($output | Out-String).Trim()
            if ($outputStr -match 'Conflict') {
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds $attempt
                } else {
                    Write-SyncLog "[Status] ConfigMap patch failed after $maxAttempts attempts: $(Get-SanitizedMessage $outputStr)" -IsError
                }
            } else {
                # Non-conflict error: fail fast without retry.
                Write-SyncLog "[Status] ConfigMap patch failed (non-retryable): $(Get-SanitizedMessage $outputStr)" -IsError
                return
            }
        }
    } catch {
        Write-SyncLog "[Status] ConfigMap patch threw unexpectedly: $(Get-SanitizedMessage $_.ToString())" -IsError
    }
}

# ===========================================================================
# Backoff State Management — exponential backoff with digest-keyed state
# ===========================================================================

function Get-AddonFailureState {
    param([Parameter(Mandatory)] [string]$AddonName)

    if (-not (Test-IsValidAddonNameToken -Token $AddonName)) {
        Write-SyncLog "[Backoff] Invalid addon name token for Get-AddonFailureState: $AddonName" -Warning
        return $null
    }

    $failureFile = Join-Path $stateDir "$AddonName.failure"
    if (-not (Test-Path $failureFile)) {
        return $null
    }

    try {
        $json = Get-Content -Path $failureFile -Raw | ConvertFrom-Json
        return $json
    } catch {
        Write-SyncLog "[Backoff] Failed to parse failure state for '$AddonName': $_" -Warning
        return $null
    }
}

function Set-AddonFailureState {
    param(
        [Parameter(Mandatory)] [string]$AddonName,
        [Parameter(Mandatory)] [string]$CurrentDigest
    )

    if (-not (Test-IsValidAddonNameToken -Token $AddonName)) {
        Write-SyncLog "[Backoff] Invalid addon name token for Set-AddonFailureState: $AddonName" -Warning
        return
    }

    $failureFile = Join-Path $stateDir "$AddonName.failure"
    $existingState = Get-AddonFailureState -AddonName $AddonName
    $attemptCount = if ($existingState -and $existingState.CurrentDigest -eq $CurrentDigest) {
        $existingState.AttemptCount + 1
    } else {
        1
    }

    $failureState = @{
        CurrentDigest  = $CurrentDigest
        AttemptCount   = $attemptCount
        LastAttemptUtc = [DateTime]::UtcNow.ToString('O')
    }

    try {
        $failureState | ConvertTo-Json -Depth 10 | Set-Content -Path $failureFile -Encoding UTF8 -Force
    } catch {
        Write-SyncLog "[Backoff] Failed to write failure state for '$AddonName': $_" -Warning
    }
}

function Clear-AddonFailureState {
    param([Parameter(Mandatory)] [string]$AddonName)

    if (-not (Test-IsValidAddonNameToken -Token $AddonName)) {
        Write-SyncLog "[Backoff] Invalid addon name token for Clear-AddonFailureState: $AddonName" -Warning
        return
    }

    $failureFile = Join-Path $stateDir "$AddonName.failure"
    if (Test-Path $failureFile) {
        try {
            Remove-Item -Path $failureFile -Force
            Write-SyncLog "[addon-sync] Cleared failure state for $AddonName"
        } catch {
            Write-SyncLog "[Backoff] Failed to delete failure state for '$AddonName': $_" -Warning
        }
    }
}

function Test-ShouldSkipForBackoff {
    param(
        [Parameter(Mandatory)] [string]$AddonName,
        [Parameter(Mandatory)] [string]$CurrentDigest
    )

    $failureState = Get-AddonFailureState -AddonName $AddonName
    if (-not $failureState) {
        return $false
    }

    # Different digest → new attempt, don't skip
    if ($failureState.CurrentDigest -ne $CurrentDigest) {
        return $false
    }

    # Same digest → check backoff window
    try {
        $lastAttemptUtc = [DateTime]::Parse($failureState.LastAttemptUtc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        Write-SyncLog "[Backoff] Failed to parse LastAttemptUtc for '$AddonName': $_ - treating as immediate retry" -Warning
        return $false
    }

    # Exponential backoff: min(2^attemptCount * 1 minute, 60 minutes)
    $attemptCount = $failureState.AttemptCount
    $backoffMinutes = [Math]::Min([Math]::Pow(2, $attemptCount), 60)
    $backoffWindow = [TimeSpan]::FromMinutes($backoffMinutes)
    $nextRetryTime = $lastAttemptUtc.Add($backoffWindow)
    $now = [DateTime]::UtcNow

    if ($now -lt $nextRetryTime) {
        Write-SyncLog "[addon-sync] Skipping $AddonName (backoff until $($nextRetryTime.ToString('O')))"
        return $true
    }

    return $false
}

# ===========================================================================
# Main
# ===========================================================================

# Strip oci:// prefix - oras expects plain host/path references.
# REGISTRY_URL is the base registry (e.g. k2s.registry.local:30500).
# Per-addon repos are discovered via: oras repo ls <registryBase> | addons/*
$registryBase = $RegistryUrl -replace '^oci://', ''
$sanitizedRegistryBase = Get-SanitizedRegistryUrl $registryBase

if ($InsecureBool) {
    Write-SyncLog 'Insecure plain-HTTP registry connections enabled (expected for the local K2s NodePort registry which has no TLS).' -Warning
}

Write-SyncLog "Starting per-addon sync from $sanitizedRegistryBase"
Write-SyncLog "K2s install dir: $K2sInstallDir"
if ($CheckDigestBool) {
    Write-SyncLog "Digest-check mode enabled - only syncing changed addons"
}

$addonsDir = Join-Path $K2sInstallDir 'addons'
if (-not (Test-Path $addonsDir)) {
    throw "Addons directory not found: $addonsDir - is K2sInstallDir correct?"
}

# Per-addon digest tracking: one file per addon under .addon-sync-digests/
$digestDir = Join-Path $addonsDir '.addon-sync-digests'
if (-not (Test-Path $digestDir)) { New-Item -ItemType Directory -Path $digestDir -Force | Out-Null }

# Per-addon failure state tracking: one file per addon under .addon-sync-state/
$stateDir = Join-Path $addonsDir '.addon-sync-state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

# ---------------------------------------------------------------------------
# Step 1: Discover per-addon repositories at <registryBase>/addons/<name>
# ---------------------------------------------------------------------------
$invalidDiscoveredReposCount = 0
if ($AddonName -ne '') {
    if (-not (Test-IsValidAddonNameToken -Token $AddonName)) {
        throw "Invalid AddonName '$AddonName'. Allowed pattern: ^[a-z0-9][a-z0-9._-]*$"
    }
    Write-SyncLog "AddonName filter set - syncing only '$AddonName'"
    $addonRepos = @($AddonName)
} else {
    Write-SyncLog "Discovering addon repositories under $sanitizedRegistryBase/addons/"

    $repoListArgs = @('repo', 'ls', $registryBase)
    if ($InsecureBool) { $repoListArgs += '--plain-http' }

    try {
        $allRepos = & $OrasExe @repoListArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "oras repo ls failed (exit $LASTEXITCODE): $allRepos" }
    } catch {
        Write-SyncLog "Failed to list repositories at $sanitizedRegistryBase : $(Get-SanitizedRegistryUrl ($_ | Out-String))" -IsError
        throw
    }

    $discoveredAddonRepos = @($allRepos | Where-Object { $_ -match '^addons/' } | ForEach-Object { $_ -replace '^addons/', '' })
    $addonRepos = @()
    foreach ($discoveredAddonRepo in $discoveredAddonRepos) {
        if (Test-IsValidAddonNameToken -Token $discoveredAddonRepo) {
            $addonRepos += $discoveredAddonRepo
            continue
        }

        Write-SyncLog "Skipping discovered addon repository with invalid name token" -Warning
        $invalidDiscoveredReposCount++
    }
    if ($addonRepos.Count -eq 0) {
        if ($invalidDiscoveredReposCount -gt 0) {
            Write-SyncLog "No valid addon repositories found at $sanitizedRegistryBase/addons/ ($invalidDiscoveredReposCount invalid name token(s) rejected)" -Warning
        } else {
            Write-SyncLog "No addon repositories found at $sanitizedRegistryBase/addons/ - push addons first" -Warning
        }
        [System.Environment]::Exit(0)
    }
    if ($invalidDiscoveredReposCount -gt 0) {
        Write-SyncLog "Rejected $invalidDiscoveredReposCount discovered addon repository name token(s)" -Warning
    }
}
Write-SyncLog "Found $($addonRepos.Count) addon repo(s): $($addonRepos -join ', ')"

# ---------------------------------------------------------------------------
# Step 2: For each addon repo - check digest, pull if changed, extract
# ---------------------------------------------------------------------------
$syncedCount  = 0
$skippedCount = $invalidDiscoveredReposCount
$failedCount  = 0

foreach ($addonRepoName in $addonRepos) {
    if (-not (Test-IsValidAddonNameToken -Token $addonRepoName)) {
        Write-SyncLog "Skipping addon with invalid name token before processing loop" -Warning
        $failedCount++
        continue
    }

    $addonRef = "$registryBase/addons/$addonRepoName"
    $sanitizedAddonRef = Get-SanitizedRegistryUrl $addonRef
    Write-SyncLog "Processing '$addonRepoName' ($sanitizedAddonRef)"

    # Discover tag: prefer 'latest', otherwise deterministic semver-desc / lexical-desc
    $tagListArgs = @('repo', 'tags', $addonRef)
    if ($InsecureBool) { $tagListArgs += '--plain-http' }
    $tagsOutput = & $OrasExe @tagListArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-SyncLog "  Failed to list tags for '$addonRepoName' (exit $LASTEXITCODE): $tagsOutput" -IsError
        Set-AddonStatusConfigMap -StateKey $addonRepoName -Phase 'Failed'
        $failedCount++
        continue
    }
    if (-not $tagsOutput) {
        if ($AddonName -ne '') {
            # Per-addon mode (Flux sync Job) expects exactly one concrete addon repository.
            # If no tags are published this is a configuration/runtime error, not a benign skip.
            Write-SyncLog "  No tags published for '$addonRepoName' in per-addon mode - failing sync (push a versioned tag first)" -IsError
            Set-AddonStatusConfigMap -StateKey $addonRepoName -Phase 'Failed'
            $failedCount++
            continue
        }

        Write-SyncLog "  No tags published for '$addonRepoName' - skipping (push a versioned tag first)" -Warning
        $skippedCount++
        continue
    }

    $tags = @($tagsOutput | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -ne '' })
    $selectedTag = Select-AddonTag -AddonRepoName $addonRepoName -Tags $tags
    if (-not $selectedTag) {
        Write-SyncLog "  Unable to select a tag for '$addonRepoName' (candidates: $($tags -join ', ')) - skipping" -IsError
        Set-AddonStatusConfigMap -StateKey $addonRepoName -Phase 'Failed'
        $failedCount++
        continue
    }
    $fullRef = "${addonRef}:${selectedTag}"
    $sanitizedFullRef = Get-SanitizedRegistryUrl $fullRef

    # Fetch current digest (needed for both digest-check and backoff logic)
    $currentDigest = $null
    $digestFetchFailed = $false
    try {
        $fetchArgs = @('manifest', 'fetch', '--descriptor', $fullRef)
        if ($InsecureBool) { $fetchArgs += '--plain-http' }
        $descriptorJson = & $OrasExe @fetchArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            $currentDigest = ($descriptorJson | Out-String | ConvertFrom-Json).digest
        } else {
            Write-SyncLog "  Digest fetch failed for '$addonRepoName' (exit $LASTEXITCODE): $(Get-SanitizedRegistryUrl ($descriptorJson | Out-String))" -Warning
            $digestFetchFailed = $true
        }
    } catch {
        Write-SyncLog "  Digest fetch error for '$addonRepoName': $(Get-SanitizedRegistryUrl ($_ | Out-String))" -Warning
        $digestFetchFailed = $true
    }

    # Per-addon digest check - skip if unchanged
    $digestFile = Join-Path $digestDir $addonRepoName
    if ($CheckDigestBool -and $currentDigest) {
        if (Test-Path $digestFile) {
            $lastDigest = (Get-Content $digestFile -Raw).Trim()
            if ($currentDigest -eq $lastDigest) {
                if (Test-HostAddonPresentForRepo -AddonsDir $addonsDir -RepoName $addonRepoName) {
                    Write-SyncLog "  '$addonRepoName' unchanged (digest: $currentDigest), skipping"
                    $skippedCount++
                    continue
                }
                Write-SyncLog "  '$addonRepoName' digest unchanged but expected host addon content missing -- forcing re-sync"
            } else {
                Write-SyncLog "  '$addonRepoName' digest changed (was: $lastDigest)"
            }
        } else {
            Write-SyncLog "  '$addonRepoName' first sync run"
        }
    }

    # Backoff check - skip if same digest and within backoff window
    if ($currentDigest -and (Test-ShouldSkipForBackoff -AddonName $addonRepoName -CurrentDigest $currentDigest)) {
        if ($AddonName -ne '') {
            Write-SyncLog "  Backoff is active for '$addonRepoName' in per-addon mode - failing sync" -IsError
            Set-AddonStatusConfigMap -StateKey $addonRepoName -Phase 'Failed'
            $failedCount++
            continue
        }

        $skippedCount++
        continue
    }

    # Pull per-addon OCI artifact into a temp OCI layout directory
    $addonTmpDir = Join-Path $env:TEMP "addon-sync-${addonRepoName}-$(Get-Date -Format 'HHmmss')"
    New-Item -ItemType Directory -Path $addonTmpDir -Force | Out-Null

    Write-SyncLog "  Pulling $sanitizedFullRef"
    $orasArgs = @('copy', $fullRef, '--to-oci-layout', "${addonTmpDir}:${selectedTag}")
    if ($InsecureBool) { $orasArgs += '--from-plain-http' }

    try {
        $pullResult = & $OrasExe @orasArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "oras copy failed (exit $LASTEXITCODE): $pullResult" }
        Write-SyncLog "  Pull completed: $(Get-SanitizedRegistryUrl ($pullResult | Out-String))"

        # Extract layers 0-3 into the addons directory
        Sync-AddonFromOciLayout -OciLayoutDir $addonTmpDir -AddonsDir $addonsDir

        $syncRunSucceeded = $true
        if ($ApplyIfEnabledBool) {
            $lifecycleOk = Invoke-AddonUpdateLifecycle -LocalAddonName $addonRepoName -AddonVersion $selectedTag
            if (-not $lifecycleOk) {
                Write-SyncLog "  ApplyIfEnabled lifecycle failed for '$addonRepoName' - marking sync as failed" -IsError
                $syncRunSucceeded = $false
            }
        }

        if ($syncRunSucceeded) {
            # Save per-addon digest after successful sync
            if ($CheckDigestBool -and $currentDigest) {
                try {
                    Set-Content -Path $digestFile -Value $currentDigest -NoNewline -Encoding UTF8 -Force
                    Write-SyncLog "  Saved digest for '$addonRepoName': $currentDigest"
                } catch {
                    Write-SyncLog "  Failed to save digest for '$addonRepoName': $_" -Warning
                }
            }

            Clear-AddonFailureState -AddonName $addonRepoName
            Write-SyncLog "[addon-sync] $addonRepoName synced successfully, backoff cleared"

            Set-AddonStatusConfigMap -StateKey $addonRepoName -Phase 'Synced'
            $syncedCount++
        } else {
            if ($currentDigest) {
                Set-AddonFailureState -AddonName $addonRepoName -CurrentDigest $currentDigest
                Write-SyncLog "[addon-sync] Update failed for $addonRepoName, entering backoff"
            }

            Set-AddonStatusConfigMap -StateKey $addonRepoName -Phase 'Failed'
            $failedCount++
        }
    } catch {
        Write-SyncLog "  Failed to sync '$addonRepoName': $_" -IsError
        
        if ($currentDigest) {
            Set-AddonFailureState -AddonName $addonRepoName -CurrentDigest $currentDigest
            Write-SyncLog "[addon-sync] Update failed for $addonRepoName, entering backoff"
        }

        Set-AddonStatusConfigMap -StateKey $addonRepoName -Phase 'Failed'
        $failedCount++
    } finally {
        Remove-Item -Path $addonTmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-SyncLog "Addon sync completed. Synced: $syncedCount, Skipped (unchanged): $skippedCount, Failed: $failedCount"
if ($failedCount -gt 0) {
    Write-SyncLog "Some addons failed to sync -- check logs above for details" -IsError
    exit 1
}
Write-SyncLog "Layers processed for each synced addon:"
Write-SyncLog "  Layer 0: config files      (addon.manifest.yaml, values.yaml, etc.)"
Write-SyncLog "  Layer 1: K8s manifests     (YAML, kustomization, CRDs)"
Write-SyncLog "  Layer 2: Helm charts       (.tgz packages)"
Write-SyncLog "  Layer 3: scripts           (Enable/Disable/Status/Update .ps1)"
Write-SyncLog "  Layer 4: Linux images      [SKIPPED - pulled from registry]"
Write-SyncLog "  Layer 5: Windows images    [SKIPPED - pulled from registry]"
Write-SyncLog "  Layer 6: packages          [SKIPPED - not used in GitOps flow]"
Write-SyncLog "Run 'k2s addons ls' to see synced addons."
