param(
    [Parameter(Mandatory = $true)]
    [string] $BackupFile,

    [Parameter(Mandatory = $false)]
    [switch] $ShowLogs = $false,

    [Parameter(Mandatory = $false)]
    [string] $AdditionalHooksDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot "..\..\..\..\modules\k2s\k2s.cluster.module\upgrade\upgrade.module.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "..\..\..\..\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1") -Force

# ------------------------------------------------------------
# Verify K2s is installed
# ------------------------------------------------------------
$setupInfo = Get-SetupInfo
if ($null -eq $setupInfo -or -not $setupInfo.Name) {
    throw "K2s is not installed. Please run 'k2s install' first."
}

Write-Log "Starting K2s system backup..." -Console

# ------------------------------------------------------------
# Prepare temporary backup directory
# ------------------------------------------------------------
$backupRoot = Get-TempPath
Write-Log "Using temporary backup directory: $backupRoot"

# ------------------------------------------------------------
# Resolve kube paths (once, reuse)
# ------------------------------------------------------------
$kubePath    = Get-KubePath
$kubeExePath = Get-KubeBinPathGivenKubePath -KubePathLocal $kubePath

# ------------------------------------------------------------
# Export cluster resources (no cluster start/stop)
# ------------------------------------------------------------
Write-Log "Exporting cluster resources..."
Export-ClusterResources `
    -SkipResources:$false `
    -PathResources $backupRoot `
    -ExePath $kubeExePath

# ------------------------------------------------------------
# Determine included namespaces from exported content
# ------------------------------------------------------------
$namespacedDir = Join-Path $backupRoot "Namespaced"
$includedNamespaces = @()

if (Test-Path $namespacedDir) {
    $includedNamespaces = Get-ChildItem -Path $namespacedDir -Directory |
            Select-Object -ExpandProperty Name
}

# ------------------------------------------------------------
# Execute backup hooks (if any)
# ------------------------------------------------------------
$hooksBackupPath = Join-Path $backupRoot "hooks"
New-Item -ItemType Directory -Path $hooksBackupPath -Force | Out-Null

Invoke-UpgradeBackupRestoreHooks `
    -HookType Backup `
    -BackupDir $hooksBackupPath `
    -ShowLogs:$ShowLogs `
    -AdditionalHooksDir $AdditionalHooksDir

# ------------------------------------------------------------
# Snapshot config.json separately (human-friendly design)
# ------------------------------------------------------------
$configBackupDir = Join-Path $backupRoot "config"
New-Item -ItemType Directory -Path $configBackupDir -Force | Out-Null

$configSourcePath = Join-Path $kubePath "cfg\config.json"
$configTargetPath = Join-Path $configBackupDir "config.json"

if (Test-Path $configSourcePath) {
    Copy-Item $configSourcePath -Destination $configTargetPath -Force
} else {
    Write-Log "Warning: config.json not found at $configSourcePath"
}

# ------------------------------------------------------------
# Create backup.json manifest (CLEAN + READABLE)
# ------------------------------------------------------------
Write-Log "Creating backup metadata (backup.json)..."

$rootConfig  = Get-RootConfigk2s
$clusterName = Get-ClusterName
$productVersion = Get-ProductVersion

$backupManifest = @{
    apiVersion = "k2s.backup/v1"
    kind       = "SystemBackup"

    metadata = @{
        backupTimestamp     = (Get-Date).ToString("o")
        backupTool          = "k2s system backup"
        backupToolVersion   = $productVersion
        backupFormatVersion = "1"
    }

    cluster = @{
        name       = $clusterName
        k2sVersion = $productVersion
    }

    content = @{
        included = @{
            clusterResources = $true
            namespaces       = $includedNamespaces
        }
        excluded = @{
            namespaces          = ($rootConfig.upgrade.excludednamespaces -split ",")
            namespacedResources = ($rootConfig.upgrade.excludednamespacedresources -split ",")
            clusterResources    = ($rootConfig.upgrade.excludedclusterresources -split ",")
        }
    }

    configSnapshot = @{
        source = "config/config.json"
    }
}

$metadataPath = Join-Path $backupRoot "backup.json"
$backupManifest |
        ConvertTo-Json -Depth 10 |
        Out-File -FilePath $metadataPath -Encoding utf8

# ------------------------------------------------------------
# Create final ZIP archive
# ------------------------------------------------------------
Write-Log "Creating backup archive: $BackupFile"

$backupDir = Split-Path -Path $BackupFile -Parent
if ([string]::IsNullOrWhiteSpace($backupDir)) {
    # Relative path with no directory component, use current directory
    $backupDir = Get-Location | Select-Object -ExpandProperty Path
    Write-Log "Using current directory for backup: $backupDir"
} elseif (-not (Test-Path $backupDir)) {
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Write-Log "Created backup directory: $backupDir"
}

if (Test-Path $BackupFile) {
    Remove-Item $BackupFile -Force
}

Compress-Archive `
    -Path (Join-Path $backupRoot '*') `
    -DestinationPath $BackupFile `
    -Force

Write-Log "System backup completed successfully." -Console
Write-Log "Backup file created at: $BackupFile" -Console
