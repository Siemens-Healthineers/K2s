# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to restore the data of updates addon.

.DESCRIPTION
Hook to restore the data of updates addon.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to restore data from.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)
$logModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$updatesModule = "$PSScriptRoot\..\updates\updates.module.psm1"

Import-Module $logModule, $updatesModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "Restoring the data of updates addon from '$BackupDir'.." -Console

Restore-AddonData -BackupDir $BackupDir

Write-Log "Updates addons data restored from '$BackupDir'." -Console