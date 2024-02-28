# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    . "$PSScriptRoot\..\..\common\GlobalFunctions.ps1"

    $linuxNodeUbuntuModule = "$PSScriptRoot\linuxnode.ubuntu.module.psm1"
    $linuxNodeUbuntuModuleName = (Import-Module $linuxNodeUbuntuModule -PassThru -Force).Name
}

Describe 'Set-UpComputerWithSpecificOsBeforeProvisioning' -Tag 'unit', 'ci', 'linuxnode' {
    BeforeEach {
        $DefaultParameterValues = @{
            UserName  = 'myUserName'
            UserPwd   = 'myUserPwd'
            IpAddress = 'myIpAddress'
        }
    }
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserName')

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserPwd')
 
                # act + assert
                { Set-UpComputerWithSpecificOsBeforeProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('IpAddress')

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; nameToUse = $nameToUse } {
                # arrange
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['UserName'] = $nameToUse

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }
            }
        }
    }
    Context 'execution' {
        It 'performs remote calls in right order' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                $expectedExecutedRemoteCommands = @()
                $expectedExecutedRemoteCommands += "echo 'APT::Periodic::Update-Package-Lists `"0`";' | sudo tee /etc/apt/apt.conf.d/20auto-upgrades" 
                $expectedExecutedRemoteCommands += "echo 'APT::Periodic::Download-Upgradeable-Packages `"0`";' | sudo tee -a /etc/apt/apt.conf.d/20auto-upgrades" 
                $expectedExecutedRemoteCommands += "echo 'APT::Periodic::AutocleanInterval `"0`";' | sudo tee -a /etc/apt/apt.conf.d/20auto-upgrades" 
                $expectedExecutedRemoteCommands += "echo 'APT::Periodic::Unattended-Upgrade `"0`";' | sudo tee -a /etc/apt/apt.conf.d/20auto-upgrades" 
                $expectedExecutedRemoteCommands += 'sudo systemctl disable unattended-upgrades'
                $expectedExecutedRemoteCommands += 'sudo systemctl stop unattended-upgrades'

                $expectedExecutedRemoteCommands += 'sudo swapon --show' 
                $expectedExecutedRemoteCommands += "swapFiles=`$(cat /proc/swaps | awk 'NR>1 {print `$1}')" 
                $expectedExecutedRemoteCommands += 'sudo swapoff -a' 
                $expectedExecutedRemoteCommands += "for swapFile in `$swapFiles; do sudo rm '`$swapFile'; done" 
                $expectedExecutedRemoteCommands += "sudo sed -i '/\sswap\s/d' /etc/fstab" 
                
                $expectedExecutedRemoteCommands += 'sudo add-apt-repository universe' 
            
                $expectedExecutedRemoteCommands += 'sudo DEBIAN_FRONTEND=noninteractive apt update' 
            
                $expectedExecutedRemoteCommands += 'echo Acquire::Check-Valid-Until \\\"false\\\"\; | sudo tee /etc/apt/apt.conf.d/00snapshot' 
                $expectedExecutedRemoteCommands += 'echo Acquire::Max-FutureTime 86400\; | sudo tee -a /etc/apt/apt.conf.d/00snapshot' 
            
                $expectedExecutedRemoteCommands += 'sudo DEBIAN_FRONTEND=noninteractive apt-get install curl --yes' 

                $expectedUser = "$($DefaultParameterValues.UserName)@$($DefaultParameterValues.IpAddress)"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += $CmdToExecute } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $($DefaultParameterValues.UserPwd) -and $UsePwd -eq $true }
                Mock Get-IsValidIPv4Address { $true }
                Mock Write-Log { }

                # act
                Set-UpComputerWithSpecificOsBeforeProvisioning -UserName $DefaultParameterValues.UserName -UserPwd $DefaultParameterValues.UserPwd -IpAddress $DefaultParameterValues.IpAddress

                # assert
                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count

                for ($i = 0; $i -lt $global:actualExecutedRemoteCommands.Count; $i++) {
                    $global:actualExecutedRemoteCommands[$i] | Should -Be $expectedExecutedRemoteCommands[$i]
                }
            }
        }
    }
}

