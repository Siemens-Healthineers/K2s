# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to restore storage ceph configuration.

.DESCRIPTION
Hook to restore storage ceph configuration for 'k2s system restore' and cluster upgrade.

During an upgrade the addon install folder is replaced and ceph-config.json is reset to the shipped
defaults. This hook copies the previously backed-up ceph-config.json back into the addon config
directory BEFORE the addon is re-enabled, so the effective monitor endpoints and credentials are
preserved. Without this, re-enabling the ceph addon would fail because the required connection
settings would be missing.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to restore data from.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.'),
    [Parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch]$ShowLogs = $false
)
$script = $MyInvocation.MyCommand.Name
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $infraModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[$script] Restoring storage ceph configuration.." -Console

$sourcePath = Join-Path $BackupDir 'ceph-config.json'

if (-not (Test-Path -LiteralPath $sourcePath)) {
    Write-Log "[$script] No storage ceph config snapshot found at '$sourcePath'; nothing to restore." -Console
    return
}

$configDir = "$(Get-KubePath)\addons\storage\ceph\config"
if (-not (Test-Path -LiteralPath $configDir)) {
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null
}

$targetPath = Join-Path $configDir 'ceph-config.json'
Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force

Write-Log "[$script] Storage ceph configuration restored to '$targetPath'." -Console
