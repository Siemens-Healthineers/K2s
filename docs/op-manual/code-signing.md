# K2s Code Signing

This document describes the K2s code signing functionality that ensures all executables and PowerShell scripts are signed with a trusted certificate.

## Overview

K2s includes comprehensive code signing capabilities to meet enterprise security requirements:

- **PowerShell Scripts**: All `.ps1` files are signed with Authenticode signatures
- **Executables**: All `.exe` files are signed with code signing certificates
- **Automated Packaging**: Create complete signed packages via `k2s system package`
- **CI/CD Integration**: Automated signing in GitHub Actions workflows

**Important**: Certificate operations require administrator privileges as certificates are stored in the LocalMachine certificate store for enterprise-wide deployment.

## Quick Start

### Create a Signed Package

```powershell
# Create package with existing certificate
k2s system package --certificate mycert.pfx --output k2s-signed.zip
```

### Install Certificate for Trust

```powershell
# Import the signing module (requires administrator privileges)
Import-Module .\lib\modules\k2s\k2s.signing.module\k2s.signing.module.psm1

# Import certificate from package (requires administrator privileges)
Import-K2sCodeSigningCertificate -CertificatePath k2s-signing.pfx
```

## Command Reference

### `k2s system package`

Creates a complete K2s package with all components signed.

**Options:**

- `--certificate, -c`: Path to existing code signing certificate (.pfx)
- `--output, -o`: Output path for signed package (required)

**Examples:**

```bash
# Use existing certificate
k2s system package --certificate ./certs/my-cert.pfx --output ./packages/k2s-signed.zip
```

## PowerShell Module Reference

The `k2s.signing.module` provides low-level signing functionality. **Note**: All certificate operations require administrator privileges.

### Certificate Management

```powershell
# Create new certificate (requires administrator privileges)
$cert = New-K2sCodeSigningCertificate -OutputPath "cert.pfx" -Password $securePassword

# Import certificate (requires administrator privileges)
Import-K2sCodeSigningCertificate -CertificatePath "cert.pfx" -Password $securePassword

# List K2s certificates (requires administrator privileges)
Get-K2sCodeSigningCertificate
```

### Signing Operations

```powershell
# Sign single PowerShell script
Set-K2sScriptSignature -ScriptPath "script.ps1" -CertificateThumbprint "ABC123..."

# Sign all scripts in directory
Set-K2sScriptSignatures -RootPath "C:\k2s" -CertificateThumbprint "ABC123..."

# Sign executable
Set-K2sExecutableSignature -ExecutablePath "app.exe" -CertificatePath "cert.pfx"
```

## Certificate Requirements

### Self-Signed Certificates

The built-in certificate creation uses:

- **Algorithm**: RSA 2048-bit
- **Key Usage**: Digital Signature
- **Validity**: 10 years (configurable)
- **Type**: Code Signing Certificate

### External Certificates

For production use, you can provide:

- **Commercial certificates** from trusted CAs (Digicert, GlobalSign, etc.)
- **Enterprise certificates** from internal CAs
- **Hardware Security Module (HSM)** certificates

Requirements:

- Must support code signing (`Enhanced Key Usage: 1.3.6.1.5.5.7.3.3`)
- Must be in PKCS#12 (.pfx) format with private key
- Must be password-protected

## Security Considerations

### Certificate Storage

- **Development**: Self-signed certificates stored in `LocalMachine\My` (requires administrator privileges)
- **Production**: Use HSM or secure certificate storage
- **CI/CD**: Certificates stored as encrypted secrets

### Trust Validation

The signing process installs certificates in:

- `LocalMachine\My`: For signing operations
- `LocalMachine\TrustedPublisher`: For script execution
- `LocalMachine\Root`: For trust chain validation

### Execution Policy

Signed scripts work with these PowerShell execution policies:

- `RemoteSigned`: Allows locally created and signed scripts
- `AllSigned`: Requires all scripts to be signed
- `Restricted`: Blocks all script execution

## CI/CD Integration

### GitHub Actions

The included workflow (`.github/workflows/code-signing.yml`) provides:

