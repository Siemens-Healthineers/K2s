# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

<#
.SYNOPSIS
Installs KubeVirt in the cluster

.DESCRIPTION
Kubevirt is needed for running VMs in Kubernetes for apps which cannot containerized

# Current version is checked in, pick an upstream version of KubeVirt to install:
$ export RELEASE=v0.58.0
# Deploy the KubeVirt operator
$ kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-operator.yaml
# Create the KubeVirt CR (instance deployment request) which triggers the actual installation
$ kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${RELEASE}/kubevirt-cr.yaml
# wait until all KubeVirt components are up
$ kubectl -n kubevirt wait kv kubevirt --for condition=Available

.EXAMPLE
# For k2sSetup
powershell <installation folder>\addons\Kubevirt\Enable.ps1
# with software virtualization
powershell <installation folder>\addons\Kubevirt\Enable.ps1 -UseSoftwareVirtualization
# For OnPremise setup
powershell <installation folder>\addons\Kubevirt\Enable.ps1 -K8sSetup  OnPremise
#>

Param(
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Use software virtualization')]
    [switch] $UseSoftwareVirtualization = $false,
    [parameter(Mandatory = $false, HelpMessage = 'K8sSetup: SmallSetup/OnPremise')]
    [string] $K8sSetup = 'SmallSetup',
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
$cliMessagesModule = "$PSScriptRoot/../../lib/modules/k2s/k2s.infra.module/cli-messages/cli-messages.module.psm1"

Import-Module $logModule, $addonsModule, $clusterModule, $cliMessagesModule

Initialize-Logging -ShowLogs:$ShowLogs

Write-Log 'Checking cluster status' -Console

$systemError = Test-SystemAvailability
if ($systemError) {
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $systemError }
        return
    }

    Write-Log $systemError -Error
    exit 1
}

if ((Test-IsAddonEnabled -Name 'kubevirt') -eq $true) {
    Write-Log "Addon 'kubevirt' is already enabled, nothing to do." -Console

    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
    
    exit 0
}

$wsl = Get-WSLFromConfig
if ($wsl) {
    $errMsg = "kubevirt addon is not available with WSL2 setup!`n" `
        + "Please install cluster without wsl option in order to use kubevirt addon!`n" `
        + 'kubevirt not available on current setup!'
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

Write-Log 'Installing kubevirt addon' -Console

# check memory
$MasterVMMemory = Get-VMMemory -VMName $global:VMName
if ( $MasterVMMemory.Startup -lt 10GB ) {
    $errMsg = "KubeVirt needs minimal 8GB main memory, you have a Small K8s Setup with less memory!`n" `
        + "Please increase main memory for the VM $global:VMName (shutdown, increase memory to 10GB, start)`n" `
        + "or install from scratch with k2s install --master-cpus 8 --master-memory 12GB --master-disk 120GB`n"`
        + 'Memory in master vm too low, stop your cluster and increase the memory of your master vm to at least 12GB!'
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# check disk
$MasterDiskSize = Get-VM -VMName $global:VMName | Select-Object VMId | Get-VHD
if ( $MasterDiskSize.Size -lt 100GB ) {
    $errMsg = "KubeVirt needs minimal 100GB disk size, you have a Small K8s Setup with less disk size!`n" `
        + "Please increase disk size for the VM $global:VMName (shutdown, increase disk size to 100GB by expanding vhdx, start)`n" `
        + "or install from scratch with k2s install --master-cpus 8 --master-memory 12GB --master-disk 120GB`n"`
        + 'Disk size for master vm too low'
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $errMsg }
        return
    }

    Write-Log $errMsg -Error
    exit 1
}

# restart KubeMaster
Write-Log "Stopping VM $global:VMName"
Stop-VM -Name $global:VMName -Force -WarningAction SilentlyContinue
$state = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
while (!$state) {
    Write-Log 'Still waiting for stop...'
    Start-Sleep -s 1
}
Set-VMProcessor -VMName $global:VMName -ExposeVirtualizationExtensions $true
Write-Log "Start VM $global:VMName"
Start-VM -Name $global:VMName
# for the next steps we need ssh access, so let's wait for ssh
Wait-ForSSHConnectionToLinuxVMViaSshKey

# missing
Install-DebianPackages -addon 'kubevirt' -packages 'fuse3'

# enable virtualization in VM
Write-Log 'enable virtualization in the VM'
# https://wiki.debian.org/KVM
# for debian 11: sudo apt-get install --no-install-recommends qemu-system libvirt-clients libvirt-daemon-system
Install-DebianPackages -addon 'kubevirt' -packages 'qemu-system', 'libvirt-clients', 'libvirt-daemon-system'

# disable app armor
ExecCmdMaster 'sudo systemctl stop apparmor 2>&1'
ExecCmdMaster 'sudo systemctl disable apparmor 2>&1'
ExecCmdMaster 'sudo apt remove --assume-yes --purge apparmor 2>&1'

# check state of virtualization
ExecCmdMaster 'sudo virt-host-validate qemu'

# add kernel parameter to use cgroup v1 (will be only valid after restart of VM)
Write-Log 'change to cgroup v1'
ExecCmdMaster "sudo sed -i 's,systemd.unified_cgroup_hierarchy=0\ ,,g' /etc/default/grub"
ExecCmdMaster "sudo sed -i 's,console=tty0,systemd.unified_cgroup_hierarchy=0\ console=tty0,g' /etc/default/grub"
ExecCmdMaster 'sudo update-grub 2>&1'

# wait for API server
Wait-ForAPIServer

Write-Log "Use of software virtualization: $UseSoftwareVirtualization"

