# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [string] $UserName = $(throw 'Argument missing: UserName'),
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [string] $NodeName,
    [string] $WindowsHostIpAddress = '',
    [string] $Proxy = '',
    [switch] $ShowLogs = $false
)

$durationStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

Write-Log "Performing pre-requisites check" -Console

$connectionCheck = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'which ls' -UserName $UserName -IpAddress $IpAddress)
if (!$connectionCheck.Success) {
    throw "Cannot connect to node with IP '$IpAddress'. Error message: $($connectionCheck.Output)"
}

# check if the authorized public key in the computer is the same as the one in the Windows Host
$localPublicKeyFilePath = "$(Get-SSHKeyControlPlane).pub"
if (!(Test-Path -Path $localPublicKeyFilePath)) {
    throw "Precondition not met: the file '$localPublicKeyFilePath' shall exist."
}
$localPublicKey = (Get-Content -Raw $localPublicKeyFilePath).Trim()
if ([string]::IsNullOrWhiteSpace($localPublicKey)) {
    throw "Precondition not met: the file '$localPublicKeyFilePath' is not empty."
}
$authorizedKeysFilePath = '~/.ssh/authorized_keys'
$authorizedKeys = (Invoke-CmdOnVmViaSSHKey -CmdToExecute "[ -f $authorizedKeysFilePath ] && cat $authorizedKeysFilePath || echo 'File $authorizedKeysFilePath not available'" -UserName $UserName -IpAddress $IpAddress).Output
if (!($authorizedKeys.Contains($localPublicKey))) {
    throw "Precondition not met: the local public key from the file '$localPublicKeyFilePath' is present in the file '$authorizedKeysFilePath' of the computer with IP '$IpAddress'."
}

$actualHostname = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'echo $(hostname)' -UserName $UserName -IpAddress $IpAddress).Output

$k8sFormattedNodeName = $actualHostname.ToLower()

# check if the intended node name to add to the cluster is the same as the hostname of the computer behind the passed IP address
if (![string]::IsNullOrWhiteSpace($NodeName) -and ($NodeName.ToLower() -ne $k8sFormattedNodeName)) {
    throw "Precondition not met: the passed NodeName '$NodeName' is the hostname of the computer with IP '$IpAddress' ($actualHostname)"
}

# check if the computer is already part of the cluster
$clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
if ($clusterState -match $k8sFormattedNodeName) {
    throw "Precondition not met: the node '$k8sFormattedNodeName' is already part of the cluster."
}

Write-Log "Adding node with hostname '$k8sFormattedNodeName'"

Write-Log "Disable swap"
(Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapon --show' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
(Invoke-CmdOnVmViaSSHKey -CmdToExecute "swapFiles=`$(cat /proc/swaps | awk 'NR>1 {print `$1}')" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
(Invoke-CmdOnVmViaSSHKey -CmdToExecute 'sudo swapoff -a' -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
(Invoke-CmdOnVmViaSSHKey -CmdToExecute "for swapFile in `$swapFiles; do sudo rm '`$swapFile'; done" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log
(Invoke-CmdOnVmViaSSHKey -CmdToExecute "sudo sed -i '/\sswap\s/d' /etc/fstab" -UserName $UserName -IpAddress $IpAddress).Output | Write-Log

if ($WindowsHostIpAddress -eq '') {
    $loopbackAdapter = Get-L2BridgeName
    $WindowsHostIpAddress = Get-HostPhysicalIp -ExcludeNetworkInterfaceName $loopbackAdapter
}
Write-Log "Windows Host IP address: $WindowsHostIpAddress"

# If configuration is present, retrieve proxy
if ($Proxy -eq '') {
    $proxyConfig = Get-ProxyConfig
    $Proxy = $proxyConfig.HttpProxy
}

$workerNodeParams = @{
    NodeName = $actualHostname
    UserName = $UserName
    IpAddress = $IpAddress
    WindowsHostIpAddress = $WindowsHostIpAddress
    Proxy = $Proxy
    AdditionalHooksDir = $AdditionalHooksDir
}
Add-LinuxWorkerNodeOnUbuntuBareMetal @workerNodeParams

if (! $SkipStart) {
    Write-Log 'Starting worker node' -Console
    & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $IpAddress -NodeName $NodeName

    if ($RestartAfterInstallCount -gt 0) {
        $restartCount = 0;

        while ($true) {
            $restartCount++
            Write-Log "Restarting worker (iteration #$restartCount):"

            & "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -NodeName $NodeName
            Start-Sleep 10

            & "$PSScriptRoot\Start.ps1" -AdditionalHooksDir:$AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay -IpAddress $IpAddress -NodeName $NodeName
            Start-Sleep -s 5

            if ($restartCount -eq $RestartAfterInstallCount) {
                Write-Log 'Restarting worker node completed'
                break;
            }
        }
    }
}

Write-Log "Current state of cluster nodes:" -Console
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log -Console

Write-Log '---------------------------------------------------------------'
Write-Log "Linux computer with IP '$IpAddress' and hostname '$NodeName' added to the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $durationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

