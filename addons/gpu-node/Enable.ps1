# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Enables GPU support for KubeMaster node.

.DESCRIPTION
The "gpu-node" addons enables the KubeMaster node to get direct access to the host's GPU.

#>
Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'JSON config object to override preceeding parameters')]
    [pscustomobject] $Config,
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

if ((Test-IsAddonEnabled -Addon ([pscustomobject] @{Name = 'gpu-node' })) -eq $true) {
    $errMsg = "Addon 'gpu-node' is already enabled, nothing to do."

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonAlreadyEnabled) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }
    
    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Checking Nvidia driver installation' -Console

$WSL = Get-ConfigWslFlag
$kubeSwitchIp = Get-ConfiguredKubeSwitchIP
$tunnelProc = $null
$sshErrFile = $null

if (!(Test-Path -Path 'C:\Windows\System32\lxss\lib\libdxcore.so')) {
    $errMsg = "It seems that the needed Nvidia drivers are not installed.`nPlease install them from the following URL: https://www.nvidia.com/Download/index.aspx"

    if ($WSL) {
        $errMsg += "`nAfter Nvidia driver installation you need to reinstall the cluster for the changes to take effect."
    }

    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

if ($WSL) {
    $success = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute '[ -f /usr/lib/wsl/lib/libdxcore.so ]').Success
    if (!$success) {
        $errMsg = "It seems that the needed Nvidia drivers are not installed.`n" `
            + "Please install them from the following URL: https://www.nvidia.com/Download/index.aspx`n"`
            + 'After Nvidia driver installation you need to reinstall the cluster for the changes to take effect.'

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }

    $success = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute '/usr/lib/wsl/lib/nvidia-smi').Success
    if (!$success) {
        $errMsg = "It seems that the needed Nvidia drivers are not installed correctly.`n" `
            + "If you recently updated your NVIDIA drivers, restart the cluster first to refresh the WSL2 GPU libraries:`n" `
            + "  k2s stop ; k2s start`n" `
            + 'Otherwise, please reinstall Nvidia drivers and cluster and try again.'

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }

    # In WSL2 mode the vEthernet (WSL*) adapter IP can be reset between 'k2s start' and addon enable.
    # Re-ensure the k2s gateway IP is assigned so the HTTP proxy is reachable for package downloads.
    # (Mirrors the Hyper-V else-block which refreshes networking by stopping/starting the VM.)
    $wslAdapter = Get-NetAdapter -Name 'vEthernet (WSL*)' -ErrorAction SilentlyContinue -IncludeHidden
    if ($wslAdapter) {
        $existingAddresses = (Get-NetIPAddress -InterfaceIndex $wslAdapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        if ($existingAddresses -notcontains $kubeSwitchIp) {
            Write-Log "[gpu-node] WSL switch lost k2s IP ($kubeSwitchIp) - reassigning to ensure proxy reachability" -Console
            foreach ($addr in $existingAddresses) {
                Remove-NetIPAddress -InterfaceIndex $wslAdapter.ifIndex -IPAddress $addr -Confirm:$false -ErrorAction SilentlyContinue
            }
            New-NetIPAddress -IPAddress $kubeSwitchIp -PrefixLength 24 -InterfaceAlias $wslAdapter.Name -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 2  # allow ARP/routing to settle
        }
        else {
            Write-Log "[gpu-node] WSL switch IP $kubeSwitchIp verified"
        }
    }
    else {
        Write-Log '[gpu-node] WARNING: vEthernet (WSL*) adapter not found - proxy-based download may fail' -Console
    }

    # SSH reverse tunnel: Windows SSH client forwards Linux:127.0.0.1:8181 → Windows:${kubeSwitchIp}:8181
    # so the Linux VM can reach httpproxy for apt/buildah. Kill any stale sshd listener first.
    Write-Log '[gpu-node] Releasing port 8181 in Linux VM if held by a stale sshd tunnel'
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute `
        'pid=$(sudo ss -tlnp | grep '':8181'' | grep -o ''pid=[0-9][0-9]*'' | head -1 | cut -d= -f2); if [ -n "$pid" ] && [ "$(cat /proc/$pid/comm 2>/dev/null)" = "sshd" ]; then sudo kill "$pid" 2>/dev/null; fi; true' `
        -IgnoreErrors).Output | Write-Log
    Start-Sleep -Seconds 1  # allow OS to release the port before we re-bind it

    # Diagnostic: log what (if anything) is still on port 8181 after the kill attempt
    $portCheck = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'ss -tlnp | grep '':8181'' || echo ''[gpu-node] port 8181 is free''' -IgnoreErrors).Output
    Write-Log "[gpu-node] port 8181 status after cleanup: $portCheck"

    Write-Log "[gpu-node] Establishing SSH reverse proxy tunnel (Linux:127.0.0.1:8181 -> Windows:${kubeSwitchIp}:8181)" -Console
    $sshKey = Get-SSHKeyControlPlane
    $ipControlPlane = Get-ConfiguredIPControlPlane
    $tunnelArgs = '-N', '-o', 'StrictHostKeyChecking=no', '-o', 'ExitOnForwardFailure=yes', `
        '-o', 'ServerAliveInterval=10', '-i', $sshKey, `
        '-R', "8181:${kubeSwitchIp}:8181", "remote@${ipControlPlane}"
    # Redirect SSH stderr to a temp file so we can log the reason if the tunnel exits prematurely.
    $sshErrFile = [System.IO.Path]::GetTempFileName()
    $tunnelProc = Start-Process -FilePath 'ssh.exe' -ArgumentList $tunnelArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardError $sshErrFile
    Start-Sleep -Seconds 2
    if ($tunnelProc.HasExited) {
        $sshErrText = if (Test-Path $sshErrFile) { (Get-Content $sshErrFile -Raw).Trim() } else { '' }
        Write-Log "[gpu-node] WARNING: SSH reverse tunnel exited (code $($tunnelProc.ExitCode)) - proxy-based downloads may fail" -Console
        if ($sshErrText) { Write-Log "[gpu-node] SSH error output: $sshErrText" -Console }
        $tunnelProc = $null
    } else {
        Write-Log "[gpu-node] SSH reverse tunnel started (PID $($tunnelProc.Id))"
        # Redirect apt proxy to tunnel; restored in finally block.
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute `
            "sudo sed -i 's|${kubeSwitchIp}:8181|127.0.0.1:8181|g' /etc/apt/apt.conf.d/proxy.conf 2>/dev/null; true" `
            -IgnoreErrors).Output | Write-Log
        Write-Log '[gpu-node] apt proxy temporarily redirected to 127.0.0.1:8181 via SSH tunnel'
    }
}
else {    
    # Reconfigure KubeMaster
    $controlPlaneNodeName = Get-ConfigControlPlaneNodeHostname
    Write-Log "Configuring $controlPlaneNodeName VM"
    Write-Log "Stopping VM $controlPlaneNodeName"
    Stop-VM -Name $controlPlaneNodeName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $controlPlaneNodeName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
    }

    if (Get-VMGpuPartitionAdapter -VMName $controlPlaneNodeName -ErrorAction SilentlyContinue) {
        Remove-VMGpuPartitionAdapter -VMName $controlPlaneNodeName
    }
    Set-VM -GuestControlledCacheTypes $true -VMName $controlPlaneNodeName
    Set-VM -LowMemoryMappedIoSpace 3Gb -VMName $controlPlaneNodeName
    Set-VM -HighMemoryMappedIoSpace 32Gb -VMName $controlPlaneNodeName
    Add-VMGpuPartitionAdapter -VMName $controlPlaneNodeName
    Write-Log "Start VM $controlPlaneNodeName"
    Start-VM -Name $controlPlaneNodeName
    # for the next steps we need ssh access, so let's wait for ssh
    Wait-ForSSHConnectionToLinuxVMViaSshKey

    Write-Log 'Copying drivers' -Console
    $installedDisplayDriver = Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | ForEach-Object { $_.InstalledDisplayDrivers }
    $drivers = Split-Path ($installedDisplayDriver -split ',')[0]

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p .nvidiadrivers/lib').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p .nvidiadrivers/drivers').Output | Write-Log

    Copy-ToControlPlaneViaSSHKey 'C:\Windows\System32\lxss\lib\*' '.nvidiadrivers/lib'
    Copy-ToControlPlaneViaSSHKey $drivers '.nvidiadrivers/drivers'

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /usr/lib/wsl').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -p /usr/lib/wsl/lib').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo cp -r .nvidiadrivers/* /usr/lib/wsl').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chmod 555 /usr/lib/wsl/lib/*').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chown -R root:root /usr/lib/wsl').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo '/usr/lib/wsl/lib' | sudo tee /etc/ld.so.conf.d/ld.wsl.conf").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo ldconfig 2>&1' -IgnoreErrors).Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo 'export PATH=`$PATH:/usr/lib/wsl/lib' | sudo tee /etc/profile.d/wsl.sh").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chmod +x /etc/profile.d/wsl.sh').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf .nvidiadrivers').Output | Write-Log

    # Apply WSL2 Kernel
    Write-Log 'Changing linux kernel' -Console
    $microsoftStandardWSL2 = 'shsk2s.azurecr.io/microsoft-standard-wsl2:6.1.21.2'
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p .microsoft-standard-wsl2').Output | Write-Log
    $command = "container=`$(sudo buildah from $microsoftStandardWSL2 2> /dev/null)  && mountpoint=`$(sudo buildah mount `$container) && sudo find `$mountpoint -iname *.deb | xargs sudo cp -t .microsoft-standard-wsl2 && sudo buildah unmount `$container && sudo buildah rm `$container > /dev/null 2>&1"
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $command).Output | Write-Log
    $count = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'ls -1 .microsoft-standard-wsl2/*.deb 2>/dev/null | wc -l').Output
    if ($count -eq '0') {
        $errMsg = "$microsoftStandardWSL2 could not be pulled!"
        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
    }
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'cd .microsoft-standard-wsl2 && sudo dpkg -i *.deb 2>&1').Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf .microsoft-standard-wsl2').Output | Write-Log

    # change linux kernel
    $prefix = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -o \'gnulinux-advanced.*\' /boot/grub/grub.cfg | tr -d `"\'`"").Output
    $kernel = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -o \'gnulinux.*microsoft-standard-WSL2.*\' /boot/grub/grub.cfg | head -1 | tr -d `"\'`"").Output

    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sed -i `"s/GRUB_DEFAULT=.*/GRUB_DEFAULT=\'${prefix}\>${kernel}\'/g`" /etc/default/grub").Output | Write-Log
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo update-grub 2>&1' -IgnoreErrors).Output | Write-Log

    # Restart KubeMaster
    Write-Log "Stopping VM $controlPlaneNodeName"
    Stop-VM -Name $controlPlaneNodeName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $controlPlaneNodeName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
    }
    Write-Log "Start VM $controlPlaneNodeName"
    Start-VM -Name $controlPlaneNodeName
    # for the next steps we need ssh access, so let's wait for ssh
    Wait-ForSSHConnectionToLinuxVMViaSshKey
}

