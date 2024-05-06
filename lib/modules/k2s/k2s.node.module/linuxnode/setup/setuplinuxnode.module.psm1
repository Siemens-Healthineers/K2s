# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
$validationModule = "$PSScriptRoot\..\..\..\k2s.infra.module\validation\validation.module.psm1"
$vmModule = "$PSScriptRoot\..\vm\vm.module.psm1"
$networkModule = "$PSScriptRoot\..\network\network.module.psm1"
$provisioningModule = "$PSScriptRoot\..\baseimage\provisioning.module.psm1"

$vmNodeModule = "$PSScriptRoot\..\..\vmnode\vmnode.module.psm1"

Import-Module $logModule, $configModule, $pathModule, $vmModule, $networkModule, $validationModule, $provisioningModule, $vmNodeModule

$sshKeyControlPlane = Get-SSHKeyControlPlane
$controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName
$linuxNodeHostName = Get-ConfigControlPlaneNodeHostname
$sshConfigDir = Get-SshConfigDir
$ipControlPlane = Get-ConfiguredIPControlPlane
$defaultProvisioningBaseImageSize = Get-DefaultProvisioningBaseImageDiskSize

function Set-ProxySettings {
    param (
        [parameter(Mandatory = $true, HelpMessage = 'The HTTP proxy')]
        [string] $ProxySettings
    )
    # put proxy in VM
    Write-Log "Set proxy: '$ProxySettings' in VM"
    Invoke-CmdOnControlPlaneViaSSHKey 'sudo touch /etc/apt/apt.conf.d/proxy.conf'
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        Invoke-CmdOnControlPlaneViaSSHKey "echo Acquire::http::Proxy \""$ProxySettings\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf"
    }
    else {
        Invoke-CmdOnControlPlaneViaSSHKey "echo Acquire::http::Proxy \\\""$ProxySettings\\\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf"
    }

    Write-Log 'Set proxy for crio'
    Invoke-CmdOnControlPlaneViaSSHKey 'sudo mkdir -p /etc/systemd/system/crio.service.d'
    Invoke-CmdOnControlPlaneViaSSHKey 'sudo touch /etc/systemd/system/crio.service.d/http-proxy.conf'
    Invoke-CmdOnControlPlaneViaSSHKey 'echo [Service] | sudo tee /etc/systemd/system/crio.service.d/http-proxy.conf'
    Invoke-CmdOnControlPlaneViaSSHKey "echo Environment=\'HTTP_PROXY=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
    Invoke-CmdOnControlPlaneViaSSHKey "echo Environment=\'HTTPS_PROXY=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
    Invoke-CmdOnControlPlaneViaSSHKey "echo Environment=\'http_proxy=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
    Invoke-CmdOnControlPlaneViaSSHKey "echo Environment=\'https_proxy=$ProxySettings\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"
    Invoke-CmdOnControlPlaneViaSSHKey "echo Environment=\'no_proxy=.local\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"

    Write-Log 'Set other proxy settings'
    Invoke-CmdOnControlPlaneViaSSHKey 'echo [engine] | sudo tee /etc/containers/containers.conf'
    if ($PSVersionTable.PSVersion.Major -gt 5) {
        Invoke-CmdOnControlPlaneViaSSHKey "echo env = [\""https_proxy=$ProxySettings\""] | sudo tee -a /etc/containers/containers.conf"
    }
    else {
        Invoke-CmdOnControlPlaneViaSSHKey "echo env = [\\\""https_proxy=$ProxySettings\\\""] | sudo tee -a /etc/containers/containers.conf"
    }
}

function New-SshKey() {
    # remove previous VM key from known hosts
    $file = $sshConfigDir + '\known_hosts'
    if (Test-Path $file) {
        Write-Log 'Remove previous VM key from known_hosts file'

        ssh-keygen.exe -R $ipControlPlane 2>&1 | % { "$_" }
    }


    # Create SSH keypair, if not yet available
    $sshDir = Split-Path -parent $sshKeyControlPlane
    if (!(Test-Path $sshDir)) {
        mkdir $sshDir | Out-Null
    }
    if (!(Test-Path $sshKeyControlPlane)) {
        Write-Log "creating SSH key $sshKeyControlPlane"
        if ($PSVersionTable.PSVersion.Major -gt 5) {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $sshKeyControlPlane -N ''
        }
        else {
            echo y | ssh-keygen.exe -t rsa -b 2048 -f $sshKeyControlPlane -N '""'  # strange powershell syntax for empty passphrase...
        }
    }
    if (!(Test-Path $sshKeyControlPlane)) {
        throw "unable to generate SSH keys ($sshKeyControlPlane)"
    }
}

