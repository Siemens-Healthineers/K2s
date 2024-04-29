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

function Invoke-Script_AddContextToConfig {
    &"$installationPath\smallsetup\common\AddContextToConfig.ps1"
}

function Invoke-Script_JoinWindowsHost {
    &"$installationPath\smallsetup\common\JoinWindowsHost.ps1"
}

function Invoke-Script_AddToHosts {
    &"$installationPath\smallsetup\AddToHosts.ps1"
}

function Invoke-Script_StartK8s {
    Param(
        [switch] $ShowLogs = $false,
        [string] $AdditionalHooksDir = ''
    )
    & "$installationPath\smallsetup\StartK8s.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
}

function Invoke-Script_StopK8s {
    Param(
        [switch] $ShowLogs = $false,
        [string] $AdditionalHooksDir = ''
    )
    & "$installationPath\smallsetup\StopK8s.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs
}

Export-ModuleMember -Function Set-InstallationPathIntoScriptsIsolationModule, Set-LoggingPreferencesIntoScriptsIsolationModule,  
Invoke-Script_ExistingUbuntuComputerAsMasterNodeInstaller,
Invoke-Script_AddContextToConfig,
Invoke-Script_JoinWindowsHost,
Invoke-Script_AddToHosts,
Invoke-Script_StartK8s,
Invoke-Script_StopK8s