- **Automatic signing** on commits to main/develop
- **Certificate management** via GitHub Secrets
- **Signed release packages** for tagged versions
- **Signature verification** in CI pipeline

### Setup GitHub Secrets

For automated signing, configure these secrets:

```
K2S_SIGNING_CERT_BASE64    # Base64-encoded .pfx certificate
K2S_SIGNING_CERT_PASSWORD  # Certificate password
```

### Manual Certificate Creation

To create certificates for CI/CD:

```powershell
# Create certificate
$cert = New-K2sCodeSigningCertificate -OutputPath "k2s-ci.pfx"

# Convert to base64 for GitHub Secrets
$bytes = [System.IO.File]::ReadAllBytes("k2s-ci.pfx")
$base64 = [Convert]::ToBase64String($bytes)
Write-Output $base64
```

## Verification

### Verify PowerShell Scripts

```powershell
# Check script signature
$sig = Get-AuthenticodeSignature -FilePath "script.ps1"
Write-Host "Status: $($sig.Status)"
Write-Host "Signer: $($sig.SignerCertificate.Subject)"
```

### Verify Executables

```cmd
# Using signtool (Windows SDK required)
signtool verify /v /pa app.exe

# Check certificate details
signtool verify /v /pa /all app.exe
```

### Package Verification

Signed packages include a `package-manifest.json` with:

- Package creation timestamp
- Certificate information
- Count of signed files
- Verification checksums

## Troubleshooting

### Common Issues

**"Execution policy does not allow this script"**

- Solution: Install certificate with `Import-K2sCodeSigningCertificate`
- Alternative: Set execution policy to `RemoteSigned`

**"Certificate not found for signing"**

- Solution: Verify certificate is in `LocalMachine\My` store (requires administrator privileges)
- Check thumbprint matches signing command

**"Signtool not found"**

- Solution: Install Windows SDK or Visual Studio Build Tools
- Alternative: Use Windows ADK

### Debug Signing Issues

```powershell
# List available certificates (requires administrator privileges)
Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.KeyUsage -band [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DigitalSignature }

# Test certificate
$cert = Get-ChildItem Cert:\LocalMachine\My\THUMBPRINT
Test-Certificate -Cert $cert -Policy SSL

# Validate script signature
$sig = Get-AuthenticodeSignature -FilePath "script.ps1"
$sig | Format-List *
```

## Best Practices

### Development

- Use self-signed certificates for local development
- Include certificate import in setup scripts
- Test with `AllSigned` execution policy

### Production

- Use commercial or enterprise CA certificates
- Implement certificate rotation procedures
- Monitor certificate expiration dates
- Use HSM for private key protection

### Distribution

- Include certificates in installation packages
- Document certificate import procedures
- Provide verification instructions
- Maintain certificate trust chains

## Related Documentation

- [PowerShell Execution Policies](https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies)
- [Authenticode Signing](https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-authenticodesignature)
- [Code Signing Best Practices](https://docs.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-best-practices)

## Development and Testing

### Unit Testing

The K2s signing module includes comprehensive unit tests that demonstrate best practices for testing PowerShell modules with external dependencies:

**Location**: `lib\modules\k2s\k2s.signing.module\k2s.signing.module.unit.tests.ps1`

**Key Features**:

- **Zero Side Effects**: Tests use mocks and don't create certificates or modify system state
- **Fast Execution**: Complete test suite runs in ~1-2 seconds
- **Comprehensive Coverage**: Tests all signing functions and edge cases
- **Mock Strategy**: Uses module-level mocking with PSObject-based certificate mocks

**Running Tests**:

```powershell
# Run signing module unit tests
Invoke-Pester .\lib\modules\k2s\k2s.signing.module\k2s.signing.module.unit.tests.ps1

# Run with detailed output
Invoke-Pester -Output Detailed .\lib\modules\k2s\k2s.signing.module\k2s.signing.module.unit.tests.ps1
```

The unit tests serve as both validation and documentation of proper mocking techniques for external dependencies like certificate operations, file system access, and external tool execution.

For detailed information about PowerShell module unit testing best practices, see [Automated Testing](../dev-guide/contributing/automated-testing.md#powershell-module-unit-testing-best-practices).
