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
$ErrorActionPreference = 'Continue'
if ($Trace) {
    Set-PSDebug -Trace 1
}

Write-Host "Take ownership now on items in dir: $Directory"
takeown /a /r /d Y /F $Directory 2>&1 | Write-Host

Write-Host "Add ownership also for Administrators"
icacls $Directory /grant Administrators:F /t /C 2>&1 | Write-Host

Write-Host "Delete reparse points in the directory: $Directory"
Get-ChildItem -Path $Directory -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" }

Write-Host "Remove items from: $Directory"
remove-item -path $Directory -Force -Recurse -ErrorAction 'silentlycontinue'

Write-Host "Cleanup finished"