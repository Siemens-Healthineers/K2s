# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
The image name of the image to be exported

.PARAMETER Password
The path where the image sould be exported

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

Invoke-CmdOnControlPlaneViaSSHKey "grep location=\\\""$RegistryName\\\"" /etc/containers/registries.conf || echo -e `'\n[[registry]]\nlocation=\""$RegistryName\""\ninsecure=true`' | sudo tee -a /etc/containers/registries.conf"

Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl daemon-reload'
Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl restart crio'

Start-Sleep 2

Connect-Buildah -username $username -password $password -registry $RegistryName

if (!$?) {
    Invoke-CmdOnControlPlaneViaSSHKey "grep location=\\\""$RegistryName\\\"" /etc/containers/registries.conf | sudo sed -i -z 's/\[\[registry]]\nlocation=\\\""$RegistryName\\\""\ninsecure=true//g' /etc/containers/registries.conf"
    throw 'Login to private registry not possible! Please check credentials!'
}

$authJson = Invoke-CmdOnControlPlaneViaSSHKey 'sudo cat /root/.config/containers/auth.json' -NoLog | Out-String

# Add dockerd parameters and restart docker daemon to push nondistributable artifacts and use insecure registry
$storageLocalDrive = Get-StorageLocalDrive
nssm set docker AppParameters --exec-opt isolation=process --data-root "$storageLocalDrive\docker" --log-level debug --allow-nondistributable-artifacts "$RegistryName" --insecure-registry "$RegistryName" | Out-Null
if (Get-IsNssmServiceRunning('docker')) {
    Restart-NssmService('docker')
}
else {
    Start-NssmService('docker')
}

Connect-Docker -username $username -password $password -registry $RegistryName

# set authentification for containerd
Add-RegistryToContainerdConf -RegistryName $RegistryName -authJson $authJson

Write-Log 'Restarting kubernetes services' -Console
Stop-NssmService('kubeproxy')
Stop-NssmService('kubelet')
Restart-NssmService('containerd')
Start-NssmService('kubelet')
Start-NssmService('kubeproxy')

Set-ConfigLoggedInRegistry -Value $RegistryName
Add-RegistryToSetupJson -Name $RegistryName
Write-Log "Registry '$RegistryName' added successfully.'" -Console