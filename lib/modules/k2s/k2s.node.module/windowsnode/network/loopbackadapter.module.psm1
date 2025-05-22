# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
Import-Module $logModule, $pathModule, $configModule

$defaultLoopbackAdapterName = 'Loopbackk2s'
$kubeBinPath = Get-KubeBinPath
$devgonPath = "$kubeBinPath\devgon.exe"

$setupConfigRoot = Get-RootConfigk2s

$loopbackAdapterIp = $setupConfigRoot.psobject.properties['loopback'].value
$loopbackAdapterGateway = $setupConfigRoot.psobject.properties['loopbackGateway'].value
$loopbackAdapterCIDR = $setupConfigRoot.psobject.properties['loopbackAdapterCIDR'].value

function New-DefaultLoopbackAdapter {
    New-LoopbackAdapter -Name $defaultLoopbackAdapterName -DevConExe $devgonPath | Out-Null
    Set-LoopbackAdapterProperties -Name $defaultLoopbackAdapterName -IPAddress $loopbackAdapterIp -Gateway $loopbackAdapterGateway
}

function Enable-LoopbackAdapter {
    Write-Log "Enabling network adapter $defaultLoopbackAdapterName"
    Enable-NetAdapter -Name $defaultLoopbackAdapterName -Confirm:$false -ErrorAction SilentlyContinue
    Set-LoopbackAdapterProperties -Name $defaultLoopbackAdapterName -IPAddress $loopbackAdapterIp -Gateway $loopbackAdapterGateway
}

function Disable-LoopbackAdapter {
    Write-Log "Disabling network adapter $defaultLoopbackAdapterName"
    Disable-NetAdapter -Name $defaultLoopbackAdapterName -Confirm:$false -ErrorAction SilentlyContinue
}

function Uninstall-LoopbackAdapter {
    Remove-LoopbackAdapter -Name $defaultLoopbackAdapterName -DevConExe $devgonPath
}

function Get-LoopbackAdapterIP {
    return $loopbackAdapterIp
}

function Get-LoopbackAdapterGateway {
    return $loopbackAdapterGateway
}

function Get-LoopbackAdapterCIDR {
    return $loopbackAdapterCIDR
}

function Get-L2BridgeName {
    return $defaultLoopbackAdapterName
}

function Get-DevgonExePath {
    return $devgonPath
}

