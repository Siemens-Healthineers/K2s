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
    [pscustomobject] $Config
)

# load global settings
&$PSScriptRoot\..\..\smallsetup\common\GlobalVariables.ps1
# import global functions
. $PSScriptRoot\..\..\smallsetup\common\GlobalFunctions.ps1

. $PSScriptRoot\Common.ps1

Import-Module "$PSScriptRoot/../../smallsetup/ps-modules/log/log.module.psm1"
Initialize-Logging -ShowLogs:$ShowLogs

$addonsModule = "$PSScriptRoot\..\Addons.module.psm1"
$setupInfoModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.cluster.module\setupinfo\setupinfo.module.psm1"
$registryFunctionsModule = "$PSScriptRoot\..\..\smallsetup\helpers\RegistryFunctions.module.psm1"
Import-Module $addonsModule, $registryFunctionsModule, $setupInfoModule -DisableNameChecking

Write-Log 'Checking Nvidia driver installation' -Console

$WSL = Get-WSLFromConfig

if (!(Test-Path -Path 'C:\Windows\System32\lxss\lib\libdxcore.so')) {
    if ($WSL) {
        Write-Log 'It seems that the needed Nvidia drivers are not installed.' -Console
        Write-Log 'Please install them from the following link: https://www.nvidia.com/Download/index.aspx' -Console
        Write-Log 'After Nvidia driver installation you need to reinstall the cluster for the changes to take effect.' -Console
    }
    else {
        Write-Log 'It seems that the needed Nvidia drivers are not installed.' -Console
        Write-Log 'Please install them from the following link: https://www.nvidia.com/Download/index.aspx' -Console
    }

    exit 1
}

Write-Log 'Checking cluster status' -Console
Test-ClusterAvailability

if ((Test-IsAddonEnabled -Name 'gpu-node') -eq $true) {
    Write-Log "Addon 'gpu-node' is already enabled, nothing to do." -Console
    exit 0
}

if ($WSL) {
    ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master '[ -f /usr/lib/wsl/lib/libdxcore.so ]'
    if (!$?) {
        Write-Log 'It seems that the needed Nvidia drivers are not installed.' -Console
        Write-Log 'Please install them from the following link: https://www.nvidia.com/Download/index.aspx' -Console
        Write-Log 'After Nvidia driver installation you need to reinstall the cluster for the changes to take effect.' -Console
        exit 1
    }
    ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master '/usr/lib/wsl/lib/nvidia-smi'
    if (!$?) {
        Write-Log 'It seems that the needed Nvidia drivers are not installed correctly!' -Console
        Write-Log 'Please reinstall Nvidia drivers and cluster and try again!' -Console
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
        Write-Error "$microsoftStandardWSL2 could not be pulled!"
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
    if ($setupInfo.ValidationError) {
        throw $setupInfo.ValidationError
    }

    if ($setupInfo.Name -ne $global:SetupType_MultiVMK8s) {
        ExecCmdMaster "distribution=`$(. /etc/os-release;echo `$ID`$VERSION_ID) && curl --retry 3 --retry-connrefused -fsSL https://nvidia.github.io/libnvidia-container/gpgkey -x $global:HttpProxy | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-connrefused -s -L https://nvidia.github.io/libnvidia-container/`$distribution/libnvidia-container.list -x $global:HttpProxy | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
    }
    else {
        ExecCmdMaster "distribution=`$(. /etc/os-release;echo `$ID`$VERSION_ID) && curl --retry 3 --retry-connrefused -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor --batch --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && curl --retry 3 --retry-connrefused -s -L https://nvidia.github.io/libnvidia-container/`$distribution/libnvidia-container.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"
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
    Write-Error 'Nvidia device plugin could not be started!'
    exit 1
}

Write-Log 'Installing DCGM-Exporter' -Console
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\gpu-node\manifests\dcgm-exporter.yaml" | Write-Log
&$global:KubectlExe rollout status daemonset dcgm-exporter -n gpu-node --timeout 300s | Write-Log
if (!$?) {
    Write-Error 'DCGM-Exporter could not be started!'
    exit 1
}

Write-Log 'KubeMaster configured successfully as GPU node' -Console

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'gpu-node' })
