# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$logModule = "$PSScriptRoot\..\log\log.module.psm1"

Import-Module $logModule

Function Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost {
    param (
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $physicalInterfaceIndexes = Get-NetAdapter -Physical | Where-Object Status -Eq 'Up' | Where-Object Name -ne $ExcludeNetworkInterfaceName | Select-Object -expand 'ifIndex'

    $allDnsIpAddresses = @()

    foreach ($networkInterfaceIndex in $physicalInterfaceIndexes) {
        $interfaceName = (Get-NetIPAddress -InterfaceIndex $networkInterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
        if ($interfaceName -eq $null) {
            Write-Warning "Cannot get information from network interface index $networkInterfaceIndex)"
        } else {
            $configuredDnsServersOnNetworkInterface = (Get-DnsClientServerAddress -InterfaceIndex $networkInterfaceIndex -AddressFamily IPv4 | Select-Object -ExpandProperty ServerAddresses)
            $allDnsIpAddresses = $allDnsIpAddresses += $configuredDnsServersOnNetworkInterface
            Write-Log "Found the the network interface '$interfaceName' with the following configured DNS IP addresses: $configuredDnsServersOnNetworkInterface"
        }
    }
    $allDnsIpAddressesWithoutDuplicates = $allDnsIpAddresses | Select-Object -Unique

    $allCommaSeparatedDnsIpAddressesWithoutDuplicates = $allDnsIpAddressesWithoutDuplicates -join ","
    Write-Log "Windows host DNS IP addresses: $allCommaSeparatedDnsIpAddressesWithoutDuplicates"

    return $allCommaSeparatedDnsIpAddressesWithoutDuplicates
}

Export-ModuleMember Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost