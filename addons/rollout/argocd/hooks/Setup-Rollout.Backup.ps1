# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to back-up the data of the rollout addon.

.DESCRIPTION
Hook to back-up the data of the rollout addon.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)
$logModule = "$PSScriptRoot/../../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$rolloutModule = "$PSScriptRoot\..\rollout.module.psm1"

Import-Module $logModule, $rolloutModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Backing-up data of rollout addon..' -Console

Backup-AddonData -BackupDir $BackupDir

Write-Log 'rollout addons data backed-up.' -Console