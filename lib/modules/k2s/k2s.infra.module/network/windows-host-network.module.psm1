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

# function Set-K2sDnsProxyForActivePhysicalInterfacesOnWindowsHost {
#     param (
#         [string]$ExcludeNetworkInterfaceName = ''
#     )

#     $k2sDnsProxyIpAddress = Get-ConfiguredKubeSwitchIP
#     $physicalInterfaceIndexes = Get-NetAdapter -Physical | Where-Object Status -Eq 'Up' | Where-Object Name -ne $ExcludeNetworkInterfaceName | Select-Object -expand 'ifIndex'

#     foreach ($networkInterfaceIndex in $physicalInterfaceIndexes) {
#         $interfaceName = (Get-NetIPAddress -InterfaceIndex $networkInterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
#         if ($null -eq $interfaceName) {
#             Write-Warning "Cannot get information from network interface index $networkInterfaceIndex)"
#         }
#         else {
#             Write-Log "Setting DNSProxy(1) IP address '$k2sDnsProxyIpAddress' as main DNS server for network interface '$interfaceName'"
#             Set-DnsClientServerAddress -InterfaceIndex $networkInterfaceIndex -ServerAddresses $k2sDnsProxyIpAddress
#         }
#     }
# }

# function Reset-DnsForActivePhysicalInterfacesOnWindowsHost {
#     param (
#         [string]$ExcludeNetworkInterfaceName = ''
#     )

#     $k2sDnsProxyIpAddress = Get-ConfiguredKubeSwitchIP
#     $physicalInterfaceIndexes = Get-DNSClientServerAddress -AddressFamily IPv4 | Where-Object Name -ne $ExcludeNetworkInterfaceName | Where-Object ServerAddresses -contains $k2sDnsProxyIpAddress | Select-Object -expand 'InterfaceIndex'

#     foreach ($networkInterfaceIndex in $physicalInterfaceIndexes) {
#         $interfaceName = (Get-NetIPAddress -InterfaceIndex $networkInterfaceIndex -ErrorAction SilentlyContinue).InterfaceAlias
#         if ($null -eq $interfaceName) {
#             Write-Warning "Cannot get information from network interface index $networkInterfaceIndex)"
#         }
#         else {
#             Write-Log "Setting DNSProxy(2) server settings for network interface '$interfaceName' with reset"
#             Set-DnsClientServerAddress -InterfaceIndex $networkInterfaceIndex -ResetServerAddresses
#         }
#     }

# }

function Get-HostPhysicalIp {
    param (
        [string]$ExcludeNetworkInterfaceName = ''
    )

    $hostphysicalIp = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.Name -notmatch 'vEthernet' -and $_.Name -ne $ExcludeNetworkInterfaceName } | ForEach-Object { Get-NetIPAddress -InterfaceIndex $_.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue } |  Select-Object -ExpandProperty IPAddress -First 1
    return $hostphysicalIp
}

<#
.SYNOPSIS
Checks if Hyper-V Default Switch subnet collides with K2s network configuration.

.DESCRIPTION
Validates that the Hyper-V "Default Switch" (if it exists) does not use
subnet ranges that overlap with the configured K2s network subnets from config.json.
This prevents network routing issues and IP address conflicts.

.EXAMPLE
Test-DefaultSwitch

