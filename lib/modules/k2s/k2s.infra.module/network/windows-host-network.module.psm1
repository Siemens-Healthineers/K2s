# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$logModule = "$PSScriptRoot\..\log\log.module.psm1"

Import-Module $logModule

function Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost {
    param (
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $physicalInterfaceIndexes = Get-NetAdapter -Physical | Where-Object Status -Eq 'Up' | Where-Object Name -ne $ExcludeNetworkInterfaceName | Select-Object -expand 'ifIndex'

    $allDnsIpAddresses = @()

    foreach ($networkInterfaceIndex in $physicalInterfaceIndexes) {
        $interfaceName = (Get-NetIPAddress -InterfaceIndex $networkInterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
        if ($null -eq $interfaceName) {
            Write-Warning "Cannot get information from network interface index $networkInterfaceIndex)"
        }
        else {
            $configuredDnsServersOnNetworkInterface = (Get-DnsClientServerAddress -InterfaceIndex $networkInterfaceIndex -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses)
            $allDnsIpAddresses = $allDnsIpAddresses += $configuredDnsServersOnNetworkInterface
            Write-Log "Found the the network interface '$interfaceName' with the following configured DNS IP addresses: $configuredDnsServersOnNetworkInterface"
        }
    }
    $allDnsIpAddressesWithoutDuplicates = $allDnsIpAddresses | Select-Object -Unique

    $allCommaSeparatedDnsIpAddressesWithoutDuplicates = $allDnsIpAddressesWithoutDuplicates -join ','
    Write-Log "Windows host DNS IP addresses: $allCommaSeparatedDnsIpAddressesWithoutDuplicates"

    return $allCommaSeparatedDnsIpAddressesWithoutDuplicates
}

function Set-K2sDnsProxyForActivePhysicalInterfacesOnWindowsHost {
    param (
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $k2sDnsProxyIpAddress = Get-ConfiguredKubeSwitchIP
    $physicalInterfaceIndexes = Get-NetAdapter -Physical | Where-Object Status -Eq 'Up' | Where-Object Name -ne $ExcludeNetworkInterfaceName | Select-Object -expand 'ifIndex'

    foreach ($networkInterfaceIndex in $physicalInterfaceIndexes) {
        $interfaceName = (Get-NetIPAddress -InterfaceIndex $networkInterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
        if ($null -eq $interfaceName) {
            Write-Warning "Cannot get information from network interface index $networkInterfaceIndex)"
        }
        else {
            Write-Log "Setting DNS proxy IP address '$k2sDnsProxyIpAddress' as main DNS server for network interface '$interfaceName'"
            Set-DnsClientServerAddress -InterfaceIndex $networkInterfaceIndex -ServerAddresses $k2sDnsProxyIpAddress
        }
    }
}

function Reset-DnsForActivePhysicalInterfacesOnWindowsHost {
    param (
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $physicalInterfaceIndexes = Get-NetAdapter -Physical | Where-Object Status -Eq 'Up' | Where-Object Name -ne $ExcludeNetworkInterfaceName | Select-Object -expand 'ifIndex'

    foreach ($networkInterfaceIndex in $physicalInterfaceIndexes) {
        $interfaceName = (Get-NetIPAddress -InterfaceIndex $networkInterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
        if ($null -eq $interfaceName) {
            Write-Warning "Cannot get information from network interface index $networkInterfaceIndex)"
        }
        else {
            Write-Log "Resetting DNS server settings for network interface '$interfaceName'"
            Set-DnsClientServerAddress -InterfaceIndex $networkInterfaceIndex -ResetServerAddresses
        }
    }

}


Export-ModuleMember -Function Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost,
Set-K2sDnsProxyForActivePhysicalInterfacesOnWindowsHost, Reset-DnsForActivePhysicalInterfacesOnWindowsHost