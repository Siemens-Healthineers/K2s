# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param (
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Name of the registry')]
    [string] $RegistryName,
    [parameter(Mandatory = $false, HelpMessage = 'Username')]
    [string] $Username,
    [parameter(Mandatory = $false, HelpMessage = 'Password')]
    [string] $Password,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

# load global settings
&$PSScriptRoot\..\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\common\GlobalFunctions.ps1

$registryFunctionsModule = "$PSScriptRoot\RegistryFunctions.module.psm1"
$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
$statusModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\status\status.module.psm1"
$imageFunctionsModule = "$PSScriptRoot\ImageFunctions.module.psm1"
$logModule = "$PSScriptRoot\..\ps-modules\log\log.module.psm1"
Import-Module $registryFunctionsModule, $setupInfoModule, $statusModule, $imageFunctionsModule -DisableNameChecking

if (-not (Get-Module -Name $logModule -ListAvailable)) { Import-Module $logModule; Initialize-Logging -ShowLogs:$ShowLogs }

function Set-Containerd-Config() {
    param(
        [Parameter()]
        [String]
        $RegistryName,
        [Parameter()]
        [String]
        $authJson
    )
    $containerdConfig = "$global:KubernetesPath\cfg\containerd\config.toml"
    Write-Log "Changing $containerdConfig"

    $content = Get-Content $containerdConfig | Out-String
    if ($content.Contains("[plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$RegistryName"".auth]")) {
        return
    }

    $dockerConfig = $authJson | ConvertFrom-Json
    $dockerAuth = $dockerConfig.psobject.properties['auths'].value
    $authk2s = $dockerAuth.psobject.properties["$RegistryName"].value
    $auth = $authk2s.psobject.properties['auth'].value

    $authPlaceHolder = Get-Content $containerdConfig | Select-String '#add_new_registry_auth' | Select-Object -ExpandProperty Line
    if ( $authPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($authPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$RegistryName"".auth]`r`n          auth = ""$auth""`r`n`r`n        #add_new_registry_auth") } | Set-Content $containerdConfig
    }

    $tlsPlaceHolder = Get-Content $containerdConfig | Select-String '#add_new_insecure_verify_skip' | Select-Object -ExpandProperty Line
    if ( $tlsPlaceHolder ) {
        $content = Get-Content $containerdConfig
        $content | ForEach-Object { $_.replace($tlsPlaceHolder, "        [plugins.""io.containerd.grpc.v1.cri"".registry.configs.""$RegistryName"".tls]`r`n          insecure_skip_verify = true`r`n`r`n        #add_new_insecure_verify_skip") } | Set-Content $containerdConfig
    }
}

function Restart-Services() {
    param(
        [Parameter()]
        [String]
        $setupType
    )
    Write-Output 'Restarting services'
    if ($setupType -ne $global:SetupType_BuildOnlyEnv) {
        &$global:NssmInstallDirectory\nssm stop kubeproxy
        &$global:NssmInstallDirectory\nssm stop kubelet
    }

    &$global:NssmInstallDirectory\nssm restart containerd

    if ($setupType -ne $global:SetupType_BuildOnlyEnv) {
        &$global:NssmInstallDirectory\nssm start kubelet
        &$global:NssmInstallDirectory\nssm start kubeproxy
    }
}

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

$registries = $(Get-RegistriesFromSetupJson)
if ($registries) {
    $registryAlreadyExists = $registries | Where-Object { $_ -eq $RegistryName }
    if ($registryAlreadyExists) {
        Write-Log "Registry '$RegistryName' is already configured!" -Console
        exit 0
    }
}

Write-Log "Adding registry '$RegistryName'" -Console

if ($Username -and $Password) {
    $username = $Username
    $password = $password
}
else {
    Write-Log 'Please enter credentials for registry access:' -Console
    $username = Read-Host 'Enter username'
    $passwordSecured = Read-Host 'Enter password' -AsSecureString
    $cred = New-Object System.Management.Automation.PSCredential ($username, $passwordSecured)
    $password = $cred.GetNetworkCredential().Password
}

if ($PSVersionTable.PSVersion.Major -gt 5) {
    ExecCmdMaster "grep location=\""$RegistryName\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=""$RegistryName""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf"
}
else {
    ExecCmdMaster "grep location=\\\""$RegistryName\\\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=\""$RegistryName\""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf"
}

ExecCmdMaster 'sudo systemctl daemon-reload'
ExecCmdMaster 'sudo systemctl restart crio'

Start-Sleep 2

Login-Buildah -username $username -password $password -registry $RegistryName

if (!$?) {
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        ExecCmdMaster "grep location=\""$RegistryName\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\""$RegistryName\""\ninsecure=true//g' /etc/containers/registries.conf"
    }
    else {
        ExecCmdMaster "grep location=\\\""$RegistryName\\\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\\\""$RegistryName\\\""\ninsecure=true//g' /etc/containers/registries.conf"
    }

    throw 'Login to private registry not possible! Please check credentials!'
}

$setupInfo = Get-SetupInfo

$authJson = ExecCmdMaster 'sudo cat /root/.config/containers/auth.json' -NoLog | Out-String

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

    Login-Docker -username $username -password $password -registry $RegistryName

    # set authentification for containerd
    Set-Containerd-Config -RegistryName $RegistryName -authJson $authJson

    Restart-Services -setupType $setupInfo.Name
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
        Import-Module $env:SystemDrive\k\smallsetup\ps-modules\log\log.module.psm1
        Initialize-Logging -Nested:$true


        &"$global:NssmInstallDirectory\nssm" set docker AppParameters --exec-opt isolation=process --data-root 'C:\docker' --log-level debug --allow-nondistributable-artifacts "$using:RegistryName" --insecure-registry "$using:RegistryName" | Out-Null
        if ($(Get-Service -Name 'docker' -ErrorAction SilentlyContinue).Status -eq 'Running') {
            &"$global:NssmInstallDirectory\nssm" restart docker
        }
        else {
            &"$global:NssmInstallDirectory\nssm" start docker
        }

        Login-Docker -username $using:username -password $using:password -registry $using:RegistryName
    }

    Invoke-Command -Session $session -ScriptBlock ${Function:Set-Containerd-Config} -ArgumentList $RegistryName, $authJson
    Invoke-Command -Session $session -ScriptBlock ${Function:Restart-Services} -ArgumentList $setupInfo.Name

    if (!$?) {
        throw "Login to registry $RegistryName not possible! Please check credentials!"
    }
}

Set-ConfigValue -Path $global:SetupJsonFile -Key $global:ConfigKey_LoggedInRegistry -Value $RegistryName
Add-RegistryToSetupJson -Name $RegistryName
Write-Log "Registry '$RegistryName' added successfully.'" -Console