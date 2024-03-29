# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
# SPDX-License-Identifier: MIT

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$hnsModule = "$PSScriptRoot\hns.module.psm1"
Import-Module $logModule, $pathModule, $configModule, $hnsModule

$l2BridgeSwitchName = 'cbr0'
$netNatName = 'VMsNAT'
$setupConfigRoot = Get-RootConfigk2s
$ipControlPlaneCIDR = Get-ConfiguredControlPlaneCIDR
$clusterCIDRNextHop = $setupConfigRoot.psobject.properties['cbr0'].value
$clusterCIDRGateway = $setupConfigRoot.psobject.properties['cbr0Gateway'].value
$clusterCIDRHost = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR'].value
$clusterCIDRNatExceptions = $setupConfigRoot.psobject.properties['clusterCIDRNatExceptions'].value


function Set-IndexForDefaultSwitch {
    # Change index for default switch (on some computers the index is lower as for the main interface Ethernet)
    $ipindexDefault = Get-NetIPInterface | Where-Object InterfaceAlias -Like '*Default*' | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
    if ( $ipindexDefault ) {
        Write-Log "Index for interface Default : ($ipindexDefault) -> metric 35"
        Set-NetIPInterface -InterfaceIndex $ipindexDefault -InterfaceMetric 35
    }
}

function Get-L2BridgeSwitchName {
    return $l2BridgeSwitchName
}

function Get-ConfiguredClusterCIDRHost {
    return $clusterCIDRHost
}

function New-ExternalSwitch {
    param (
        [Parameter()]
        [string] $adapterName
    )

    $nic = Get-NetIPAddress -InterfaceAlias $adapterName -ErrorAction SilentlyContinue
    if ($nic) {
        $ipaddress = $nic.IPv4Address
        $dhcp = $nic.PrefixOrigin
        Write-Log "Using card: '$adapterName' with $ipaddress and $dhcp"
    }
    else {
        Write-Log 'FAILURE: no NIC found which is appropriate !'
        throw 'Fatal: no network interface found which works for K2s Setup!'
    }

    # get DNS server from NIC
    $dnsServers = @(Get-DnsClientServerAddress -InterfaceIndex $nic.InterfaceIndex -AddressFamily IPv4)
    $adr = $('8.8.8.8', '8.8.4.4')
    if ( $dnsServers) {
        if ($dnsServers.ServerAddresses) {
            $adr = $dnsServers.ServerAddresses
        }
    }
    Write-Log "DNS servers found: '$adr'"
    # build string for DNS server
    $dnsserver = $($adr -join ',')

    # start of external switch
    Write-Log "Create l2 bridge network with subnet: $clusterCIDRHost, switch name: $l2BridgeSwitchName, DNS server: $dnsserver, gateway: $clusterCIDRGateway, NAT exceptions: $clusterCIDRNatExceptions, adapter name: $adapterName"
    $netResult = New-HnsNetwork -Type 'L2Bridge' -Name "$l2BridgeSwitchName" -AdapterName "$adapterName" -AddressPrefix "$clusterCIDRHost" -Gateway "$clusterCIDRGateway" -DNSServer "$dnserver"
    Write-Log $netResult

    # create endpoint
    $cbr0 = Get-HnsNetwork | Where-Object -FilterScript { $_.Name -EQ "$l2BridgeSwitchName" }
    if ( $null -Eq $cbr0 ) {
        throw 'No l2 bridge found. Please do a stopk8s ans start from scratch !'
    }

    $endpointname = $l2BridgeSwitchName + '_ep'
    $hnsEndpoint = New-HnsEndpoint -NetworkId $cbr0.ID -Name $endpointname -IPAddress $clusterCIDRNextHop -Verbose -EnableOutboundNat -OutboundNatExceptions $clusterCIDRNatExceptions
    if ($null -Eq $hnsEndpoint) {
        throw 'Not able to create a endpoint. Please do a stopk8s and restart again. Aborting.'
    }

    Invoke-AttachHnsHostEndpoint -EndpointID $hnsEndpoint.Id -CompartmentID 1
    $iname = "vEthernet ($endpointname)"
    netsh int ipv4 set int $iname for=en | Out-Null
    #netsh int ipv4 add neighbors $iname $clusterCIDRGateway '00-01-e8-8b-2e-4b' | Out-Null
}

