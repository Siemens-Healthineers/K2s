# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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

Remove-K2sHostsFromNoProxyEnvVar

# Refresh PATH for current session to avoid stale k2s entries
$env:PATH =
[Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
        [Environment]::GetEnvironmentVariable("Path", "User")

Write-Log 'PATH refreshed for current PowerShell session after uninstall.'

Write-Log "K2s $installationType setup uninstalled."

Save-k2sLogDirectory -RemoveVar

