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

$logUseCase = "Start-System"

function Wait-NetAdapterUp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$AdapterName,
        [int]$TimeoutSeconds = 60,
        [int]$DelaySeconds = 2
    )

    $endTime = [DateTime]::Now.AddSeconds($TimeoutSeconds)
    $adapterStatus = ""

    Write-Log  "[$logUseCase] Waiting for network adapter '$AdapterName' to come up..."

    while ([DateTime]::Now -lt $endTime) {
        try {
            $adapter = Get-NetAdapter -Name $AdapterName -ErrorAction Stop
            $adapterStatus = $adapter.Status
            if ($adapterStatus -eq "Up") {
                Write-Log  "[$logUseCase] Network adapter '$AdapterName' is up."
                return $true
            }
        }
        catch {
            Write-Log  "[$logUseCase] Could not get status for adapter '$AdapterName'. Retrying..."
        }

        Write-Log  "[$logUseCase] Adapter status is '$adapterStatus'. Waiting $DelaySeconds seconds..."
        Start-Sleep -Seconds $DelaySeconds
    }

    Write-Log  "Timeout reached. Network adapter '$AdapterName' did not come up within $TimeoutSeconds seconds. Current status: '$adapterStatus'"
    return $false
}

try {
    Write-Log "[$logUseCase] started"
    # check if there is an HNS network with l2 bridge
    $l2BridgeSwitchName = Get-L2BridgeSwitchName
    $found = Invoke-HNSCommand -Command { 
        param($l2BridgeSwitchName)
        Get-HNSNetwork | Where-Object Name -Like $l2BridgeSwitchName 
    } -ArgumentList $l2BridgeSwitchName
    if ($found) {
        Write-Log "[$logUseCase] External switch with l2 bridge network already exists"
    } else {
        Write-Log "[$logUseCase] Switch cbr0 with l2 bridge network does not exist, check for Loopback Adapter"
        # need to start the services to see the NIC
        Start-Service -Name 'vmcompute'
        Start-Service -Name 'hns'
        $adapterName = Get-L2BridgeName
        # $PodSubnetworkNumber = '1'
        Write-Log "[$logUseCase] All NICs 1: $((Get-NetAdapter).Name)"
        $nic = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
        if( $nic.Status -eq "Disabled" ) {
            # Adapter is disabled, must be after a stop
            Write-Log "[$logUseCase] Also Loopback Adapter is disabled, must be a normal startup"
            # Wait-NetAdapterUp -AdapterName $adapterName
            # Write-Log "[$logUseCase] All NICs Ips: $((Get-NetIPAddress).InterfaceAlias)"
            # Write-Log "[$logUseCase] All NICs 2: $((Get-NetAdapter).Name)"
        } else {
            # Adapter is enable, must be after a reboot where no stop was done
            Write-Log "[$logUseCase] Also Loopback Adapter is not disabled, must be a start of windows after no stop was done"
            # Write-Log "[$logUseCase] All NICs Ips: $((Get-NetIPAddress).InterfaceAlias)"
            # Write-Log "[$logUseCase] All NICs 2: $((Get-NetAdapter).Name)"
            # $kubePath = Get-KubePath
            # Import-Module "$kubePath\smallsetup\hns.v2.psm1" -WarningAction:SilentlyContinue -Force
            # # enable adapter
            # Enable-NetAdapter -Name $adapterName -Confirm:$false -ErrorAction SilentlyContinue
            # # wait to be ready
            # Wait-NetAdapterUp -AdapterName $adapterName
            # Enable-LoopbackAdapter
            # New-ExternalSwitch -adapterName $adapterName -PodSubnetworkNumber $PodSubnetworkNumber
        }
    }
    Write-Log "[$logUseCase] finished"
} catch {
    Write-Log "[$logUseCase] $($_.Exception.Message) - $($_.ScriptStackTrace)" -Error

    throw $_
}