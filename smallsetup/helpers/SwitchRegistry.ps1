# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

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
&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$registryFunctionsModule = "$PSScriptRoot\RegistryFunctions.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
$cliModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\cli-messages\cli-messages.module.psm1"

Import-Module $registryFunctionsModule, $clusterModule, $imageFunctionsModule, $cliModule -DisableNameChecking

if (-not (Get-Module -Name $logModule -ListAvailable)) { Import-Module $logModule; Initialize-Logging -ShowLogs:$ShowLogs }

$systemError = Test-SystemAvailability
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError -Error
    exit 1
}

$setupInfo = Get-SetupInfo

$registries = $(Get-RegistriesFromSetupJson)
if ($null -eq $registries) {
    Write-Log 'No registries configured.' -Console
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    return
}

if ($registries.Contains($RegistryName) -ne $true) {
    Write-Log "Registry $RegistryName not configured, please add it first." -Console
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    return
}

Write-Log "Trying to log in into $RegistryName" -Console

Login-Buildah -registry $RegistryName

# Add dockerd parameters and restart docker daemon to push nondistributable artifacts and use insecure registry
if ($setupInfo.Name -eq $global:SetupType_k2s -or $setupInfo.Name -eq $global:SetupType_BuildOnlyEnv) {
    $storageLocalDrive = Get-StorageLocalDrive
    &"$global:NssmInstallDirectory\nssm" set docker AppParameters --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --log-level debug --allow-nondistributable-artifacts "$RegistryName" --insecure-registry "$RegistryName" | Out-Null
    if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
        &"$global:NssmInstallDirectory\nssm" restart docker
    }
    else {
        &"$global:NssmInstallDirectory\nssm" start docker
    }

    Login-Docker -registry $RegistryName
}
elseif ($setupInfo.Name -eq $global:SetupType_MultiVMK8s -and !$($setupInfo.LinuxOnly)) {
    $session = Open-RemoteSessionViaSSHKey $global:Admin_WinNode $global:WindowsVMKey

    Invoke-Command -Session $session {
        Set-Location "$env:SystemDrive\k"
        Set-ExecutionPolicy Bypass -Force -ErrorAction Stop

        &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1
        . $env:SystemDrive\k\smallsetup\common\GlobalFunctions.ps1

        $registryFunctionsModule = "$env:SystemDrive\k\smallsetup\helpers\RegistryFunctions.module.psm1"
        Import-Module $registryFunctionsModule -DisableNameChecking

        &"$global:NssmInstallDirectory\nssm" set docker AppParameters --exec-opt isolation=process --data-root 'C:\docker' --log-level debug --allow-nondistributable-artifacts "$using:RegistryName" --insecure-registry "$using:RegistryName" | Out-Null
        if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
            &"$global:NssmInstallDirectory\nssm" restart docker
        }
        else {
            &"$global:NssmInstallDirectory\nssm" start docker
        }

        Login-Docker -registry $using:RegistryName
    }
}

Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry -Value $RegistryName

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}