Describe 'Set-UpComputerWithSpecificOsAfterProvisioning' -Tag 'unit', 'ci', 'linuxnode' {
    It 'contains expected parameters' {
        InModuleScope $linuxNodeUbuntuModuleName {
            # arrange
            $expectedUserName = 'myUserName'
            $expectedUserPwd = 'myUserPwd'
            $expectedIpAddress = 'myIpAddress'
            Mock Set-UpComputerWithSpecificOsAfterProvisioning { $global:actualUserName = $UserName; $global:actualUserPwd = $UserPwd; $global:actualIpAddress = $IpAddress; $global:actualProxy = $Proxy }

            # act
            Set-UpComputerWithSpecificOsAfterProvisioning -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress

            # assert
            $global:actualUserName | Should -Be $expectedUserName
            $global:actualUserPwd | Should -Be $expectedUserPwd
            $global:actualIpAddress | Should -Be $expectedIpAddress
        }
    }
}

Describe 'Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode' -Tag 'unit', 'ci', 'linuxnode' {
    BeforeEach {
        $DefaultParameterValues = @{
            UserName   = 'myUserName'
            UserPwd    = 'myUserPwd'
            IpAddress  = 'myIpAddress'
            DnsEntries = 'myDnsEntry1,myDnsEntry2'
        }
    }
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserName')

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserPwd')
 
                # act + assert
                { Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('IpAddress')

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'DnsEntries' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('DnsEntries')

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*DnsEntries*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; nameToUse = $nameToUse } {
                # arrange
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['UserName'] = $nameToUse

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }
            }
        }
    }
    Context 'execution' {
        It 'performs remote calls in right order' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                $expectedExecutedRemoteCommands = @()
                $expectedExecutedRemoteCommands += 'sudo systemctl disable systemd-resolved'
                $expectedExecutedRemoteCommands += 'sudo systemctl stop systemd-resolved' 
                $expectedExecutedRemoteCommands += 'sudo unlink /etc/resolv.conf' 
                $expectedFormattedDnsEntries = $DefaultParameterValues.DnsEntries -replace ',', '\\n nameserver '
                $expectedExecutedRemoteCommands += "echo -e nameserver $expectedFormattedDnsEntries | sudo tee /etc/resolv.conf"
                
                $expectedExecutedRemoteCommands += 'sudo ufw allow 6443/tcp' 
                $expectedExecutedRemoteCommands += 'sudo ufw allow 2379:2380/tcp' 
                $expectedExecutedRemoteCommands += 'sudo ufw allow 10250/tcp' 
                $expectedExecutedRemoteCommands += 'sudo ufw allow 10259/tcp' 
                $expectedExecutedRemoteCommands += 'sudo ufw allow 10257/tcp' 
                $expectedExecutedRemoteCommands += 'sudo ufw allow 53/udp' 
                $expectedExecutedRemoteCommands += 'sudo ufw allow 53/tcp' 
                $expectedExecutedRemoteCommands += 'sudo ufw allow 9153/tcp' 
            
                $expectedUser = "$($DefaultParameterValues.UserName)@$($DefaultParameterValues.IpAddress)"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += $CmdToExecute } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $DefaultParameterValues.UserPwd -and $UsePwd -eq $true }
                Mock Get-IsValidIPv4Address { $true }
                Mock Write-Log { }

                # act
                Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode @DefaultParameterValues

                # assert
                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count

                for ($i = 0; $i -lt $global:actualExecutedRemoteCommands.Count; $i++) {
                    $global:actualExecutedRemoteCommands[$i] | Should -Be $expectedExecutedRemoteCommands[$i]
                }
            }
        }
    }
}

