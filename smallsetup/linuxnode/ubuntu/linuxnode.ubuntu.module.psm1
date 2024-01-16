# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

. "$PSScriptRoot\..\..\common\GlobalFunctions.ps1"

$validationModule = "$global:KubernetesPath\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
Import-Module $validationModule

<#
.SYNOPSIS
Sets up the computer with Ubuntu OS before it gets provisioned.
.DESCRIPTION
During the set-up the following is done:
- disable automatic upgrades.
- disable swap.
- add apt repository 'universe'.
- update apt repository.
- disable release file validity check.
- install tool 'curl'.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
#>
Function Set-UpComputerWithSpecificOsBeforeProvisioning {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress")
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($command = $(throw "Argument missing: Command")) 
        ExecCmdMaster -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -UsePwd
    }

    Write-Log "Disable automatic upgrades"
    &$executeRemoteCommand "echo 'APT::Periodic::Update-Package-Lists `"0`";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades" 
    &$executeRemoteCommand "echo 'APT::Periodic::Download-Upgradeable-Packages `"0`";' | sudo tee -a /etc/apt/apt.conf.d/20auto-upgrades" 
    &$executeRemoteCommand "echo 'APT::Periodic::AutocleanInterval `"0`";' | sudo tee -a /etc/apt/apt.conf.d/20auto-upgrades" 
    &$executeRemoteCommand "echo 'APT::Periodic::Unattended-Upgrade `"0`";' | sudo tee -a /etc/apt/apt.conf.d/20auto-upgrades" 
    &$executeRemoteCommand "sudo systemctl disable unattended-upgrades"
    &$executeRemoteCommand "sudo systemctl stop unattended-upgrades"


    Write-Log "Disable swap"
    &$executeRemoteCommand "sudo swapon --show" 
    &$executeRemoteCommand "swapFiles=`$(cat /proc/swaps | awk 'NR>1 {print `$1}')" 
    &$executeRemoteCommand "sudo swapoff -a" 
    &$executeRemoteCommand "for swapFile in `$swapFiles; do sudo rm '`$swapFile'; done" 
    &$executeRemoteCommand "sudo sed -i '/\sswap\s/d' /etc/fstab" 

    Write-Log "Add apt repository 'universe'"
    &$executeRemoteCommand "sudo add-apt-repository universe" 

    Write-Log "Update apt repository"
    &$executeRemoteCommand "sudo DEBIAN_FRONTEND=noninteractive apt update" 

    Write-Log "Disable release file validity check"
    &$executeRemoteCommand 'echo Acquire::Check-Valid-Until \\\"false\\\"\; | sudo tee /etc/apt/apt.conf.d/00snapshot' 
    &$executeRemoteCommand 'echo Acquire::Max-FutureTime 86400\; | sudo tee -a /etc/apt/apt.conf.d/00snapshot' 

    Write-Log "Install tool 'curl'"
    &$executeRemoteCommand "sudo DEBIAN_FRONTEND=noninteractive apt-get install curl --yes" 
}

<#
.SYNOPSIS
Sets up the computer with Ubuntu OS after it gets provisioned.
.DESCRIPTION
After provisioning the Ubuntu OS does not need any further set-up therefore no set-up is performed.
This method is emtpy by intention and exists only to satisfy a dependency.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
#>
Function Set-UpComputerWithSpecificOsAfterProvisioning {
    param (
        [string]$UserName,
        [string]$UserPwd,
        [string]$IpAddress
    )
    # empty by intention
}

