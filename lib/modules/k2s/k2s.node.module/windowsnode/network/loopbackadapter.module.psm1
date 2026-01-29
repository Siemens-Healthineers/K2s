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
    $AdapterName = Get-L2BridgeName
    Set-LoopbackAdapterProperties -Name $AdapterName -IPAddress $loopbackAdapterIp -Gateway $loopbackAdapterGateway
}

function Enable-LoopbackAdapter {
    $AdapterName = Get-L2BridgeName
    Write-Log "Enabling network adapter $AdapterName"
    Enable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue
    Set-LoopbackAdapterProperties -Name $AdapterName -IPAddress $loopbackAdapterIp -Gateway $loopbackAdapterGateway
}

function Disable-LoopbackAdapter {
    $AdapterName = Get-L2BridgeName
    Write-Log "Disabling network adapter $AdapterName"
    Disable-NetAdapter -Name $AdapterName -Confirm:$false -ErrorAction SilentlyContinue
}

function Uninstall-LoopbackAdapter {
    $AdapterName = Get-L2BridgeName
    Write-Log "Uninstalling network adapter $AdapterName"
    Remove-LoopbackAdapter -Name $AdapterName -DevConExe $devgonPath
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
    # Find the newly added Loopback Adapter
    $Adapter = Get-NetAdapter  | Where-Object { ($_.InterfaceDescription -like 'Microsoft KM-TEST Loopback Adapter*') }
    # check for zero or multiple entries
    if (!$Adapter) {
        # return the default name
        Write-Log "No Loopback Adapter found, returning default name: $defaultLoopbackAdapterName"
        return $defaultLoopbackAdapterName
    } # if
    if ($Adapter.Count -gt 1) {
        Throw 'More than one Loopback Adapter was found, this is an inconsistency on the system.'
    } # if
    # return the name of the first adapter
    return $Adapter.Name
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
    $Adapter = Get-NetAdapter  | Where-Object { ($_.InterfaceDescription -like 'Microsoft KM-TEST Loopback Adapter*') }
    # check for zero or multiple entries
    if (!$Adapter) {
        Throw 'The new Loopback Adapter was not found.'
    } # if
    if ($Adapter.Count -gt 1) {
        Throw 'More than one Loopback Adapter was found, this is an inconsistency on the system.'
    } # if

    # Rename the new Loopback adapter
    Set-NewNameForLoopbackAdapter -Adapter $Adapter

    # get the newly renamed adapter
    $NewName = Get-L2BridgeName

    # Set the metric to 254
    Set-NetIPInterface `
        -InterfaceAlias $NewName `
        -InterfaceMetric 254 `
        -ErrorAction Stop

    # Pull the newly named adapter (to be safe)
    $Adapter = Get-NetAdapter `
        -Name $NewName `
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

function Test-LoopbackAdapterIPAddress {
    param (
        [Parameter()]
        [string] $Name,
        [Parameter()]
        [string] $ExpectedIPAddress
    )

    $currentAddresses = Get-NetIPAddress -InterfaceAlias "$Name" -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($null -eq $currentAddresses) {
        return $false
    }

    foreach ($addr in $currentAddresses) {
        if ($addr.IPAddress -eq $ExpectedIPAddress) {
            return $true
        }
    }
    return $false
}

function Confirm-LoopbackAdapterIP {
    <#
    .SYNOPSIS
    Verifies loopback adapter has the correct IP address and corrects it if needed.
    .DESCRIPTION
    Checks if the loopback adapter has the expected static IP address. If the IP is wrong
    (e.g., APIPA 169.254.x.x address), it removes existing IPs and re-applies the static IP.
    This should be called right before starting flanneld service.
    .NOTES
    After an external switch is created, the IP is on vEthernet (AdapterName) not the base adapter.
    This function checks both adapters and operates on the correct one.
    Throws an exception if the IP cannot be corrected after retries.
    #>
    $baseAdapterName = Get-L2BridgeName
    $vEthernetAdapterName = "vEthernet ($baseAdapterName)"
    $expectedIP = $loopbackAdapterIp
    $gateway = $loopbackAdapterGateway
    $prefixLength = 24
    $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $prefixLength) -shr (32 - $prefixLength))

    # Determine which adapter to check - vEthernet adapter if external switch exists, otherwise base adapter
    $vEthernetAdapter = Get-NetAdapter -Name $vEthernetAdapterName -ErrorAction SilentlyContinue
    if ($null -ne $vEthernetAdapter) {
        $adapterName = $vEthernetAdapterName
        Write-Log "[LoopbackAdapter] External switch detected, checking vEthernet adapter '$adapterName'"
    } else {
        $adapterName = $baseAdapterName
        Write-Log "[LoopbackAdapter] No external switch, checking base adapter '$adapterName'"
    }

    Write-Log "[LoopbackAdapter] Verifying IP address on adapter '$adapterName' before flanneld start..."

    # Check if IP is already correct
    if (Test-LoopbackAdapterIPAddress -Name $adapterName -ExpectedIPAddress $expectedIP) {
        Write-Log "[LoopbackAdapter] IP address $expectedIP verified successfully on adapter '$adapterName'"
        return
    }

    # Log current addresses for diagnostics
    $currentAddresses = Get-NetIPAddress -InterfaceAlias "$adapterName" -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($null -ne $currentAddresses) {
        foreach ($addr in $currentAddresses) {
            if ($addr.IPAddress -like "169.254.*") {
                Write-Log "[LoopbackAdapter] WARNING: APIPA address detected: $($addr.IPAddress)" -Warning
            } else {
                Write-Log "[LoopbackAdapter] Current IP address: $($addr.IPAddress)"
            }
        }
    } else {
        Write-Log "[LoopbackAdapter] No IPv4 addresses currently assigned"
    }

    Write-Log "[LoopbackAdapter] IP address mismatch detected, correcting..."

    # Remove existing IPv4 addresses (including APIPA) before setting static IP
    $currentAddresses | ForEach-Object {
        Write-Log "[LoopbackAdapter] Removing existing IP address: $($_.IPAddress)"
        Remove-NetIPAddress -InterfaceAlias $adapterName -IPAddress $_.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Apply static IP using netsh
    Write-Log "[LoopbackAdapter] Setting static IP address $expectedIP..."
    netsh interface ipv4 set address name="$adapterName" static $expectedIP $($mask.IPAddressToString) $gateway

    # Brief wait for networking stack
    Start-Sleep -Seconds 1

    # Verify the IP was applied
    if (Test-LoopbackAdapterIPAddress -Name $adapterName -ExpectedIPAddress $expectedIP) {
        Write-Log "[LoopbackAdapter] IP address $expectedIP successfully corrected on adapter '$adapterName'"
        return
    }

    # If still not correct, throw exception
    throw "[LoopbackAdapter] Failed to configure IP $expectedIP on adapter '$adapterName'. Flanneld cannot start with incorrect IP."
}

function Set-LoopbackAdapterProperties {
    param (
        [Parameter()]
        [string] $Name,
        [Parameter()]
        [string] $IPAddress,
        [Parameter()]
        [string] $Gateway
    )

    $maxRetries = 3
    $retryDelaySeconds = 3
    $stabilizationDelaySeconds = 1
    $prefixLength = 24
    $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $prefixLength) -shr (32 - $prefixLength))

    $if = Get-NetIPInterface -InterfaceAlias "$Name" -ErrorAction SilentlyContinue
    if( $if ) {
        Set-NetIPInterface -InterfaceAlias "$Name" -Dhcp Disabled

        $ipConfigured = $false
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            if ($attempt -gt 1) {
                Write-Log "[LoopbackAdapter] Waiting $retryDelaySeconds seconds before retry..."
                Start-Sleep -Seconds $retryDelaySeconds
            }

            Write-Log "[LoopbackAdapter] Setting IP address (attempt $attempt of $maxRetries)..."
            netsh interface ipv4 set address name="$Name" static $IPAddress $mask.IPAddressToString $Gateway

            # Wait for Windows networking stack to apply the IP
            Start-Sleep -Seconds $stabilizationDelaySeconds

            # Verify IP was applied correctly
            if (Test-LoopbackAdapterIPAddress -Name $Name -ExpectedIPAddress $IPAddress) {
                Write-Log "[LoopbackAdapter] Loopback Adapter $Name configured with IP: $IPAddress, mask: $($mask.IPAddressToString), gateway: $Gateway (attempt $attempt)"
                $ipConfigured = $true
                break
            }
            else {
                Write-Log "[LoopbackAdapter] IP verification failed on attempt $attempt of $maxRetries"
            }
        }

        if (-not $ipConfigured) {
            Write-Log "[LoopbackAdapter] Failed to configure IP $IPAddress on adapter $Name after $maxRetries attempts" -Error
            return
        }

        # enable forwarding
        netsh int ipv4 set int "$Name" forwarding=enabled | Out-Null
        # reset DNS settings
        Set-DnsClient -InterfaceAlias "$Name" -ResetConnectionSpecificSuffix -RegisterThisConnectionsAddress $false
    }
    else {
        Write-Log "[LoopbackAdapter] No loopback adapter '$Name' found to configure."
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
    Set-NetIPInterface -InterfaceIndex $loopbackAdapterIfIndex -Dhcp Disabled  | Out-Null
    $dnsServersAsArray = $DnsServers -split ','
    Set-IPAddressAndDnsClientServerAddress -IPAddress $ipAddressForLoopbackAdapter -DefaultGateway $gw -Index $loopbackAdapterIfIndex -DnsAddresses $dnsServersAsArray
    # Removed, not at the end of start cmd
    # Set-InterfacePrivate -InterfaceAlias "$loopbackAdapterAlias"
    Set-DnsClient -InterfaceIndex $loopbackAdapterIfIndex -RegisterThisConnectionsAddress $false | Out-Null
    netsh int ipv4 set int "$loopbackAdapterAlias" forwarding=enabled | Out-Null
    Set-NetIPInterface -InterfaceIndex $loopbackAdapterIfIndex -InterfaceMetric 102  | Out-Null
}

function Set-NewNameForLoopbackAdapter {
    param (
        [Parameter()]
        [object] $Adapter
    )    
    # start with the default name
    $NewName = $defaultLoopbackAdapterName
    # if that default name does not work, then use a next name $defaultLoopbackAdapterName + '1'
    $iMaxLoops = 5
    for ($i = 0; $i -lt $iMaxLoops; $i++) {
        if ($i -gt 0) {
            # if the default name does not work, then use a next name $defaultLoopbackAdapterName + '1'
            $NewName = "$defaultLoopbackAdapterName$i"
            Write-Log "Trying to rename Loopback Adapter to '$NewName'"
        } else {
            $NewName = $defaultLoopbackAdapterName
            Write-Log "Trying to rename Loopback Adapter to '$defaultLoopbackAdapterName'"
        }  

        # try to rename the Loopback Adapter
        try {
            $Adapter | Rename-NetAdapter -NewName $NewName -ErrorAction Stop
        }
        catch {
            Write-Log "Renaming Loopback Adapter to '$NewName' failed: $($_.Exception.Message)"
            Write-Debug "Will try to rename it to the next name."
            # if the rename fails, then try the next name
            continue
        }
        # if the rename was successful, then break the loop
        Write-Log "Renaming Loopback Adapter to '$NewName' was successful."
        break
    }
}

function Set-PrivateNetworkProfileForLoopbackAdapter {
    $adapterName = Get-L2BridgeName
    $loopbackAdapterAlias = Get-NetIPInterface | Where-Object InterfaceAlias -Like "vEthernet ($adapterName)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'InterfaceAlias' -First 1
    Set-InterfacePrivate -InterfaceAlias "$loopbackAdapterAlias"
}

Export-ModuleMember New-LoopbackAdapter
Export-ModuleMember Remove-LoopbackAdapter
Export-ModuleMember New-DefaultLoopbackAdaterRemote
Export-ModuleMember Set-LoopbackAdapterProperties, Get-LoopbackAdapterIP,
Get-LoopbackAdapterGateway, Get-LoopbackAdapterCIDR, New-DefaultLoopbackAdapter, Get-L2BridgeName,
Enable-LoopbackAdapter, Disable-LoopbackAdapter, Uninstall-LoopbackAdapter, Get-DevgonExePath, Set-LoopbackAdapterExtendedProperties,
Set-NewNameForLoopbackAdapter, Set-PrivateNetworkProfileForLoopbackAdapter, Confirm-LoopbackAdapterIP
