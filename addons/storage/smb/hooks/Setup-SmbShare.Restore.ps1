# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to restore SMB share data.

.DESCRIPTION
Hook to restore SMB share data.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to restore data from.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)
$logModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$smbShareModule = "$PSScriptRoot\..\storage\smb\module\Smb-share.module.psm1"

Import-Module $logModule, $smbShareModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "Restoring SMB share data from '$BackupDir'.." -Console

Restore-AddonData -BackupDir $BackupDir

Write-Log "SMB share data restored from '$BackupDir'." -Console