.NOTES
Throws an error if a collision is detected.
#>
function Test-DefaultSwitch {
    Write-Log "Checking Hyper-V Default Switch for subnet collisions..."
    
    # Get Default Switch IP configuration
    $defaultSwitchIp = Get-NetIPAddress -InterfaceAlias "vEthernet (Default Switch)" -AddressFamily IPv4 -ErrorAction SilentlyContinue
    
    if ($null -eq $defaultSwitchIp) {
        Write-Log "No Hyper-V Default Switch found, skipping collision check."
        return
    }
    
    $defaultSwitchSubnet = "$($defaultSwitchIp.IPAddress)/$($defaultSwitchIp.PrefixLength)"
    Write-Log "Found Hyper-V Default Switch with subnet: $defaultSwitchSubnet"
    
    # Get K2s network configuration
    $configModule = "$PSScriptRoot\..\config\config.module.psm1"
    Import-Module $configModule -DisableNameChecking -ErrorAction SilentlyContinue
    
    $configPath = Get-ConfigurationFilePath
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    
    # List of all K2s subnets to check
    $k2sSubnets = @(
        @{ Name = 'masterNetworkCIDR'; Value = $config.smallsetup.masterNetworkCIDR },
        @{ Name = 'podNetworkCIDR'; Value = $config.smallsetup.podNetworkCIDR },
        @{ Name = 'podNetworkMasterCIDR'; Value = $config.smallsetup.podNetworkMasterCIDR },
        @{ Name = 'podNetworkWorkerCIDR'; Value = $config.smallsetup.podNetworkWorkerCIDR },
        @{ Name = 'servicesCIDR'; Value = $config.smallsetup.servicesCIDR },
        @{ Name = 'servicesCIDRLinux'; Value = $config.smallsetup.servicesCIDRLinux },
        @{ Name = 'servicesCIDRWindows'; Value = $config.smallsetup.servicesCIDRWindows },
        @{ Name = 'loopbackAdapterCIDR'; Value = $config.smallsetup.loopbackAdapterCIDR }
    )
    
    # Check for overlaps
    foreach ($k2sSubnet in $k2sSubnets) {
        if (Test-SubnetOverlap -Subnet1 $defaultSwitchSubnet -Subnet2 $k2sSubnet.Value) {
            $errorMsg = "Hyper-V Default Switch subnet ($defaultSwitchSubnet) collides with K2s network configuration $($k2sSubnet.Name) ($($k2sSubnet.Value))!`n" +
                        "The Default Switch is automatically created by Hyper-V and conflicts with K2s networking.`n" +
                        "Please remove the Default Switch before installing K2s:`n" +
                        "  Get-HnsNetwork | Where-Object Name -EQ 'Default Switch' | Remove-HnsNetwork"
            Write-Log $errorMsg -Error
            throw "[PREREQ-FAILED] $errorMsg"
        }
    }
    
    Write-Log "No subnet collision detected with Default Switch."
}

<#
.SYNOPSIS
Tests if two IP subnets overlap.

.DESCRIPTION
Checks whether two CIDR subnets have overlapping IP address ranges.

.PARAMETER Subnet1
First subnet in CIDR notation (e.g., "172.19.1.5/24")

.PARAMETER Subnet2
Second subnet in CIDR notation (e.g., "172.19.1.0/24")

.OUTPUTS
Returns $true if subnets overlap, $false otherwise.

.EXAMPLE
Test-SubnetOverlap -Subnet1 "172.19.1.5/24" -Subnet2 "172.19.1.0/24"
#>
function Test-SubnetOverlap {
    param(
        [string]$Subnet1,
        [string]$Subnet2
    )
    
    # Parse subnet1
    $parts1 = $Subnet1 -split '/'
    $ip1 = [System.Net.IPAddress]::Parse($parts1[0])
    $prefix1 = [int]$parts1[1]
    
    # Parse subnet2
    $parts2 = $Subnet2 -split '/'
    $ip2 = [System.Net.IPAddress]::Parse($parts2[0])
    $prefix2 = [int]$parts2[1]
    
    # Calculate network addresses
    $mask1 = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix1))
    $mask2 = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefix2))
    
    $network1 = [uint32]([System.BitConverter]::ToUInt32($ip1.GetAddressBytes()[3..0], 0)) -band $mask1
    $network2 = [uint32]([System.BitConverter]::ToUInt32($ip2.GetAddressBytes()[3..0], 0)) -band $mask2
    
    # Check if networks overlap - use the smaller prefix to determine overlap
    $minPrefix = [Math]::Min($prefix1, $prefix2)
    $overlapMask = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $minPrefix))
    
    return ($network1 -band $overlapMask) -eq ($network2 -band $overlapMask)
}


Export-ModuleMember -Function Get-DnsIpAddressesFromActivePhysicalNetworkInterfacesOnWindowsHost, Get-HostPhysicalIp, Test-DefaultSwitch
# Set-K2sDnsProxyForActivePhysicalInterfacesOnWindowsHost, Reset-DnsForActivePhysicalInterfacesOnWindowsHost
