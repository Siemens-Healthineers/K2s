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

Import-Module "$PSScriptRoot\..\..\smallsetup\ps-modules\log\log.module.psm1", "$PSScriptRoot\..\smb-share\module\Smb-share.module.psm1"

Write-Log 'Removing SMB share after cluster deinstallation..' -Console

# no need to cleanup the node VMs, they get deleted anyways
Disable-SmbShare -SkipNodesCleanup

Write-Log 'SMB share removed after cluster deinstallation.' -Console