# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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

function Get-HostPhysicalIp {
    param (
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $hostphysicalIp = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notmatch 'vEthernet' -and $_.Name -ne $ExcludeNetworkInterfaceName } | ForEach-Object { Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue } |  Select-Object -ExpandProperty IPAddress -First 1
    return $hostphysicalIp
}


Export-ModuleMember -Function Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost, Get-HostPhysicalIp

