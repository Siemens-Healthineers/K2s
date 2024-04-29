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

function Invoke-Script_PublishNssm {
    &"$installationPath\smallsetup\windowsnode\publisher\PublishNssm.ps1"
}

function Invoke-Script_PublishDocker {
    &"$installationPath\smallsetup\windowsnode\publisher\PublishDocker.ps1"
}

function Invoke-Script_InstallDockerWin10 {
    Param(
        [switch] $AutoStart = $false,
        [string] $Proxy = ''
    )
    &"$installationPath\smallsetup\windowsnode\InstallDockerWin10.ps1" -AutoStart:$AutoStart -Proxy "$Proxy"
}

function Invoke-Script_SetupNode {
    Param(
        [string] $KubernetesVersion,
        [string] $MasterIp,
        [bool] $MinSetup,
        [string] $Proxy = '',
        [bool] $HostGW
    )
    &"$installationPath\smallsetup\windowsnode\SetupNode.ps1" -KubernetesVersion $KubernetesVersion -MasterIp $MasterIp -MinSetup:$MinSetup -HostGW:$HostGW -Proxy:"$Proxy"
}

function Invoke-Script_InstallContainerd {
    Param(
        [string] $Proxy = ''
    )
    &"$installationPath\smallsetup\windowsnode\InstallContainerd.ps1" -Proxy "$Proxy"
}

function Invoke-Script_PublishWindowsImages {
    &"$installationPath\smallsetup\windowsnode\publisher\PublishWindowsImages.ps1"
}

function Invoke-Script_PublishKubetools {
    &"$installationPath\smallsetup\windowsnode\publisher\PublishKubetools.ps1"
}

function Invoke-Script_InstallKubelet {
    Param(
        [switch] $UseContainerd = $false
    )
    &"$installationPath\smallsetup\windowsnode\InstallKubelet.ps1" -UseContainerd:$UseContainerd
}

function Invoke-Script_PublishFlannel {
    &"$installationPath\smallsetup\windowsnode\publisher\PublishFlannel.ps1"
}

function Invoke-Script_InstallFlannel {
    &"$installationPath\smallsetup\windowsnode\InstallFlannel.ps1"
}

function Invoke-Script_InstallKubeProxy {
    &"$installationPath\smallsetup\windowsnode\InstallKubeProxy.ps1"
}

function Invoke-Script_PublishWindowsExporter {
    &"$installationPath\smallsetup\windowsnode\publisher\PublishWindowsExporter.ps1"
}

function Invoke-Script_InstallWinExporter {
    &"$installationPath\smallsetup\windowsnode\InstallWinExporter.ps1"
}

function Invoke-Script_InstallHttpProxy {
    Param(
        [string] $Proxy = ''
    )
    &"$installationPath\smallsetup\windowsnode\InstallHttpProxy.ps1" -Proxy $Proxy
}

function Invoke-Script_PublishDnsProxy {
    &"$installationPath\smallsetup\windowsnode\publisher\PublishDnsProxy.ps1"
}

function Invoke-Script_InstallDnsProxy {
    &"$installationPath\smallsetup\windowsnode\InstallDnsProxy.ps1"
}

function Invoke-Script_PublishPuttytools {
    &"$installationPath\smallsetup\windowsnode\publisher\PublishPuttytools.ps1"
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

Export-ModuleMember -Function Set-InstallationPathIntoScriptsIsolationModule, Set-LoggingPreferencesIntoScriptsIsolationModule, Invoke-Script_PublishNssm, Invoke-Script_PublishDocker, Invoke-Script_InstallDockerWin10, Invoke-Script_SetupNode,
Invoke-Script_InstallContainerd,
Invoke-Script_PublishWindowsImages,
Invoke-Script_PublishKubetools,
Invoke-Script_InstallKubelet,
Invoke-Script_PublishFlannel,
Invoke-Script_InstallFlannel,
Invoke-Script_InstallKubeProxy,
Invoke-Script_PublishWindowsExporter,
Invoke-Script_InstallWinExporter,
Invoke-Script_InstallHttpProxy,
Invoke-Script_PublishDnsProxy,
Invoke-Script_InstallDnsProxy,
Invoke-Script_PublishPuttytools,
Invoke-Script_ExistingUbuntuComputerAsMasterNodeInstaller,
Invoke-Script_AddContextToConfig,
Invoke-Script_JoinWindowsHost,
Invoke-Script_AddToHosts,
Invoke-Script_StartK8s,
Invoke-Script_StopK8s


