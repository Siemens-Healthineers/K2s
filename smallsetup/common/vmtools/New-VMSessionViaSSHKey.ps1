# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Hostname,
    [Parameter(Mandatory = $true)]
    [string]$KeyFilePath,
    [Parameter(Mandatory = $false)]
    [int]$TimeoutInSeconds = 1800,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false
)

Import-Module "$PSScriptRoot\..\..\ps-modules\log\log.module.psm1"

$secondsIncrement = 5
$elapsedSeconds = 0

if ($NoLog -ne $true) {
    Write-Log "Waiting for connection with Hostname: '$Hostname' (timeout: $($TimeoutInSeconds)s) ..."
}

do {
    $result = New-PSSession -Hostname $Hostname -KeyFilePath $KeyFilePath -ErrorAction SilentlyContinue

    if (-not $result) {
        Start-Sleep -Seconds $secondsIncrement
        $elapsedSeconds += $secondsIncrement

        if ($NoLog -ne $true) {
            Write-Log "$($elapsedSeconds)s..<<<"
        }
    }
} while (-not $result -and $elapsedSeconds -lt $TimeoutInSeconds)

if ($elapsedSeconds -gt 0 -and $NoLog -ne $true) {
    Write-Log '.'
}

$result