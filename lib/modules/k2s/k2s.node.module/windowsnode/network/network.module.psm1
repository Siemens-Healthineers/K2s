# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

$configModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\config.module.psm1"
$fileModule = "$PSScriptRoot\..\..\..\k2s.infra.module\config\file.module.psm1"
$pathModule = "$PSScriptRoot\..\..\..\k2s.infra.module\path\path.module.psm1"
$logModule = "$PSScriptRoot\..\..\..\k2s.infra.module\log\log.module.psm1"
$hnsModule = "$PSScriptRoot\hns.module.psm1"
Import-Module $logModule, $pathModule, $configModule, $hnsModule, $fileModule

$hnsService = 'hns'
$l2BridgeSwitchName = 'cbr0'
$setupConfigRoot = Get-RootConfigk2s
$clusterCIDRNextHop = $setupConfigRoot.psobject.properties['cbr0'].value
$clusterCIDRGateway = $setupConfigRoot.psobject.properties['cbr0Gateway'].value
$clusterCIDRHost = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR'].value
$clusterCIDRHost_2 = $setupConfigRoot.psobject.properties['podNetworkWorkerCIDR_2'].value
$clusterCIDRForFlannel = $setupConfigRoot.psobject.properties['podNetworkCIDR'].value
$clusterCIDRNatExceptions = $setupConfigRoot.psobject.properties['clusterCIDRNatExceptions'].value

$global:HNSRestarted = $false

function Set-IndexForDefaultSwitch {
    # Change index for default switch (on some computers the index is lower as for the main interface Ethernet)
    $ipindexDefault = Get-NetIPInterface | Where-Object InterfaceAlias -Like '*Default*' | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
    if ( $ipindexDefault ) {
        Write-Log "Index for interface Default : ($ipindexDefault) -> metric 103"
        Set-NetIPInterface -InterfaceIndex $ipindexDefault -InterfaceMetric 103
    }
}

function Get-L2BridgeSwitchName {
    return $l2BridgeSwitchName
}

function Get-ConfiguredClusterCIDRHost {
    param (
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )
    #$podNetworkCIDR = $clusterCIDRHost.Replace('X', $PodSubnetworkNumber)
    #return $podNetworkCIDR
    return $clusterCIDRHost
}

function Get-ConfiguredClusterCIDRHost_2 {
    param (
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )
    $podNetworkCIDR = $clusterCIDRHost_2.Replace('X', $PodSubnetworkNumber)
    return $podNetworkCIDR
    
}

function Get-ConfiguredClusterCIDRForFlannel{

    return $clusterCIDRForFlannel
}

function Get-ConfiguredClusterCIDRNextHop {
    param (
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )
    # $nextHop = $clusterCIDRNextHop.Replace('__SUBNETWORK_NUMBER__', $PodSubnetworkNumber)
    # return $nextHop
    return $clusterCIDRNextHop
}

function Get-ConfiguredClusterCIDRGateway {
    param (
        [string] $PodSubnetworkNumber = $(throw 'Argument missing: PodSubnetworkNumber')
    )
    # $gateway = $clusterCIDRGateway.Replace('__SUBNETWORK_NUMBER__', $PodSubnetworkNumber)
    # return $gateway
    return $clusterCIDRGateway
}

