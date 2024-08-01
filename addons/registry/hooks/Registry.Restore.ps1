# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Hook to restore local registry data.

.DESCRIPTION
Hook to restore local registry data.
#>
param (
    [Parameter(Mandatory = $false, HelpMessage = 'Back-up directory to restore data from.')]
    [string]$BackupDir = $(throw 'Please specify the back-up directory.')
)

$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/k2s.node.module.psm1"
Import-Module $infraModule, $nodeModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log "Restoring local registry data from '$BackupDir'.." -Console

Copy-ToControlPlaneViaSSHKey -Source "$BackupDir\images\*" -Target '/registry/repository'
Copy-ToControlPlaneViaSSHKey -Source "$BackupDir\auth\auth.json" -Target '/root/.config/containers/auth.json'

Write-Log "Local registry data restored from '$BackupDir'." -Console