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

$infraModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for executing this script
$installationPath = Get-KubePath
Set-Location $installationPath

$installationType = 'Build-only'
Write-Log "Uninstalling $installationType setup"

Uninstall-WinNode

$controlPlaneNodeParams = @{
    ShowLogs = $ShowLogs
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    SkipHeaderDisplay = $true
}
& "$PSScriptRoot\..\..\control-plane\Uninstall.ps1" @controlPlaneNodeParams

Write-Log "K2s $installationType setup uninstalled."

Save-k2sLogDirectory -RemoveVar

