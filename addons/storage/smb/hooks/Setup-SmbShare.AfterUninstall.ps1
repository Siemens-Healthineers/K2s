# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Post-uninstall hook to remove SMB share.

.DESCRIPTION
Post-uninstall hook to remove SMB share.
#>

$logModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$smbShareModule = "$PSScriptRoot\..\storage\smb\module\Smb-share.module.psm1"

Import-Module $logModule, $smbShareModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Removing SMB share after cluster deinstallation..' -Console

# no need to cleanup the node VMs, they get deleted anyways
$err = (Disable-SmbShare -SkipNodesCleanup).Error
if ($err) {
    Write-Log $err.Message -Console
    exit 1
}

Write-Log 'SMB share removed after cluster deinstallation.' -Console