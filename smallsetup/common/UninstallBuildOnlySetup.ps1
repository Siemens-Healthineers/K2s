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

# load global settings
&$PSScriptRoot\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/../ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Uninstalling Build Only Environment'

Write-Log 'Uninstall containerd daemon on Windows' -Console
&"$global:KubernetesPath\smallsetup\windowsnode\UninstallContainerd.ps1"

Write-Log 'Uninstalling docker daemon on Windows' -Console
& "$global:KubernetesPath\smallsetup\windowsnode\UninstallDockerWin10.ps1"

Write-Log 'Uninstalling httpproxy daemon on Windows' -Console
Remove-ServiceIfExists 'httpproxy'

Write-Log "Uninstalling $global:VMName" -Console
& "$global:KubernetesPath\smallsetup\kubemaster\UninstallKubeMaster.ps1" -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Remove-Item -Path "$global:NssmInstallDirectory\nssm.exe" -Force -ErrorAction SilentlyContinue

Get-ChildItem "$($global:SystemDriveLetter):\var" -Recurse -ErrorAction SilentlyContinue | ? LinkType -eq 'SymbolicLink' | % { $_.Delete() }
Remove-Item -Path "$($global:SystemDriveLetter):\var" -Force -Recurse -ErrorAction SilentlyContinue
Remove-Item -Path "$global:SetupJsonFile" -Force -ErrorAction SilentlyContinue

Write-Log 'Delete downloaded artifacts for the Windows node'
&"$global:KubernetesPath\smallsetup\windowsnode\downloader\DownloadsCleaner.ps1" -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

if (Test-Path($global:DownloadsDirectory)) {
    Remove-Item $global:DownloadsDirectory -Force -Recurse
}

Reset-EnvVars

Write-Log 'Uninstalling Build Only Environment done.'