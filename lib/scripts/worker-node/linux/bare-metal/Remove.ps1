# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [string] $UserName = $(throw 'Argument missing: UserName'),
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [switch] $ShowLogs = $false,
    [string] $AdditionalHooksDir = '',
    [switch] $SkipHeaderDisplay = $false
)

$preparationStopwatch = [system.diagnostics.stopwatch]::StartNew()

$infraModule =   "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule =    "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

$ErrorActionPreference = 'Stop'

# make sure we are at the right place for install
$installationPath = Get-KubePath
Set-Location $installationPath

# check if the computer is already part of the cluster
$k8sFormattedNodeName = $NodeName.ToLower()
$clusterState = (Invoke-Kubectl -Params @('get', 'nodes', '-o', 'wide')).Output
if ($clusterState -notmatch $k8sFormattedNodeName) {
    Write-Log "The node '$k8sFormattedNodeName' is not part of the cluster."
}

$connectionCheck = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'which ls' -UserName $UserName -IpAddress $IpAddress)
if (!$connectionCheck.Success) {
    throw "Cannot connect to the computer with IP address '$IpAddress'."
}

$k8sFormattedNodeName = $NodeName.ToLower()
$actualHostname = (Invoke-CmdOnVmViaSSHKey -CmdToExecute 'echo $(hostname)' -UserName $UserName -IpAddress $IpAddress).Output
if ($k8sFormattedNodeName -ne $actualHostname.ToLower()) {
    throw "The passed NodeName '$NodeName' is not the name of the node with IP '$IpAddress' ($actualHostname)"
}

Write-Log 'Stop the worker node'
& "$PSScriptRoot\Stop.ps1" -AdditionalHooksDir $AdditionalHooksDir -ShowLogs:$ShowLogs -SkipHeaderDisplay:$SkipHeaderDisplay -NodeName $NodeName

$workerNodeParams = @{
    NodeName = $NodeName
    UserName = $UserName
    IpAddress = $IpAddress
    SkipHeaderDisplay = $SkipHeaderDisplay
    AdditionalHooksDir = $AdditionalHooksDir
}
Remove-LinuxWorkerNodeOnUbuntuBareMetal @workerNodeParams

Write-Log "Current state of kubernetes nodes:`n"
Start-Sleep 2
$kubeToolsPath = Get-KubeToolsPath
&"$kubeToolsPath\kubectl.exe" get nodes -o wide 2>&1 | ForEach-Object { "$_" } | Write-Log

Write-Log '---------------------------------------------------------------'
Write-Log "Linux computer with IP '$IpAddress' and hostname '$NodeName' removed from the cluster.   Total duration: $('{0:hh\:mm\:ss}' -f $preparationStopwatch.Elapsed )"
Write-Log '---------------------------------------------------------------'

