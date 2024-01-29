# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$hookFilePaths = @()
$hookFilePaths += Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.FullName }
$hookFileNames = @()
$hookFileNames += Get-ChildItem -Path "$PSScriptRoot\hooks" | ForEach-Object { $_.Name }