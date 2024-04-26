# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
$addonsModule = "$PSScriptRoot\..\addons.v2.module.psm1"
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

if ((Test-IsAddonEnabled -Name 'gpu-node') -eq $true) {
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

if (!(Test-Path -Path 'C:\Windows\System32\lxss\lib\libdxcore.so')) {
    $errMsg = "It seems that the needed Nvidia drivers are not installed.`nPlease install them from the following link: https://www.nvidia.com/Download/index.aspx"

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

$remoteUser = Get-ControlPlaneRemoteUser

if ($WSL) {
    $sshKey = Get-SSHKeyControlPlane    

    ssh.exe -n -o StrictHostKeyChecking=no -i $sshKey $remoteUser '[ -f /usr/lib/wsl/lib/libdxcore.so ]'
    if (!$?) {
        $errMsg = "It seems that the needed Nvidia drivers are not installed.`n" `
            + "Please install them from the following link: https://www.nvidia.com/Download/index.aspx`n"`
            + 'After Nvidia driver installation you need to reinstall the cluster for the changes to take effect.'

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }
    
        Write-Log $errMsg -Error
        exit 1
    }

    ssh.exe -n -o StrictHostKeyChecking=no -i $sshKey $remoteUser '/usr/lib/wsl/lib/nvidia-smi'
    if (!$?) {
        $errMsg = "It seems that the needed Nvidia drivers are not installed correctly.`n" `
            + 'Please reinstall Nvidia drivers and cluster and try again.'

        if ($EncodeStructuredOutput -eq $true) {
            $err = New-Error -Severity Warning -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
            Send-ToCli -MessageType $MessageType -Message @{Error = $err }
            return
        }

        Write-Log $errMsg -Error
        exit 1
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

    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p .nvidiadrivers/lib'
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p .nvidiadrivers/drivers'

    Copy-ToControlPlaneViaSSHKey 'C:\Windows\System32\lxss\lib\*' '.nvidiadrivers/lib'
    Copy-ToControlPlaneViaSSHKey $drivers '.nvidiadrivers/drivers'

    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /usr/lib/wsl'
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo mkdir -p /usr/lib/wsl/lib'
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo cp -r .nvidiadrivers/* /usr/lib/wsl'
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chmod 555 /usr/lib/wsl/lib/*'
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chown -R root:root /usr/lib/wsl'
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo '/usr/lib/wsl/lib' | sudo tee /etc/ld.so.conf.d/ld.wsl.conf"
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo ldconfig 2>&1' -IgnoreErrors
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo 'export PATH=`$PATH:/usr/lib/wsl/lib' | sudo tee /etc/profile.d/wsl.sh"
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo chmod +x /etc/profile.d/wsl.sh'
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf .nvidiadrivers'

    # Apply WSL2 Kernel
    Write-Log 'Changing linux kernel' -Console
    $microsoftStandardWSL2 = 'shsk2s.azurecr.io/microsoft-standard-wsl2:6.1.21.2'
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'mkdir -p .microsoft-standard-wsl2'
    $command = "container=`$(sudo buildah from $microsoftStandardWSL2 2> /dev/null)  && mountpoint=`$(sudo buildah mount `$container) && sudo find `$mountpoint -iname *.deb | xargs sudo cp -t .microsoft-standard-wsl2 && sudo buildah unmount `$container && sudo buildah rm `$container > /dev/null 2>&1"
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $command
    $count = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'ls -1 .microsoft-standard-wsl2/*.deb 2>/dev/null | wc -l' -NoLog
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
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'cd .microsoft-standard-wsl2 && sudo dpkg -i *.deb 2>&1'
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf .microsoft-standard-wsl2'

    # change linux kernel
    $prefix = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -o \'gnulinux-advanced.*\' /boot/grub/grub.cfg | tr -d `"\'`"" -NoLog
    $kernel = Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "grep -o \'gnulinux.*microsoft-standard-WSL2.*\' /boot/grub/grub.cfg | head -1 | tr -d `"\'`"" -NoLog

    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "sudo sed -i `"s/GRUB_DEFAULT=.*/GRUB_DEFAULT=\'${prefix}\>${kernel}\'/g`" /etc/default/grub"
    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo update-grub 2>&1' -IgnoreErrors

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
if (!(Get-DebianPackageAvailableOffline -addon 'gpu-node' -package 'nvidia-container-toolkit')) {
    $setupInfo = Get-SetupInfo
    
    if ($setupInfo.Name -ne 'MultiVMK8s') {
        $httpProxy = "$(Get-ConfiguredKubeSwitchIP):8181"
        $command = "distribution=`$(. /etc/os-release;echo `$ID`$VERSION_ID) && curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -x $httpProxy | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/`$distribution/libnvidia-container.list -x $httpProxy | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $command
    }
    else {
        $command = "distribution=`$(. /etc/os-release;echo `$ID`$VERSION_ID) && curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/`$distribution/libnvidia-container.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
        Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute $command
    }

    Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo apt-get update'
}
Install-DebianPackages -addon 'gpu-node' -packages 'libnvidia-container1', 'libnvidia-container-tools', 'nvidia-container-runtime', 'nvidia-container-toolkit'

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

Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute 'sudo rm -rf /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json'
Invoke-CmdOnControlPlaneViaSSHKey -Timeout 2 -CmdToExecute "echo -e '$hook' | sudo tee -a /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json" | Out-Null

# Apply Nvidia device plugin
Write-Log 'Installing Nvidia Device Plugin' -Console
Wait-ForAPIServer
(Invoke-Kubectl -Params 'apply', '-f', "$PSScriptRoot\manifests\nvidia-device-plugin.yaml").Output | Write-Log
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
$kubectlCmd = (Invoke-Kubectl -Params 'rollout', 'status', 'daemonset', 'dcgm-exporter', '-n', 'gpu-node', '--timeout', '300s')
Write-Log $kubectlCmd.Output
if (!$kubectlCmd.Success) {
    $errMsg = 'DCGM-Exporter could not be started!'
    if ($EncodeStructuredOutput -eq $true) {
        $err = New-Error -Code (Get-ErrCodeAddonEnableFailed) -Message $errMsg
        Send-ToCli -MessageType $MessageType -Message @{Error = $err }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'KubeMaster configured successfully as GPU node' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'gpu-node' })

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}