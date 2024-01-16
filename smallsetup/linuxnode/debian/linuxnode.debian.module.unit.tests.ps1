# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    . "$PSScriptRoot\..\..\common\GlobalFunctions.ps1"

    $linuxNodeDebianModule = "$PSScriptRoot\linuxnode.debian.module.psm1"
    $linuxNodeDebianModuleName = (Import-Module $linuxNodeDebianModule -PassThru -Force).Name
}

Describe 'Set-UpComputerWithSpecificOsBeforeProvisioning' -Tag 'unit', 'linuxnode' {
    BeforeEach {
        $DefaultParameterValues = @{
            UserName = 'myUserName'
            UserPwd = 'myUserPwd'
            IpAddress = 'myIpAddress'
        }
    }
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserName')

                # act + assert
                { Set-UpComputerWithSpecificOsBeforeProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                 # arrange
                 Mock Get-IsValidIPv4Address { $true }
                 $DefaultParameterValues.Remove('UserPwd')
 
                 # act + assert
                { Set-UpComputerWithSpecificOsBeforeProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
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
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; nameToUse = $nameToUse } {
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
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
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
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                class ActualRemoteCommand {
                    [string]$Command
                    [bool]$IgnoreErrors
                }
                $expectedExecutedRemoteCommands = @()
                $expectedExecutedRemoteCommands += @{Command = "sudo touch /etc/cloud/cloud-init.disabled"; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "sudo update-grub"; IgnoreErrors = $true }
                if ($PSVersionTable.PSVersion.Major -gt 5) {
                    $expectedExecutedRemoteCommands += @{Command = 'echo Acquire::Check-Valid-Until \"false\"\; | sudo tee /etc/apt/apt.conf.d/00snapshot' ; IgnoreErrors = $false }
                } else {
                    $expectedExecutedRemoteCommands += @{Command = 'echo Acquire::Check-Valid-Until \\\"false\\\"\; | sudo tee /etc/apt/apt.conf.d/00snapshot' ; IgnoreErrors = $false }
                }
                $expectedExecutedRemoteCommands += @{Command = 'echo Acquire::Max-FutureTime 86400\; | sudo tee -a /etc/apt/apt.conf.d/00snapshot' ; IgnoreErrors = $false }

                $expectedUserName = 'theUser'
                $expectedUserPwd = 'thePwd'
                $expectedIpAddress = 'myIpAddress'
                $expectedUser = "$expectedUserName@$expectedIpAddress"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += (New-Object ActualRemoteCommand -Property @{Command = $CmdToExecute; IgnoreErrors = $IgnoreErrors }) } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }
                Mock Get-IsValidIPv4Address { $true }
                Mock Wait-ForSSHConnectionToLinuxVMViaPwd { }
                Mock Write-Log { }

                # act
                Set-UpComputerWithSpecificOsBeforeProvisioning -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress

                # assert
                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count

                for ($i = 0; $i -lt $global:actualExecutedRemoteCommands.Count; $i++) {
                    $global:actualExecutedRemoteCommands[$i].Command | Should -Be $expectedExecutedRemoteCommands[$i].Command
                    $global:actualExecutedRemoteCommands[$i].IgnoreErrors | Should -Be $expectedExecutedRemoteCommands[$i].IgnoreErrors
                }

                Should -Invoke -CommandName Wait-ForSSHConnectionToLinuxVMViaPwd -Times 1 -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd }
            }
        }
    }
}

Describe 'Set-UpComputerWithSpecificOsAfterProvisioning' -Tag 'unit', 'linuxnode' {
    BeforeEach {
        $DefaultParameterValues = @{
            UserName = 'myUserName'
            UserPwd = 'myUserPwd'
            IpAddress = 'myIpAddress'
        }
    }
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserName')

                # act + assert
                { Set-UpComputerWithSpecificOsAfterProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                 # arrange
                 Mock Get-IsValidIPv4Address { $true }
                 $DefaultParameterValues.Remove('UserPwd')
 
                 # act + assert
                { Set-UpComputerWithSpecificOsAfterProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('IpAddress')

                # act + assert
               { Set-UpComputerWithSpecificOsAfterProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; nameToUse = $nameToUse } {
                # arrange
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['UserName'] = $nameToUse

                # act + assert
                { Set-UpComputerWithSpecificOsAfterProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }

                # act + assert
                { Set-UpComputerWithSpecificOsAfterProvisioning @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }
            }
        }
    }
    Context 'execution' {
        It 'performs remote calls in right order' {
            InModuleScope $linuxNodeDebianModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                $expectedExecutedRemoteCommands = @('sudo cloud-init clean')

                $expectedUserName = 'theUser'
                $expectedUserPwd = 'thePwd'
                $expectedIpAddress = 'myIpAddress'
                $expectedUser = "$expectedUserName@$expectedIpAddress"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += 'sudo cloud-init clean' } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }
                Mock Get-IsValidIPv4Address { $true }

                # act
                Set-UpComputerWithSpecificOsAfterProvisioning -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress

                # assert
                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count
                $global:actualExecutedRemoteCommands[0] | Should -Be $expectedExecutedRemoteCommands[0]
            }
        }
    }
}