# Install Nvidia container toolkit
Write-Log 'Installing Nvidia Container Toolkit' -Console

$offlineWorkflowMsg = "To resolve, use the offline workflow:`n" `
    + "  1. On a machine with internet access: k2s addons export gpu-node -d <export-dir>`n" `
    + "  2. Transfer the exported .oci.tar file to the restricted host`n" `
    + "  3. On the restricted host: k2s addons import gpu-node -f <path-to-oci-tar>`n" `
    + '  4. Then run: k2s addons enable gpu-node'

# NOTE: 'exit' inside a try-block does NOT trigger finally in PowerShell.
# Use $installFailed + return so finally always runs, then exit after the try/finally.
$installFailed = $false
try {
    # Remove any previously corrupted source list from a failed run
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list').Output | Write-Log
    # Remove stale package directories that have no .deb files (left over from a failed run)
    (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'find .gpu-node -maxdepth 1 -mindepth 1 -type d -exec sh -c ''ls "$1"/*.deb >/dev/null 2>&1 || rm -rf "$1"'' _ {} \; 2>/dev/null' -IgnoreErrors).Output | Write-Log

    if (!(Get-DebianPackageAvailableOffline -addon 'gpu-node' -package 'nvidia-container-toolkit')) {
        $httpProxy = if ($WSL) { '127.0.0.1:8181' } else { "${kubeSwitchIp}:8181" }
        $command = "curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -x $httpProxy | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list -x $httpProxy | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
        $repoSetupResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $command)
        $repoSetupResult.Output | Write-Log
        if (!$repoSetupResult.Success) {
            $errMsg = "Failed to set up NVIDIA container toolkit apt repository via proxy ($httpProxy).`n" `
                + "This usually means the host has no internet access or the K2s HTTP proxy is not reachable.`n" `
                + $offlineWorkflowMsg

            if ($EncodeStructuredOutput -eq $true) {
                $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
                Send-ToCli -MessageType $MessageType -Message @{Error = $err }
                return
            }

            Write-Log $errMsg -Error
            $installFailed = $true
            return
        }

        $updateResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get update')
        $updateResult.Output | Write-Log
        if (!$updateResult.Success) {
            Write-Log '[gpu-node] apt-get update failed after adding NVIDIA repository, installation may fail' -Console
        }
    }
    Install-DebianPackages -addon 'gpu-node' -packages 'libnvidia-container1', 'libnvidia-container-tools', 'nvidia-container-runtime', 'nvidia-container-toolkit'

    # Verify NVIDIA container toolkit was installed successfully
    $verifyResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'dpkg -l nvidia-container-toolkit 2>/dev/null | grep -q "^ii"')
    if (!$verifyResult.Success) {
        $errMsg = "NVIDIA container toolkit packages could not be installed.`n" `
            + $offlineWorkflowMsg

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        $installFailed = $true
        return
    }

    # Pre-pull images via buildah while the SSH tunnel is active (WSL2 only).
    # buildah obeys HTTPS_PROXY directly; images land in /var/lib/containers/storage shared with CRI-O.
    if ($WSL -and $null -ne $tunnelProc -and !$tunnelProc.HasExited) {
        Write-Log '[gpu-node] Pre-pulling images via SSH tunnel (buildah)' -Console

        $imagesToPrePull = @(
            'nvcr.io/nvidia/k8s-device-plugin:v0.15.0-ubi8',
            'nvcr.io/nvidia/k8s/dcgm-exporter:3.1.8-3.1.5-ubuntu20.04'
        )
        foreach ($img in $imagesToPrePull) {
            Write-Log "[gpu-node] Pre-pulling image via SSH tunnel: $img" -Console
            $prePullResult = (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute `
                "sudo HTTPS_PROXY=http://127.0.0.1:8181 HTTP_PROXY=http://127.0.0.1:8181 buildah pull '$img' 2>&1" `
                -IgnoreErrors)
            $prePullResult.Output | Write-Log
            if (!$prePullResult.Success) {
                Write-Log "[gpu-node] WARNING: Pre-pull of $img failed - deployment may stall waiting for image" -Console
            } else {
                Write-Log "[gpu-node] Pre-pull succeeded: $img"
            }
        }
    }
} finally {
    if ($null -ne $tunnelProc) {
        # Always restore apt proxy — it was redirected when the tunnel started, regardless of whether the tunnel is still alive.
        Write-Log "[gpu-node] Restoring apt proxy config to ${kubeSwitchIp}:8181"
        (Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute `
            "sudo sed -i 's|127.0.0.1:8181|${kubeSwitchIp}:8181|g' /etc/apt/apt.conf.d/proxy.conf 2>/dev/null; true" `
            -IgnoreErrors).Output | Write-Log
        if (!$tunnelProc.HasExited) {
            Write-Log "[gpu-node] Stopping SSH reverse proxy tunnel (PID $($tunnelProc.Id))"
            Stop-Process -Id $tunnelProc.Id -Force -ErrorAction SilentlyContinue
        }
        $tunnelProc = $null
    }
    if ($null -ne $sshErrFile -and (Test-Path $sshErrFile)) {
        Remove-Item $sshErrFile -Force -ErrorAction SilentlyContinue
    }
}
if ($installFailed) { exit 1 }

# Create hook oci-nvidia-hook.json
$hook = @'
{
\"version\": \"1.0.0\",
\"hook\": {
\"path\": \"/usr/bin/nvidia-container-toolkit\",
\"args\": [\"nvidia-container-toolkit\", \"prestart\"]
},
\"when\": {
\"always\": true,
\"commands\": [\".*\"]
},
\"stages\": [\"prestart\"]
}
'@

if ($PSVersionTable.PSVersion.Major -gt 5) {
    $hook = $hook.Replace('\', '')
}

(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json').Output | Write-Log
(Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo -e '$hook' | sudo tee -a /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json").Output | Write-Log

# Apply Nvidia device plugin
Write-Log 'Installing Nvidia Device Plugin' -Console
Wait-ForAPIServer
(Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\nvidia-device-plugin.yaml").Output | Write-Log

# Patch: mount /usr/lib/wsl/lib + set LD_LIBRARY_PATH so NVML stub is found (dxcore path, both WSL2 and Hyper-V GPU-PV).
# privileged:true is required because /dev/dxg is blocked inside unprivileged containers.
Write-Log '[GPU] Patching device plugin to resolve NVML via WSL2 lib path (/usr/lib/wsl/lib)' -Console
$wslLibPatchJson = '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"LD_LIBRARY_PATH","value":"/usr/lib/wsl/lib"}},{"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"wsl-libs","mountPath":"/usr/lib/wsl/lib"}},{"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"wsl-libs","hostPath":{"path":"/usr/lib/wsl/lib"}}},{"op":"replace","path":"/spec/template/spec/containers/0/securityContext","value":{"privileged":true}}]'
# Use a temp file — passing JSON inline via PowerShell loses double quotes
$patchTmpFile = [System.IO.Path]::GetTempFileName() + '.json'
try {
    $wslLibPatchJson | Set-Content $patchTmpFile -Encoding UTF8
    $patchResult = (Invoke-Kubectl -Params 'patch', 'deployment', 'nvidia-device-plugin', '-n', 'gpu-node', '--type=json', "--patch-file=$patchTmpFile")
    $patchResult.Output | Write-Log
    if (!$patchResult.Success) {
        Write-Log '[GPU] WARNING: Failed to patch device plugin with WSL2 lib path — nvidia.com/gpu may not be registered' -Console
    }
} finally {
    Remove-Item $patchTmpFile -Force -ErrorAction SilentlyContinue
}

if ($WSL) {
    # WSL2 only: delete existing pods so the patched spec (LD_LIBRARY_PATH + wsl-libs) is
    # picked up immediately and any ImagePullBackOff from a previous failed run is cleared.
    # On Hyper-V the Kubernetes rolling update handles spec changes natively.
    (Invoke-Kubectl -Params 'delete', 'pod', '-n', 'gpu-node', '--all', '--ignore-not-found').Output | Write-Log
}
$kubectlCmd = (Invoke-Kubectl -Params 'wait', '--timeout=180s', '--for=condition=Available', '-n', 'gpu-node', 'deployment/nvidia-device-plugin')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'Nvidia device plugin could not be started!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing DCGM-Exporter' -Console
(Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\dcgm-exporter.yaml").Output | Write-Log
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'dcgm-exporter', '-n', 'gpu-node', '--timeout', '30s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    # DCGM-Exporter requires NVML, which is unavailable via dxcore (both WSL2 and Hyper-V GPU-PV). Non-fatal.
    Write-Log '[GPU] DCGM-Exporter could not be started. This is expected: NVML cannot access the GPU via the dxcore/D3D12 path (WSL2 and Hyper-V GPU-PV). GPU workloads will still function correctly.' -Console
}

Write-Log 'KubeMaster configured successfully as GPU node' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'gpu-node' })

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}