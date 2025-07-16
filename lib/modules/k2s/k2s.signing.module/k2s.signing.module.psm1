# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
K2s Code Signing Module

.DESCRIPTION
This module provides functionality for creating and managing code signing certificates
for K2s executables and scripts.
#>

$ErrorActionPreference = 'Stop'

<#
.SYNOPSIS
Creates a new self-signed code signing certificate for K2s

.DESCRIPTION
Creates a new self-signed certificate that can be used for signing K2s executables and PowerShell scripts.

.PARAMETER CertificateName
The subject name for the certificate (default: "K2s Code Signing Certificate")

.PARAMETER ValidityYears
Number of years the certificate should be valid (default: 10)

.PARAMETER OutputPath
Path where the certificate file (.pfx) should be saved

.PARAMETER Password
Password for the certificate file (if not provided, will be prompted securely)

.EXAMPLE
New-K2sCodeSigningCertificate -OutputPath "C:\k2s\certificates\k2s-signing.pfx"
#>
function New-K2sCodeSigningCertificate {
    param(
        [string]$CertificateName = "K2s Code Signing Certificate",
        [int]$ValidityYears = 10,
        [string]$OutputPath,
        [SecureString]$Password
    )

    Write-Log "Creating new K2s code signing certificate..." -Console

    # Generate output path if not provided
    if (-not $OutputPath) {
        $OutputPath = "$env:TEMP\k2s-signing-cert-$(Get-Random).pfx"
    }

    # Generate password if not provided
    if (-not $Password) {
        $randomPassword = -join ((65..90) + (97..122) + (48..57) | Get-Random -Count 16 | ForEach-Object {[char]$_})
        $Password = ConvertTo-SecureString -String $randomPassword -AsPlainText -Force
    }

    # Create the certificate
    $cert = New-SelfSignedCertificate -Subject "CN=$CertificateName" `
        -Type CodeSigningCert `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -NotAfter (Get-Date).AddYears($ValidityYears) `
        -CertStoreLocation Cert:\CurrentUser\My

    Write-Log "Certificate created with thumbprint: $($cert.Thumbprint)" -Console

    # Export the certificate to a .pfx file
    $certDir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $certDir)) {
        New-Item -ItemType Directory -Path $certDir -Force | Out-Null
    }

    Export-PfxCertificate -Cert $cert -FilePath $OutputPath -Password $Password | Out-Null
    Write-Log "Certificate exported to: $OutputPath" -Console

    # Return certificate information
    return @{
        Thumbprint = $cert.Thumbprint
        Subject = $cert.Subject
        NotAfter = $cert.NotAfter
        FilePath = $OutputPath
        Password = $Password
    }
}

<#
.SYNOPSIS
Imports a K2s code signing certificate into the local certificate store

.DESCRIPTION
Imports the K2s code signing certificate into the appropriate certificate stores
for code signing validation.

.PARAMETER CertificatePath
Path to the certificate file (.pfx)

.PARAMETER Password
Password for the certificate file

.EXAMPLE
Import-K2sCodeSigningCertificate -CertificatePath "C:\k2s\certificates\k2s-signing.pfx"
#>
function Import-K2sCodeSigningCertificate {
    param(
        [Parameter(Mandatory)]
        [string]$CertificatePath,
        [SecureString]$Password
    )

    if (-not (Test-Path $CertificatePath)) {
        throw "Certificate file not found: $CertificatePath"
    }

    if (-not $Password) {
        $Password = Read-Host -AsSecureString "Enter password for certificate file"
    }

    Write-Log "Importing K2s code signing certificate..." -Console

    # Import to Personal store (for signing)
    $cert = Import-PfxCertificate -FilePath $CertificatePath `
        -CertStoreLocation Cert:\CurrentUser\My `
        -Password $Password

    # Import to Trusted Publishers (for validation)
    Import-Certificate -FilePath $CertificatePath `
        -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null

    # Import to Root store (for trust chain)
    Import-Certificate -FilePath $CertificatePath `
        -CertStoreLocation Cert:\LocalMachine\Root | Out-Null

    Write-Log "Certificate imported successfully. Thumbprint: $($cert.Thumbprint)" -Console

    return $cert
}

<#
.SYNOPSIS
Signs a PowerShell script with the K2s code signing certificate

.DESCRIPTION
Signs a PowerShell script file using the K2s code signing certificate.

.PARAMETER ScriptPath
Path to the PowerShell script file to sign

.PARAMETER CertificateThumbprint
Thumbprint of the certificate to use for signing

.EXAMPLE
Set-K2sScriptSignature -ScriptPath "C:\k2s\scripts\example.ps1" -CertificateThumbprint "ABC123..."
#>
function Set-K2sScriptSignature {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [Parameter(Mandatory)]
        [string]$CertificateThumbprint
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Script file not found: $ScriptPath"
    }

    $cert = Get-ChildItem -Path Cert:\CurrentUser\My\$CertificateThumbprint -ErrorAction SilentlyContinue
    if (-not $cert) {
        throw "Certificate with thumbprint $CertificateThumbprint not found in CurrentUser\My store"
    }

    Write-Log "Signing script: $ScriptPath" -Console
    Set-AuthenticodeSignature -FilePath $ScriptPath -Certificate $cert | Out-Null
    Write-Log "Script signed successfully" -Console
}

<#
.SYNOPSIS
Signs an executable file with the K2s code signing certificate

.DESCRIPTION
Signs an executable file using the K2s code signing certificate and signtool.

.PARAMETER ExecutablePath
Path to the executable file to sign

.PARAMETER CertificatePath
Path to the certificate file (.pfx)

.PARAMETER Password
Password for the certificate file

.PARAMETER TimestampUrl
URL for timestamping service (default: http://timestamp.digicert.com)

.EXAMPLE
Set-K2sExecutableSignature -ExecutablePath "C:\k2s\bin\k2s.exe" -CertificatePath "C:\k2s\certificates\k2s-signing.pfx"
#>
function Set-K2sExecutableSignature {
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath,
        [Parameter(Mandatory)]
        [string]$CertificatePath,
        [SecureString]$Password,
        [string]$TimestampUrl = "http://timestamp.digicert.com"
    )

    if (-not (Test-Path $ExecutablePath)) {
        throw "Executable file not found: $ExecutablePath"
    }

    if (-not (Test-Path $CertificatePath)) {
        throw "Certificate file not found: $CertificatePath"
    }

    # Find signtool.exe
    $signtool = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
    if (-not $signtool) {
        # Try to find it in Windows SDK paths
        $sdkPaths = @(
            "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe",
            "${env:ProgramFiles}\Windows Kits\10\bin\*\x64\signtool.exe"
        )
        
        foreach ($path in $sdkPaths) {
            $found = Get-ChildItem -Path $path -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $signtool = $found
                break
            }
        }
    }

    if (-not $signtool) {
        throw "signtool.exe not found. Please install Windows SDK or Visual Studio Build Tools."
    }

    if (-not $Password) {
        $Password = Read-Host -AsSecureString "Enter password for certificate file"
    }

    # Convert SecureString to plain text for signtool
    $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    )

    Write-Log "Signing executable: $ExecutablePath" -Console

    $arguments = @(
        "sign",
        "/f", $CertificatePath,
        "/p", $plainPassword,
        "/t", $TimestampUrl,
        "/v",
        $ExecutablePath
    )

    $result = & $signtool.FullName $arguments
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to sign executable. Signtool output: $result"
    }

    Write-Log "Executable signed successfully" -Console
}

<#
.SYNOPSIS
Signs all K2s PowerShell scripts in a directory

.DESCRIPTION
Recursively finds and signs all PowerShell scripts in the specified directory.

.PARAMETER RootPath
Root directory to search for PowerShell scripts

.PARAMETER CertificateThumbprint
Thumbprint of the certificate to use for signing

.PARAMETER Exclude
Array of file patterns to exclude from signing

.EXAMPLE
Set-K2sScriptSignatures -RootPath "C:\k2s" -CertificateThumbprint "ABC123..." -Exclude @("*.tests.ps1")
#>
function Set-K2sScriptSignatures {
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,
        [Parameter(Mandatory)]
        [string]$CertificateThumbprint,
        [string[]]$Exclude = @("*.tests.ps1", "*test*.ps1")
    )

    Write-Log "Signing all PowerShell scripts in: $RootPath" -Console

    $scripts = Get-ChildItem -Path $RootPath -Filter "*.ps1" -Recurse | Where-Object {
        $file = $_
        -not ($Exclude | Where-Object { $file.Name -like $_ })
    }

    $signedCount = 0
    foreach ($script in $scripts) {
        try {
            Set-K2sScriptSignature -ScriptPath $script.FullName -CertificateThumbprint $CertificateThumbprint
            $signedCount++
        }
        catch {
            Write-Log "Failed to sign $($script.FullName): $($_.Exception.Message)" -Console -Error
        }
    }

    Write-Log "Signed $signedCount of $($scripts.Count) PowerShell scripts" -Console
}

<#
.SYNOPSIS
Gets information about K2s code signing certificates

.DESCRIPTION
Retrieves information about installed K2s code signing certificates.

.EXAMPLE
Get-K2sCodeSigningCertificate
#>
function Get-K2sCodeSigningCertificate {
    $certs = Get-ChildItem -Path Cert:\CurrentUser\My | Where-Object {
        $_.Subject -like "*K2s*" -and $_.HasPrivateKey -and 
        ($_.KeyUsage -band [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature)
    }

    return $certs | Select-Object Subject, Thumbprint, NotAfter, @{
        Name = 'IsValid'
        Expression = { $_.NotAfter -gt (Get-Date) }
    }
}

<#
.SYNOPSIS
Signs all K2s executables and PowerShell scripts in a directory

.DESCRIPTION
Recursively finds and signs all PowerShell scripts (.ps1, .psm1) and executable files (.exe)
in the specified directory using the provided certificate.

.PARAMETER SourcePath
Root directory to search for files to sign

.PARAMETER CertificatePath
Path to the code signing certificate (.pfx file)

.PARAMETER Password
Password for the certificate file

.PARAMETER ExclusionList
Array of file paths or directory paths to exclude from signing

.EXAMPLE
Invoke-K2sCodeSigning -SourcePath "C:\k2s" -CertificatePath "C:\certs\signing.pfx" -Password $securePassword
#>
function Invoke-K2sCodeSigning {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$CertificatePath,
        [SecureString]$Password,
        [string[]]$ExclusionList = @()
    )

    if (-not (Test-Path $SourcePath)) {
        throw "Source path does not exist: $SourcePath"
    }

    if (-not (Test-Path $CertificatePath)) {
        throw "Certificate file not found: $CertificatePath"
    }

    Write-Log "Starting code signing process for: $SourcePath" -Console
    Write-Log "Using certificate: $CertificatePath" -Console

    # Check if certificate is already imported before attempting to import
    try {
        # First, get the certificate thumbprint without importing
        $tempCert = Get-PfxCertificate -FilePath $CertificatePath
        $existingCert = Get-ChildItem -Path "Cert:\CurrentUser\My\$($tempCert.Thumbprint)" -ErrorAction SilentlyContinue
        
        if ($existingCert) {
            Write-Log "Certificate already exists in store. Thumbprint: $($existingCert.Thumbprint)" -Console
            $cert = $existingCert
        } else {
            Write-Log "Importing certificate to certificate store..." -Console
            $cert = Import-PfxCertificate -FilePath $CertificatePath -CertStoreLocation Cert:\CurrentUser\My -Password $Password
            Write-Log "Certificate imported successfully. Thumbprint: $($cert.Thumbprint)" -Console
        }
    }
    catch {
        throw "Failed to access or import certificate: $_"
    }

    # Get all signable files
    $filesToSign = Get-SignableFiles -Path $SourcePath -ExclusionList $ExclusionList

    if ($filesToSign.Count -eq 0) {
        Write-Log "No files found to sign." -Console
        return
    }

    Write-Log "Found $($filesToSign.Count) files to sign" -Console

    $signedCount = 0
    $failedCount = 0

    foreach ($file in $filesToSign) {
        try {
            Write-Log "Signing: $file" -Console
            
            if ($file.EndsWith('.exe')) {
                # Sign executable
                Set-AuthenticodeSignature -FilePath $file -Certificate $cert | Out-Null
            }
            else {
                # Sign PowerShell script
                Set-AuthenticodeSignature -FilePath $file -Certificate $cert | Out-Null
            }
            
            # Verify the signature
            $signature = Get-AuthenticodeSignature -FilePath $file
            if ($signature.Status -eq 'Valid') {
                $signedCount++
                Write-Log "Successfully signed: $file" -Console
            }
            else {
                $failedCount++
                Write-Log "Failed to sign (invalid signature): $file" -Error
            }
        }
        catch {
            $failedCount++
            Write-Log "Failed to sign: $file - Error: $_" -Error
        }
    }

    Write-Log "Code signing completed. Signed: $signedCount, Failed: $failedCount" -Console

    if ($failedCount -gt 0) {
        throw "Code signing failed for $failedCount files"
    }
}

<#
.SYNOPSIS
Gets a list of files that can be code signed

.DESCRIPTION
Recursively searches a directory for PowerShell scripts and executable files
that can be code signed, excluding specified paths.

.PARAMETER Path
Root directory to search

.PARAMETER ExclusionList
Array of file paths or directory paths to exclude

.EXAMPLE
Get-SignableFiles -Path "C:\k2s" -ExclusionList @("C:\k2s\.git", "C:\k2s\temp")
#>
function Get-SignableFiles {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [string[]]$ExclusionList = @()
    )

    if (-not (Test-Path $Path)) {
        throw "Path does not exist: $Path"
    }

    # Extensions of files that can be signed
    $signableExtensions = @('*.ps1', '*.psm1', '*.exe')
    
    $allFiles = @()
    
    foreach ($extension in $signableExtensions) {
        $files = Get-ChildItem -Path $Path -Filter $extension -Recurse -File | ForEach-Object { $_.FullName }
        $allFiles += $files
    }

    # Filter out excluded files
    $filteredFiles = @()
    foreach ($file in $allFiles) {
        $shouldExclude = $false
        
        foreach ($exclusion in $ExclusionList) {
            if ($file -eq $exclusion -or $file.StartsWith($exclusion)) {
                $shouldExclude = $true
                break
            }
        }
        
        if (-not $shouldExclude) {
            $filteredFiles += $file
        }
    }

    return $filteredFiles
}

<#
.SYNOPSIS
Tests if a code signing certificate is valid and can be used for signing

.DESCRIPTION
Validates a code signing certificate file (.pfx) by attempting to import it
and checking if it's suitable for code signing operations.

.PARAMETER CertificatePath
Path to the certificate file (.pfx) to test

.PARAMETER Password
Password for the certificate file (optional)

.OUTPUTS
System.Boolean - Returns $true if certificate is valid, $false otherwise

.EXAMPLE
Test-CodeSigningCertificate -CertificatePath "C:\certs\signing.pfx" -Password $securePassword
#>
function Test-CodeSigningCertificate {
    param(
        [Parameter(Mandatory)]
        [string]$CertificatePath,
        [SecureString]$Password
    )

    try {
        if (-not (Test-Path $CertificatePath)) {
            return $false
        }

        # Try to import the certificate temporarily to test validity
        $tempStore = "Cert:\CurrentUser\My"
        $cert = Import-PfxCertificate -FilePath $CertificatePath -CertStoreLocation $tempStore -Password $Password -ErrorAction Stop
        
        # Check if certificate is suitable for code signing
        $isValid = $cert.HasPrivateKey -and ($cert.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.37" -and $_.Format($true) -match "Code Signing" })
        
        # Clean up - remove the temporarily imported certificate
        Remove-Item -Path "$tempStore\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
        
        return $isValid
    }
    catch {
        return $false
    }
}

Export-ModuleMember -Function @(
    'New-K2sCodeSigningCertificate',
    'Import-K2sCodeSigningCertificate', 
    'Set-K2sScriptSignature',
    'Set-K2sExecutableSignature',
    'Set-K2sScriptSignatures',
    'Get-K2sCodeSigningCertificate',
    'Test-CodeSigningCertificate',
    'Invoke-K2sCodeSigning',
    'Get-SignableFiles'
)
