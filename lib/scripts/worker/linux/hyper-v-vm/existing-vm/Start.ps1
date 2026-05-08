# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator


Param(
    [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
    [string] $NodeName = $(throw 'Argument missing: NodeName'),
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Directory containing additional hooks to be executed after local hooks are executed')]
    [string] $AdditionalHooksDir = '',
    [parameter(Mandatory = $false, HelpMessage = 'Skips showing start header display')]
    [switch] $SkipHeaderDisplay = $false,
    [parameter(Mandatory = $false, HelpMessage = 'Indicates this is a single node start operation')]
    [switch] $SingleNode = $false,
    [switch] $ObtainCIDR = $false
)

$infraModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.infra.module\k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.node.module\k2s.node.module.psm1"
$clusterModule = "$PSScriptRoot\..\..\..\..\..\modules\k2s\k2s.cluster.module\k2s.cluster.module.psm1"
$addonsModule = "$PSScriptRoot\..\..\..\..\..\..\addons\addons.module.psm1"
Import-Module $infraModule, $nodeModule, $clusterModule, $addonsModule

Initialize-Logging -ShowLogs:$ShowLogs
$kubePath = Get-KubePath

# make sure we are at the right place for executing this script
Set-Location $kubePath

$ProgressPreference = 'SilentlyContinue'

$workerNodeName = $NodeName.ToLower()

$workerNodeStartParams = @{
    AdditionalHooksDir = $AdditionalHooksDir
    SkipHeaderDisplay = $SkipHeaderDisplay
    IpAddress = $IpAddress
    NodeName = $workerNodeName
    ObtainCIDR = $ObtainCIDR
}
Start-LinuxWorkerNode @workerNodeStartParams


<#
.SYNOPSIS
Starts kubelet and container runtime services on a Linux worker node.

.DESCRIPTION
Connects to a remote Linux worker node via SSH and starts crio/containerd and kubelet services.
This is used when starting individual nodes (via --node flag) to ensure they transition back to Ready.

.PARAMETER NodeName
The name of the worker node.

.PARAMETER IpAddress
The IP address of the worker node.

.PARAMETER UserName
The SSH username for the remote connection.

.PARAMETER LogPrefix
Prefix for log messages (e.g., '[LocalVM]', '[BareMetal]').
#>
function Start-LinuxWorkerNodeServices {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [string] $IpAddress = $(throw 'Argument missing: IpAddress'),
        [string] $UserName = $(throw 'Argument missing: UserName'),
        [switch] $WaitForReady = $false,
        [string] $LogPrefix = '[Worker]'
    )

    $workerNodeName = $NodeName.ToLower()

    $sshProbeToken = 'k2s-ssh-ok'
    $sshProbeCmd = "echo $sshProbeToken"
    $startServicesCmd = 'sudo systemctl start crio || true; sudo systemctl start containerd || true; sudo systemctl start kubelet'
    $maxSshRetries = 12
    $retryDelaySeconds = 5
    $sshProbeTimeoutSeconds = 5
    $startServicesTimeoutSeconds = 60
    $sshProbeResult = $null
    $sshProbeSucceeded = $false
    $startServicesResult = $null
    $waitingLogged = $false

    for ($attempt = 1; $attempt -le $maxSshRetries; $attempt++) {
        $sshProbeResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $sshProbeCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$true -ExecutionTimeoutSeconds $sshProbeTimeoutSeconds
        $sshProbeOutput = if ($sshProbeResult.Output -is [array]) { $sshProbeResult.Output -join "`n" } else { [string]$sshProbeResult.Output }
        $sshProbeSucceeded = $sshProbeResult.Success -or ($sshProbeOutput -match [regex]::Escape($sshProbeToken))

        if ($sshProbeSucceeded) {
            if (-not $sshProbeResult.Success) {
                Write-Log "$LogPrefix SSH probe token received from '$workerNodeName' despite non-zero ssh exit code; continuing."
            }
            break
        }

        if ($attempt -lt $maxSshRetries) {
            if (-not $waitingLogged) {
                Write-Log "$LogPrefix Waiting for SSH connection to node '$workerNodeName'..." -Console
                $waitingLogged = $true
            }
            Start-Sleep -Seconds $retryDelaySeconds
        }
    }

    if (-not $sshProbeSucceeded) {
        Write-Log "$LogPrefix Failed to establish SSH connection to '$workerNodeName' after retries: $($sshProbeResult.Output)"

        try {
            $tcpCheck = Test-NetConnection -ComputerName $IpAddress -Port 22 -WarningAction SilentlyContinue
            Write-Log "$LogPrefix Connectivity check for '$IpAddress': Ping=$($tcpCheck.PingSucceeded), Tcp22=$($tcpCheck.TcpTestSucceeded)"

            $matchingVmAdapters = @(Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue | Where-Object {
                @($_.IPAddresses) -contains $IpAddress
            })

            if ($matchingVmAdapters.Count -eq 0) {
                Write-Log "$LogPrefix No Hyper-V VM adapter currently reports guest IP '$IpAddress'. The VM may have lost this IP (check 'ip address' / netplan inside the Linux VM)." -Console
            } else {
                $switches = ($matchingVmAdapters | Select-Object -ExpandProperty SwitchName -Unique) -join ', '
                Write-Log "$LogPrefix Hyper-V adapter for '$IpAddress' is attached to switch(es): $switches"
            }

            $staleNodeAdapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like 'vEthernet (k2s-node-*'
            })
            if ($staleNodeAdapters.Count -gt 3) {
                Write-Log "$LogPrefix Detected $($staleNodeAdapters.Count) 'vEthernet (k2s-node-*)' adapters on host. This can interfere with local VM reachability after full stop/start."
            }
        } catch {
            Write-Log "$LogPrefix Failed to collect SSH failure diagnostics: $($_.Exception.Message)"
        }

        return
    }

    $startServicesResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $startServicesCmd -UserName $UserName -IpAddress $IpAddress -IgnoreErrors:$true -ExecutionTimeoutSeconds $startServicesTimeoutSeconds
    
    if ($startServicesResult.Success) {
        Write-Log "$LogPrefix Started kubelet/runtime services on '$workerNodeName'"

        if ($WaitForReady) {
            Write-Log "$LogPrefix Waiting for node '$workerNodeName' to transition to Ready (max ~60 seconds)..." -Console
            $maxRetries = 30
            $retryCount = 0
            while ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 2
                $nodeStatusOutput = (Invoke-Kubectl -Params @('get', 'node', $workerNodeName, '--no-headers')).Output | Out-String
                $nodeStatus = $nodeStatusOutput.Trim()
                if (-not [string]::IsNullOrWhiteSpace($nodeStatus) -and $nodeStatus -match '\s+Ready(?:\s|,)') {
                    Write-Log "$LogPrefix Node '$workerNodeName' is now Ready" -Console
                    return
                }
                $retryCount++
            }
            Write-Log "$LogPrefix Timeout waiting for node to become Ready" -Console
        }
    } else {
        Write-Log "$LogPrefix Failed to start kubelet/runtime services on '$workerNodeName': $($startServicesResult.Output)"
    }
}

