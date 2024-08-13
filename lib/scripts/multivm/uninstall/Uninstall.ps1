# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
PS> .\lib\scripts\multivm\uninstall\Uninstall.ps1
Files will be purged.

.EXAMPLE
PS> .\lib\scripts\multivm\uninstall\Uninstall.ps1 -SkipPurge
Purge is skipped.

.EXAMPLE
PS> .\lib\scripts\multivm\uninstall\Uninstall.ps1 -AdditonalHooks 'C:\AdditionalHooks'
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


$infraModule = "$PSScriptRoot/../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot/../../../modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule
$kubePath = Get-KubePath
Import-Module "$kubePath/addons/addons.module.psm1"

$multiVMWindowsVMName = Get-ConfigVMNodeHostname

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

Write-Log 'First stop complete K8s incl. VMs'

& "$PSScriptRoot\..\stop\Stop.ps1" -AdditionalHooksDir:$AdditionalHooksDir -StopDuringUninstall

Stop-VirtualMachine $multiVMWindowsVMName

# remove from kubeswitch
$svm = Get-VMNetworkAdapter -VMName $multiVMWindowsVMName -ErrorAction SilentlyContinue
if ( $svm ) {
    Write-Log "VM with name: $multiVMWindowsVMName found"
    Write-Log "Disconnect current network adapter from VM: $multiVMWindowsVMName"

    Disconnect-VMNetworkAdapter -VMName $multiVMWindowsVMName
}

Write-Log "Removing $multiVMWindowsVMName VM" -Console
Remove-VirtualMachine $multiVMWindowsVMName

Uninstall-LinuxNode -DeleteFilesForOfflineInstallation $DeleteFilesForOfflineInstallation

Write-Log 'Cleaning up' -Console

Invoke-AddonsHooks -HookType 'AfterUninstall'

Remove-SshKey
Remove-VMSshKey
Remove-DefaultNetNat

if ($global:PurgeOnUninstall) {
    Remove-Item -Path "$(Get-K2sConfigDir)" -Force -Recurse -ErrorAction SilentlyContinue

    $kubePath = Get-KubePath
    Remove-Item -Path "$kubePath\smallsetup\multivm\debian*.qcow2" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$global:KubernetesImagesJson" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\bin\kube*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\bin\cri*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\bin\crictl.yaml" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\bin\kube" -Force -Recurse -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\config" -Force -ErrorAction SilentlyContinue

    Remove-Item -Path "$kubePath\bin\cni\win*.exe" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\bin\cni\vfprules.json" -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "$kubePath\kubevirt\bin\*.exe" -Force -ErrorAction SilentlyContinue
}

Reset-EnvVars

Write-Log 'Uninstalling MultiVMK8s setup done.'

Save-k2sLogDirectory -RemoveVar