function New-LoopbackAdapter {
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    [CmdLetBinding()]
    param
    (
        [Parameter(
            Mandatory = $true,
            Position = 0)]
        [string]
        $Name,

        [string]
        $DevConExe
    )

    Write-Log "Creating new loopback adapter '$Name'"

    # Check for the existing Loopback Adapter
    $Adapter = Get-NetAdapter `
        -Name $Name `
        -ErrorAction SilentlyContinue

    # Is the loopback adapter installed?
    if ($Adapter) {
        return $Adapter
    } # if

    Write-Log 'First remove all existing LoopbackAdapters'
    Get-NetAdapter | Where-Object -Property InterfaceDescription -like 'Microsoft KM-TEST Loopback Adapter*' | ForEach-Object { Remove-LoopbackAdapter -Name $_.Name -DevConExe $DevconExe }

    # Use Devcon.exe to install the Microsoft Loopback adapter
    # Requires local Admin privs.
    $null = & $DevConExe @('install', '-p', "$($ENV:SystemRoot)\inf\netloop.inf", '-i', '*MSLOOP')

    # Find the newly added Loopback Adapter
    $Adapter = Get-NetAdapter | Where-Object { ($_.InterfaceDescription -eq 'Microsoft KM-TEST Loopback Adapter') }
    if (!$Adapter) {
        Throw 'The new Loopback Adapter was not found.'
    } # if

    # Rename the new Loopback adapter
    $Adapter | Rename-NetAdapter `
        -NewName $Name `
        -ErrorAction Stop

    # Set the metric to 254
    Set-NetIPInterface `
        -InterfaceAlias $Name `
        -InterfaceMetric 254 `
        -ErrorAction Stop

    # Pull the newly named adapter (to be safe)
    $Adapter = Get-NetAdapter `
        -Name $Name `
        -ErrorAction Stop

    Return $Adapter
} # function New-LoopbackAdapter

function Get-LoopbackAdapter {
    [OutputType([Microsoft.Management.Infrastructure.CimInstance[]])]
    [CmdLetBinding()]
    param
    (
        [Parameter(
            Position = 0)]
        [string]
        $Name
    )
    # Check for the existing Loopback Adapter
    if ($Name) {
        $Adapter = Get-NetAdapter `
            -Name $Name `
            -ErrorAction SilentlyContinue

        if (!$Adapter) {
            return
        }
        if ($Adapter.InterfaceDescription -ne 'Microsoft KM-TEST Loopback Adapter') {
            Throw "The Network Adapter $Name exists but it is not a Microsoft KM-TEST Loopback Adapter."
        } # if
        return $Adapter
    }
    else {
        Get-NetAdapter | Where-Object -Property InterfaceDescription -eq 'Microsoft KM-TEST Loopback Adapter'
    }
}

function Remove-LoopbackAdapter {
    [CmdLetBinding()]
    param
    (
        [Parameter(Position = 0)]
        [string]
        $Name,

        [string]
        $DevConExe,

        [switch]
        $Force
    )

    Write-Log "Removing loopback adapter '$Name'"

    # Check for the existing Loopback Adapter
    $Adapter = Get-NetAdapter `
        -Name $Name `
        -ErrorAction SilentlyContinue

    # Is the loopback adapter installed?
    if (!$Adapter) {
        Write-Log "No loopback adapter '$Name' found to remove."
        return
    }

    # Is the adapter Loopback adapter?
    if ($Adapter.InterfaceDescription -notlike 'Microsoft KM-TEST Loopback Adapter*') {
        # Not a loopback adapter - don't uninstall this!
        Throw "Network Adapter $Name is not a Microsoft KM-TEST Loopback Adapter."
    } # if

    # Use Devcon.exe to remove the Microsoft Loopback adapter using the PnPDeviceID.
    # Requires local Admin privs.
    $null = & $DevConExe @('remove', '-i', "$($Adapter.PnPDeviceID)")
} # function Remove-LoopbackAdapter

function Set-LoopbackAdapterProperties {
    param (
        [Parameter()]
        [string] $Name,
        [Parameter()]
        [string] $IPAddress,
        [Parameter()]
        [string] $Gateway
    )

    $prefixLength = 24
    $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $prefixLength) -shr (32 - $prefixLength))

    $if = Get-NetIPInterface -InterfaceAlias "$Name" -ErrorAction SilentlyContinue
    if( $if ) {
        Set-NetIPInterface -InterfaceAlias "$Name" -Dhcp Disabled
        netsh interface ipv4 set address name="$Name" static $IPAddress $mask.IPAddressToString $Gateway
        Write-Log "Loopback Adapter $Name configured with IP: $IPAddress, mask: $($mask.IPAddressToString), gateway: $Gateway"
        # enable forwarding
        netsh int ipv4 set int "$Name" forwarding=enabled | Out-Null
        # reset DNS settings
        Set-DnsClient -InterfaceAlias "$Name" -ResetConnectionSpecificSuffix -RegisterThisConnectionsAddress $false
    }
    else {
        Write-Log "No loopback adapter '$Name' found to configure."
    }
}

function Set-LoopbackAdapterExtendedProperties {
    param (
        [Parameter()]
        [string] $AdapterName,
        [Parameter()]
        [string] $DnsServers
    )
    $adapterName = $AdapterName
    Write-Log 'Figuring out IPv4DefaultGateway'
    $if = Get-NetIPConfiguration -InterfaceAlias "$adapterName" -ErrorAction SilentlyContinue 2>&1 | Out-Null
    $gw = Get-LoopbackAdapterGateway
    if ( $if ) {
        $gw = $if.IPv4DefaultGateway.NextHop
        Write-Log "Gateway found (from interface '$adapterName'): $gw"
    }
    Write-Log "The following gateway IP address will be used: $gw"
    $loopbackAdapterIfIndex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "vEthernet ($adapterName)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex' -First 1
    $loopbackAdapterAlias = Get-NetIPInterface | Where-Object InterfaceAlias -Like "vEthernet ($adapterName)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'InterfaceAlias' -First 1
    if ($null -eq $loopbackAdapterIfIndex -or $null -eq $loopbackAdapterAlias) {
        Write-Log 'Unable to find the loopback adapter' -Error
        Write-Log 'Found following interfaces:'
        Get-NetIPInterface | Write-Log
        throw 'Unable to find the loopback adapter'
    }    
    Write-Log "Found Loopback adapter with Alias: '$loopbackAdapterAlias' and ifIndex: '$loopbackAdapterIfIndex'"
    $ipAddressForLoopbackAdapter = Get-LoopbackAdapterIP
    Set-NetIPInterface -InterfaceIndex $loopbackAdapterIfIndex -Dhcp Disabled
    $dnsServersAsArray = $DnsServers -split ','
    Set-IPAdressAndDnsClientServerAddress -IPAddress $ipAddressForLoopbackAdapter -DefaultGateway $gw -Index $loopbackAdapterIfIndex -DnsAddresses $dnsServersAsArray
    Set-InterfacePrivate -InterfaceAlias "$loopbackAdapterAlias"
    Set-DnsClient -InterfaceIndex $loopbackAdapterIfIndex -RegisterThisConnectionsAddress $false | Out-Null
    netsh int ipv4 set int "$loopbackAdapterAlias" forwarding=enabled | Out-Null
    Set-NetIPInterface -InterfaceIndex $loopbackAdapterIfIndex -InterfaceMetric 102
}

Export-ModuleMember New-LoopbackAdapter
Export-ModuleMember Get-LoopbackAdapter
Export-ModuleMember Remove-LoopbackAdapter
Export-ModuleMember Set-LoopbackAdapterProperties, Get-LoopbackAdapterIP,
Get-LoopbackAdapterGateway, Get-LoopbackAdapterCIDR, New-DefaultLoopbackAdapter, Get-L2BridgeName,
Enable-LoopbackAdapter, Disable-LoopbackAdapter, Uninstall-LoopbackAdapter, Get-DevgonExePath, Set-LoopbackAdapterExtendedProperties