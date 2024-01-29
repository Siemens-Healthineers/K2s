# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables GPU support for KubeMaster node.

.DESCRIPTION
The "gpu-node" addons enables the KubeMaster node to get direct access to the host's GPU.
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability
if ($systemError) {
    throw $systemError
}

Write-Log 'Check whether gpu-node addon is already disabled'

if ($null -eq (kubectl get namespace gpu-node --ignore-not-found)) {
    Write-Log 'Addon already disabled.' -Console
    exit 0
}

Write-Log 'Uninstalling GPU node' -Console

kubectl delete -f "$global:KubernetesPath\addons\gpu-node\manifests\dcgm-exporter.yaml" | Write-Log
kubectl delete -f "$global:KubernetesPath\addons\gpu-node\manifests\nvidia-device-plugin.yaml" | Write-Log

$WSL = Get-WSLFromConfig
if (!$WSL) {
    # change linux kernel
    Write-Log 'Changing linux kernel' -Console
    $prefix = ExecCmdMaster "grep -o \'gnulinux-advanced.*\' /boot/grub/grub.cfg | tr -d `"\'`"" -NoLog
    $kernel = ExecCmdMaster "grep -o \'gnulinux.*cloud-amd64.*\' /boot/grub/grub.cfg | head -1 | tr -d `"\'`"" -NoLog
    ExecCmdMaster "sudo sed -i `"s/GRUB_DEFAULT=.*/GRUB_DEFAULT=\'${prefix}\>${kernel}\'/g`" /etc/default/grub"
    ExecCmdMaster 'sudo update-grub 2>&1' -IgnoreErrors

    # Restart KubeMaster
    Write-Log "Stopping VM $global:VMName"
    Stop-VM -Name $global:VMName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
    }
    Write-Log "Start VM $global:VMName"
    Start-VM -Name $global:VMName
    # for the next steps we need ssh access, so let's wait for ssh
    Wait-ForSSHConnectionToLinuxVMViaSshKey
    Wait-ForAPIServer
}

Remove-AddonFromSetupJson -Name 'gpu-node'
