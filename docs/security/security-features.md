<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Security Features

*K2s* provides multiple layers of security — from code signing and package integrity verification to runtime security addons and encrypted container images. This page provides an overview of all security capabilities.

## Code Signing

*K2s* packages can be code-signed using Authenticode to ensure integrity and provenance. The signing module signs all executables, DLLs, MSI installers, and PowerShell scripts within a package.

### Signing During Package Creation

Pass a PFX certificate to the `k2s system package` command:

```console
k2s system package -d C:\output -n k2s-signed.zip --certificate C:\certs\signing.pfx --password <cert-password>
```

This signs all signable files before they are included in the zip package.

### What Gets Signed

| File Type | Extensions |
|-----------|-----------|
| Executables | `.exe`, `.dll`, `.msi` |
| PowerShell scripts | `.ps1`, `.psm1` |

The signing module (`k2s.signing.module`) provides:

- `Set-K2sFileSignature` — signs all K2s files using a PFX certificate with Authenticode
- `Get-SignableFiles` — discovers signable files with built-in exclusion lists for vendored third-party binaries

### Certificate Requirements

- **Format:** PFX (PKCS#12) with private key
- **For testing:** self-signed certificates work (see [Code Signing](../op-manual/code-signing.md) for creation steps)
- **For production:** use certificates from a trusted CA or an organization-managed PKI
- The PFX is imported to `LocalMachine\My` certificate store during signing

!!! tip
    For detailed step-by-step instructions including CI/CD integration, certificate creation, and verification, see the [Code Signing Guide](../op-manual/code-signing.md).

---

## Catalog Signing (WDAC / Device Guard)

For environments using Windows Defender Application Control (WDAC) or Device Guard, *K2s* supports Windows catalog file signing.

A catalog file (`.cat`) lists cryptographic hashes of all files in the distribution. Once signed with a trusted certificate, Windows can verify every file's integrity before execution.

### How It Works

1. *K2s* includes catalog definition files (`build/catalog/k2s.cdf`) that enumerate all distributed files.
2. During packaging, `PackageInspector.exe` generates the catalog file `k2s.cat`.
3. The catalog is signed using `signtool.exe` with an Authenticode certificate.
4. On target machines, the signed catalog is installed — WDAC then trusts all files listed in the catalog.

For detailed instructions, see [Sign K2s Package](../op-manual/signcatalog-k2s.md).

---

## AppLocker Policies

*K2s* ships pre-built AppLocker rules in `cfg\applocker\applockerrules.xml` for environments where AppLocker is enforced.

The rules grant the `ContainerAdministrator` account (SID `S-1-5-93-2-2`) permission to run executables from `C:\*`. This is necessary because Windows containers run processes under `ContainerAdministrator`, and AppLocker blocks execution by default for non-administrator accounts.

!!! note
    These rules only need to be imported on Windows hosts where AppLocker policies are active. In environments without AppLocker, they have no effect.

---

## SSH Key Management

*K2s* automates SSH key generation and deployment for secure communication between the Windows host and the Linux control-plane VM.

### Automated Workflow

During installation, the `k2s.node.module/linuxnode/security/` module:

1. **Generates an SSH key pair** (`New-SshKey`) — Ed25519 keys placed in the user's `~/.ssh` directory
2. **Deploys the public key** (`Copy-LocalPublicSshKeyToRemoteComputer`) — copies the public key to the Linux VM's `authorized_keys`
3. **Disables password authentication** (`Remove-ControlPlaneAccessViaUserAndPwd`) — after key deployment, password-based SSH is disabled

### Adding Additional Users

When granting a Windows user access to *K2s* via `k2s system users add`, their SSH key pair is created and deployed automatically. See [Adding K2s Users](../op-manual/adding-k2s-users.md) for the full workflow.

---

## OCI Image Encryption

The containerd configuration template (`cfg\containerd\config.toml.template`) includes support for OCI image encryption and decryption via the `ocicrypt` stream processors.

### Configuration

Encryption keys are expected at:

```
C:\k\bin\certs\encrypt\
```

The containerd configuration includes `ocicrypt` stream processors that handle transparent decryption of encrypted container image layers at pull time.

!!! note
    Image encryption is an advanced feature. Standard *K2s* deployments use unencrypted images. Enable this when deploying sensitive container images that must be protected at rest.

---

## Security Addon

The **security** addon provides runtime security features for the cluster, with two modes:

### Basic Mode (Default)

```console
k2s addons enable security
```

Installs **cert-manager** for automatic TLS certificate management within the cluster. See [Certificate Management](../user-guide/certificate-management.md) for details on the default self-signed CA, using external certificate authorities, and the `--omitCertMgr` flag.

### Enhanced Mode (Zero Trust)

```console
k2s addons enable security --type enhanced
```

Adds the following on top of basic mode:

| Component | Purpose |
|-----------|---------|
| **Linkerd** | Service mesh providing mutual TLS (mTLS) between all pods — zero-trust networking |
| **Ory Hydra** | OAuth2/OIDC provider for authentication flows |
| **Keycloak** | Identity and access management |
| **OAuth2 Proxy** | Reverse proxy for adding authentication to any service |

Optional flags to customize the security stack:

| Flag | Effect |
|------|--------|
| `--omitHydra` | Skip Hydra and the Windows login integration |
| `--omitKeycloak` | Skip Keycloak and use an external OAuth2 provider |
| `--omitOAuth2Proxy` | Skip the OAuth2 Proxy deployment |

The `login.exe` tool (bundled in `bin/`) provides Windows-logon-based authentication for the Hydra OAuth2 flow, enabling single sign-on from the Windows host.

!!! tip
    The enhanced security mode with Linkerd also enables the [Compartment Launcher](../dev-guide/architecture.md) (`cplauncher.exe`) for Windows service mesh support.

---

## SBOM Generation

*K2s* supports Software Bill of Materials (SBOM) generation for supply chain transparency, using:

- **Trivy** — vulnerability scanner and SBOM generator
- **CycloneDX** — standard SBOM format

### Generating an SBOM

```console
powershell -File build\bom\GenerateBom.ps1
```

The script:

1. Scans all container images in the running cluster
2. Scans addon manifests for additional images
3. Generates a CycloneDX-format SBOM
4. Optionally annotates components with clearance information (`-Annotate`)

### Image Inventory

A separate script dumps all container images used by *K2s*:

```console
powershell -File build\bom\DumpK2sImages.ps1
```

This produces `kubernetes_images.json` listing every image across the cluster and all addon manifests.

---

## Package Integrity

The `build/catalog/` directory contains Windows catalog files (`.cat`, `.cdf`) used for file integrity verification:

1. `PackageInspector.exe` scans the *K2s* distribution and records file hashes in a catalog definition file (`.cdf`)
2. The `.cdf` is compiled into a `.cat` catalog file
3. The catalog is signed with `signtool.exe`
4. On target machines, Windows verifies each file's hash against the catalog before execution

This provides tamper detection for the entire *K2s* distribution without requiring individual file signing.

---

## Summary

| Feature | Scope | Tool/Component |
|---------|-------|----------------|
| Code signing | Packaging | `k2s.signing.module`, `k2s system package --certificate` |
| Catalog signing | Distribution integrity | `signtool.exe`, `PackageInspector.exe` |
| AppLocker rules | Enterprise host lockdown | `cfg/applocker/applockerrules.xml` |
| SSH key management | Host-to-VM communication | `k2s.node.module/linuxnode/security/` |
| OCI image encryption | Container image protection | containerd `ocicrypt` stream processors |
| Basic security addon | TLS certificate management | cert-manager |
| Enhanced security addon | Zero trust, SSO | Linkerd, Hydra, Keycloak, OAuth2 Proxy |
| SBOM generation | Supply chain transparency | Trivy, CycloneDX |
| Package integrity | Tamper detection | Windows catalog files |

## See Also

- [Code Signing Guide](../op-manual/code-signing.md) — detailed signing workflow
- [Sign K2s Package](../op-manual/signcatalog-k2s.md) — catalog signing for WDAC
- [Adding K2s Users](../op-manual/adding-k2s-users.md) — SSH key deployment for users
- [Addons](../user-guide/addons.md) — security addon details
- [Architecture & Tools](../dev-guide/architecture.md) — bundled security tools
