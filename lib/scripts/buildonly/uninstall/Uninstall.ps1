# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
Import-Module $infraModule, $nodeModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Uninstalling Build Only Environment'

Uninstall-LinuxNode -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Uninstall-WinNode

Clear-WinNode -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Reset-EnvVars

Write-Log 'Uninstalling Build Only Environment done.'

Save-k2sLogDirectory -RemoveVar