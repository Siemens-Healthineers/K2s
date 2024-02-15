# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Post-uninstall hook to remove nginx-ext service.

.DESCRIPTION
Post-uninstall hook to remove nginx-ext service.
#>

$logModule = "$PSScriptRoot\..\..\smallsetup\ps-modules\log\log.module.psm1"
$pathModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/path/path.module.psm1"
Import-Module $logModule, $pathModule

# stop nginx service
Write-Log 'Stop nginx service' -Console
nssm stop nginx-ext | Write-Log

# remove nginx service
Write-Log 'Remove nginx service' -Console
nssm remove nginx-ext confirm | Write-Log

# cleanup installation directory
Remove-Item -Recurse -Force "$(Get-KubeBinPath)\nginx" | Out-Null

Write-Log 'exthttpaccess removed after cluster deinstallation.' -Console