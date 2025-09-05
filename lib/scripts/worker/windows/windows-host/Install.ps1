# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
    [switch] $ForceOnlineInstallation = $false,
    [parameter(HelpMessage = 'DNS Addresses')]
    [string]$DnsAddresses = $(throw 'Argument missing: DnsAddresses'),
    [parameter(Mandatory = $false, HelpMessage = 'The path to local builds of Kubernetes binaries')]
    [string] $K8sBinsPath = ''
)

$installStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

Write-Log 'Setting up Windows worker node' -Console

$windowsHostIpAddress = Get-ConfiguredKubeSwitchIP
$transparentProxy = "http://$($windowsHostIpAddress):8181"
$joinCommand = New-JoinCommand

$workerNodeParams = @{
    Proxy                             = $transparentProxy
    AdditionalHooksDir                = $AdditionalHooksDir
    DeleteFilesForOfflineInstallation = $DeleteFilesForOfflineInstallation
    ForceOnlineInstallation           = $ForceOnlineInstallation
    PodSubnetworkNumber               = '1'
    JoinCommand                       = $JoinCommand
    K8sBinsPath                       = $K8sBinsPath
}
Add-WindowsWorkerNodeOnWindowsHost @workerNodeParams

Write-Log 'Adding mirror registries'
$mirrorRegistries = Get-MirrorRegistries
foreach ($registry in $mirrorRegistries) {
    Set-Registry -Name $registry.registry -Https -SkipVerify -Mirror $registry.mirror -Server $registry.server 
}


Write-Log '---------------------------------------------------------------'
Write-Log "K2s Windows worker node on Windows host setup finished.   Total duration: $('{0:hh\:mm\:ss}' -f $installStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'



