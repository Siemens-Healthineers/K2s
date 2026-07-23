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
