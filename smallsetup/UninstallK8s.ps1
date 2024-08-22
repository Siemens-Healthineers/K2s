# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with uninstalling a Windows system to be used for a mixed Linux/Windows Kubernetes cluster
This script is only valid for the K2s Setup !!!
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
    [switch] $SkipPurge = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
    [switch] $SkipHeaderDisplay = $false
)

$uninstallParameters = @{
    SkipPurge = $SkipPurge
    ShowLogs = $ShowLogs
    AdditionalHooksDir = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    SkipHeaderDisplay = $SkipHeaderDisplay
}

& "$PSScriptRoot\..\lib\scripts\k2s\uninstall\uninstall.ps1" @uninstallParameters