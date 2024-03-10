# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

# Only for docker: Cleanup in the docker way by renaming the folders
# Get-ChildItem -Path d:\docker\windowsfilter -Directory | % {Rename-Item $_.FullName "$($_.FullName)-removing" -ErrorAction:SilentlyContinue}
# Restart-Service *docker*
# needs to be done multiple times till all directories from windowsfilter are deleted !!

# OR

# 1. set right to be able to delete reparse points
# 2. icacls "D:\containerdold" /grant Administrators:F /t /C
# 3. Get-ChildItem -Path e:\docker_old3 -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim("\"); fsutil reparsepoint delete "$n" }
# deletes all reparse points
# then afterwards all directories can be deleted
# 4. takeown /a /r /d Y /f e:\docker_old3
# 5. remove-item -path "e:\docker_old3" -Force -Recurse -ErrorAction SilentlyContinue
<#
.SYNOPSIS
Cleanup docker storage directory 

.DESCRIPTION
Cleanup docker storage directory  from all reparse points which could lead to an inconsistent system.
Allso delete the whole folder afterwards.

.EXAMPLE
powershell <installation folder>\helpers\CleanupContainerStorage.ps1 -Directory d:\docker
powershell <installation folder>\helpers\CleanupContainerStorage.ps1 -Directory d:\containerd
#>

Param(
    [parameter(Mandatory = $true, HelpMessage = 'Docker directory to clean up')]
    [string] $Directory = 'd:\docker1'
)

&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
Import-Module $logModule -DisableNameChecking

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

Write-Log "Take ownership now on items in dir: $Directory" -Console
takeown /a /r /d Y /F $Directory 2>&1 | Write-Log -Console

Write-Log "Add ownership also for Administrators" -Console
icacls $Directory /grant Administrators:F /t /C 2>&1 | Write-Log -Console

Write-Log "Delete reparse points in the directory: $Directory" -Console
Get-ChildItem -Path $Directory -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" 2>&1 | Write-Log -Console }

Write-Log "Remove items from: $Directory" -Console
remove-item -path $Directory -Force -Recurse -ErrorAction 'silentlycontinue'

Write-Log "Cleanup finished" -Console