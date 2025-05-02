# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Post-start hook to re-establish SMB share.

.DESCRIPTION
Post-start hook to re-establish SMB share.
#>

$logModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/log/log.module.psm1"
$setupInfoModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/setupinfo/setupinfo.module.psm1"
$smbShareModule = "$PSScriptRoot\..\storage\smb\module\Smb-share.module.psm1"

Import-Module $logModule, $setupInfoModule, $smbShareModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Re-establishing SMB share after cluster start..' -Console

$smbHostType = Get-SmbHostType
$setupInfo = Get-SetupInfo

$global:configFile = "$PSScriptRoot\..\storage\smb\Config\SmbStorage.json"
if (Test-Path $global:configFile) {
    if (Test-Path $global:configFile) {
        $global:pathValues = Get-Content $global:configFile -Raw | ConvertFrom-Json
        if (-not $global:pathValues) {
            throw "The configuration file '$global:configFile' is empty or invalid."
        }
    } else {
        throw "Configuration file '$global:configFile' not found."
    }
} else {
    throw "Configuration file '$global:configFile' not found."
}

foreach($pathValue in $global:pathValues){
     Set-PathValue -PathValue $pathValue
     Restore-SmbShareAndFolder -SmbHostType $smbHostType -SetupInfo $setupInfo 
    }

Write-Log 'SMB share re-established after cluster start.' -Console