Describe 'Add-LocalIPAddress' -Tag 'unit', 'ci', 'linuxnode' {
    BeforeEach {
        $DefaultParameterValues = @{
            UserName       = 'myUserName'
            UserPwd        = 'myUserPwd'
            IpAddress      = 'myIpAddress'
            LocalIpAddress = 'myLocalIpAddress'
            PrefixLength   = 24
        }
    }
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserName')

                # act + assert
                { Add-LocalIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserPwd')
 
                # act + assert
                { Add-LocalIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('IpAddress')

                # act + assert
                { Add-LocalIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'LocalIpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('LocalIpAddress')

                # act + assert
                { Add-LocalIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*LocalIpAddress*'
            }
        }
        It 'PrefixLength' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('PrefixLength')

                # act + assert
                { Add-LocalIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*PrefixLength*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; nameToUse = $nameToUse } {
                # arrange
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['UserName'] = $nameToUse

                # act + assert
                { Add-LocalIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }

                # act + assert
                { Add-LocalIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }
            }
        }
        It 'LocalIpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.LocalIpAddress }

                # act + assert
                { Add-LocalIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*LocalIpAddress*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.LocalIpAddress }
            }
        }
        It "PrefixLength '<prefixLengthToUse>' throws? '<shallThrow>'" -ForEach @(
            @{ prefixLengthToUse = -1; shallThrow = $true }
            @{ prefixLengthToUse = 0; shallThrow = $false }
            @{ prefixLengthToUse = 32; shallThrow = $false }
            @{ prefixLengthToUse = 33; shallThrow = $true }
        ) {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; prefixLengthToUse = $prefixLengthToUse; shallThrow = $shallThrow } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Add-LocalIPAddress { }
                $DefaultParameterValues['PrefixLength'] = $prefixLengthToUse

                # act + assert
                if ($shallThrow) {
                    { Add-LocalIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*PrefixLength*'
                }
                else {
                    { Add-LocalIPAddress @DefaultParameterValues } | Should -Not -Throw
                }

            }
        }
    }
    Context 'execution' {
        It 'gets gateway IP from remote computer and adds new IP address to network connection of local machine having the IP of the gateway' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                $expectedGatewayIp = 'myGatewayIP'
                $expectedExecutedRemoteCommands = @()
                $expectedExecutedRemoteCommands += "ip route | awk '/default/ {print `$3}'"
            
                $expectedUser = "$($DefaultParameterValues.UserName)@$($DefaultParameterValues.IpAddress)"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += $CmdToExecute; $expectedGatewayIp } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $DefaultParameterValues.UserPwd -and $UsePwd -eq $true -and $NoLog -eq $true }
                Mock Get-IsValidIPv4Address { $true }
                $expectedInterfaceAlias = 'myInterfaceAlias'
                $expectedNetIpAddress = [PSCustomObject]@{
                    InterfaceAlias = $expectedInterfaceAlias
                }
                Mock Get-NetIPAddress { $expectedNetIpAddress } -ParameterFilter { $IPAddress -eq $expectedGatewayIp }
                Mock New-NetIPAddress { }

                # act
                Add-LocalIPAddress @DefaultParameterValues

                # assert
                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count
                $global:actualExecutedRemoteCommands[0] | Should -Be $expectedExecutedRemoteCommands[0]
                
                Should -Invoke -CommandName New-NetIPAddress -Times 1 -ParameterFilter { $IPAddress -eq $DefaultParameterValues.LocalIpAddress -and $PrefixLength -eq $DefaultParameterValues.PrefixLength -and $InterfaceAlias -eq $expectedInterfaceAlias }
            }
        }
    }
}

