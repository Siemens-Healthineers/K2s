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
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$clusterModule = "$PSScriptRoot/../../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
Import-Module $clusterModule, $infraModule, $nodeModule

Initialize-Logging -ShowLogs:$ShowLogs

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
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
        $errMsg = "Registry $RegistryName not configured, please add it first."    
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'registry-not-configured' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
        Write-Log $errMsg -Error
        exit 1
    }
}
else {
    Write-Log 'No registries configured!' -Console$errMsg = 'No registries configured.'    
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code 'no-registry-configured' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}