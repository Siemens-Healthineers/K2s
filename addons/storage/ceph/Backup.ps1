# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Backs up storage ceph configuration

.DESCRIPTION
Creates a backup in a staging folder. The CLI wraps the staging folder into a zip archive.

Ceph is backed by an EXTERNAL Ceph cluster, so there is no local persistent data owned by
this addon to back up. The user data lives on the external Ceph cluster and is not touched by
enabling/disabling this addon. Therefore this backup only captures the connection configuration
that is required to re-enable the addon (monitor endpoints, credentials, pool/filesystem names).

This backup contains:
- A snapshot of the storage ceph config file (ceph-config.json)
- A snapshot of the addon entry from setup.json (best-effort)
- A rendered snapshot of the SMB CSI manifests used by Ceph (when SMB is configured)
- Best-effort snapshots of Ceph SMB Kubernetes resources (namespace, secret, StorageClass)

.PARAMETER BackupDir
Destination directory for backup artifacts.

.EXAMPLE
powershell <installation folder>\addons\storage\ceph\Backup.ps1 -BackupDir C:\Temp\storage-ceph-backup
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Directory where backup files will be written')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot/../../addons.module.psm1"

Import-Module $infraModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[StorageCephBackup] Backing up addon 'storage ceph'" -Console

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'storage'; Implementation = 'ceph' })) -ne $true) {
    $errMsg = "Addon 'storage ceph' is not enabled. Nothing to back up."
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'addon-not-enabled' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# Best-effort only: allow backing up local config even if cluster isn't running
$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    Write-Log "[StorageCephBackup] Note: system not available ($($systemError.Message)). Backing up local config only." -Console
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null

$files = @()

try {
    # 1) Snapshot config file (contains monitor endpoints, credentials, pool/filesystem names)
    $configPath = "$PSScriptRoot\config\ceph-config.json"
    $configSnapshotPath = Join-Path $BackupDir 'ceph-config.json'

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Storage Ceph config file not found: $configPath"
    }

    Copy-Item -LiteralPath $configPath -Destination $configSnapshotPath -Force
    $files += (Split-Path -Leaf $configSnapshotPath)

    # 2) Snapshot addon config from setup.json (best-effort)
    $addonConfigSnapshotPath = Join-Path $BackupDir 'ceph-addon-config.json'

    $storageAddonConfig = Get-AddonConfig -Name 'storage'
    if ($null -ne $storageAddonConfig -and ($null -eq $storageAddonConfig.Implementation -or $storageAddonConfig.Implementation -eq 'ceph')) {
        $storageAddonConfig | ConvertTo-Json -Depth 100 | Set-Content -Path $addonConfigSnapshotPath -Encoding UTF8 -Force
        $files += (Split-Path -Leaf $addonConfigSnapshotPath)
    }
    else {
        Write-Log "[StorageCephBackup] No matching addon config entry found in setup.json (or implementation is not 'ceph'); skipping addon-config snapshot." -Console
    }

    # 3) Snapshot Ceph SMB manifests/resources (best-effort, only when configured).
    $cephConfig = $null
    try {
        $cephConfig = Get-Content -Path $configPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Log "[StorageCephBackup] WARNING: Failed to parse ceph-config.json for SMB snapshot: $($_.Exception.Message)" -Console
    }

    $smbConfig = if ($cephConfig -and ($cephConfig.PSObject.Properties.Name -contains 'smb')) { $cephConfig.smb } else { $null }
    $smbNamespace = if ($smbConfig -and ($smbConfig.PSObject.Properties.Name -contains 'namespace') -and -not [string]::IsNullOrWhiteSpace($smbConfig.namespace)) { "$($smbConfig.namespace)" } else { 'storage-smb-ceph' }
    $smbStorageClassName = if ($smbConfig -and ($smbConfig.PSObject.Properties.Name -contains 'storageClassName') -and -not [string]::IsNullOrWhiteSpace($smbConfig.storageClassName)) { "$($smbConfig.storageClassName)" } else { 'ceph-smb' }

    $smbSnapshotDir = Join-Path $BackupDir 'smb-csi-manifests'
    New-Item -ItemType Directory -Path $smbSnapshotDir -Force | Out-Null

    $smbManifestsDir = "$PSScriptRoot\..\smb\manifests\windows"
    if (Test-Path $smbManifestsDir) {
        Copy-Item -Path (Join-Path $smbManifestsDir '*') -Destination $smbSnapshotDir -Recurse -Force
        Get-ChildItem -Path $smbSnapshotDir -Recurse -File | ForEach-Object {
            $manifestContent = Get-Content -Path $_.FullName -Raw
            $manifestContent = $manifestContent.Replace('storage-smb', $smbNamespace)
            Set-Content -Path $_.FullName -Value $manifestContent -Encoding utf8
        }
        $files += 'smb-csi-manifests/'
    }

    if ($systemError -eq $null) {
        $smbNsResult = Invoke-Kubectl -Params 'get', 'namespace', $smbNamespace, '-o', 'yaml', '--ignore-not-found'
        if ($smbNsResult.Success -and -not [string]::IsNullOrWhiteSpace($smbNsResult.Output)) {
            $nsOut = Join-Path $BackupDir 'ceph-smb-namespace.yaml'
            Set-Content -Path $nsOut -Value $smbNsResult.Output -Encoding utf8
            $files += (Split-Path -Leaf $nsOut)
        }

        $smbCredsResult = Invoke-Kubectl -Params 'get', 'secret', 'smbcreds', '-n', $smbNamespace, '-o', 'yaml', '--ignore-not-found'
        if ($smbCredsResult.Success -and -not [string]::IsNullOrWhiteSpace($smbCredsResult.Output)) {
            $secretOut = Join-Path $BackupDir 'ceph-smb-smbcreds-secret.yaml'
            Set-Content -Path $secretOut -Value $smbCredsResult.Output -Encoding utf8
            $files += (Split-Path -Leaf $secretOut)
        }

        $smbScResult = Invoke-Kubectl -Params 'get', 'storageclass', $smbStorageClassName, '-o', 'yaml', '--ignore-not-found'
        if ($smbScResult.Success -and -not [string]::IsNullOrWhiteSpace($smbScResult.Output)) {
            $scOut = Join-Path $BackupDir 'ceph-smb-storageclass.yaml'
            Set-Content -Path $scOut -Value $smbScResult.Output -Encoding utf8
            $files += (Split-Path -Leaf $scOut)
        }
    }
}
catch {
    $errMsg = "Backup of addon 'storage ceph' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-backup-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

$version = 'unknown'
try {
    $version = Get-ConfigProductVersion
}
catch {
    # best-effort only
}

$manifest = [pscustomobject]@{
    k2sVersion     = $version
    addon          = 'storage'
    implementation = 'ceph'
    files          = $files
    createdAt      = (Get-Date).ToString('o')
}

$manifestPath = Join-Path $BackupDir 'backup.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -Path $manifestPath -Encoding UTF8 -Force

Write-Log "[StorageCephBackup] Backup artifacts prepared" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
