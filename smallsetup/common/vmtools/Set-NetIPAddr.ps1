# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [System.Management.Automation.Runspaces.PSSession[]]$PSSession,

    [Parameter(Mandatory = $false)]
    [string[]]$DnsAddr = @('8.8.8.8', '8.8.4.4'),

    [Parameter(Mandatory = $true)]
    [string]$IPAddr,

    [Parameter(Mandatory = $true)]
    [byte]$MaskPrefixLength,
    
    [Parameter(Mandatory = $true)]
    [string]$DefaultGatewayIpAddr
)

$ErrorActionPreference = 'Stop'

Invoke-Command -Session $PSSession { 
    Remove-NetRoute -NextHop $using:DefaultGatewayIpAddr -Confirm:$false -ErrorAction SilentlyContinue
    $network = 'Ethernet'
    $neta = Get-NetAdapter $network       # Use the exact adapter name for multi-adapter VMs

    Write-Output "Remove old ip address"
    $neta | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false 

    # New-NetIPAddress may fail for certain scenarios (e.g. PrefixLength = 32). Using netsh instead.
    Write-Output "Set new ip address"
    $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $using:MaskPrefixLength) -shr (32 - $using:MaskPrefixLength))
    netsh interface ipv4 set address name="$($neta.InterfaceAlias)" static $using:IPAddr $mask.IPAddressToString $using:DefaultGatewayIpAddr

    Write-Output "Disable DHCP"
    $neta | Set-NetIPInterface -Dhcp Disabled

    Write-Output "Set DNS servers"
    $neta | Set-DnsClientServerAddress -Addresses $using:DnsAddr
}
