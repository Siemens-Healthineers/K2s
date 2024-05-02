# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

&$PSScriptRoot\..\..\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\..\common\GlobalFunctions.ps1

$installationPath = ''

function Set-LoggingPreferencesIntoScriptsIsolationModule {
    Param(
        [switch] $ShowLogs,
        [switch] $AppendLogFile
    )
    Initialize-Logging -ShowLogs:$ShowLogs
    Reset-LogFile -AppendLogFile:$AppendLogFile
}

function Set-InstallationPathIntoScriptsIsolationModule {
    Param(
        [string] $Value
    )
    $script:installationPath = $Value
}

function Invoke-Script_ExistingUbuntuComputerAsMasterNodeInstaller {
    param (
        [string]$UserName,
        [string]$UserPwd,
        [string]$IpAddress,
        [string]$Proxy = ''
    )
    &"$installationPath\smallsetup\linuxnode\ubuntu\ExistingUbuntuComputerAsMasterNodeInstaller.ps1" -IpAddress $IpAddress -UserName $UserName -UserPwd $UserPwd -Proxy $Proxy
}

function Invoke-Script_UninstallKubeMaster {
    Param(
        [Boolean] $DeleteFilesForOfflineInstallation = $false
    )
    &"$installationPath\smallsetup\kubemaster\UninstallKubeMaster.ps1" -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation
}

Export-ModuleMember -Function Set-InstallationPathIntoScriptsIsolationModule, Set-LoggingPreferencesIntoScriptsIsolationModule,  
Invoke-Script_ExistingUbuntuComputerAsMasterNodeInstaller,
Invoke-Script_UninstallKubeMaster


