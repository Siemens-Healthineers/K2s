# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to back-up SMB share data.

.DESCRIPTION
Hook to back-up SMB share data.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)

Import-Module "$PSScriptRoot\..\..\smallsetup\ps-modules\log\log.module.psm1", "$PSScriptRoot\..\smb-share\module\Smb-share.module.psm1"

Write-Log 'Backing-up SMB share data..' -Console

Backup-AddonData -BackupDir $BackupDir

Write-Log 'SMB share data backed-up.' -Console