# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
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
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$linuxNodeModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.node.module/linuxnode/vm/vm.module.psm1"

Import-Module $clusterModule, $infraModule, $addonsModule, $linuxNodeModule

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

if ($null -eq (Invoke-Kubectl -Params 'get', 'namespace', 'gpu-node', '--ignore-not-found').Output -and (Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'gpu-node' })) -ne $true) {
    $errMsg = "Addon 'gpu-node' is already disabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyDisabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

# Remove OCI hook (legacy; cleanup is idempotent)
Write-Log '[GPU] Removing OCI prestart hook (if present)' -Console
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json').Output | Write-Log

Write-Log '[GPU] Removing CDI spec (if present)' -Console
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /var/run/cdi/k8s.device-plugin.nvidia.com-gpu.json' -IgnoreErrors).Output | Write-Log

# Remove nvidia-container-toolkit packages
Write-Log '[GPU] Removing nvidia-container-toolkit packages' -Console
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get remove -y nvidia-container-toolkit libnvidia-container1 libnvidia-container-tools nvidia-container-runtime 2>/dev/null || true' -IgnoreErrors).Output | Write-Log

Write-Log 'Uninstalling GPU node' -Console
(Invoke-Kubectl -Params 'delete', '-f', "$PSScriptRoot\manifests\dcgm-exporter.yaml", '--ignore-not-found').Output | Write-Log
(Invoke-Kubectl -Params 'delete', '-f', "$PSScriptRoot\manifests\nvidia-device-plugin.yaml", '--ignore-not-found').Output | Write-Log

# Clean up any residual CRI-O nvidia drop-in from prior installations.
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /etc/crio/crio.conf.d/*nvidia* /etc/crio/conf.d/*nvidia* 2>/dev/null || true' -IgnoreErrors).Output | Write-Log

$WSL = Get-ConfigWslFlag
if (!$WSL) {
    # change linux kernel
    Write-Log 'Changing linux kernel' -Console
    $prefix = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -o \'gnulinux-advanced.*\' /boot/grub/grub.cfg | tr -d `"\'`"").Output
    $kernel = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -o \'gnulinux.*cloud-amd64.*\' /boot/grub/grub.cfg | head -1 | tr -d `"\'`"").Output
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sed -i `"s/GRUB_DEFAULT=.*/GRUB_DEFAULT=\'${prefix}\>${kernel}\'/g`" /etc/default/grub").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo update-grub 2>&1' -IgnoreErrors).Output | Write-Log

    # Remove driver files copied into VM during enable (must happen while VM is running/SSH is up)
    Write-Log '[gpu-node] Removing NVIDIA driver files from VM' -Console
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /etc/profile.d/wsl.sh' -IgnoreErrors).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /etc/ld.so.conf.d/ld.wsl.conf' -IgnoreErrors).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /usr/lib/wsl' -IgnoreErrors).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo ldconfig 2>&1' -IgnoreErrors).Output | Write-Log

    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname

    # Stop VM before modifying Hyper-V GPU partition settings
    Write-Log "Stopping VM $controlPlaneNodeName"
    Stop-VM -Name $controlPlaneNodeName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $controlPlaneNodeName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
    }

    # Revert Hyper-V GPU partition adapter and memory-mapped IO settings added during enable
    Write-Log '[gpu-node] Removing GPU partition adapter from VM' -Console
    if (Get-VMGpuPartitionAdapter -VMName $controlPlaneNodeName -ErrorAction SilentlyContinue) {
        Remove-VMGpuPartitionAdapter -VMName $controlPlaneNodeName
    }
    Set-VM -VMName $controlPlaneNodeName -GuestControlledCacheTypes $false -LowMemoryMappedIoSpace 128MB -HighMemoryMappedIoSpace 512MB

    Write-Log "Start VM $controlPlaneNodeName"
    Start-VM -Name $controlPlaneNodeName
    # for the next steps we need ssh access, so let's wait for ssh
    Wait-ForSSHConnectionToLinuxVMViaSshKey
    Wait-ForAPIServer
}

# Remove GPU node labels added during enable.
$nodeName = (Invoke-Kubectl -Params 'get', 'nodes', '-l', 'node-role.kubernetes.io/control-plane', '-o', 'jsonpath={.items[0].metadata.name}').Output
if (![string]::IsNullOrWhiteSpace($nodeName)) {
    Write-Log "[gpu-node] Removing gpu and accelerator labels from node '$nodeName'" -Console
    (Invoke-Kubectl -Params 'label', 'node', $nodeName, 'gpu-', 'accelerator-').Output | Write-Log
}

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'gpu-node' })

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}