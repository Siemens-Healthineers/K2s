# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

Param(
    [parameter(Mandatory = $false, HelpMessage = 'Show all logs in terminal')]
    [switch] $ShowLogs = $false,

    [parameter(Mandatory = $false, HelpMessage = 'If set to true, will encode and send result as structured data to the CLI.')]
    [switch] $EncodeStructuredOutput,

    [parameter(Mandatory = $false, HelpMessage = 'Message type of the encoded structure; applies only if EncodeStructuredOutput was set to $true')]
    [string] $MessageType
)

$infraModule = "$PSScriptRoot/../../../../modules/k2s/k2s.infra.module/k2s.infra.module.psm1"
$nodeModule = "$PSScriptRoot/../../../../modules/k2s/k2s.node.module/k2s.node.module.psm1"

Import-Module $infraModule, $nodeModule
Initialize-Logging

$logUseCase = 'Start-System'

function Wait-NetInterfaceAdapterUp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AdapterName,
        [int]$TimeoutSeconds = 60,
        [int]$DelaySeconds = 2
    )

    $endTime = [DateTime]::Now.AddSeconds($TimeoutSeconds)
    $adapterStatus = ''

    Write-Log "[$logUseCase] Waiting for network adapter '$AdapterName' to come up..."

    while ([DateTime]::Now -lt $endTime) {
        try {
            $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
            $adapterStatus = $adapter.Status
            if ($adapterStatus -eq 'Up') {
                Write-Log "[$logUseCase] Network adapter '$AdapterName' is up."
                $if = Get-NetIPInterface -InterfaceAlias $AdapterName -ErrorAction SilentlyContinue
                if ( $if ) {
                    Write-Log "[$logUseCase] Network adapter '$AdapterName' is up and interfaces are available: $if"
                    return $true
                }
                else {
                    Write-Log "[$logUseCase] Could not get IP interface for adapter '$AdapterName'. Retrying..."
                }
            }
        }
        catch {
            Write-Log "[$logUseCase] Could not get status for adapter '$AdapterName'. Retrying..."
        }

        Write-Log "[$logUseCase] Adapter status is '$adapterStatus'. Waiting $DelaySeconds seconds..."
        Start-Sleep -Seconds $DelaySeconds
    }

    Write-Log "Timeout reached. Network adapter '$AdapterName' did not come up within $TimeoutSeconds seconds. Current status: '$adapterStatus'"
    return $false
}

function Select-K2sIsRunning {
    $processName = 'k2s.exe'
    $requiredArgs = @('install', 'start') # Create an array of required arguments

    # Get the process information using Get-CimInstance (recommended over Get-WmiObject for modern PowerShell)
    # This allows access to the CommandLine property.
    $k2sProcess = Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq $processName
    }

    if ($k2sProcess) {
        Write-Log "[$logUseCase] Process '$processName' is running."

        $found = $false
        foreach ($process in $k2sProcess) {
            $commandLine = $process.CommandLine

            # Check if the command line contains any of the required arguments
            # We use -clike for case-insensitive contains, and wildcard for flexibility
            if ($requiredArgs | ForEach-Object { $commandLine -clike "*$_*" }) {
                $found = $true
                break # Exit the loop once a matching argument is found for this process
            }
        }

        if ($found) {
            Write-Log "[$logUseCase] K2s is OK with the right parameters."
            return $true
        }
        else {
            Write-Log "[$logUseCase] K2s is not doing an install or start."
            return $false
        }
    }
    else {
        Write-Log "[$logUseCase] Process '$processName' is NOT running."
        return $false
    }
}

