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
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,
    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$statusModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/status/status.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"

Import-Module $logModule, $addonsModule, $statusModule, $cliMessagesModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability -Structured
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError.Message -Error
    exit 1
}

Write-Log 'Check whether gpu-node addon is already disabled'

if ($null -eq (&$global:KubectlExe get namespace gpu-node --ignore-not-found) -or (Test-IsAddonEnabled -Name 'gpu-node') -ne $true) {
    $errMsg = "Addon 'gpu-node' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = @{Type = 'precondition-not-met'; Code = 'addon-already-disabled'; Message = $errMsg } }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Uninstalling GPU node' -Console

&$global:KubectlExe delete -f "$global:KubernetesPath\addons\gpu-node\manifests\dcgm-exporter.yaml" | Write-Log
&$global:KubectlExe delete -f "$global:KubernetesPath\addons\gpu-node\manifests\nvidia-device-plugin.yaml" | Write-Log

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

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}