<#
.SYNOPSIS
Sets up the computer with Ubuntu OS before it gets configured as Master Node.
.DESCRIPTION
During the set-up the following is done:
- disable service servicing port 53 (i.e. systemd-resolved).
- add next available DNS server(s).
- add firewall rules for Kubernetes.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
.PARAMETER DnsEntries
A comma separated list of DNS addresses.
#>
Function Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [string]$DnsEntries = $(throw "Argument missing: DnsEntries")
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($command = $(throw "Argument missing: Command"))
        ExecCmdMaster -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -UsePwd
    }

    Write-Log "Disable service servicing port 53 (i.e. systemd-resolved)"
    &$executeRemoteCommand "sudo systemctl disable systemd-resolved" 
    &$executeRemoteCommand "sudo systemctl stop systemd-resolved" 
    &$executeRemoteCommand "sudo unlink /etc/resolv.conf" 

    Write-Log "Add next available DNS server(s)"
    $formattedDnsEntries = $DnsEntries -replace ",", "\\n nameserver "
    &$executeRemoteCommand "echo -e nameserver $formattedDnsEntries | sudo tee /etc/resolv.conf" 

    Write-Log "Add firewall rules for Kubernetes"
    &$executeRemoteCommand "sudo ufw allow 6443/tcp" 
    &$executeRemoteCommand "sudo ufw allow 2379:2380/tcp" 
    &$executeRemoteCommand "sudo ufw allow 10250/tcp" 
    &$executeRemoteCommand "sudo ufw allow 10259/tcp" 
    &$executeRemoteCommand "sudo ufw allow 10257/tcp" 
    &$executeRemoteCommand "sudo ufw allow 53/udp" 
    &$executeRemoteCommand "sudo ufw allow 53/tcp" 
    &$executeRemoteCommand "sudo ufw allow 9153/tcp" 
}

<#
.SYNOPSIS
Adds an IP address to the Windows host.
.DESCRIPTION
Adds an IP address to the network adapter in the Windows host that links to the Ubuntu OS computer.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
.PARAMETER LocalIpAddress
The IP address to add to the network adapter in the Windows host.
.PARAMETER PrefixLength
A value between 0 and 32 to specify the network part.
#>
function Add-LocalIPAddress {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$LocalIpAddress = $(throw "Argument missing: LocalIpAddress"),
        [ValidateRange(0,32)]
        [int]$PrefixLength = $(throw "Argument missing: PrefixLength")
    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    [string]$gateway = ExecCmdMaster -CmdToExecute "ip route | awk '/default/ {print `$3}'" -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -UsePwd -NoLog

    $interfaceAliasHavingGatewayIPAddress =  Get-NetIPAddress -IPAddress $gateway | Select-Object -ExpandProperty "InterfaceAlias"
    New-NetIPAddress -IPAddress "$LocalIPAddress" -PrefixLength $PrefixLength -InterfaceAlias "$interfaceAliasHavingGatewayIPAddress"
}

