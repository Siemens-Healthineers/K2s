# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Input package one (the older version)')]
    [string] $InputPackageOne,
    [parameter(Mandatory = $false, HelpMessage = 'Input package two (the newer version)')]
    [string] $InputPackageTwo,
    [parameter(Mandatory = $false, HelpMessage = 'Target directory')]
    [string] $TargetDirectory,
    [parameter(Mandatory = $false, HelpMessage = 'The name of the zip package (it must have the extension .zip)')]
    [string] $ZipPackageFileName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Path to code signing certificate (.pfx file)')]
    [string] $CertificatePath,
    [parameter(Mandatory = $false, HelpMessage = 'Password for the certificate file')]
    [string] $Password
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$signingModule = "$PSScriptRoot/../../../../modules/k2s/k2s.signing.module/k2s.signing.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $signingModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "- Proxy to be used: $Proxy"
Write-Log "- Target Directory: $TargetDirectory"
Write-Log "- Package file name: $ZipPackageFileName"

Add-type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$errMsg = ''
if ('' -eq $TargetDirectory) {
    $errMsg = 'The passed target directory is empty'
}
elseif (!(Test-Path -Path $TargetDirectory)) {
    $errMsg = "The passed target directory '$TargetDirectory' could not be found"
}
elseif ('' -eq $ZipPackageFileName) {
    $errMsg = 'The passed zip package name is empty'
}
elseif ($ZipPackageFileName.EndsWith('.zip') -eq $false) {
    $errMsg = "The passed zip package name '$ZipPackageFileName' does not have the extension '.zip'"
}

if ($errMsg -ne '') {
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'build-package-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$zipPackagePath = Join-Path "$TargetDirectory" "$ZipPackageFileName"

if (Test-Path $zipPackagePath) {
    Write-Log "Removing already existing file '$zipPackagePath'" -Console
    Remove-Item $zipPackagePath -Force
}

Write-Log "Zip package available at '$zipPackagePath'." -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}

# --- Delta Package Construction -------------------------------------------------

if ([string]::IsNullOrWhiteSpace($InputPackageOne) -or -not (Test-Path -LiteralPath $InputPackageOne)) {
    Write-Log "InputPackageOne missing or not found: '$InputPackageOne'" -Error
    exit 2
}
if ([string]::IsNullOrWhiteSpace($InputPackageTwo) -or -not (Test-Path -LiteralPath $InputPackageTwo)) {
    Write-Log "InputPackageTwo missing or not found: '$InputPackageTwo'" -Error
    exit 3
}

Write-Log "Building delta between:'$InputPackageOne' -> '$InputPackageTwo'" -Console

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("k2s-delta-" + [guid]::NewGuid())
$oldExtract = Join-Path $tempRoot 'old'
$newExtract = Join-Path $tempRoot 'new'
$stageDir   = Join-Path $tempRoot 'stage'
New-Item -ItemType Directory -Force -Path $oldExtract | Out-Null
New-Item -ItemType Directory -Force -Path $newExtract | Out-Null
New-Item -ItemType Directory -Force -Path $stageDir   | Out-Null

$overallError = $null
try {
    try {
        Write-Log "Extracting old package -> $oldExtract"
        [IO.Compression.ZipFile]::ExtractToDirectory($InputPackageOne, $oldExtract)
        Write-Log "Extracting new package -> $newExtract"
        [IO.Compression.ZipFile]::ExtractToDirectory($InputPackageTwo, $newExtract)
    }
    catch {
        Write-Log "Extraction failed: $($_.Exception.Message)" -Error
        throw
    }

function Get-FileMap {
    param($root)
    $map = @{}
    Get-ChildItem -Path $root -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length)
        # Remove any leading path separators (handles both Windows and Unix style)
        $rel = $rel -replace '^[\\/]+',''
        # Normalize to forward slashes for manifest portability
        $rel = $rel -replace '\\','/'
        try {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        }
        catch {
            Write-Log "Hash failed for '$($_.FullName)': $($_.Exception.Message)" -Error
            $hash = ''
        }
        $map[$rel] = [pscustomobject]@{ Hash = $hash; Size = $_.Length }
    }
    return $map
}

