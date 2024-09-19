# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Removes the Multi-VM K8s setup.

.DESCRIPTION
This script assists in the following actions for K2s:
- Removal of
-- VMs
-- virtual disks
-- virtual switches
-- config files
-- config entries
-- etc.

.PARAMETER SkipPurge
Specifies whether to skipt the deletion of binaries, config files etc.

.EXAMPLE
PS> .\UninstallMultiVMK8sSetup.ps1
Files will be purged.

.EXAMPLE
PS> .\UninstallMultiVMK8sSetup.ps1 -SkipPurge
Purge is skipped.

.EXAMPLE
PS> .\UninstallMultiVMK8sSetup.ps1 -AdditonalHooks 'C:\AdditionalHooks'
For specifying additional hooks to be executed.
#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Do not purge all files')]
    [switch] $SkipPurge = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
    [switch] $DeleteFilesForOfflineInstallation = $false
)


&$PSScriptRoot\..\common\GlobalVariables.ps1
. $PSScriptRoot\..\common\GlobalFunctions.ps1
Import-Module "$PSScriptRoot/../../addons/addons.module.psm1"
Import-Module "$PSScriptRoot/../ps-modules/log/log.module.psm1"
Import-Module "$PSScriptRoot\..\..\lib\modules\k2s\k2s.node.module\k2s.node.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Continue'

if ($Trace) {
    Set-PSDebug -Trace 1
}

Write-Log '---------------------------------------------------------------'
Write-Log 'Multi-VM Kubernetes Deinstallation started.'
Write-Log '---------------------------------------------------------------'

if (! $SkipPurge) {
    # this negative logic is important to have the right defaults:
    # if UninstallK8s is called directly, the default is to purge
    # if UninstallK8s is called from InstallK8s, the default is not to purge
    $global:PurgeOnUninstall = $true
}

$linuxOnly = Get-LinuxOnlyFromConfig

Write-Log 'First stop complete K8s incl. VMs'
& "$global:KubernetesPath\smallsetup\multivm\Stop_MultiVMK8sSetup.ps1" -AdditionalHooksDir:$AdditionalHooksDir -StopDuringUninstall

if ($linuxOnly -ne $true) {
    Stop-VirtualMachine $global:MultiVMWindowsVMName

    # remove from kubeswitch
    $svm = Get-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName -ErrorAction SilentlyContinue
    if ( $svm ) {
        Write-Log "VM with name: $global:MultiVMWindowsVMName found"
        Write-Log "Disconnect current network adapter from VM: $global:MultiVMWindowsVMName"

        Disconnect-VMNetworkAdapter -VMName $global:MultiVMWindowsVMName
    }

    Write-Log "Removing $global:MultiVMWindowsVMName VM" -Console
    Remove-VirtualMachine $global:MultiVMWindowsVMName
}

Write-Log "Removing $global:VMName VM" -Console
& $PSScriptRoot\..\kubemaster\UninstallKubeMaster.ps1 -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation
Remove-KubeNodeBaseImage -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Write-Log 'Cleaning up' -Console
Write-Log 'Remove previous VM key from known_hosts file'
ssh-keygen.exe -R $global:IP_Master 2>&1 | % { "$_" }
ssh-keygen.exe -R $global:MultiVMWinNodeIP 2>&1 | % { "$_" }

Invoke-AddonsHooks -HookType 'AfterUninstall'

# TODO: necessary on host-only?
# remove folders from installation drive
Get-ChildItem -Path $global:KubeletConfigDir -Force -Recurse -Attributes Reparsepoint -ErrorAction 'silentlycontinue' | ForEach-Object { $n = $_.FullName.Trim('\'); fsutil reparsepoint delete "$n" }
Remove-Item -Path "$($global:SystemDriveLetter):\etc" -Force -Recurse -ErrorAction SilentlyContinue
Remove-Item -Path "$($global:SystemDriveLetter):\run" -Force -Recurse -ErrorAction SilentlyContinue

if ($global:PurgeOnUninstall) {
    Remove-Item -Path "$global:KubernetesPath\smallsetup\multivm\debian*.qcow2" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:SetupJsonFile" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesImagesJson" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:BinPath\kube*.exe" -Force -ErrorAction SilentlyContinue
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

    Remove-Item -Path ($global:SshConfigDir + '\kubemaster') -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path ($global:SshConfigDir + '\windowsvm') -Force -Recurse -ErrorAction SilentlyContinue
}

Remove-K2sHostsFromNoProxyEnvVar
Reset-EnvVars

Write-Log 'Uninstalling MultiVMK8s setup done.'

Save-Log -RemoveVar