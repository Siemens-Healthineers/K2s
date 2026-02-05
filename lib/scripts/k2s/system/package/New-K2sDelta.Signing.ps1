# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

# Code signing helpers

<#
.SYNOPSIS
    Signs executable and script files in the staging directory.

.DESCRIPTION
    Uses the provided certificate to sign .exe, .dll, .ps1, .psm1, and .psd1 files.
    Logs warnings for files that fail to sign but does not throw.

.PARAMETER Context
    Hashtable containing:
    - StageDir: Directory containing files to sign
    - CertificatePath: Path to .pfx certificate file
    - Password: Certificate password (plain string)

.OUTPUTS
    PSCustomObject with properties:
    - Success: $true if signing was attempted (even with warnings)
    - SignedCount: Number of successfully signed files
    - FailedCount: Number of files that failed to sign
    - Skipped: $true if signing was skipped due to missing parameters
    - Error: Error message if signing setup failed
#>
function Invoke-DeltaCodeSigning {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $Context
    )

    $result = [pscustomobject]@{
        Success     = $false
        SignedCount = 0
        FailedCount = 0
        Skipped     = $false
        Error       = $null
    }

    # Check if both parameters are provided
    if (-not $Context.CertificatePath -or -not $Context.Password) {
        if ($Context.CertificatePath -or $Context.Password) {
            Write-Log "[Warning] Both -CertificatePath and -Password must be specified for signing; skipping signing."
        }
        $result.Skipped = $true
        $result.Success = $true
        return $result
    }

    Write-Log "Attempting code signing using certificate '$($Context.CertificatePath)'" -Console

    try {
        # Validate certificate file exists
        if (-not (Test-Path -LiteralPath $Context.CertificatePath)) {
            throw "Certificate file not found."
        }

        # Load certificate
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $Context.CertificatePath,
            $Context.Password,
            'Exportable,MachineKeySet'
        )

        if (-not $cert.HasPrivateKey) {
            throw "Certificate does not contain a private key."
        }

        # Find files to sign
        $signExtensions = @('*.exe', '*.dll', '*.ps1', '*.psm1', '*.psd1')
        $filesToSign = foreach ($pat in $signExtensions) {
            Get-ChildItem -Path $Context.StageDir -Recurse -Include $pat -File
        }

        # Sign each file
        foreach ($f in $filesToSign) {
            try {
                $sig = Set-AuthenticodeSignature -FilePath $f.FullName `
                    -Certificate $cert `
                    -TimestampServer "http://timestamp.digicert.com" `
                    -ErrorAction Stop

                if ($sig.Status -ne 'Valid') {
                    Write-Log "[Warning] Signing issue for $($f.FullName): Status=$($sig.Status)"
                    $result.FailedCount++
                }
                else {
                    Write-Log "Signed: $($f.FullName)"
                    $result.SignedCount++
                }
            }
            catch {
                Write-Log "[Warning] Failed to sign '$($f.FullName)': $($_.Exception.Message)"
                $result.FailedCount++
            }
        }

        $result.Success = $true
    }
    catch {
        Write-Log "[Warning] Code signing setup failed: $($_.Exception.Message)"
        $result.Error = $_.Exception.Message
    }

    return $result
}
