# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Assists with uninstalling a Windows system to be used for a mixed Linux/Windows Kubernetes cluster
This script is only valid for the Small K8s Setup !!!
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'K8sSetup: SmallSetup')]
    [string] $K8sSetup = 'SmallSetup',
    [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
    [switch] $SkipPurge = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false
)

&$PSScriptRoot\common\GlobalVariables.ps1
. $PSScriptRoot\common\GlobalFunctions.ps1

Import-Module "$PSScriptRoot/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\addons\addons.module.psm1"
Import-Module $addonsModule -DisableNameChecking

if ( $K8sSetup -eq 'SmallSetup' ) {
    Write-Log 'Uninstalling small kubernetes system'
}

if (! $SkipPurge) {
    # this negative logic is important to have the right defaults:
    # if UninstallK8s is called directly, the default is to purge
    # if UninstallK8s is called from InstallK8s, the default is not to purge
    $global:PurgeOnUninstall = $true
}

# make sure we are at the right place for executing this script
Set-Location $global:KubernetesPath

if ($global:HeaderLineShown -ne $true) {
    Write-Log 'Uninstalling kubernetes system'
    $global:HeaderLineShown = $true
}

# stop services
Write-Log 'First stop complete kubernetes incl. VM'
& $global:KubernetesPath\smallsetup\StopK8s.ps1 -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs

Write-Log "Uninstalling $global:VMName VM" -Console

& "$global:KubernetesPath\smallsetup\kubemaster\UninstallKubeMaster.ps1" -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Write-Log 'Uninstalling Windows worker node' -Console

Remove-ServiceIfExists 'flanneld'
Remove-ServiceIfExists 'kubelet'
Remove-ServiceIfExists 'kubeproxy'
Remove-ServiceIfExists 'windows_exporter'
Remove-ServiceIfExists 'httpproxy'
Remove-ServiceIfExists 'dnsproxy'

# remove firewall rules
Remove-NetFirewallRule -Group 'k2s' -ErrorAction SilentlyContinue

Write-Log 'Uninstall containerd service if existent'
&"$global:KubernetesPath\smallsetup\windowsnode\UninstallContainerd.ps1"

&"$global:KubernetesPath\smallsetup\windowsnode\UninstallDockerWin10.ps1"

Import-Module "$global:KubernetesPath\smallsetup\LoopbackAdapter.psm1" -Force
Remove-LoopbackAdapter -Name $global:LoopbackAdapter -DevConExe $global:DevconExe

Write-Log 'Cleaning up' -Console

Write-Log 'Remove previous VM key from known_hosts file'
ssh-keygen.exe -R $global:IP_Master 2>&1 | % { "$_" } | Out-Null

Invoke-AddonsHooks -HookType 'AfterUninstall'

# remove folders from installation folder
Get-ChildItem -Path $global:KubeletConfigDir -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | % { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" }
Remove-Item -Path "$($global:SystemDriveLetter):\etc" -Force -Recurse -ErrorAction SilentlyContinue
Remove-Item -Path "$($global:SystemDriveLetter):\run" -Force -Recurse -ErrorAction SilentlyContinue
Remove-Item -Path "$($global:SystemDriveLetter):\opt" -Force -Recurse -ErrorAction SilentlyContinue
Remove-Item -Path "$($global:InstallationDriveLetter):\run" -Force -Recurse -ErrorAction SilentlyContinue

if ($global:PurgeOnUninstall) {
    Remove-Item -Path "$global:NssmInstallDirectory\nssm.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:SetupJsonFile" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesImagesJson" -Force -ErrorAction SilentlyContinue
    # to handle the upgrade scenario, we should try to remove kubectl exe from the old version's bin folder.
    Remove-Item -Path "$global:BinPath\kube*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\nerdctl.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\jq.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\yq.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\dnsproxy.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\dnsproxy.yaml" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\cri*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\crictl.yaml" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:ExecutableFolderPath" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\config" -Force -ErrorAction SilentlyContinue
    #Backward compatibility for few versions
    Remove-Item -Path "$global:KubernetesPath\cni\bin\win*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\cni\bin\flannel.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\cni\bin\host-local.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\cni\bin\vfprules.json" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\cni\bin" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\cni\conf" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\cni" -Force -ErrorAction SilentlyContinue

    Remove-Item -Path "$global:KubernetesPath\bin\cni\win*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\bin\cni\flannel.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\bin\cni\host-local.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\bin\cni\vfprules.json" -Force -ErrorAction SilentlyContinue

    Remove-Item -Path "$global:KubernetesPath\kubevirt\bin\*.exe" -Force -ErrorAction SilentlyContinue

    Remove-Item -Path "$global:KubernetesPath\smallsetup\en_windows*business*.iso" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesPath\debian*.qcow2" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path ($global:SshConfigDir + '\kubemaster') -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:JoinConfigurationFilePath" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\plink.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\pscp.exe" -Force -ErrorAction SilentlyContinue
}

if (Test-Path $global:NssmInstallDirectoryLegacy) {
    Write-Log 'Remove nssm'
    Remove-Item -Path $global:NssmInstallDirectoryLegacy -Force -Recurse -ErrorAction SilentlyContinue
}

&"$global:KubernetesPath\smallsetup\windowsnode\downloader\DownloadsCleaner.ps1" -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Reset-EnvVars

Write-Log 'Uninstalling K2s setup done.'

Save-Log -RemoveVar