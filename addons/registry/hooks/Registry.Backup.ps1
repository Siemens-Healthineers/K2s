# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to back-up local registry data.

.DESCRIPTION
Hook to back-up local registry data.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to write data to.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
Import-Module $infraModule, $nodeModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Backing-up local registry data..' -Console

Copy-FromControlPlaneViaSSHKey -Source "/registry/repository/*" -Target "$BackupDir\images"

Write-Log 'Local registry data backed-up.' -Console