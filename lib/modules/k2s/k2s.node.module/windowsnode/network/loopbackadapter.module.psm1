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

function New-DefaultLoopbackAdaterRemote {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [string]$UserPwd = '',
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress'),
        [parameter(Mandatory = $false)]
        [string] $Proxy = ''
    )
     # Define the remote path for devgon.exe
     $remoteDevgonPath = "C:\Windows\Temp\devgon.exe"

     # Copy devgon.exe to the remote machine
     Write-Log "Copying devgon.exe to remote machine at $IpAddress..."
     if (-not [string]::IsNullOrWhiteSpace($UserPwd)) {
         # Use username and password for file transfer
         Copy-ToRemoteComputerViaUserAndPwd -SourcePath $devgonPath -DestinationPath $remoteDevgonPath -HostName $IpAddress -UserName $UserName -Password $UserPwd
     } else {
         Copy-ToRemoteComputerViaSshKey -Source $devgonPath -Target $remoteDevgonPath -IpAddress $IpAddress -UserName $UserName
     }
    New-LoopbackAdapterRemote -Name $defaultLoopbackAdapterName -DevConExe $devgonPath -UserName $UserName -IpAddress $IpAddress | Out-Null
    Set-LoopbackAdapterPropertiesRemote -Name $defaultLoopbackAdapterName -IPAddress $loopbackAdapterIp -Gateway $loopbackAdapterGateway
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

function New-LoopbackAdapterRemote {
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
        $DevConExe,
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$UserName = $(throw 'Argument missing: UserName'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw 'Argument missing: IpAddress')
    )

    Write-Log "Creating new loopback adapter '$Name' on remote machine"

    $scriptBlock = {
        param (
            $Name,
            $DevConExe
        )

        # Check for the existing Loopback Adapter
        $Adapter = Get-NetAdapter -Name $Name -ErrorAction SilentlyContinue

        # Is the loopback adapter installed?
        if ($Adapter) {
            return $Adapter
        }

        Write-Log 'First remove all existing LoopbackAdapters'
        Get-NetAdapter | Where-Object -Property InterfaceDescription -like 'Microsoft KM-TEST Loopback Adapter*' | ForEach-Object { Remove-LoopbackAdapter -Name $_.Name -DevConExe $DevConExe }

        # Use Devcon.exe to install the Microsoft Loopback adapter
        # Requires local Admin privs.
        $null = & $DevConExe @('install', '-p', "$($ENV:SystemRoot)\inf\netloop.inf", '-i', '*MSLOOP')

        # Find the newly added Loopback Adapter
        $Adapter = Get-NetAdapter | Where-Object { ($_.InterfaceDescription -eq 'Microsoft KM-TEST Loopback Adapter') }
        if (!$Adapter) {
            Throw 'The new Loopback Adapter was not found.'
        }

        # Rename the new Loopback adapter
        $Adapter | Rename-NetAdapter -NewName $Name -ErrorAction Stop

        # Set the metric to 254
        Set-NetIPInterface -InterfaceAlias $Name -InterfaceMetric 254 -ErrorAction Stop

        # Pull the newly named adapter (to be safe)
        $Adapter = Get-NetAdapter -Name $Name -ErrorAction Stop

        Return $Adapter
    } 

    $scriptBlockText = $scriptBlock.ToString()
    $encodedScriptBlock = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptBlockText))

    $invokeParams = @{
        CmdToExecute = "powershell.exe -EncodedCommand $encodedScriptBlock -ArgumentList $Name, $DevConExe"
        UserName = $UserName
        IpAddress = $IpAddress
    }

    $result = Invoke-CmdOnVmViaSSHKey @invokeParams

    if (!$result.Success) {
        throw "Failed to execute script on remote machine. Error message: $($result.Output)"
    }

    return $result.Output
}# function New-LoopbackAdapter

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

