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
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

$logModule = "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
$clusterModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.cluster.module/k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\addons.module.psm1"
$registryFunctionsModule = "$PSScriptRoot\..\..\smallsetup\helpers\RegistryFunctions.module.psm1"
$infraModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/k2s.infra.module.psm1"

Import-Module $logModule, $addonsModule, $clusterModule, $registryFunctionsModule, $infraModule -DisableNameChecking

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

$WSL = Get-WSLFromConfig

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

if ($WSL) {
    ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master '[ -f /usr/lib/wsl/lib/libdxcore.so ]'
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
    ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master '/usr/lib/wsl/lib/nvidia-smi'
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
    Write-Log "Configuring $global:VMName VM"
    Write-Log "Stopping VM $global:VMName"
    Stop-VM -Name $global:VMName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
    }

    if (Get-VMGpuPartitionAdapter -VMName $global:VMName -ErrorAction SilentlyContinue) {
        Remove-VMGpuPartitionAdapter -VMName $global:VMName
    }
    Set-VM -GuestControlledCacheTypes $true -VMName $global:VMName
    Set-VM -LowMemoryMappedIoSpace 3Gb -VMName $global:VMName
    Set-VM -HighMemoryMappedIoSpace 32Gb -VMName $global:VMName
    Add-VMGpuPartitionAdapter -VMName $global:VMName
    Write-Log "Start VM $global:VMName"
    Start-VM -Name $global:VMName
    # for the next steps we need ssh access, so let's wait for ssh
    Wait-ForSSHConnectionToLinuxVMViaSshKey

    Write-Log 'Copying drivers' -Console
    $installedDisplayDriver = Get-CimInstance -ClassName Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | ForEach-Object { $_.InstalledDisplayDrivers }
    $drivers = Split-Path ($installedDisplayDriver -split ',')[0]

    ExecCmdMaster 'mkdir -p .nvidiadrivers/lib'
    ExecCmdMaster 'mkdir -p .nvidiadrivers/drivers'
    Copy-FromToMaster 'C:\Windows\System32\lxss\lib\*' $($global:Remote_Master + ':' + '.nvidiadrivers/lib')
    Copy-FromToMaster "$drivers" $($global:Remote_Master + ':' + '.nvidiadrivers/drivers')

    ExecCmdMaster 'sudo rm -rf /usr/lib/wsl'
    ExecCmdMaster 'sudo mkdir -p /usr/lib/wsl/lib'
    ExecCmdMaster 'sudo cp -r .nvidiadrivers/* /usr/lib/wsl'
    ExecCmdMaster 'sudo chmod 555 /usr/lib/wsl/lib/*'
    ExecCmdMaster 'sudo chown -R root:root /usr/lib/wsl'
    ExecCmdMaster "echo '/usr/lib/wsl/lib' | sudo tee /etc/ld.so.conf.d/ld.wsl.conf"
    ExecCmdMaster 'sudo ldconfig 2>&1' -IgnoreErrors
    ExecCmdMaster "echo 'export PATH=`$PATH:/usr/lib/wsl/lib' | sudo tee /etc/profile.d/wsl.sh"
    ExecCmdMaster 'sudo chmod +x /etc/profile.d/wsl.sh'
    ExecCmdMaster 'sudo rm -rf .nvidiadrivers'

    # Apply WSL2 Kernel
    Write-Log 'Changing linux kernel' -Console
    $microsoftStandardWSL2 = 'shsk2s.azurecr.io/microsoft-standard-wsl2:6.1.21.2'
    ExecCmdMaster 'mkdir -p .microsoft-standard-wsl2'
    ExecCmdMaster "container=`$(sudo buildah from $microsoftStandardWSL2 2> /dev/null)  && mountpoint=`$(sudo buildah mount `$container) && sudo find `$mountpoint -iname *.deb | xargs sudo cp -t .microsoft-standard-wsl2 && sudo buildah unmount `$container && sudo buildah rm `$container > /dev/null 2>&1"
    $count = ExecCmdMaster 'ls -1 .microsoft-standard-wsl2/*.deb 2>/dev/null | wc -l' -NoLog
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
    ExecCmdMaster 'cd .microsoft-standard-wsl2 && sudo dpkg -i *.deb 2>&1'
    ExecCmdMaster 'sudo rm -rf .microsoft-standard-wsl2'

    # change linux kernel
    $prefix = ExecCmdMaster "grep -o \'gnulinux-advanced.*\' /boot/grub/grub.cfg | tr -d `"\'`"" -NoLog
    $kernel = ExecCmdMaster "grep -o \'gnulinux.*microsoft-standard-WSL2.*\' /boot/grub/grub.cfg | head -1 | tr -d `"\'`"" -NoLog

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
}

# Install Nvidia container toolkit
Write-Log 'Installing Nvidia Container Toolkit' -Console
if (!(Get-DebianPackageAvailableOffline -addon 'gpu-node' -package 'nvidia-container-toolkit')) {
    $setupInfo = Get-SetupInfo

    if ($setupInfo.Name -ne $global:SetupType_MultiVMK8s) {
        ExecCmdMaster "distribution=`$(. /etc/os-release;echo `$ID`$VERSION_ID) && curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -x $global:HttpProxy | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/`$distribution/libnvidia-container.list -x $global:HttpProxy | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    }
    else {
        ExecCmdMaster "distribution=`$(. /etc/os-release;echo `$ID`$VERSION_ID) && curl --retry 3 --retry-all-errors -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-all-errors -s -L https://nvidia.github.io/libnvidia-container/`$distribution/libnvidia-container.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    }

    ExecCmdMaster 'sudo apt-get update'
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

ExecCmdMaster 'sudo rm -rf /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json'
ExecCmdMaster "echo -e '$hook' | sudo tee -a /usr/share/containers/oci/hooks.d/oci-nvidia-hook.json" | Out-Null

# Apply Nvidia device plugin
Write-Log 'Installing Nvidia Device Plugin' -Console
Wait-ForAPIServer
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\gpu-node\manifests\nvidia-device-plugin.yaml" | Write-Log
&$global:KubectlExe wait --timeout=180s --for=condition=Available -n gpu-node deployment/nvidia-device-plugin | Write-Log
if (!$?) {
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
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\gpu-node\manifests\dcgm-exporter.yaml" | Write-Log
&$global:KubectlExe rollout status daemonset dcgm-exporter -n gpu-node --timeout 300s | Write-Log
if (!$?) {
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