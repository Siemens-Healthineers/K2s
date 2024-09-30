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

$logModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$exthttpaccessModule = "$PSScriptRoot/../exthttpaccess/exthttpaccess.module.psm1"

Import-Module $logModule, $exthttpaccessModule

Initialize-Logging

Remove-Nginx

Write-Log 'exthttpaccess removed after cluster deinstallation.' -Console