function Remove-SshKey {
    Write-Log 'Remove control plane ssh keys from host'
    ssh-keygen.exe -R $ipControlPlane 2>&1 | % { "$_" } | Out-Null
    Remove-Item -Path ($sshConfigDir + '\kubemaster') -Force -Recurse -ErrorAction SilentlyContinue
}

<#
.Description
Copy-CloudInitFiles save cloud init files to master VM.
#>
function Copy-CloudInitFiles () {
    $source = '/var/log/cloud-init*'
    $target = "$(Get-SystemDriveLetter):\var\log\cloud-init"
    Remove-Item -Path $target -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
    mkdir $target -ErrorAction SilentlyContinue | Out-Null

    Write-Log "copy $source to $target"
    Copy-FromControlPlaneViaSSHKey $source $target
}

function New-VmFromIso {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        [Parameter(Mandatory = $true)]
        [string]$VhdxPath,
        [uint64]$VHDXSizeBytes,
        [int64]$MemoryStartupBytes = 1GB,
        [int64]$ProcessorCount = 2,
        [string]$SwitchName = 'SWITCH',
        [switch]$UseGeneration1
    )

    if ($VHDXSizeBytes) {
        Resize-VHD -Path $VhdxPath -SizeBytes $VHDXSizeBytes
    }

    # Create VM
    $generation = 2
    if ($UseGeneration1) {
        $generation = 1
    }
    Write-Log "Creating VM: $VMName"
    Write-Log "             - Vhdx: $VhdxPath"
    Write-Log "             - MemoryStartupBytes: $MemoryStartupBytes"
    Write-Log "             - SwitchName: $SwitchName"
    Write-Log "             - VM Generation: $generation"
    $vm = New-VM -Name $VMName -Generation $generation -MemoryStartupBytes $MemoryStartupBytes -VHDPath $VhdxPath -SwitchName $SwitchName
    $vm | Set-VMProcessor -Count $ProcessorCount

    <#
    Avoid using VM Service name as it is not culture neutral, use the ID instead.
    Name: Guest Service Interface; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\6C09BB55-D683-4DA0-8931-C9BF705F6480
    Name: Heartbeat; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\84EAAE65-2F2E-45F5-9BB5-0E857DC8EB47
    Name: Key-Value Pair Exchange; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\2A34B1C2-FD73-4043-8A5B-DD2159BC743F
    Name: Shutdown; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\9F8233AC-BE49-4C79-8EE3-E7E1985B2077
    Name: Time Synchronization; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\2497F4DE-E9FA-4204-80E4-4B75C46419C0
    Name: VSS; ID: Microsoft:F25734B3-090B-42B7-9EA7-018A5AB04C5E\5CED1297-4598-4915-A5FC-AD21BB4D02A4
    #>

    $GuestServiceInterfaceID = '6C09BB55-D683-4DA0-8931-C9BF705F6480'
    Get-VMIntegrationService -VM $vm | Where-Object { $_.Id -match $GuestServiceInterfaceID } | Enable-VMIntegrationService
    $vm | Set-VMMemory -DynamicMemoryEnabled $false

    # Sets Secure Boot Template.
    #   Set-VMFirmware -SecureBootTemplate 'MicrosoftUEFICertificateAuthority' doesn't work anymore (!?).
    if ( $generation -eq 2 ) {
        $vm | Set-VMFirmware -SecureBootTemplateId ([guid]'272e7447-90a4-4563-a4b9-8e4ab00526ce')
    }

    # Enable nested virtualization (if processor supports it)
    $virt = Get-CimInstance Win32_Processor | Where-Object { ($_.Name -like 'Intel*') }
    if ( $virt ) {
        Write-Log 'Enable nested virtualization'
        $vm | Set-VMProcessor -ExposeVirtualizationExtensions $true
    }

    # Disable Automatic Checkpoints. Check if command is available since it doesn't exist in Server 2016.
    $command = Get-Command Set-VM
    if ($command.Parameters.AutomaticCheckpointsEnabled) {
        $vm | Set-VM -AutomaticCheckpointsEnabled $false
    }

    Write-Log "Starting VM $VMName"
    $i = 0;
    $RetryCount = 3;
    while ($true) {
        $i++
        if ($i -gt $RetryCount) {
            throw "           Failure starting $VMName VM"
        }
        Write-Log "VM Start Handling loop (iteration #$i):"
        Start-VM -Name $VMName -ErrorAction Continue
        if ($?) {
            Write-Log "           Start success $VMName VM"
            break;
        }
        Start-Sleep -s 5
    }

    # Wait for VM
    Write-Log 'Waiting for VM to send heartbeat...'
    Wait-VM -Name $VMName -For Heartbeat

    Write-Log 'VM started ok'
}