function New-ExternalSwitch {
    param (
        [Parameter()]
        [string] $adapterName,
        [string] $PodSubnetworkNumber = '1'
    )

    # if the L2 bridge is already found we don't need to create it again
    $l2BridgeSwitchName = Get-L2BridgeSwitchName
    $found = Invoke-HNSCommand -Command { 
        param($l2BridgeSwitchName)
        Get-HNSNetwork | Where-Object Name -Like $l2BridgeSwitchName 
    } -ArgumentList $l2BridgeSwitchName
    if ($found) {
        Write-Log "L2 bridge network switch name: $l2BridgeSwitchName already exists"
        return
    }

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
    $adr = $()
    if ( $dnsServers) {
        if ($dnsServers.ServerAddresses) {
            $adr = $dnsServers.ServerAddresses
        }
    }
    Write-Log "DNS servers found: '$adr'"
    # build string for DNS server
    $dnsserver = $($adr -join ',')

    # start of external switch
    $gatewayIpAddress = Get-ConfiguredClusterCIDRGateway -PodSubnetworkNumber $PodSubnetworkNumber
    $podNetworkCIDR = Get-ConfiguredClusterCIDRHost -PodSubnetworkNumber $PodSubnetworkNumber
    Write-Log "Create l2 bridge network with subnet: $podNetworkCIDR, switch name: $l2BridgeSwitchName, DNS server: $dnsserver, gateway: $gatewayIpAddress, NAT exceptions: $clusterCIDRNatExceptions, adapter name: $adapterName"
    $netResult = Invoke-HNSCommand -Command {
        param(
            $l2BridgeSwitchName,
            $podNetworkCIDR,
            $dnsserver,
            $gatewayIpAddress,
            $adapterName
        )
        New-HnsNetwork -Type 'L2Bridge' -Name "$l2BridgeSwitchName" -AdapterName "$adapterName" -AddressPrefix "$podNetworkCIDR" -Gateway "$gatewayIpAddress" -DNSServer "$dnsserver" 
    } -ArgumentList @($l2BridgeSwitchName, $podNetworkCIDR, $dnsserver, $gatewayIpAddress, $adapterName)
    Write-Log $netResult

    # create endpoint
    $cbr0 = Invoke-HNSCommand -Command {
        param(
            $l2BridgeSwitchName
        ) 
        Get-HnsNetwork | Where-Object -FilterScript { $_.Name -EQ "$l2BridgeSwitchName" } 
    } -ArgumentList $l2BridgeSwitchName
    if ( $null -Eq $cbr0 ) {
        throw 'No l2 bridge found. Please do a stopk8s ans start from scratch !'
    }

    $endpointname = $l2BridgeSwitchName + '_ep'
    $podNetworkNextHop = Get-ConfiguredClusterCIDRNextHop -PodSubnetworkNumber $PodSubnetworkNumber
    $hnsEndpoint = Invoke-HNSCommand -Command {
        param(
            $cbr0,
            $endpointname,
            $podNetworkNextHop,
            $clusterCIDRNatExceptions
        )
        New-HnsEndpoint -NetworkId $cbr0.ID -Name $endpointname -IPAddress $podNetworkNextHop -Verbose -EnableOutboundNat -OutboundNatExceptions $clusterCIDRNatExceptions 
    } -ArgumentList @($cbr0, $endpointname, $podNetworkNextHop, $clusterCIDRNatExceptions)

    if ($null -Eq $hnsEndpoint) {
        throw 'Not able to create a endpoint. Please do a stopk8s and restart again. Aborting.'
    }

    Invoke-HNSCommand -Command {
        param($hnsEndpointId)
        Invoke-AttachHnsHostEndpoint -EndpointID $hnsEndpointId -CompartmentID 1 
    } -ArgumentList @($hnsEndpoint.Id)

    $iname = "vEthernet ($endpointname)"
    netsh int ipv4 set int $iname for=en | Out-Null

    # disable DNS
    $cbr0AdapterIfIndex = Get-NetIPInterface | Where-Object InterfaceAlias -Like "vEthernet ($endpointname)*" | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex' -First 1
    if ( $cbr0AdapterIfIndex ) {
        Write-Log "Disable DNS for interface $endpointname : ($cbr0AdapterIfIndex)"
        Set-DnsClient -InterfaceIndex $cbr0AdapterIfIndex -ResetConnectionSpecificSuffix -RegisterThisConnectionsAddress $false
    }
}

function Remove-ExternalSwitch () {
    Write-Log "Remove l2 bridge network switch name: $l2BridgeSwitchName"
    Get-HnsNetwork | Where-Object Name -Like "$l2BridgeSwitchName" | Remove-HnsNetwork -ErrorAction SilentlyContinue

    $controlPlaneSwitchName = Get-ControlPlaneNodeDefaultSwitchName

    $hns = Invoke-HNSCommand -Command { Get-HNSNetwork }
    # there's always at least the Default Switch network available, so we check for >= 2
    if ($($hns | Measure-Object).Count -ge 2) {
        Write-Log 'Delete bridge, clear HNSNetwork (short disconnect expected)'
        Invoke-HNSCommand -Command { 
            param($hns, $controlPlaneSwitchName)
            $hns | Where-Object Name -Like '*cbr0*' | Remove-HNSNetwork -ErrorAction SilentlyContinue 
            $hns | Where-Object Name -Like ('*' + $controlPlaneSwitchName + '*') | Remove-HNSNetwork -ErrorAction SilentlyContinue
        } -ArgumentList @($hns, $controlPlaneSwitchName)
    }
}

