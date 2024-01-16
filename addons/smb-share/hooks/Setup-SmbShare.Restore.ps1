# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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

Import-Module "$PSScriptRoot\..\..\smallsetup\ps-modules\log\log.module.psm1", "$PSScriptRoot\..\smb-share\module\Smb-share.module.psm1"

Write-Log "Restoring SMB share data from '$BackupDir'.." -Console

Restore-AddonData -BackupDir $BackupDir

Write-Log "SMB share data restored from '$BackupDir'." -Console