# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [string] $VmName = $(throw 'Argument missing: VmName'),
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [string] $UserName = $(throw 'Argument missing: UserName'),
    [string] $CurrentIpAddress = $(throw 'Argument missing: CurrentIpAddress'),
    [string] $ClusterIpAddress = $(throw 'Argument missing: ClusterIpAddress'),
    [parameter(Mandatory = $false, HelpMessage = 'HTTP proxy if available')]
    [string] $Proxy,
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false
)

$durationStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

# check if the VM is already part of the cluster
$k8sFormattedNodeName = $NodeName.ToLower()
$clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
if ($clusterState -match $k8sFormattedNodeName) {
    throw "Precondition not met: the node '$k8sFormattedNodeName' is not part of the cluster."
}

$vm = Get-VM | Where-Object Name -eq $VmName
if ($null -eq $vm) {
    throw "Precondition not met: the VM $VmName shall exist."
}
if ($vm.State -ne [Microsoft.HyperV.PowerShell.VMState]::Running) {
    throw "Precondition not met: the VM $VmName has the state 'Running'."
}

$connectionCheck = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'which ls' -UserName $UserName -IpAddress $CurrentIpAddress)
if (!$connectionCheck.Success) {
    throw "Cannot connect to node with IP '$CurrentIpAddress'. Error message: $($connectionCheck.Output)"
}

# check if the authorized public key in the VM is the same as the one in the Windows Host
$localPublicKeyFilePath = "$(Get-SSHKeyControlPlane).pub"
if (!(Test-Path -Path $localPublicKeyFilePath)) {
    throw "Precondition not met: the file '$localPublicKeyFilePath' shall exist."
}
$localPublicKey = (Get-Content -Raw $localPublicKeyFilePath).Trim()
if ([string]::IsNullOrWhiteSpace($localPublicKey)) {
    throw "Precondition not met: the file '$localPublicKeyFilePath' is not empty."
}
$authorizedKeysFilePath = '~/.ssh/authorized_keys'
$authorizedKeys = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "[ -f $authorizedKeysFilePath ] && cat $authorizedKeysFilePath || echo 'File $authorizedKeysFilePath not available'" -UserName $UserName -IpAddress $CurrentIpAddress).Output
if (!($authorizedKeys.Contains($localPublicKey))) {
    throw "Precondition not met: the local public key from the file '$localPublicKeyFilePath' is present in the file '$authorizedKeysFilePath' of the computer with IP '$CurrentIpAddress'."
}

# check if the VM OS is one of the supported ones
$installedOSCmd = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'lsb_release -a' -UserName $UserName -IpAddress $CurrentIpAddress)
if (!$installedOSCmd.Success) {
    throw "Precondition not met: the computer to add to the cluster has Linux OS."
} else {
    $installedOS = $installedOSCmd.Output
    Write-Host $installedOS
    if (!($installedOS -like '*Ubuntu 24.04*')) {
        throw "Precondition not met: the installed Linux OS is Ubuntu 24.04."
    }
}

# check if the intended node name to add to the cluster is the same as the hostname of the VM behind the passed IP address
$actualHostname = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'echo $(hostname)' -UserName $UserName -IpAddress $CurrentIpAddress).Output
if ($k8sFormattedNodeName -ne $actualHostname.ToLower()) {
    throw "Precondition not met: the passed NodeName '$NodeName' is the hostname of the computer with IP '$CurrentIpAddress' ($actualHostname)"
}

Write-Log "Disable swap"
(Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapon --show' -UserName $UserName -IpAddress $CurrentIpAddress).Output | Write-Log
(Invoke-CmdOnVmViaSSHKey -CmdToExecute "swapFiles=`$(cat /proc/swaps | awk 'NR>1 {print `$1}')" -UserName $UserName -IpAddress $CurrentIpAddress).Output | Write-Log
(Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapoff -a' -UserName $UserName -IpAddress $CurrentIpAddress).Output | Write-Log
(Invoke-CmdOnVmViaSSHKey -CmdToExecute "for swapFile in `$swapFiles; do sudo rm '`$swapFile'; done" -UserName $UserName -IpAddress $CurrentIpAddress).Output | Write-Log
(Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo sed -i '/\sswap\s/d' /etc/fstab" -UserName $UserName -IpAddress $CurrentIpAddress).Output | Write-Log

$workerNodeParams = @{
    VmName = $VmName
    NodeName = $NodeName
    UserName = $UserName
    IpAddress = $CurrentIpAddress
    Proxy = $Proxy
    ClusterIpAddress = $ClusterIpAddress
    AdditionalHooksDir = $AdditionalHooksDir
}
Add-LinuxWorkerNodeOnExistingUbuntuVM @workerNodeParams

if (! $SkipStart) {
    Write-Log 'Starting worker node'
    & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $ClusterIpAddress -NodeName $NodeName

    if ($RestartAfterInstallCount -gt 0) {
        $restartCount = 0;
    
        while ($true) {
            $restartCount++
            Write-Log "Restarting worker (iteration #$restartCount):"
    
            & "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -NodeName $NodeName
            Start-Sleep 10
    
            & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $ClusterIpAddress -NodeName $NodeName
            Start-Sleep -s 5
    
            if ($restartCount -eq $RestartAfterInstallCount) {
                Write-Log 'Restarting worker node completed'
                break;
            }
        }
    }
} 

Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log

Write-Log '---------------------------------------------------------------'
Write-Log "Linux Hyper-V VM with IP '$CurrentIpAddress' (Cluster IP address: '$ClusterIpAddress') and hostname '$NodeName' added to the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $durationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

