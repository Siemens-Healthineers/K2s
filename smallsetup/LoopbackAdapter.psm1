# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

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
        Write-Log "$Name configured with IP: $IPAddress, mask: $($mask.IPAddressToString), gateway: $Gateway"
        # enable forwarding
        netsh int ipv4 set int "$Name" forwarding=enabled | Out-Null
    }
    else {
        Write-Log "No loopback adapter '$Name' found to configure."
    }
}

Export-ModuleMember New-LoopbackAdapter
Export-ModuleMember Get-LoopbackAdapter
Export-ModuleMember Remove-LoopbackAdapter
Export-ModuleMember Set-LoopbackAdapterProperties