function Remove-ExternalSwitch () {
    Write-Log "Remove l2 bridge network switch name: $l2BridgeSwitchName"
    Get-HnsNetwork | Where-Object Name -Like "$l2BridgeSwitchName" | Remove-HnsNetwork -ErrorAction SilentlyContinue

    $controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName

    $hns = $(Get-HNSNetwork)
    # there's always at least the Default Switch network available, so we check for >= 2
    if ($($hns | Measure-Object).Count -ge 2) {
        Write-Log 'Delete bridge, clear HNSNetwork (short disconnect expected)'
        $hns | Where-Object Name -Like '*cbr0*' | Remove-HNSNetwork -ErrorAction SilentlyContinue
        $hns | Where-Object Name -Like ('*' + $controlPlaneSwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
    }
}

function Invoke-RecreateNAT {
    # configure NAT
    if (Get-NetNat -Name $netNatName -ErrorAction SilentlyContinue) {
        Write-Log "  $netNatName exists, removing it"
        Remove-NetNat -Name $netNatName -Confirm:$False | Out-Null
    }
    # Write-Log 'Configure NAT...'
    # New-NetNat -Name $netNatName -InternalIPInterfaceAddressPrefix $global:IP_CIDR | Out-Null

    # disable IPv6
    # Disable-NetAdapterBinding -Name "vEthernet ($global:SwitchName)" -ComponentID ms_tcpip6 | Out-Null
}

function New-DefaultNetNat {
    New-NetNat -Name $netNatName -InternalIPInterfaceAddressPrefix $ipControlPlaneCIDR | Out-Null
}

function Remove-DefaultNetNat {
    Remove-NetNatStaticMapping -NatName $netNatName -Confirm:$False -ErrorAction SilentlyContinue
    Remove-NetNat -Name $netNatName -Confirm:$False -ErrorAction SilentlyContinue
}

function Set-InterfacePrivate {
    param (
        [Parameter()]
        [string] $InterfaceAlias
    )

    $iteration = 60
    while ($iteration -gt 0) {
        $iteration--
        Set-NetConnectionProfile -InterfaceAlias $InterfaceAlias -NetworkCategory Private -ErrorAction SilentlyContinue

        if ($?) {
            if ($((Get-NetConnectionProfile -interfacealias $InterfaceAlias).NetworkCategory) -eq 'Private') {
                break
            }
        }

        Write-Log "$InterfaceAlias not set to private yet..."
        Start-Sleep 5
    }

    if ($iteration -eq 0 -and $((Get-NetConnectionProfile -interfacealias $InterfaceAlias).NetworkCategory) -ne 'Private') {
        throw "$InterfaceAlias could not set to private in time"
    }

    Write-Log "OK: $InterfaceAlias set to private now"
}

function Set-IPAdressAndDnsClientServerAddress {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $IPAddress = $(throw 'Please specify the target IP address.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $DefaultGateway = $(throw 'Please specify the default gateway.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [UInt32] $Index = $(throw 'Please specify index of card.'),
        [Parameter(Mandatory = $False)]
        [string[]]$DnsAddresses = @('8.8.8.8', '8.8.4.4')

    )
    New-NetIPAddress -IPAddress $IPAddress -PrefixLength 24 -InterfaceIndex $Index -DefaultGateway $DefaultGateway -ErrorAction SilentlyContinue | Out-Null
    if ($DnsAddresses.Count -eq 0) {
        $DnsAddresses = $('8.8.8.8', '8.8.4.4')
    }
    Set-DnsClientServerAddress -InterfaceIndex $Index -Addresses $DnsAddresses

    $kubePath = Get-KubePath
    if ( !(Test-Path "$kubePath\bin\dnsproxy.yaml")) {
        Write-Log '           dnsproxy.exe is not configured, skipping DNS server config...'
        return
    }

    $nameServer = $DnsAddresses[0]
    $nameServerSet = Get-Content "$kubePath\bin\dnsproxy.yaml" | Select-String -Pattern $DnsAddresses[0]

    if ( $nameServerSet ) {
        Write-Log '           DNS Server is already configured in dnsproxy.yaml (config for dnsproxy.exe)'
        return
    }

    #Last entry in the dnsproxy.yaml is reserved for default DNS Server, we will replace the default one with machine DNS server
    $existingNameServer = Get-Content "$kubePath\bin\dnsproxy.yaml" | Select-String -Pattern '  -' | Select-Object -Last 1 | Select-Object -ExpandProperty Line
    $existingNameServer = $existingNameServer.Substring(4)
    Write-Log "           Existing DNS Address in dnsproxy.yaml $existingNameServer"
    Write-Log "           Updating dnsproxy.yaml (config for dnsproxy.exe) with DNS Address $nameServer"
    $newContent = Get-content "$kubePath\bin\dnsproxy.yaml" | ForEach-Object { $_ -replace $existingNameServer, """$nameServer""" }
    $newContent | Set-Content "$kubePath\bin\dnsproxy.yaml"
}



Export-ModuleMember Set-IndexForDefaultSwitch, Get-ConfiguredClusterCIDRHost,
New-ExternalSwitch, Remove-ExternalSwitch,
Invoke-RecreateNAT, Set-InterfacePrivate,
Get-L2BridgeSwitchName, Remove-DefaultNetNat,
New-DefaultNetNat, Set-IPAdressAndDnsClientServerAddress