# use software virtualization
if ( $UseSoftwareVirtualization ) {
    Write-Log 'enable the software virtualization'
    &$global:KubectlExe create namespace kubevirt | Write-Log
    # enable feature
    &$global:KubectlExe create configmap kubevirt-config -n kubevirt --from-literal=feature-gates=HostDisk --from-literal=debug.useEmulation=true | Write-Log
}

# deploy kubevirt
$VERSION_KV = 'v0.59.2'
Write-Log "deploy kubevirt version $VERSION_KV"
# &$global:KubectlExe apply -f https://github.com/kubevirt/kubevirt/releases/download/$VERSION_KV/kubevirt-operator.yaml
# &$global:KubectlExe apply -f https://github.com/kubevirt/kubevirt/releases/download/$VERSION_KV/kubevirt-cr.yaml
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\kubevirt\kubevirt-operator.yaml" | Write-Log
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\kubevirt\kubevirt-cr.yaml" | Write-Log

# deploy virtctrl
$VERSION_VCTRL = 'v0.59.2'
$IMPLICITPROXY = 'http://' + $global:IP_NextHop + ':8181'
Write-Log "deploy virtctl version $VERSION_VCTRL"
if ( $K8sSetup -eq 'SmallSetup' ) {
    ExecCmdMaster "export VERSION_VCTRL=$VERSION_VCTRL"
    ExecCmdMaster "export IMPLICITPROXY=$IMPLICITPROXY"
    # NOTE: DO NOT USE `ExecCmdMaster` here to get the return value.
    ssh.exe -n -o StrictHostKeyChecking=no -i $global:LinuxVMKey $global:Remote_Master '[ -f /usr/local/bin/virtctl ]'
    if (!$?) {
        $setupInfo = Get-SetupInfo
        if ($setupInfo.Name -ne $global:SetupType_MultiVMK8s) {
            ExecCmdMaster "sudo curl --retry 3 --retry-connrefused --proxy $IMPLICITPROXY -sL -o /usr/local/bin/virtctl https://github.com/kubevirt/kubevirt/releases/download/$VERSION_VCTRL/virtctl-$VERSION_VCTRL-linux-amd64 2>&1"
        }
        else {
            ExecCmdMaster "sudo curl --retry 3 --retry-connrefused -sL -o /usr/local/bin/virtctl https://github.com/kubevirt/kubevirt/releases/download/$VERSION_VCTRL/virtctl-$VERSION_VCTRL-linux-amd64 2>&1"
        }
    }
    ExecCmdMaster 'sudo chmod +x /usr/local/bin/virtctl'
}
if (!(Test-Path "$global:KubernetesPath\bin\virtctl.exe")) {
    DownloadFile "$global:KubernetesPath\bin\virtctl.exe" https://github.com/kubevirt/kubevirt/releases/download/$VERSION_VCTRL/virtctl-$VERSION_VCTRL-windows-amd64.exe $true -ProxyToUse $Proxy
}

$hostname = Get-ControlPlaneNodeHostname
# enable config
&$global:KubectlExe wait --timeout=180s --for=condition=Ready -n kube-system "pod/kube-apiserver-$hostname" | Write-Log
&$global:KubectlExe wait --timeout=30s --for=condition=Available -n kubevirt deployment/virt-operator | Write-Log
&$global:KubectlExe apply -f "$global:KubernetesPath\addons\kubevirt\kubevirt-cr.yaml" | Write-Log

# for small setup restart VM
if ( $K8sSetup -eq 'SmallSetup' ) {
    # restart KubeMaster
    Write-Log "Stopping VM $global:VMName"
    Stop-VM -Name $global:VMName -Force -WarningAction SilentlyContinue
    $state = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    while (!$state) {
        Write-Log 'Still waiting for stop...'
        Start-Sleep -s 1
        $state = (Get-VM -Name $global:VMName).State -eq [Microsoft.HyperV.PowerShell.VMState]::Off
    }
    Write-Log "Start VM $global:VMName"
    Start-VM -Name $global:VMName
    # wait for API server
    Wait-ForAPIServer
}

# install virt viewer
$virtviewer = 'virt-viewer-x64-11.0-1.0.msi';
if (!(Test-Path "$global:KubernetesPath\bin\$virtviewer")) {
    Write-Log 'Installing VirtViewer ...'
    if (!(Test-Path "$global:KubernetesPath\bin\$virtviewer")) {
        DownloadFile "$global:KubernetesPath\bin\$virtviewer" "https://releases.pagure.org/virt-viewer/$virtviewer" $true -ProxyToUse $Proxy
    }
    msiexec.exe /i "$global:KubernetesPath\bin\$virtviewer" /L*VX "$global:KubernetesPath\bin\msiinstall.log" /quiet /passive /norestart

    # add to environment variable
    $pathAdditions = 'C:\Program Files\VirtViewer v11.0-256\bin'
    Update-SystemPath -Action 'add' "$pathAdditions"

    Write-Log 'VirtViewer installed !'
}

# wait for kubevirt components to be running
Write-Log 'wait for kubevirt components to be running ...'
&$global:KubectlExe wait --timeout=180s --for=condition=Ready -n kube-system "pod/kube-apiserver-$hostname" | Write-Log
&$global:KubectlExe wait --timeout=180s --for=condition=Available -n kubevirt kv/kubevirt | Write-Log

# label master node with kubevirt label
if ( $K8sSetup -eq 'SmallSetup' ) {
    &$global:KubectlExe label node $hostname kubevirt=true --overwrite | Write-Log
}

Write-Log 'kubevirt components are running !'

Write-RefreshEnvVariables

Add-AddonToSetupJson -Addon ([pscustomobject] @{Name = 'kubevirt' })

if ($EncodeStructuredOutput -eq $true) {
    Send-ToCli -MessageType $MessageType -Message @{Error = $null }
}