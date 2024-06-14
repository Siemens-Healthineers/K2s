# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$infraModule =   "$PSScriptRoot\..\..\..\k2s.infra.module\k2s.infra.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\k2s.cluster.module\k2s.cluster.module.psm1"

Import-Module $infraModule, $clusterModule


function Add-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
        [string] $Proxy,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [switch] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Force the installation online. This option is needed if the files for an offline installation are available but you want to recreate them.')]
        [switch] $ForceOnlineInstallation = $false,
        [string] $WorkerNodeNumber = $(throw 'Argument missing: WorkerNodeNumber')
    )
    Write-Log 'Prerequisites checks before installation' -Console
    Stop-InstallIfNoMandatoryServiceIsRunning

    Write-Log 'Starting installation of K2s worker node on Windows host.'

    # Install loopback adapter for l2bridge
    New-DefaultLoopbackAdater

    Write-Log 'Add vfp rules'
    $rootConfiguration = Get-RootConfigk2s
    $vfpRoutingRules = $rootConfiguration.psobject.properties['vfprules-k2s'].value | ConvertTo-Json
    Add-VfpRulesToWindowsNode -VfpRulesInJsonFormat $vfpRoutingRules

    $kubernetesVersion = Get-DefaultK8sVersion
    $controlPlaneIpAddress = Get-ConfiguredIPControlPlane
    $windowsHostIpAddress = Get-ConfiguredKubeSwitchIP

    Initialize-WinNode -KubernetesVersion $kubernetesVersion `
        -HostGW:$true `
        -Proxy:"$Proxy" `
        -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation `
        -ForceOnlineInstallation $ForceOnlineInstallation `
        -WorkerNodeNumber $WorkerNodeNumber

    $transparentproxy = 'http://' + $windowsHostIpAddress + ':8181'
    Set-ProxySettingsOnKubenode -ProxySettings $transparentproxy -IpAddress $controlPlaneIpAddress
    Restart-Service httpproxy -ErrorAction SilentlyContinue

    # join the cluster
    Write-Log "Preparing Kubernetes $KubernetesVersion by joining nodes" -Console

    Initialize-KubernetesCluster -AdditionalHooksDir $AdditionalHooksDir -WorkerNodeNumber $WorkerNodeNumber
}

function Remove-WindowsWorkerNodeOnWindowsHost {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
        [switch] $SkipPurge = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
        [string] $AdditionalHooksDir = '',
        [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
        [switch] $SkipHeaderDisplay = $false
    )

    if ($SkipHeaderDisplay -eq $false) {
        Write-Log 'Removing K2s worker node on Windows host from cluster'
    }
    
    Write-Log 'Remove external switch'
    Remove-ExternalSwitch
   
    Write-Log 'Uninstall the worker node artifacts from the Windows host'
    Uninstall-WinNode -ShallowUninstallation $SkipPurge
    
    Write-Log 'Uninstall the loopback adapter'
    Uninstall-LoopbackAdapter
    
    Write-Log 'Remove vfp rules'
    Remove-VfpRulesFromWindowsNode

    Write-Log 'Uninstalling K2s worker node on Windows host done.'  
}

Export-ModuleMember -Function Add-WindowsWorkerNodeOnWindowsHost,
Remove-WindowsWorkerNodeOnWindowsHost