# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#[
.SYNOPSIS
Enables the storage ceph addon in restore mode

.DESCRIPTION
Restore-specific enable hook for the storage ceph addon.

Ceph connects to an EXTERNAL Ceph cluster, so the only state required to re-enable the addon is
its connection configuration (monitor endpoints, credentials, pool/filesystem names). This script
first restores the 'ceph-config.json' snapshot from the backup staging folder into the addon config
directory, then delegates to Enable.ps1 which reads that restored config.

The CLI invokes this script (instead of Enable.ps1) before running Restore.ps1.

.PARAMETER BackupDir
Directory containing extracted backup artifacts (staging folder with backup.json + ceph-config.json).

.EXAMPLE
powershell <installation folder>\addons\storage\ceph\EnableForRestore.ps1 -BackupDir C:\Temp\storage-ceph-restore
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing extracted backup artifacts')]
    [string] $BackupDir,

    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[StorageCephEnableForRestore] Enabling addon 'storage ceph' (restore mode)" -Console

$configPath = "$PSScriptRoot\config\ceph-config.json"

try {
    if (-not [string]::IsNullOrWhiteSpace($BackupDir)) {
        $configSnapshotPath = Join-Path $BackupDir 'ceph-config.json'
        if (Test-Path -LiteralPath $configSnapshotPath) {
            Write-Log "[StorageCephEnableForRestore] Restoring config snapshot to '$configPath'" -Console
            Copy-Item -LiteralPath $configSnapshotPath -Destination $configPath -Force
        }
        else {
            Write-Log "[StorageCephEnableForRestore] No config snapshot found (ceph-config.json) in '$BackupDir'; using current config." -Console
        }
    }
}
catch {
    $errMsg = "Restore of storage ceph config failed: $($_.Exception.Message)"
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'addon-restore-failed' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{ Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# Delegate to the regular Enable.ps1, which reads the (restored) ceph-config.json.
$enableParams = @{ ShowLogs = $ShowLogs }
if ($EncodeStructuredOutput -eq $true) {
    $enableParams.EncodeStructuredOutput = $true
    $enableParams.MessageType = $MessageType
}

& "$PSScriptRoot\Enable.ps1" @enableParams