<#
.SYNOPSIS
Resolves node SSH credentials from cluster config and starts kubelet/runtime services.

.DESCRIPTION
Looks up the node's IpAddress and Username from the cluster config, then calls
Start-LinuxWorkerNodeServices. Logs a warning if the config entry is incomplete.
Used by both bare-metal and local-vm Start.ps1 scripts when --node is specified.

.PARAMETER NodeName
The name of the worker node (as registered in the cluster config).

.PARAMETER LogPrefix
Prefix for log messages (e.g., '[LocalVM]', '[BareMetal]').
#>
function Invoke-LinuxWorkerNodeStart {
    Param(
        [string] $NodeName = $(throw 'Argument missing: NodeName'),
        [switch] $WaitForReady = $false,
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
        Start-LinuxWorkerNodeServices -NodeName $workerNodeName -IpAddress $nodeConfig.IpAddress -UserName $nodeUserName -WaitForReady:$WaitForReady -LogPrefix $LogPrefix
    } else {
        Write-Log "$LogPrefix Cannot start kubelet/runtime on node '$workerNodeName' because Username/IpAddress is missing in cluster config."
    }
}

# Restore kubelet/runtime services after route setup and wait for the node to become Ready.
Invoke-LinuxWorkerNodeStart -NodeName $workerNodeName -WaitForReady -LogPrefix '[hyper-v existing-vm]'