function Initialize-LinuxNode {
    param (
        [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available to be used during installation')]
        [string] $InstallationStageProxy = '',
        [parameter(Mandatory = $false, HelpMessage = 'Startup Memory Size of KubeMaster VM')]
        [long] $VMStartUpMemory = 4GB,
        [parameter(Mandatory = $false, HelpMessage = 'Number of Virtual Processors for KubeMaster VM')]
        [long] $VMProcessorCount = 4,
        [parameter(Mandatory = $false, HelpMessage = 'Virtual hard disk size of KubeMaster VM')]
        [long] $VMDiskSize = 50GB,
        [parameter(Mandatory = $false, HelpMessage = 'Host-GW or VXLAN, Host-GW: true, false for VXLAN')]
        [bool] $HostGW = $true,
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Forces the installation online')]
        [Boolean] $ForceOnlineInstallation = $false,
        [parameter(Mandatory = $false, HelpMessage = 'Use WSL2 for hosting KubeMaster VM')]
        [switch] $WSL = $false,
        [parameter(Mandatory = $false, HelpMessage = 'The path to the vhdx with Ubuntu inside.')]
        [string] $LinuxVhdxPath = '',
        [parameter(Mandatory = $false, HelpMessage = 'The user name to access the computer with Ubuntu inside.')]
        [string] $LinuxUserName = '',
        [parameter(Mandatory = $false, HelpMessage = 'The password associated with the user name to access the computer with Ubuntu inside.')]
        [string] $LinuxUserPwd = '',
        [parameter(Mandatory = $false, HelpMessage = 'If true will skip addition of transparant proxy to linux node.')]
        [Boolean] $SkipTransparentProxy = $false
    )

    if (!$SkipTransparentProxy) {
        # use the local httpproxy for the linux master VM
        $ipNextHop = Get-ConfiguredKubeSwitchIP
        $transparentproxy = 'http://' + $ipNextHop + ':8181'
        Write-Log "Local httpproxy proxy was set and will be used for linux node: $transparentproxy"
    } else {
        Write-Log "No local httpproxy proxy was set to linux node"
        $transparentproxy = ''
    }

    Write-Log 'Using proxies:'
    Write-Log "    - installation stage: '$InstallationStageProxy'"
    Write-Log "    - operation stage: '$transparentproxy'"

    Write-Log "VM '$linuxNodeHostName' is not yet available, creating VM ..."

    Write-Log "InstallKubeMaster called with RAM: $VMStartUpMemory, Diskspace: $VMDiskSize, CPUs: $VMProcessorCount, Proxy (installation stage): '$InstallationStageProxy', Proxy (operation stage): '$transparentproxy'"

    if (-not (Test-Path env:KUBEMASTER_TYPE)) {
        $env:KUBEMASTER_TYPE = 'RawDebian'  # set env if called directly
    }

    $controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName

    # cleanup networking of previous setup
    if (($(Get-VMSwitch | Where-Object Name -eq $controlPlaneSwitchName | Measure-Object).Count -ge 1 )) {
        # TODO ONLY CLEANUP NETWORKING HERE
        Write-Log 'Cleaning up previous KubeMaster VM networking'
        &"$global:KubernetesPath\smallsetup\kubemaster\UninstallKubeMaster.ps1" -DeleteFilesForOfflineInstallation $ForceOnlineInstallation
    }

    $isLinuxOsDebianCloud = Get-IsLinuxOsDebian

    # Get default VHD path (requires administrative privileges)
    $vmmsSettings = Get-CimInstance -namespace root\virtualization\v2 Msvm_VirtualSystemManagementServiceSettingData
    $vhdxPath = Join-Path $vmmsSettings.DefaultVirtualHardDiskPath "$linuxNodeHostName.vhdx"

    $kubemasterBaseVhdxPath = Get-ControlPlaneVMBaseImagePath
    $isBaseImageAlreadyAvailable = (Test-Path $kubemasterBaseVhdxPath)

    Write-Log "Provisioned base image already available? $isBaseImageAlreadyAvailable"
    Write-Log "Force the build and provisioning of the base image (i.e. online installation)? $ForceOnlineInstallation"
    Write-Log "Delete the provisioned base image for offline installation? $DeleteFilesForOfflineInstallation"

    $isOfflineInstallation = ($isBaseImageAlreadyAvailable -and !$ForceOnlineInstallation)

    if ($isLinuxOsDebianCloud) {
        $kubemasterRootfsPath = Get-ControlPlaneVMRootfsPath
        $isRootfsAlreadyAvailable = (Test-Path $kubemasterRootfsPath)
        Write-Log "Provisioned base image rootfs for WSL2 already available? $isRootfsAlreadyAvailable"

        $isOfflineInstallation = ($isOfflineInstallation -and $isRootfsAlreadyAvailable)
    }

    if ($isOfflineInstallation) {
        Write-Log "Using already existing base image '$kubemasterBaseVhdxPath'"
    }
    else {
        Write-Log 'Create and provision the base image'
        New-VmBaseImageProvisioning -Proxy $InstallationStageProxy `
            -OutputPath $kubemasterBaseVhdxPath `
            -VMMemoryStartupBytes $VMStartUpMemory `
            -VMProcessorCount $VMProcessorCount `
            -VMDiskSize $defaultProvisioningBaseImageSize

        if (!(Test-Path $kubemasterBaseVhdxPath)) {
            throw "The provisioned base image is not available as $kubemasterBaseVhdxPath"
        }
        Write-Log "Provisioned base image available as $kubemasterBaseVhdxPath"
    }

    Write-Log "Removing '$vhdxPath' if existing"
    if (Test-Path $vhdxPath) {
        Remove-Item $vhdxPath -Force
    }

    Write-Log "Copy '$kubemasterBaseVhdxPath' to '$vhdxPath'"
    Copy-Item $kubemasterBaseVhdxPath $vhdxPath

    # restart httpproxy if service exists in order to listen also on new switch
    Restart-Service httpproxy -ErrorAction SilentlyContinue

    New-SshKey

    if ($WSL) {
        $kubemasterRootfsPath = Get-ControlPlaneVMRootfsPath
        $isRootfsAlreadyAvailable = (Test-Path $kubemasterRootfsPath)
        if (!$isRootfsAlreadyAvailable) {
            throw "$kubemasterRootfsPath not available!"
        }

        Write-Log 'Remove existing KubeMaster distro if existing'
        wsl --unregister $linuxNodeHostName | Out-Null
        Write-Log 'Import KubeMaster distro'
        wsl --import $linuxNodeHostName "$env:SystemDrive\wsl" "$kubemasterRootfsPath"
        Write-Log 'Set KubeMaster as default distro'
        wsl -s $linuxNodeHostName

        Write-Log 'Update fstab'
        wsl /bin/bash -c 'sudo rm /etc/fstab'
        wsl /bin/bash -c "echo '/dev/sdb / ext4 rw,discard,errors=remount-ro,x-systemd.growfs 0 1' | sudo tee /etc/fstab"
        wsl --shutdown

        Start-WSL

        Set-WSLSwitch

        Wait-ForSSHConnectionToLinuxVMViaPwd
    }
    else {
        # prepare switch for control plane VM
        New-DefaultControlPlaneSwitch

        New-VmFromIso -VMName $linuxNodeHostName `
            -VhdxPath $vhdxPath `
            -SwitchName $controlPlaneSwitchName `
            -VHDXSizeBytes $VMDiskSize `
            -MemoryStartupBytes $VMStartUpMemory `
            -ProcessorCount $VMProcessorCount `
            -UseGeneration1

        Wait-ForSSHConnectionToLinuxVMViaPwd
    }

    $kubemasterBaseImagePath = Get-ControlPlaneVMBaseImagePath
    $kubemasterRootfsPath = Get-ControlPlaneVMRootfsPath
    if ($DeleteFilesForOfflineInstallation) {
        Write-Log "Remove '$kubemasterBaseImagePath'"
        Remove-Item $kubemasterBaseImagePath -Force
        Write-Log "Remove '$kubemasterRootfsPath'"
        Remove-Item $kubemasterRootfsPath -Force
    }
    else {
        Write-Log "Leave file '$kubemasterBaseImagePath' on file system for offline installation"
        Write-Log "Leave file '$kubemasterRootfsPath' on file system for offline installation"
    }

    # copy public key into VM and add it to authorized_keys file for the remote user
    $localSourcePath = "$sshKeyControlPlane.pub"
    $keyFileName = Get-SSHKeyFileName
    $targetKeyPath = "/tmp/$keyFileName.pub"
    Copy-ToControlPlaneViaUserAndPwd $localSourcePath $targetKeyPath

    Invoke-CmdOnControlPlaneViaUserAndPwd 'sudo mkdir -p /home/remote/.ssh'
    Invoke-CmdOnControlPlaneViaUserAndPwd "sudo cat $targetKeyPath | sudo tee /home/remote/.ssh/authorized_keys"

    # for the next steps we need ssh access, so let's wait for ssh
    Wait-ForSSHConnectionToLinuxVMViaSshKey

    # remove password for remote user and disable password login
    Invoke-CmdOnControlPlaneViaSSHKey 'sudo passwd -d remote'

    Invoke-CmdOnControlPlaneViaSSHKey "sudo sed -i 's/.*NAutoVTs.*/NAutoVTs=0/' /etc/systemd/logind.conf"
    Invoke-CmdOnControlPlaneViaSSHKey "sudo sed -i 's/.*ReserveVT.*/ReserveVT=0/' /etc/systemd/logind.conf"
    Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl disable getty@tty1.service 2>&1'
    Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl stop "getty@tty*.service"'
    Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl restart systemd-logind.service'
    Invoke-CmdOnControlPlaneViaSSHKey 'echo Include /etc/ssh/sshd_config.d/*.conf | sudo tee -a /etc/ssh/sshd_config'
    Invoke-CmdOnControlPlaneViaSSHKey 'sudo touch /etc/ssh/sshd_config.d/disable_pwd_login.conf'
    Invoke-CmdOnControlPlaneViaSSHKey 'echo ChallengeResponseAuthentication no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf'
    Invoke-CmdOnControlPlaneViaSSHKey 'echo PasswordAuthentication no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf'
    Invoke-CmdOnControlPlaneViaSSHKey 'echo UsePAM no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf'
    Invoke-CmdOnControlPlaneViaSSHKey 'echo PermitRootLogin no | sudo tee -a /etc/ssh/sshd_config.d/disable_pwd_login.conf'
    Invoke-CmdOnControlPlaneViaSSHKey 'sudo systemctl reload ssh'

    if ($isLinuxOsDebianCloud) {
        Copy-CloudInitFiles
    }

    if (![string]::IsNullOrWhiteSpace($transparentproxy)) {
        Set-ProxySettings -ProxySettings $transparentproxy
    }

    # dump vm properties
    #Get-Vm -Name $nameControlPlane

    $hostname = Invoke-CmdOnControlPlaneViaSSHKey 'hostname' -NoLog
    Set-ConfigControlPlaneNodeHostname $($hostname.ToLower())

    Write-Log "All steps done, VM $nameControlPlane now available !"

    # add DNS proxy at KubeSwitch for cluster searches
    if ($WSL) {
        Add-DnsServer $global:WSLSwitchName
    }
    else {
        Add-DnsServer $controlPlaneSwitchName
    }
}

<#
.SYNOPSIS
Remove linux VM acting as KubeMaster

.DESCRIPTION
This script assists in the following actions for K2s:
- Remove linux VM
- Remove switch
- Remove virtual disk
#>
function Uninstall-LinuxNode {
    Param(
        [parameter(Mandatory = $false, HelpMessage = 'Deletes the needed files to perform an offline installation')]
        [Boolean] $DeleteFilesForOfflineInstallation = $false
    )
    $ErrorActionPreference = 'Continue'

    Write-Log "Uninstalling $linuxNodeHostName control plane VM" -Console

    # try to remove switch
    Write-Log "Remove ip address and nat: $controlPlaneSwitchName"
    Remove-KubeSwitch

    if ($(Get-ConfigWslFlag)) {
        wsl --shutdown | Out-Null
        wsl --unregister $linuxNodeHostName | Out-Null
        Reset-DnsServer $global:WSLSwitchName
    }
    else {
        # remove vm
        Stop-VirtualMachine -VmName $linuxNodeHostName -Wait
        Remove-VirtualMachine $linuxNodeHostName
    }

    Write-Log 'Uninstall provisioner of linux node'
    Clear-ProvisioningArtifacts

    if ($DeleteFilesForOfflineInstallation) {
        $kubemasterBaseImagePath = Get-ControlPlaneVMBaseImagePath
        $kubemasterRootfsPath = Get-ControlPlaneVMRootfsPath
        Write-Log "Delete file '$kubemasterBaseImagePath' if existing"
        if (Test-Path $kubemasterBaseImagePath) {
            Remove-Item $kubemasterBaseImagePath -Force
            Remove-Item $kubemasterRootfsPath -Force
        }
    }

    Remove-SshKey
}

Export-ModuleMember Initialize-LinuxNode, Uninstall-LinuxNode, Remove-SshKey