function Set-InterfacePrivate {
    param (
        [Parameter()]
        [string] $InterfaceAlias
    )

    Write-Log "OK: $InterfaceAlias trying to set to private..."

    # check if the interface is already available as a connection profile
    $connectionProfile = Get-NetConnectionProfile -InterfaceAlias $InterfaceAlias -ErrorAction SilentlyContinue
    # check if the connection profile is available
    if (-not $connectionProfile) {
        Write-Log "$InterfaceAlias has no connection profile !"
        return
    }

    # check if the interface is already set to private
    if ($connectionProfile) {
        if ($connectionProfile.NetworkCategory -eq 'Private') {
            Write-Log "$InterfaceAlias is already set to private"
            return
        }
    }    

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

        if ($iteration -eq 30) {
            Write-Log "Exhausted 30 attempts to set $InterfaceAlias to private. This could be due to issues in NlaSvc. Triggering its restart...."
            Restart-NlaSvc
        }

        Start-Sleep 5
    }

    if ($iteration -eq 0 -and $((Get-NetConnectionProfile -interfacealias $InterfaceAlias).NetworkCategory) -ne 'Private') {
        throw "$InterfaceAlias could not set to private in time"
    }

    Write-Log "OK: $InterfaceAlias set to private now"
}

function Set-IPAddressAndDnsClientServerAddress {
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

    Write-Log "Setting DNSProxy(6) server to empty addresses and no DNS partition on interface index $Index"
    Set-DnsClient -InterfaceIndex $Index -ResetConnectionSpecificSuffix -RegisterThisConnectionsAddress $false

    $kubePath = Get-KubePath
    if ( !(Test-Path "$kubePath\bin\dnsproxy.yaml")) {
        Write-Log '           dnsproxy.exe is not configured, skipping DNS server config...'
        return
    }

    $nameServer = $DnsAddresses[0]
    $nameServerSet = Get-Content "$kubePath\bin\dnsproxy.yaml" | Select-String -Pattern $nameServer

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

function Set-WSLSwitch() {
    param(
        [string]$IpAddress
    )
    $wslSwitch = 'WSL*'
    Write-Log "Configuring internal switch $wslSwitch"

    $iteration = 60
    while ($iteration -gt 0) {
        $iteration--
        $ipindex = Get-NetAdapter -Name "vEthernet ($wslSwitch)" -ErrorAction SilentlyContinue -IncludeHidden | Select-Object -expandproperty 'ifIndex'
        $interfaceAlias = Get-NetAdapter -Name "vEthernet ($wslSwitch)" -ErrorAction SilentlyContinue -IncludeHidden | Select-Object -expandproperty name
        $oldIp = $null
        if ($ipindex) {
            # needs some sync time
            Start-Sleep 2
            $oldIp = (Get-NetIPAddress -InterfaceIndex $ipindex).IPAddress
        }
        if ($ipindex -and $oldIp) {
            Write-Log "ifindex of ${interfaceAlias}: $ipindex"
            Write-Log "Old ip: $oldIp"
            if ($oldIp) {
                foreach ($ip in $oldIp) {
                    Remove-NetIPAddress -InterfaceIndex $ipindex -IPAddress $oldIp -Confirm:$False -ErrorAction SilentlyContinue
                }
            }

            break
        }

        Write-Log "No vEthernet ($wslSwitch) detected yet!"
        Start-Sleep 2
    }

    if ($iteration -eq 0) {
        throw "No vEthernet ($wslSwitch) found!"
    }

    New-NetIPAddress -IPAddress $IpAddress -PrefixLength 24 -InterfaceAlias $interfaceAlias
    # enable forwarding
    netsh int ipv4 set int $interfaceAlias forwarding=enabled | Out-Null
    # change index in order to have the Ethernet card as first card (also for much better DNS queries)
    $ipindex1 = Get-NetIPInterface | Where-Object InterfaceAlias -Like $interfaceAlias | Where-Object AddressFamily -Eq IPv4 | Select-Object -expand 'ifIndex'
    Write-Log "Index for interface $interfaceAlias : ($ipindex1) -> metric 100"
    Set-NetIPInterface -InterfaceIndex $ipindex1 -InterfaceMetric 100
}

<# .DESCRIPTION
	This function restarts the Network Location Awareness Service in Windows 10.
	After 128 cluster start and stop operations, a buffer overflow happens in this service
	This causes the Loopback Adapter detection failures in SmallK8s.
	Restarting this service resets the buffer.

	For now the hook will suffice. An official solution for this shall come as part of K2s 1.1 or beyond.

	The NlaSvc has to be killed explicitly since it has dependents.
#>
function Restart-NlaSvc {
    $networkLocationAwarenessServiceName = 'NlaSvc'
    $nlaSvcProcess = Get-CimInstance -Class Win32_Service -Filter "Name LIKE '$networkLocationAwarenessServiceName'"
    # if NlaSvc is found
    if ($null -ne $nlaSvcProcess) {
        $nlaSvcStartMode = $nlaSvcProcess.StartMode
        $nlaSvcPid = $nlaSvcProcess.ProcessId
        $nlaSvcState = $nlaSvcProcess.State

        # if service is in Manual mode and in Stopped state, the service should not be started by K2s.
        if (($nlaSvcStartMode -eq 'Manual') -and (($nlaSvcState -eq 'Stopped') -or ($nlaSvcPid -eq 0))) {
            Write-Log 'Network Location Awareness service found in Manual mode and Stopped state. Service will not be restarted...'
            return;
        }

        Write-Log "Network Location Awareness service found on host running with pid $nlaSvcPid. Initiating service restart..."
        Invoke-Expression "taskkill /f /pid $nlaSvcPid"
        Start-Sleep -seconds 10
        $serviceRestarted = $false
        if ((Get-Service -Name $networkLocationAwarenessServiceName).Status -ne 'Running') {
            Write-Log "'$networkLocationAwarenessServiceName' Service is not restarted. Starting it explicitly..."
            Start-Service $networkLocationAwarenessServiceName
            $serviceRestarted = Wait-ForServiceRunning -ServiceName $networkLocationAwarenessServiceName
        }
        
        if ($serviceRestarted -eq $false) {
            Write-Log "[WARNING] '$networkLocationAwarenessServiceName' Service could not be successfully restarted !!" -Console
        }
        else {
            Write-Log "Service re-started '$networkLocationAwarenessServiceName'"
        }
    }
}

function Get-VfpRulesFilePath {
    $kubeBinPath = Get-KubeBinPath
    return "$kubeBinPath\cni\vfprules.json"
}

function Remove-VfpRulesFromWindowsNode {
    $file = Get-VfpRulesFilePath
    Remove-Item -Path $file -Force -ErrorAction SilentlyContinue
    Write-Log "Removed file '$file'"
}

function Add-VfpRulesToWindowsNode {
    param (
        [string]$VfpRulesInJsonFormat = $(throw 'Argument missing: VfpRulesInJsonFormat')
    )
    $file = Get-VfpRulesFilePath
    Remove-Item -Path $file -Force -ErrorAction SilentlyContinue
    Write-Log "Removed file '$file'"

    $VfpRulesInJsonFormat | Out-File "$file" -Encoding ascii
    Write-Log "Added file '$file' with vfp rules"
}



# TODO: Move to infra module
function Add-VfpRoute {
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Name = $(throw 'Please specify the name of the route.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Subnet = $(throw 'Please specify the subnet for the route.'),
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $Gateway = $(throw 'Please specify the gateway for the route.'),
        [Parameter(Mandatory = $False)]
        [UInt32]$Priority = 0
    )

    $vfpFilePath = Get-VfpRulesFilePath
    $json = Get-JsonContent -FilePath $vfpFilePath
    if (-Not $json) { return }

    $existingRoute = $json.routes | Where-Object { $_.name -eq $Name }
    if ($existingRoute) {
        Write-Log "[WARN] A VFP route with the name '$Name' already exists."
        return
    }

    # Get the highest existing priority
    $maxPriority = ($json.routes | Measure-Object -Property priority -Maximum).Maximum
    if (-Not $Priority -or $Priority -le $maxPriority) {
        $Priority = $maxPriority + 1
    }

    Write-Log 'Adding new VFP route:'
    Write-Log "  Name: $Name"
    Write-Log "  Subnet: $Subnet"
    Write-Log "  Gateway: $Gateway"
    Write-Log "  Priority: $Priority"

    $newRoute = @{
        name     = $Name
        subnet   = $Subnet
        gateway  = $Gateway
        priority = "$Priority"
    }
    $json.routes += $newRoute
    Save-JsonContent -JsonObject $json -FilePath $vfpFilePath
    Write-Log "VFP Route '$Name' added successfully."
}

function Remove-VfpRoute {
    param (
        [string]$Name
    )
    $vfpFilePath = Get-VfpRulesFilePath
    $json = Get-JsonContent -FilePath $vfpFilePath
    if (-Not $json) { return }

    $routeToRemove = $json.routes | Where-Object { $_.name -eq $Name }
    if (-Not $routeToRemove) {
        Write-Log "No VFP route found with the name '$Name'."
        return
    }

    $json.routes = $json.routes | Where-Object { $_.name -ne $Name }
    Save-JsonContent -JsonObject $json -FilePath $vfpFilePath
    Write-Log "VFP Route '$Name' removed successfully."
}

function Get-VirtualSwitchName {
    param (
        [string]$Name
    )

    $interfaces = Get-NetIPInterface | Where-Object { $_.InterfaceAlias -like "vEthernet ($Name*" }
    if ($interfaces.Count -eq 0) {
        throw "No interface found with name '$Name'"
    }
    # if there are multiple interfaces with the same name, we need to find the one with the highest index
    $interface = $interfaces | Sort-Object -Property InterfaceIndex | Select-Object -First 1
    Write-Log "Found interface '$($interface.InterfaceAlias)' with index $($interface.InterfaceIndex)"
    return $interface.InterfaceAlias
}

function Wait-ForServiceRunning {
    param (
        [string] $ServiceName,
        [int] $MaxRetries = 5,
        [int] $SleepSeconds = 2
    )

    $iteration = 0
    while ($true) {
        $iteration++
        $svcstatus = $(Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
        if ($svcstatus -eq 'Running') {
            return $true
        }
        if ($iteration -ge $MaxRetries) {
            Write-Log "'$ServiceName' Service is not running !!"
            return $false
        }
        Write-Log "'$ServiceName' Waiting for service status to be started."
        Start-Sleep -Seconds $SleepSeconds
    }
}

function Restart-HNSService {
    Restart-Service $hnsService
    $serviceRestarted = Wait-ForServiceRunning -ServiceName $hnsService
    
    if ($serviceRestarted -eq $false) {
        Write-Log "[WARNING] '$hnsService' Service could not be successfully restarted !!" -Console
    }
    else {
        Write-Log "Service re-started '$hnsService'"
    }
}

function Invoke-HNSCommand {
    param (
        [scriptblock] $Command,
        [object[]] $ArgumentList,
        [int] $BaseDelayInSeconds = 2,
        [int] $MaxDelayInSeconds = 60,
        [int] $TimeoutMinutes = 10
    )

    $startTime = Get-Date
    $delay = $BaseDelayInSeconds

    while ($true) {
        try {
            if ($ArgumentList) {
                return & $Command @ArgumentList
            }
            else {
                return & $Command
            }
        }
        catch {
            Write-Log "Error encountered: $_"

            if (-not $global:HNSRestarted) {
                Restart-HNSService
                $global:HNSRestarted = $true
            }
            else {
                $elapsedMinutes = (New-TimeSpan -Start $startTime -End (Get-Date)).TotalMinutes
                if ($elapsedMinutes -ge $TimeoutMinutes) {
                    throw "HNS API failed after $TimeoutMinutes minutes of retries."
                }
                $delay = [math]::Min($delay * 2, $MaxDelayInSeconds)
            }

            Write-Log "Retrying in $delay seconds..."
            Start-Sleep -Seconds $delay
        }
    }
}

function Set-KubeSwitchToPrivate {
    
    Write-Log 'Trying to check the KubeSwitch, set to private if not set yet...'

    # get the switch name
    $WSL = Get-ConfigWslFlag
    $switchname = ''
    if ($WSL) {
        $switchname = Get-WslSwitchName
    }
    else {
        $switchname = Get-ControlPlaneNodeDefaultSwitchName
    }

    # get the real switch name
    $switchRealName = Get-VirtualSwitchName($switchname)

    # set the switch to private
    Set-InterfacePrivate -InterfaceAlias $switchRealName

    Write-Log 'Kubeswitch check finished.'
}

Export-ModuleMember -Function Add-Route, Remove-Route, Update-RoutePriority
Export-ModuleMember Set-IndexForDefaultSwitch, Get-ConfiguredClusterCIDRHost,Get-ConfiguredClusterCIDRHost_2,Get-ConfiguredClusterCIDRForFlannel,
New-ExternalSwitch, Remove-ExternalSwitch,
Set-InterfacePrivate,
Get-L2BridgeSwitchName,
Set-IPAddressAndDnsClientServerAddress, Set-WSLSwitch,
Add-VfpRulesToWindowsNode, Remove-VfpRulesFromWindowsNode, Get-ConfiguredClusterCIDRNextHop,
Add-VfpRoute, Remove-VfpRoute, Get-VirtualSwitchName, Set-KubeSwitchToPrivate, Invoke-HNSCommand
