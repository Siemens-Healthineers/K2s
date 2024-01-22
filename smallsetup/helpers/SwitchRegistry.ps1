# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Name of the registry')]
    [string] $RegistryName,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$registryFunctionsModule = "$PSScriptRoot\RegistryFunctions.module.psm1"
$statusModule = "$PSScriptRoot\..\status\Status.module.psm1"
$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
$runningStateModule = "$PSScriptRoot\..\status\RunningState.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"

Import-Module $registryFunctionsModule, $statusModule, $runningStateModule, $imageFunctionsModule, $setupInfoModule -DisableNameChecking
if (-not (Get-Module -Name $logModule -ListAvailable)) { Import-Module $logModule; Initialize-Logging -ShowLogs:$ShowLogs }

Test-ClusterAvailabilityForImageFunctions

$setupInfo = Get-SetupInfo

Write-Log "Trying to log in into $RegistryName" -Console
$registries = $(Get-RegistriesFromSetupJson)
if ($registries) {
    if ($registries.Contains($RegistryName)) {
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

                # load global settings
                &$env:SystemDrive\k\smallsetup\common\GlobalVariables.ps1
                # import global functions
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
    }
    else {
        Write-Log "Registry $RegistryName not configured! Please add it first!" -Console
    }
}
else {
    Write-Log 'No registries configured!' -Console
}