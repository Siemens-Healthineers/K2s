# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing stop header display')]
    [switch] $SkipHeaderDisplay = $false,
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [parameter(Mandatory = $false, HelpMessage = 'Indicates this is a single node stop operation')]
    [switch] $SingleNode = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Wait for node to become not ready')]
    [switch] $WaitForNotReady = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule

Initialize-Logging -ShowLogs:$ShowLogs

# make sure we are at the right place for executing this script
$kubePath = Get-KubePath
Set-Location $kubePath

$ProgressPreference = 'SilentlyContinue'

$workerNodeName = $NodeName.ToLower()

$workerNodeStopParams = @{
    AdditionalHooksDir = $AdditionalHooksDir
    SkipHeaderDisplay  = $SkipHeaderDisplay
    NodeName           = $workerNodeName 
}

Stop-LinuxWorkerNode @workerNodeStopParams

<#
.SYNOPSIS
Stops kubelet and container runtime services on a Linux worker node and optionally waits for node to transition to NotReady.

.DESCRIPTION
Connects to a remote Linux worker node via SSH and stops kubelet, crio, and containerd services.
If -WaitForNotReady is specified, polls the node status until it transitions to NotReady state or timeout occurs.
This is used when stopping individual nodes (via --node flag) to ensure they transition to NotReady.

.PARAMETER NodeName
The name of the worker node.

.PARAMETER IpAddress
The IP address of the worker node.

.PARAMETER UserName
The SSH username for the remote connection.

.PARAMETER WaitForNotReady
If specified, waits for the node to transition to NotReady state (up to 60 seconds).

.PARAMETER LogPrefix
Prefix for log messages (e.g., '[LocalVM]', '[BareMetal]').
#>
function Stop-LinuxWorkerNodeServices {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [switch] $WaitForNotReady = $false,
        [string] $LogPrefix = '[Worker]'
    )

    $workerNodeName = $NodeName.ToLower()

    $stopServicesCmd = 'sudo systemctl stop kubelet; sudo systemctl stop crio || true; sudo systemctl stop containerd || true'
    $stopServicesResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $stopServicesCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$true
    
    if ($stopServicesResult.Success) {
        Write-Log "$LogPrefix Stopped kubelet/runtime services on '$workerNodeName'"
        
        if ($WaitForNotReady) {
            Write-Log "$LogPrefix Waiting for node '$workerNodeName' to transition to NotReady (max ~60 seconds)..." -Console
            # Poll kubectl to wait for node to NOT be Ready. Since kubectl wait doesn't support negative conditions directly,
            # we poll with timeout
            $maxRetries = 30
            $retryCount = 0
            while ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 2
                $nodeStatusOutput = (Invoke-Kubectl -Params @('get', 'node', $workerNodeName, '--no-headers')).Output | Out-String
                $nodeStatus = $nodeStatusOutput.Trim()
                if (-not [string]::IsNullOrWhiteSpace($nodeStatus) -and -not ($nodeStatus -match '\s+Ready\s+')) {
                    Write-Log "$LogPrefix Node '$workerNodeName' is now NotReady" -Console
                    return
                }
                $retryCount++
            }
            Write-Log "$LogPrefix Timeout waiting for node to become NotReady (this may be normal)" -Console
        } else {
            Write-Log "$LogPrefix Node readiness can take up to ~50 seconds to flip from Ready to NotReady." -Console
            Write-Log "$LogPrefix Use stop command with wait option to wait for the state change." -Console
        }
    } else {
        Write-Log "$LogPrefix Failed to stop kubelet/runtime services on '$workerNodeName': $($stopServicesResult.Output)"
    }
}

<#
.SYNOPSIS
Resolves node SSH credentials from cluster config and stops kubelet/runtime services.

.DESCRIPTION
Looks up the node's IpAddress and Username from the cluster config, then calls
Stop-LinuxWorkerNodeServices. Logs a warning if the config entry is incomplete.
Used by both bare-metal and local-vm Stop.ps1 scripts when --node is specified.

.PARAMETER NodeName
The name of the worker node (as registered in the cluster config).

.PARAMETER WaitForNotReady
If specified, waits for the node to transition to NotReady state (up to 60 seconds).

.PARAMETER LogPrefix
Prefix for log messages (e.g., '[LocalVM]', '[BareMetal]').
#>
function Invoke-LinuxWorkerNodeStop {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [switch] $WaitForNotReady = $false,
        [string] $LogPrefix = '[Worker]'
    )

    $workerNodeName = $NodeName.ToLower()
    $nodeConfig = Get-NodeConfig -NodeName $workerNodeName
    $nodeUserName = ''
    if ($null -ne $nodeConfig) {
        $nodeUserName = $nodeConfig.UserName
        if ([string]::IsNullOrWhiteSpace($nodeUserName)) {
            $nodeUserName = $nodeConfig.Username
        }
    }

    if ($null -ne $nodeConfig -and -not [string]::IsNullOrWhiteSpace($nodeUserName) -and -not [string]::IsNullOrWhiteSpace($nodeConfig.IpAddress)) {
        Stop-LinuxWorkerNodeServices -NodeName $workerNodeName -IpAddress $nodeConfig.IpAddress -UserName $nodeUserName -WaitForNotReady:$WaitForNotReady -LogPrefix $LogPrefix
    } else {
        Write-Log "$LogPrefix Cannot stop kubelet/runtime on node '$workerNodeName' because Username/IpAddress is missing in cluster config."
    }
}

# Stop kubelet/runtime so the node transitions to NotReady.
# -WaitForNotReady controls whether to block until the transition completes.
    Invoke-LinuxWorkerNodeStop -NodeName $workerNodeName -WaitForNotReady:$WaitForNotReady -LogPrefix '[hyper-v existing-vm]'