function Set-LoopbackAdapterPropertiesRemote {
    param (
        [Parameter()]
        [string] $Name,
        [Parameter()]
        [string] $IPAddress,
        [Parameter()]
        [string] $Gateway,
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_)) })]
        [string]$RemoteUserName = $(throw 'Argument missing: UserName'),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$RemoteIpAddress = $(throw 'Argument missing: IpAddress')
    )

    $prefixLength = 24
    $mask = [IPAddress](([UInt32]::MaxValue) -shl (32 - $prefixLength) -shr (32 - $prefixLength)).IPAddressToString

    # Check for the existing Loopback Adapter
    $checkAdapterCmd = "powershell.exe -Command { Get-NetIPInterface -InterfaceAlias '$Name' -ErrorAction SilentlyContinue }"
    $checkAdapterResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $checkAdapterCmd -UserName $RemoteUserName -IpAddress $RemoteIpAddress

    if ($checkAdapterResult.Success -and $checkAdapterResult.Output) {
        # Disable DHCP
        $disableDhcpCmd = "powershell.exe -Command { Set-NetIPInterface -InterfaceAlias '$Name' -Dhcp Disabled }"
        $disableDhcpResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $disableDhcpCmd -UserName $RemoteUserName -IpAddress $RemoteIpAddress
        if (!$disableDhcpResult.Success) {
            throw "Failed to disable DHCP on remote machine. Error message: $($disableDhcpResult.Output)"
        }

        # Set static IP address
        $setIpCmd = "powershell.exe -Command { netsh interface ipv4 set address name='$Name' static $IPAddress $mask $Gateway }"
        $setIpResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $setIpCmd -UserName $RemoteUserName -IpAddress $RemoteIpAddress
        if (!$setIpResult.Success) {
            throw "Failed to set IP address on remote machine. Error message: $($setIpResult.Output)"
        }

        Write-Log "Loopback Adapter $Name configured with IP: $IPAddress, mask: $mask, gateway: $Gateway"

        # Enable forwarding
        $enableForwardingCmd = "powershell.exe -Command { netsh int ipv4 set int '$Name' forwarding=enabled }"
        $enableForwardingResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $enableForwardingCmd -UserName $RemoteUserName -IpAddress $RemoteIpAddress
        if (!$enableForwardingResult.Success) {
            throw "Failed to enable forwarding on remote machine. Error message: $($enableForwardingResult.Output)"
        }

        # Reset DNS settings
        $resetDnsCmd = "powershell.exe -Command { Set-DnsClient -InterfaceAlias '$Name' -ResetConnectionSpecificSuffix -RegisterThisConnectionsAddress $false }"
        $resetDnsResult = Invoke-CmdOnVmViaSSHKey -CmdToExecute $resetDnsCmd -UserName $RemoteUserName -IpAddress $RemoteIpAddress
        if (!$resetDnsResult.Success) {
            throw "Failed to reset DNS settings on remote machine. Error message: $($resetDnsResult.Output)"
        }
    } else {
        Write-Log "No loopback adapter '$Name' found to configure."
    }
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
    Set-NetIPInterface -InterfaceIndex $loopbackAdapterIfIndex -Dhcp Disabled  | Out-Null
    $dnsServersAsArray = $DnsServers -split ','
    Set-IPAddressAndDnsClientServerAddress -IPAddress $ipAddressForLoopbackAdapter -DefaultGateway $gw -Index $loopbackAdapterIfIndex -DnsAddresses $dnsServersAsArray
    Set-InterfacePrivate -InterfaceAlias "$loopbackAdapterAlias"
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

Export-ModuleMember New-LoopbackAdapter
Export-ModuleMember Remove-LoopbackAdapter
Export-ModuleMember New-DefaultLoopbackAdaterRemote
Export-ModuleMember Set-LoopbackAdapterProperties, Get-LoopbackAdapterIP,
Get-LoopbackAdapterGateway, Get-LoopbackAdapterCIDR, New-DefaultLoopbackAdapter, Get-L2BridgeName,
Enable-LoopbackAdapter, Disable-LoopbackAdapter, Uninstall-LoopbackAdapter, Get-DevgonExePath, Set-LoopbackAdapterExtendedProperties,
Set-NewNameForLoopbackAdapter