try {
    Write-Log "[$logUseCase] started"
    # check if k2s is running
    $k2sRunning = Select-K2sIsRunning
    if ($k2sRunning) {
        Write-Log "[$logUseCase] k2s is running, no need todo anything"
        Write-Log "[$logUseCase] finished"
        return
    }
    # check if there is an HNS network with l2 bridge
    $l2BridgeSwitchName = Get-L2BridgeSwitchName
    $found = Invoke-HNSCommand -Command { 
        param($l2BridgeSwitchName)
        Get-HNSNetwork | Where-Object Name -Like $l2BridgeSwitchName 
    } -ArgumentList $l2BridgeSwitchName
    if ($found) {
        Write-Log "[$logUseCase] External switch with l2 bridge network already exists"
    }
    else {
        Write-Log "[$logUseCase] Switch cbr0 with l2 bridge network does not exist, check for Loopback Adapter"
        # need to start the services to see the NIC
        Start-Service -Name 'vmcompute'
        Start-Service -Name 'hns'
        $hns = Get-HNSNetwork
        $hnsNames = $hns | Select-Object -ExpandProperty Name
        $logText = "[$logUseCase] HNS networks available: " + $hnsNames
        Write-Log $logText
        $adapterName = Get-L2BridgeName
        $nic = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
        if ( $null -eq $nic ) {
            Write-Log "[$logUseCase] Loopback Adapter is not there, must be during install"
        }
        else {
            if ( $nic.Status -eq 'Disabled' ) {
                # Adapter is disabled, must be after a stop
                Write-Log "[$logUseCase] Loopback Adapter is disabled, must be a normal startup"
            }
            else {
                # Adapter is enabled, must be after a reboot where no stop was done before
                Write-Log "[$logUseCase] Loopback Adapter is not disabled, must be a start of windows after no stop was done"
                $adapterName = Get-L2BridgeName
                $PodSubnetworkNumber = '1'
                
                # Stop flanneld and wait for it to fully stop to prevent race condition with L2 bridge
                Write-Log "[$logUseCase] Stopping flanneld service..."
                Stop-Service -Name 'flanneld' -Force -ErrorAction SilentlyContinue
                $stopped = Wait-ForServiceStopped -ServiceName 'flanneld' -MaxRetries 10 -SleepSeconds 1
                if (-not $stopped) {
                    Write-Log "[$logUseCase] WARNING: flanneld service did not stop cleanly, continuing anyway"
                }
                
                # Additional delay to ensure flanneld releases all L2 bridge resources
                Start-Sleep -Seconds 2
                
                Enable-NetAdapter -Name $adapterName -Confirm:$false -ErrorAction SilentlyContinue
                $return = Wait-NetInterfaceAdapterUp -AdapterName $adapterName
                if ($return -eq $true) {
                    $DnsServers = Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost -ExcludeNetworkInterfaceName $adapterName
                    Enable-LoopbackAdapter
                    Write-Log "[$logUseCase] Remove and recreate external switch"
                    Remove-ExternalSwitch
                    New-ExternalSwitch -adapterName $adapterName -PodSubnetworkNumber $PodSubnetworkNumber
                    Set-LoopbackAdapterExtendedProperties -AdapterName $adapterName -DnsServers $DnsServers
                    Write-Log "[$logUseCase] External switch recreated successfully, restart flanneld service"
                    Confirm-LoopbackAdapterIP
                    Start-Service -Name 'flanneld' -ErrorAction SilentlyContinue
                    Write-Log "[$logUseCase] Waiting for k8s L2 bridge network to be ready"
                    Wait-NetworkL2BridgeReady -PodSubnetworkNumber $PodSubnetworkNumber
                    Write-Log "[$logUseCase] L2 bridge network is ready, attempt to repair kubeswitch"
                    Repair-KubeSwitch
                    # Set-PrivateNetworkProfileForLoopbackAdapter
                }
                else {
                    Write-Log "[$logUseCase] ERROR: Could not repair k8s network !"
                    Disable-NetAdapter -Name $adapterName -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
        }
    }
    Write-Log "[$logUseCase] finished"
    if ($EncodeStructuredOutput -eq $true) {
        Send-ToCli -MessageType $MessageType -Message @{Error = $null }
    }
}
catch {
    Confirm-LoopbackAdapterIP
    Start-Service -Name 'flanneld' -ErrorAction SilentlyContinue
    Write-Log "[$logUseCase] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}