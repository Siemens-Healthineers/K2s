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

$logModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$setupInfoModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/setupinfo/setupinfo.module.psm1"
$smbShareModule = "$PSScriptRoot\..\smb-share\module\Smb-share.module.psm1"

Import-Module $logModule, $setupInfoModule, $smbShareModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Re-establishing SMB share after cluster start..' -Console

$smbHostType = Get-SmbHostType
$setupInfo = Get-SetupInfo

Restore-SmbShareAndFolder -SmbHostType $smbHostType -SetupInfo $setupInfo

Write-Log 'SMB share re-established after cluster start.' -Console