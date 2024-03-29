# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Post-start hook to re-establish SMB share.

.DESCRIPTION
Post-start hook to re-establish SMB share.
#>

Import-Module "$PSScriptRoot\..\..\smallsetup\ps-modules\log\log.module.psm1", `
    "$PSScriptRoot\..\smb-share\module\Smb-share.module.psm1", `
    "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"

Write-Log 'Re-establishing SMB share after cluster start..' -Console

$smbHostType = Get-SmbHostType
$setupInfo = Get-SetupInfo

Restore-SmbShareAndFolder -SmbHostType $smbHostType -SetupInfo $setupInfo

Write-Log 'SMB share re-established after cluster start.' -Console