Describe 'Add-RemoteIPAddress' -Tag 'unit', 'ci', 'linuxnode' {
    BeforeEach {
        $DefaultParameterValues = @{
            UserName               = 'myUserName'
            UserPwd                = 'myUserPwd'
            IpAddress              = 'myIpAddress'
            RemoteIpAddress        = 'myRemoteIpAddress'
            PrefixLength           = 24
            RemoteIpAddressGateway = 'myRemoteIpAddressGateway'
            DnsEntries             = 'myDnsEntry1,myDnsEntry2'
            NetworkInterfaceName   = 'myNetworkInterfaceName'
        }
    }
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserName')

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserPwd')
 
                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('IpAddress')

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'RemoteIpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('RemoteIpAddress')

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*RemoteIpAddress*'
            }
        }
        It 'PrefixLength' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('PrefixLength')

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*PrefixLength*'
            }
        }
        It 'RemoteIpAddressGateway' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('RemoteIpAddressGateway')

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*RemoteIpAddressGateway*'
            }
        }
        It 'DnsEntries' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('DnsEntries')

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*DnsEntries*'
            }
        }
        It 'NetworkInterfaceName' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('NetworkInterfaceName')

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceName*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; nameToUse = $nameToUse } {
                # arrange
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['UserName'] = $nameToUse

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }
            }
        }
        It 'RemoteIpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.RemoteIpAddress }

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*RemoteIpAddress*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.RemoteIpAddress }
            }
        }
        It "PrefixLength '<prefixLengthToUse>' throws? '<shallThrow>'" -ForEach @(
            @{ prefixLengthToUse = -1; shallThrow = $true }
            @{ prefixLengthToUse = 0; shallThrow = $false }
            @{ prefixLengthToUse = 32; shallThrow = $false }
            @{ prefixLengthToUse = 33; shallThrow = $true }
        ) {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; prefixLengthToUse = $prefixLengthToUse; shallThrow = $shallThrow } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Add-RemoteIPAddress { }
                $DefaultParameterValues['PrefixLength'] = $prefixLengthToUse

                # act + assert
                if ($shallThrow) {
                    { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*PrefixLength*'
                }
                else {
                    { Add-RemoteIPAddress @DefaultParameterValues } | Should -Not -Throw
                }

            }
        }
        It 'RemoteIpAddressGateway' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.RemoteIpAddressGateway }

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*RemoteIpAddressGateway*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.RemoteIpAddressGateway }
            }
        }
        It 'NetworkInterfaceName' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('NetworkInterfaceName')

                # act + assert
                { Add-RemoteIPAddress @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceName*'
            }
        }
    }
}

Describe 'New-User' -Tag 'unit', 'ci', 'linuxnode' {
    BeforeEach {
        $DefaultParameterValues = @{
            UserName    = 'myUserName'
            UserPwd     = 'myUserPwd'
            IpAddress   = 'myIpAddress'
            NewUserName = 'myNewUserName'
            NewUserPwd  = 'myNewUserPwd'
        }
    }
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserName')

                # act + assert
                { New-User @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserPwd')
 
                # act + assert
                { New-User @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('IpAddress')

                # act + assert
                { New-User @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'NewUserName' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('NewUserName')

                # act + assert
                { New-User @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*NewUserName*'
            }
        }
        It 'NewUserPwd' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('NewUserPwd')
 
                # act + assert
                { New-User @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*NewUserPwd*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; nameToUse = $nameToUse } {
                # arrange
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['UserName'] = $nameToUse

                # act + assert
                { New-User @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }

                # act + assert
                { New-User @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }
            }
        }
        It "NewUserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; nameToUse = $nameToUse } {
                # arrange
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['NewUserName'] = $nameToUse

                # act + assert
                { New-User @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*NewUserName*'
            }
        }
    }
    Context 'execution' {
        It 'creates new account' {
            InModuleScope $linuxNodeUbuntuModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                $expectedExecutedRemoteCommands = @()
                $expectedExecutedRemoteCommands += "sudo useradd -m -c '$($DefaultParameterValues.NewUserName) user' -s '/bin/bash' -g users -G users,sudo,adm,netdev $($DefaultParameterValues.NewUserName)" 
                $expectedExecutedRemoteCommands += "echo '$($DefaultParameterValues.NewUserName)`:$($DefaultParameterValues.NewUserPwd)' | sudo chpasswd" 
                $expectedExecutedRemoteCommands += "echo '$($DefaultParameterValues.NewUserName) ALL=(ALL) NOPASSWD:ALL' | sudo tee -a /etc/sudoers"
                
                $expectedUser = "$($DefaultParameterValues.UserName)@$($DefaultParameterValues.IpAddress)"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += $CmdToExecute } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $($DefaultParameterValues.UserPwd) -and $UsePwd -eq $true }
                Mock Get-IsValidIPv4Address { $true }
                Mock Write-Log { }

                # act
                New-User @DefaultParameterValues

                # assert
                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count

                for ($i = 0; $i -lt $global:actualExecutedRemoteCommands.Count; $i++) {
                    $global:actualExecutedRemoteCommands[$i] | Should -Be $expectedExecutedRemoteCommands[$i]
                }
            }
        }
    }
}
