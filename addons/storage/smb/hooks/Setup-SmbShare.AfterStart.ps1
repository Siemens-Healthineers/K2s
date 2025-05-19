# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
$smbShareModule = "$PSScriptRoot\..\storage\smb\module\Smb-share.module.psm1"

Import-Module $logModule, $smbShareModule

$script = $MyInvocation.MyCommand.Name

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "[$script] Re-establishing SMB share after cluster start.." -Console

$smbHostType = Get-SmbHostType
$storageConfig = Get-StorageConfig
    
foreach ($storageEntry in $storageConfig) {
    Restore-SmbShareAndFolder -SmbHostType $smbHostType -Config $storageEntry
}

Write-Log "[$script] SMB share re-established after cluster start." -Console