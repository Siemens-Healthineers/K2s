# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Switch login to another registry in order to push images

.DESCRIPTION
Switch login to another registry in order to push images

.PARAMETER RegistryName
The name of the registry to be added

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# Switch registry login to 'k2s-registry.local'
PS> .\Switch-Registry.ps1 -RegistryName "k2s-registry.local"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Name of the registry')]
    [string] $RegistryName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
Import-Module $clusterModule, $infraModule, $nodeModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

Write-Log "Trying to login into $RegistryName" -Console
$registries = $(Get-RegistriesFromSetupJson)
if ($registries) {
    if ($registries.Contains($RegistryName)) {
        Connect-Buildah -registry $RegistryName

        # Add dockerd parameters and restart docker daemon to push nondistributable artifacts and use insecure registry
        $storageLocalDrive = Get-StorageLocalDrive
        nssm set docker AppParameters --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --log-level debug --allow-nondistributable-artifacts "$RegistryName" --insecure-registry "$RegistryName" | Out-Null
        if (Get-IsNssmServiceRunning('docker')) {
            Restart-NssmService('docker')
        }
        else {
            Start-NssmService('docker')
        }

        Connect-Docker -registry $RegistryName

        Set-ConfigLoggedInRegistry -Value $RegistryName

        Write-Log "Login to '$RegistryName' was successful." -Console
    }
    else {
        Write-Log "Registry $RegistryName not configured! Please add it first!" -Console
    }
}
else {
    Write-Log 'No registries configured!' -Console
}