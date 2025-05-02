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
    <# $global:SmbStoragePath = $pathValues.psobject.properties['ShareDir'].value#>
     $global:linuxLocalPath = $pathValue.master
     $global:windowsLocalPath = Expand-PathSMb $pathValue.windowsWorker
     $global:linuxShareName = "k8sshare$(($global:pathValues.master).IndexOf($global:linuxLocalPath) + 1)" # exposed by Linux VM
     $global:windowsShareName = (Split-Path -Path $global:windowsLocalPath -NoQualifier).TrimStart('\') # visible from VMs
     $global:windowsSharePath = Split-Path -Path $global:windowsLocalPath -Qualifier
     $global:linuxHostRemotePath = "\\$(Get-ConfiguredIPControlPlane)\$global:linuxShareName"
     $global:windowsHostRemotePath = "\\$(Get-ConfiguredKubeSwitchIP)\$global:windowsShareName"
     $global:newClassName=$pathValue.StorageClassName
     Restore-SmbShareAndFolder -SmbHostType $smbHostType -SetupInfo $setupInfo 
    }

Write-Log 'SMB share re-established after cluster start.' -Console