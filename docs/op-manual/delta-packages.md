<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Delta Packages

Delta packages provide a bandwidth-efficient way to upgrade *K2s* installations by including only the files that have changed between two versions, rather than redistributing the entire package.

## Overview

A delta package contains:

- **Changed files**: Files that differ between the source and target versions
- **Wholesale directories**: Complete directories that must be replaced entirely (e.g., `bin/`, `addons/`)
- **Delta manifest**: A JSON file describing the changes and metadata
- **Debian package changes** (optional): Linux package differences for the KubeMaster VM
- **Apply script**: A PowerShell script to apply the delta to an existing installation

### Delta Package vs Full Package

| Aspect | Full Package | Delta Package |
|--------|--------------|---------------|
| Size | 2-4 GB typically | 50-500 MB typically |
| Contains | All K2s files | Only changed files |
| Requires | Nothing | Specific source version |
| Use case | Fresh installs, major upgrades | Minor/patch upgrades |

## Creating a Delta Package

### Prerequisites

- Two *K2s* offline packages (source and target versions)
- PowerShell 5.1 or later
- Sufficient disk space for extraction (3x package size recommended)

### Basic Usage

```console
k2s system package --delta-package `
    -d C:\packages `
    -n k2s-delta-v1.4.0-to-v1.5.0.zip `
    --package-version-from C:\packages\k2s-v1.4.0.zip `
    --package-version-to C:\packages\k2s-v1.5.0.zip
```

!!! note "Experimental Feature"
    Delta package creation is currently marked as experimental. The feature is fully functional but the CLI interface may evolve in future releases.

### Parameters

| Flag | Required | Description |
|------|----------|-------------|
| `--delta-package` | Yes | Enables delta package creation mode |
| `-d, --target-dir` | Yes | Target directory for the output package |
| `-n, --name` | Yes | Name of the output delta package ZIP file |
| `--package-version-from` | Yes | Path to the older (source) K2s package ZIP |
| `--package-version-to` | Yes | Path to the newer (target) K2s package ZIP |
| `-c, --certificate` | No | Path to code signing certificate (.pfx file) |
| `-w, --password` | No | Password for the code signing certificate |
| `-o, --output` | No | Show log output in terminal |

### Example with Code Signing

```console
k2s system package --delta-package `
    -d C:\packages `
    -n k2s-delta-v1.4.0-to-v1.5.0.zip `
    --package-version-from C:\packages\k2s-v1.4.0.zip `
    --package-version-to C:\packages\k2s-v1.5.0.zip `
    -c path\to\cert.pfx `
    -w mycertpassword
```

## Delta Package Contents

After creation, the delta package contains:

```
k2s-delta-v1.4.0-to-v1.5.0.zip
├── delta-manifest.json          # Metadata and file lists
├── Apply-Delta.ps1              # Application script
├── bin/                         # Changed binaries (wholesale)
├── addons/                      # Changed addon files (wholesale)
├── lib/                         # Changed library files
├── smallsetup/                  # Changed setup scripts
├── scripts/                     # Delta application scripts
│   ├── apply-debian-delta.sh   # Linux package update script
│   └── verify-debian-delta.sh  # Linux package verification
└── debian-delta/                # (Optional) Debian package changes
    ├── added-packages.txt
    ├── removed-packages.txt
    ├── changed-packages.txt
    └── packages/                # Downloaded .deb files
```

### Delta Manifest Structure

The `delta-manifest.json` file describes the changes between versions. A typical manifest includes:

```json
{
  "sourceVersion": "1.4.0",
  "targetVersion": "1.5.0",
  "createdAt": "2025-02-03T10:30:00Z",
  "filesAdded": ["lib/new-module.psm1"],
  "filesModified": ["lib/existing-module.psm1"],
  "filesRemoved": ["lib/deprecated-module.psm1"],
  "wholesaleDirectories": ["bin", "addons"],
  "debianDelta": {
    "added": ["new-package"],
    "removed": ["old-package"],
    "changed": ["updated-package"]
  },
  "imageDiff": {
    "added": ["new-image:tag"],
    "removed": ["old-image:tag"]
  }
}
```

## Applying a Delta Package

### Prerequisites

- An existing *K2s* installation matching the delta's source version
- Administrator privileges
- The delta package ZIP file

### Application Steps

1. Extract the delta package to a temporary location:
   ```powershell
   Expand-Archive -Path "k2s-delta-v1.4.0-to-v1.5.0.zip" -DestinationPath "C:\temp\delta"
   ```

2. Run the upgrade from the extracted delta folder:
   ```console
   cd C:\temp\delta
   k2s system upgrade
   ```

3. Verify the installation:
   ```console
   k2s system status
   ```

## Best Practices

### When to Use Delta Packages

✅ **Recommended for:**

- Minor version upgrades (e.g., 1.4.0 → 1.5.0)
- Patch releases (e.g., 1.4.0 → 1.4.1)
- Bandwidth-constrained environments
- Large-scale deployments with many nodes

❌ **Not recommended for:**

- Major version upgrades (e.g., 1.x → 2.x)
- Fresh installations
- Upgrades spanning multiple minor versions

### Version Compatibility

> **⚠️ Version Matching:** Delta packages are version-specific. A delta from v1.4.0 to v1.5.0 can **only** be applied to installations running exactly v1.4.0.

To upgrade across multiple versions, either:

1. Create sequential delta packages (v1.4.0 → v1.4.1 → v1.5.0)
2. Use a full package for the final version

## Troubleshooting

### Common Issues

#### Version Mismatch Error

```
Error: Source version mismatch. Expected 1.4.0, found 1.3.0
```

**Solution**: Ensure your current installation matches the delta's source version, or use `-Force` (with caution).

#### Missing Files After Apply

Check the delta manifest to verify which files were expected:

```powershell
Get-Content delta-manifest.json | ConvertFrom-Json | Select-Object -ExpandProperty filesAdded
```

#### Debian Delta Failures

If Linux package updates fail:

1. Check network connectivity in the VM
2. Verify the `.deb` files exist in `debian-delta/packages/`
3. Run verification script to identify missing packages

### Logs

Delta package creation logs are written to:

- Console output (with `-o` or `--output` flag)
- K2s log directory: `C:\var\log\k2s\`

For more detailed logging, use the verbosity flag:
```console
k2s system package --delta-package ... -o -v debug
```

## Integration with CI/CD

### Automated Delta Generation

```yaml
# Example GitHub Actions workflow snippet
- name: Generate Delta Package
  run: |
    k2s system package --delta-package `
      -d ${{ env.OUTPUT_DIR }} `
      -n "k2s-delta-${{ env.PREV_VERSION }}-to-${{ env.NEW_VERSION }}.zip" `
      --package-version-from "${{ env.PREV_PACKAGE }}" `
      --package-version-to "${{ env.NEW_PACKAGE }}" `
      -o
```

### Artifact Publishing

Delta packages can be published alongside full releases:

```
releases/
├── k2s-v1.5.0.zip                    # Full package
├── k2s-delta-v1.4.0-to-v1.5.0.zip   # Delta from previous minor
└── k2s-delta-v1.4.1-to-v1.5.0.zip   # Delta from previous patch
```

## See Also

- [Creating Offline Package](creating-offline-package.md) - Full offline package creation
- [Upgrading K2s](upgrading-k2s.md) - Standard upgrade procedures
- [Sign K2s Package](signcatalog-k2s.md) - Code signing for packages
