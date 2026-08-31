# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$startLocation = Get-Location

Set-Location $PSScriptRoot

$Env:GOOS = 'windows'
$Env:GOARCH = 'amd64'

go build -ldflags="-w -s" -trimpath -o "$PSScriptRoot\dist\diskwriter.exe"

if ($LASTEXITCODE -ne 0) {
    Set-Location $startLocation

    throw 'Go build failed, see logs above for details'
}

Set-Location $startLocation