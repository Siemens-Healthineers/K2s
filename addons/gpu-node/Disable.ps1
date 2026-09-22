# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Disables GPU support for KubeMaster node.

.DESCRIPTION
The "gpu-node" addon disables and removes GPU support from the KubeMaster node.
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

function Remove-GpuAddonWorkloads {
    $daemonSets = @(
        'nvidia-device-plugin'
        'nvidia-device-plugin-native'
        'dcgm-exporter'
    )
    $podSelectors = @(
        'k8s-app=nvidia-device-plugin'
        'k8s-app=nvidia-device-plugin-native'
        'app.kubernetes.io/name=dcgm-exporter'
    )

    Write-Log '[gpu-node] Removing GPU addon DaemonSets' -Console
    foreach ($daemonSet in $daemonSets) {
        $result = Invoke-Kubectl -Params 'delete', 'daemonset', $daemonSet, '-n', 'gpu-node', '--ignore-not-found', '--wait=false'
        $result.Output | Write-Log
        if (!$result.Success) {
            Write-Log "[gpu-node] Failed to delete DaemonSet '$daemonSet'" -Error
            return $false
        }
    }

    # Remove pods left behind by a deleted or previously failed DaemonSet.
    foreach ($selector in $podSelectors) {
        (Invoke-Kubectl -Params 'delete', 'pod', '-n', 'gpu-node', '-l', $selector, '--ignore-not-found', '--grace-period=0', '--force', '--wait=false').Output | Write-Log
    }

    foreach ($selector in $podSelectors) {
        $podsRemoved = $false
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $remainingPods = (Invoke-Kubectl -Params 'get', 'pods', '-n', 'gpu-node', '-l', $selector, '-o', 'name', '--ignore-not-found').Output
            if ([string]::IsNullOrWhiteSpace($remainingPods)) {
                $podsRemoved = $true
                break
            }
            Start-Sleep -Seconds 2
        }
        if (!$podsRemoved) {
            Write-Log "[gpu-node] Timed out removing pods selected by '$selector'" -Error
            return $false
        }
    }

    (Invoke-Kubectl -Params 'delete', 'configmap', 'time-slicing-config', '-n', 'gpu-node', '--ignore-not-found').Output | Write-Log
    $namespaceDeletion = Invoke-Kubectl -Params 'delete', 'namespace', 'gpu-node', '--ignore-not-found', '--wait=true', '--timeout=120s'
    $namespaceDeletion.Output | Write-Log
    if (!$namespaceDeletion.Success) {
        Write-Log '[gpu-node] Failed to remove namespace gpu-node after removing addon workloads' -Error
        return $false
    }

    return $true
}

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

$controlPlaneNodeName = (Invoke-Kubectl -Params 'get', 'nodes', '-l', 'node-role.kubernetes.io/control-plane', '-o', 'jsonpath={.items[0].metadata.name}').Output
$controlPlaneLabels = (Invoke-Kubectl -Params 'get', 'node', $controlPlaneNodeName, '-o', 'jsonpath={.metadata.labels}').Output
$controlPlaneGpuPv = ($controlPlaneLabels -match '"k2s\.siemens-healthineers\.com/gpu-mode":"gpu-pv"') -or `
    (($controlPlaneLabels -match '"gpu":"true"') -and ($controlPlaneLabels -match '"accelerator":"nvidia"'))

if ($controlPlaneGpuPv) {
    Write-Log '[gpu-node] Control-plane GPU-PV configuration detected' -Console
}

if (!(Remove-GpuAddonWorkloads)) {
    $errMsg = 'GPU addon workloads could not be removed completely. KubeMaster GPU configuration was left unchanged; resolve the Kubernetes cleanup error and retry disable.'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    Write-Log $errMsg -Error
    exit 1
}

if ($controlPlaneGpuPv) {
    # Remove KubeMaster GPU-PV state only after all addon workloads are gone.
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /var/run/cdi/k8s.device-plugin.nvidia.com-gpu.json' -IgnoreErrors).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get remove -y nvidia-container-toolkit libnvidia-container1 libnvidia-container-tools nvidia-container-runtime 2>/dev/null || true' -IgnoreErrors).Output | Write-Log
}

if ($controlPlaneGpuPv) {
    # Clean up any residual CRI-O nvidia drop-in from prior installations.
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /etc/crio/crio.conf.d/*nvidia* /etc/crio/conf.d/*nvidia* 2>/dev/null || true' -IgnoreErrors).Output | Write-Log
}

$WSL = Get-ConfigWslFlag
if ($controlPlaneGpuPv -and !$WSL) {
    # change linux kernel
    Write-Log 'Changing linux kernel' -Console
    $prefix = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -o \'gnulinux-advanced.*\' /boot/grub/grub.cfg | tr -d `"\'`"").Output
    $kernel = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -o \'gnulinux.*cloud-amd64.*\' /boot/grub/grub.cfg | head -1 | tr -d `"\'`"").Output
    if ([string]::IsNullOrWhiteSpace($kernel)) {
        Write-Log '[gpu-node] WARNING: cloud-amd64 kernel entry not found in /boot/grub/grub.cfg - skipping GRUB default revert to avoid corrupting boot config. The VM will continue with its current boot entry.' -Console
    } else {
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sed -i `"s/GRUB_DEFAULT=.*/GRUB_DEFAULT=\'${prefix}\>${kernel}\'/g`" /etc/default/grub").Output | Write-Log
        $updateGrubResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo update-grub 2>&1' -IgnoreErrors)
        $updateGrubResult.Output | Write-Log
        if (!$updateGrubResult.Success) {
            Write-Log '[gpu-node] WARNING: update-grub reported an error - boot configuration may not have been updated correctly. Verify /boot/grub/grub.cfg on the VM.' -Console
        }
    }

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

if ($controlPlaneGpuPv -and ![string]::IsNullOrWhiteSpace($controlPlaneNodeName)) {
    Write-Log "[gpu-node] Removing GPU labels from control plane node '$controlPlaneNodeName'" -Console
    (Invoke-Kubectl -Params 'label', 'node', $controlPlaneNodeName, 'gpu-', 'accelerator-', 'k2s.siemens-healthineers.com/gpu-mode-').Output | Write-Log
}

# Note: GPU labels on external worker nodes are NOT removed during addon disable.
# The gpu=true label on workers indicates they have been configured for GPU support
# when NVIDIA GPU was detected during node addition. Users can manually remove labels if needed:
#   kubectl label node <worker-name> gpu- accelerator-
Write-Log '[gpu-node] Note: GPU labels on external worker nodes are preserved. Remove manually if needed.' -Console

Remove-AddonFromSetupJson -Addon ([pscustomobject] @{Name = 'gpu-node' })

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}