# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Add access to a registry

.DESCRIPTION
Add access to a registry

.PARAMETER RegistryName
The name of the registry to be added

.PARAMETER Username
The username for the registry

.PARAMETER Password
The password for the registry

.PARAMETER ShowLogs
Show all logs in terminal

.EXAMPLE
# Add registry
PS> .\Add-Registry.ps1 -RegistryName "myregistry"

.EXAMPLE
# Add registry with username and password
PS> .\Add-Registry.ps1 -RegistryName "myregistry" -Username "user" -Password "passwd"
#>

Param (
    [parameter(Mandatory = $false, HelpMessage = 'Name of the registry')]
    [string] $RegistryName,
    [parameter(Mandatory = $false, HelpMessage = 'Username')]
    [string] $Username,
    [parameter(Mandatory = $false, HelpMessage = 'Password')]
    [string] $Password,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType,
    [parameter(Mandatory = $false, HelpMessage = 'Skips verifying HTTPS certs')]
    [switch] $SkipVerify = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Plain http')]
    [switch] $PlainHttp = $false
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

$registries = $(Get-RegistriesFromSetupJson)
if ($registries) {
    $registryAlreadyExists = $registries | Where-Object { $_ -eq $RegistryName }
    if ($registryAlreadyExists) {
        $errMsg = "Registry '$RegistryName' is already configured."
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code 'registry-already-configured' -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
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

if ($SkipVerify) {
    $https = !$PlainHttp
    Set-InsecureRegistry -Name $RegistryName -Https:$https
}

Write-Log 'Restarting Linux container runtime' -Console
(Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl daemon-reload').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl restart crio').Output | Write-Log

Start-Sleep 2

Connect-Buildah -username $username -password $password -registry $RegistryName

if (!$?) {
    Remove-InsecureRegistry -Name $RegistryName
    $errMsg = 'Login to private registry not possible, please check credentials.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code 'registry-login-impossible' -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

$authJson = (Invoke-CmdOnControlPlaneViaSSHKey 'sudo cat /root/.config/containers/auth.json' -NoLog).Output | Out-String

Connect-Nerdctl -username $username -password $password -registry $RegistryName

# set authentification for containerd
Add-RegistryToContainerdConf -RegistryName $RegistryName -authJson $authJson

Write-Log 'Restarting Windows container runtime' -Console
Stop-NssmService('kubeproxy')
Stop-NssmService('kubelet')
Restart-NssmService('containerd')
Start-NssmService('kubelet')
Start-NssmService('kubeproxy')

Add-RegistryToSetupJson -Name $RegistryName
Write-Log "Registry '$RegistryName' added successfully.'" -Console

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}