# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [string] $VmName = $(throw 'Argument missing: VmName'),
    [string] $UserName = $(throw 'Argument missing: UserName'),
    [string] $FormerIpAddress = $(throw 'Argument missing: FormerIpAddress'),
    [string] $ClusterIpAddress = $(throw 'Argument missing: ClusterIpAddress'),
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing uninstall header display')]
    [switch] $SkipHeaderDisplay = $false
)

$preparationStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

$ipAddressToUse = $ClusterIpAddress

# check if the VM is already part of the cluster
$k8sFormattedNodeName = $NodeName.ToLower()
$clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
if ($clusterState -notmatch $k8sFormattedNodeName) {
    Write-Log "The node '$k8sFormattedNodeName' is not part of the cluster."
}

$connectionCheck1 = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'which ls' -UserName $UserName -IpAddress $ipAddressToUse)
if (!$connectionCheck1.Success) {
    Write-Log "Cannot access the VM using the cluster IP address '$ipAddressToUse'."
    $ipAddressToUse = $FormerIpAddress
    Write-Log "Will try to perform an uninstallation using the previous assigned IP address '$FormerIpAddress'."
    $connectionCheck2 = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'which ls' -UserName $UserName -IpAddress $ipAddressToUse)
    if (!$connectionCheck2.Success) {
        throw "Cannot connect to the VM neither IP address '$ClusterIpAddress' nor '$FormerIpAddress'."
    }
}

$k8sFormattedNodeName = $NodeName.ToLower()
$actualHostname = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'echo $(hostname)' -UserName $UserName -IpAddress $ipAddressToUse).Output
if ($k8sFormattedNodeName -ne $actualHostname.ToLower()) {
    throw "The passed NodeName '$NodeName' is not the name of the node with IP '$ipAddressToUse' ($actualHostname)"
}

Write-Log 'Stop the worker node'
& "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay:$SkipHeaderDisplay -NodeName $NodeName

$workerNodeParams = @{
    VmName = $VmName
    NodeName = $NodeName
    UserName = $UserName
    IpAddress = $ipAddressToUse
    SkipHeaderDisplay = $SkipHeaderDisplay
    AdditionalHooksDir = $AdditionalHooksDir
}
Remove-LinuxWorkerNodeOnExistingUbuntuVM @workerNodeParams

Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log

Write-Log '---------------------------------------------------------------'
Write-Log "Linux Hyper-V VM with IP '$ipAddressToUse' and hostname '$NodeName' removed from the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $preparationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

