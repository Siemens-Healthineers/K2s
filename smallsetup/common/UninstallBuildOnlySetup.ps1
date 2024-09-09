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

$uninstallationParameters = @{
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ShowLogs = $ShowLogs
}

& "$PSScriptRoot\..\..\lib\scripts\buildonly\uninstall\uninstall.ps1" @uninstallationParameters