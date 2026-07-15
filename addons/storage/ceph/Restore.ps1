# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Restores storage ceph configuration

.DESCRIPTION
Completes the restore of the storage ceph addon.

Ceph is backed by an EXTERNAL Ceph cluster, so there is no addon-owned persistent data to copy
back. The connection configuration (ceph-config.json) is already restored and the addon is already
(re)enabled by the CLI via EnableForRestore.ps1 before this script runs. This script therefore only
validates the backup metadata and reports completion. The config snapshot is (idempotently)
re-applied as a safety net for restore paths that do not run EnableForRestore.ps1.

.PARAMETER BackupDir
Directory containing extracted backup artifacts (staging folder).

.EXAMPLE
powershell <installation folder>\addons\storage\ceph\Restore.ps1 -BackupDir C:\Temp\storage-ceph-restore
#>
Param(
    [parameter(Mandatory = $true, HelpMessage = 'Back-up directory to restore data from.')]
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

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{ Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log "[StorageCephRestore] Restoring addon 'storage ceph'" -Console

if (-not (Test-Path -LiteralPath $BackupDir)) {
    $errMsg = "Restore failed: BackupDir not found: $BackupDir"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

try {
    # Re-apply the config snapshot (idempotent). EnableForRestore.ps1 already did this before the
    # addon was enabled; this covers restore flows that call a plain Enable.ps1 without a BackupDir.
    $configSnapshotPath = Join-Path $BackupDir 'ceph-config.json'
    if (Test-Path -LiteralPath $configSnapshotPath) {
        $configPath = "$PSScriptRoot\config\ceph-config.json"
        Write-Log "[StorageCephRestore] Ensuring config snapshot is applied at '$configPath'" -Console
        Copy-Item -LiteralPath $configSnapshotPath -Destination $configPath -Force
    }
    else {
        Write-Log "[StorageCephRestore] No config snapshot found (ceph-config.json); using current config." -Console
    }

    Write-Log "[StorageCephRestore] Ceph is backed by an external cluster; no addon-owned data to restore." -Console
    Write-Log "[StorageCephRestore] Restore completed" -Console
}
catch {
    $errMsg = "Restore of addon 'storage ceph' failed: $($_.Exception.Message)"

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{ Error = $null }
}
