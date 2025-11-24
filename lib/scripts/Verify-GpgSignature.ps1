function Verify-GpgSignature {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ChecksumFile,
        [Parameter(Mandatory = $true)]
        [string]$SignatureFile
    )

    Write-Log "[DebPkg] Starting GPG signature verification"
    Write-Log "[DebPkg] ChecksumFile: $ChecksumFile"
    Write-Log "[DebPkg] SignatureFile: $SignatureFile"

    if (-not (Test-Path $ChecksumFile)) {
        Write-Log "[DebPkg] Checksum file not found: $ChecksumFile"
        return $false
    }
    if (-not (Test-Path $SignatureFile)) {
        Write-Log "[DebPkg] Signature file not found: $SignatureFile"
        return $false
    }

    # ------------------------------
    # 1. Setup GNUPGHOME
    # ------------------------------
    $env:GNUPGHOME = "$env:TEMP\k8s-gpg-home"

    if (-not (Test-Path $env:GNUPGHOME)) {
        Write-Log "[DebPkg] Creating GNUPGHOME directory at: $env:GNUPGHOME"
        New-Item -ItemType Directory -Path $env:GNUPGHOME | Out-Null
    }

    Write-Log "[DebPkg] GNUPGHOME set to $env:GNUPGHOME"

    # ------------------------------
    # 2. Locate portable gpg.exe
    # ------------------------------
    $gpgExe = Join-Path (Join-Path (Get-KubeBinPath) "gpg\bin") "gpg.exe"
    Write-Log "[DebPkg] gpg.exe path: $gpgExe"

    if (-not (Test-Path $gpgExe)) {
        Write-Log "[DebPkg] gpg.exe not found at $gpgExe"
        return $false
    }

    # ------------------------------
    # 3. Initialize GPG keybox
    # ------------------------------
    Write-Log "[DebPkg] Initializing GPG keybox"
    & $gpgExe --list-keys 2>&1 | Write-Log

    # ------------------------------
    # 4. Download Debian Release Key (.asc)
    # ------------------------------
    $keyFile = "$env:TEMP\archive-key-12.asc"

    if (-not (Test-Path $keyFile)) {
        Write-Log "[DebPkg] Downloading Debian archive-key-12.asc"
        Invoke-WebRequest `
            -Uri "https://ftp-master.debian.org/keys/archive-key-12.asc" `
            -OutFile $keyFile
    } else {
        Write-Log "[DebPkg] Debian key already present: $keyFile"
    }

    # ------------------------------
    # 5. Import Debian Key
    # ------------------------------
    Write-Log "[DebPkg] Importing Debian key from asc file"
    $importOutput = & $gpgExe --import $keyFile 2>&1
    Write-Log "[DebPkg] Import output: $importOutput"

    # ------------------------------
    # 6. Verify signature
    # ------------------------------
    Write-Log "[DebPkg] Verifying signature"
    & $gpgExe --verify $SignatureFile $ChecksumFile 2>&1 | Write-Log

    if ($LASTEXITCODE -eq 0) {
        Write-Log "[DebPkg] GPG signature verification succeeded"
        return $true
    }

    Write-Log "[DebPkg] GPG signature verification failed"
    throw "[DebPkg] GPG signature verification failed"
}
