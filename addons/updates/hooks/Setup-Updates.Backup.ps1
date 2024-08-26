# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to back-up the data of the updates addon.

.DESCRIPTION
Hook to back-up the data of the updates addon.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)
$logModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$updatesModule = "$PSScriptRoot\..\updates\updates.module.psm1"

Import-Module $logModule, $updatesModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Backing-up data of updates addon..' -Console

Backup-AddonData -BackupDir $BackupDir

Write-Log 'Updates addons data backed-up.' -Console