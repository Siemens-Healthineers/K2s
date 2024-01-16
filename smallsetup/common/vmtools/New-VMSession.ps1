# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VMName,
    [Parameter(Mandatory = $true)]
    [string]$AdministratorPassword,
    [Parameter()]
    [string]$DomainName,
    [Parameter(Mandatory = $false)]
    [int]$TimeoutInSeconds = 1800,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog = $false
)

Import-Module "$PSScriptRoot\..\..\ps-modules\log\log.module.psm1"

if ($DomainName) {
    $userName = "$DomainName\administrator"
}
else {
    $userName = 'administrator'
}

$pass = ConvertTo-SecureString $AdministratorPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($userName, $pass)
$secondsIncrement = 5
$elapsedSeconds = 0

if ($NoLog -ne $true) {
    Write-Log "Waiting for connection with VM: '$VMName' (timeout: $($TimeoutInSeconds)s) ..."
}

do {
    $result = New-PSSession -VMName $VMName -Credential $cred -ErrorAction SilentlyContinue

    if (-not $result) {
        Start-Sleep -Seconds $secondsIncrement
        $elapsedSeconds += $secondsIncrement

        if ($NoLog -ne $true) {
            Write-Log "$($elapsedSeconds)s.. " -Progress
        }
    }
} while (-not $result -and $elapsedSeconds -lt $TimeoutInSeconds)

if ($elapsedSeconds -gt 0 -and $NoLog -ne $true) {
    Write-Log '.'
}

$result