<#
.SYNOPSIS
Adds an IP address to the computer with Ubuntu OS.
.DESCRIPTION
Adds an IP address to the network adapter in the computer with Ubuntu OS.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
.PARAMETER RemoteIpAddress
The IP address to add to the network adapter in the computer with Ubuntu OS.
.PARAMETER PrefixLength
A value between 0 and 32 to specify the network part.
.PARAMETER RemoteIpAddressGateway
The IP address to use as gateway in the computer with Ubuntu OS.
.PARAMETER DnsEntries
A comma separated list of DNS addresses.
.PARAMETER NetworkInterfaceName
The name of the network adapter in the computer with Ubuntu OS.
#>
function Add-RemoteIPAddress {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$RemoteIpAddress = $(throw "Argument missing: RemoteIpAddress"),
        [ValidateRange(0,32)]
        [int]$PrefixLength = $(throw "Argument missing: PrefixLength"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$RemoteIpAddressGateway = $(throw "Argument missing: RemoteIpAddressGateway"),
        [string]$DnsEntries = $(throw "Argument missing: DnsEntries"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$NetworkInterfaceName = $(throw "Argument missing: NetworkInterfaceName")
    )

    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { 
        param(
            $command = $(throw "Argument missing: Command"), 
            [switch]$NoLog = $false
            ) 
        if ($NoLog) {
            ExecCmdMaster -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -UsePwd -NoLog
        } else {
            ExecCmdMaster -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -UsePwd
        }
    }

    $networkAddress = "$RemoteIpAddress/$PrefixLength"

    [string]$currentConfiguredIPAddresses = &$executeRemoteCommand "ip -f inet -h address show $NetworkInterfaceName | awk '/inet/ {print `$2}'" -NoLog
    $formattedCurrentConfiguredIPAddresses = $currentConfiguredIPAddresses.Replace(" ",",")
    if (!($formattedCurrentConfiguredIPAddresses.Contains($networkAddress))) {
        $formattedCurrentConfiguredIPAddresses = "$networkAddress,$formattedCurrentConfiguredIPAddresses"

        $configPath = "$PSScriptRoot\Netplank2s.yaml"
        $netplanConfigurationTemplate = Get-Content $configPath

        $netplanConfiguration = $netplanConfigurationTemplate.Replace("__NETWORK_INTERFACE_NAME__",$NetworkInterfaceName).Replace("__NETWORK_ADDRESSES__",$formattedCurrentConfiguredIPAddresses).Replace("__IP_GATEWAY__", $RemoteIpAddressGateway).Replace("__DNS_IP_ADDRESSES__",$DnsEntries)

        &$executeRemoteCommand "echo '' | sudo tee /etc/netplan/k2s.yaml" -NoLog

        foreach ($line in $netplanConfiguration) {
            &$executeRemoteCommand "echo '$line' | sudo tee -a /etc/netplan/k2s.yaml" -NoLog
        }

        &$executeRemoteCommand "sudo netplan apply"
        &$executeRemoteCommand "sudo systemctl restart systemd-networkd"

        [string]$hostname = &$executeRemoteCommand "hostname" -NoLog

        Write-Log "Added network address '$networkAddress' and gateway IP '$RemoteIpAddressGateway' to Linux based computer '$hostname' reachable on IP address '$IpAddress'"
    } else {
        Write-Log "The Linux based computer '$hostname' reachable on IP address '$IpAddress' already contains the network address $networkAddress configured."
    }
}

<#
.SYNOPSIS
Creates a new user in the computer with Ubuntu OS.
.DESCRIPTION
A new user is created and a password is set to it.
.PARAMETER UserName
The user name to log in.
.PARAMETER UserPwd
The password to use to log in.
.PARAMETER IpAddress
The IP address of the computer.
.PARAMETER NewUserName
The user name to create.
.PARAMETER NewUserPwd
The password to set to the user name.
#>
Function New-User {
    param (
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$UserName = $(throw "Argument missing: UserName"),
        [string]$UserPwd = $(throw "Argument missing: UserPwd"),
        [ValidateScript({ Get-IsValidIPv4Address($_) })]
        [string]$IpAddress = $(throw "Argument missing: IpAddress"),
        [ValidateScript({ !([string]::IsNullOrWhiteSpace($_))})]
        [string]$NewUserName = $(throw "Argument missing: NewUserName"),
        [string]$NewUserPwd = $(throw "Argument missing: NewUserPwd")

    )
    $remoteUser = "$UserName@$IpAddress"
    $remoteUserPwd = $UserPwd

    $executeRemoteCommand = { param($command = $(throw "Argument missing: Command")) 
        ExecCmdMaster -CmdToExecute $command -RemoteUser "$remoteUser" -RemoteUserPwd "$remoteUserPwd" -UsePwd
    }

    Write-Log "Create '$newUserName' user"
    &$executeRemoteCommand "sudo useradd -m -c '$newUserName user' -s '/bin/bash' -g users -G users,sudo,adm,netdev $newUserName" 
    &$executeRemoteCommand "echo '$newUserName`:$newUserPwd' | sudo chpasswd" 
    &$executeRemoteCommand "echo '$newUserName ALL=(ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers" 
}

Export-ModuleMember -Function Set-UpComputerWithSpecificOsBeforeProvisioning, Set-UpComputerWithSpecificOsAfterProvisioning, Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode, Add-LocalIPAddress, Add-RemoteIPAddress, New-User