$oldMap = Get-FileMap -root $oldExtract
$newMap = Get-FileMap -root $newExtract


$added    = @()
$removed  = @()
$changed  = @()

# Added & changed
foreach ($p in $newMap.Keys) {
    if (-not $oldMap.ContainsKey($p)) { $added += $p; continue }
    if ($oldMap[$p].Hash -ne $newMap[$p].Hash) { $changed += $p }
}
# Removed
foreach ($p in $oldMap.Keys) { if (-not $newMap.ContainsKey($p)) { $removed += $p } }

Write-Log "Added: $($added.Count)  Changed: $($changed.Count)  Removed: $($removed.Count)" -Console

# Stage added + changed files
foreach ($rel in ($added + $changed)) {
    $source = Join-Path $newExtract $rel
    $dest   = Join-Path $stageDir   $rel
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $source -Destination $dest -Force
}

# Build manifest
$manifest = [pscustomobject]@{
    GeneratedUtc = [DateTime]::UtcNow.ToString('o')
    BasePackage  = (Split-Path -Leaf $InputPackageOne)
    TargetPackage= (Split-Path -Leaf $InputPackageTwo)
    Added        = $added
    Changed      = $changed
    Removed      = $removed
    AddedCount   = $added.Count
    ChangedCount = $changed.Count
    RemovedCount = $removed.Count
    HashAlgorithm= 'SHA256'
}
$manifestPath = Join-Path $stageDir 'delta-manifest.json'
$manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $manifestPath -Encoding UTF8 -Force

    # --- Code Signing (optional) -------------------------------------------------
    if ($CertificatePath -and $Password) {
        Write-Log "Attempting code signing using certificate '$CertificatePath'" -Console
        try {
            if (-not (Test-Path -LiteralPath $CertificatePath)) { throw "Certificate file not found." }
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath, $Password, 'Exportable,MachineKeySet')
            if (-not $cert.HasPrivateKey) { throw "Certificate does not contain a private key." }
            $signExtensions = @('*.exe','*.dll','*.ps1','*.psm1','*.psd1')
            $filesToSign = foreach ($pat in $signExtensions) { Get-ChildItem -Path $stageDir -Recurse -Include $pat -File }
            foreach ($f in $filesToSign) {
                try {
                    $sig = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -TimestampServer "http://timestamp.digicert.com" -ErrorAction Stop
                    if ($sig.Status -ne 'Valid') {
                        Write-Log "Signing warning for $($f.FullName): Status=$($sig.Status)" -Warning
                    } else {
                        Write-Log "Signed: $($f.FullName)" 
                    }
                }
                catch {
                    Write-Log "Failed to sign '$($f.FullName)': $($_.Exception.Message)" -Warning
                }
            }
        }
        catch {
            Write-Log "Code signing setup failed: $($_.Exception.Message)" -Warning
        }
    }
    elseif ($CertificatePath -or $Password) {
        Write-Log "Both -CertificatePath and -Password must be specified for signing; skipping signing." -Warning
    }

    # --- Create delta zip after (optional) signing ------------------------------
    try {
        if (Test-Path $zipPackagePath) { Remove-Item $zipPackagePath -Force }
        [IO.Compression.ZipFile]::CreateFromDirectory($stageDir, $zipPackagePath)
        Write-Log "Delta package created: $zipPackagePath" -Console
    }
    catch {
        Write-Log "Failed to create delta zip: $($_.Exception.Message)" -Error
        throw
    }
}
catch {
    $overallError = $_
}
finally {
    # Cleanup temp extraction directories
    if (Test-Path $tempRoot) {
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop
            Write-Log "Cleaned up temp directory '$tempRoot'" 
        }
        catch {
            Write-Log "Failed to cleanup temp directory '$tempRoot': $($_.Exception.Message)" -Warning
        }
    }
}

if ($overallError) {
    Write-Log "Delta creation encountered an error: $($overallError.Exception.Message)" -Error
    exit 5
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ 
        Error = $null;
        Delta = @{ Added = $added; Changed = $changed; Removed = $removed; Manifest = 'delta-manifest.json' }
    }
}

Write-Log "DONE" -Console