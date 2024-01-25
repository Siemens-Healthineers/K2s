# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    . "$PSScriptRoot\..\..\common\GlobalFunctions.ps1"

    $validationModule = "$PSScriptRoot\..\..\..\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
    $validationModuleName = (Import-Module $validationModule -PassThru -Force).Name

    $linuxNodeModule = "$PSScriptRoot\..\linuxnode.module.psm1"
    $linuxNodeModuleName = (Import-Module $linuxNodeModule -PassThru -Force).Name

    $linuxNodeUbuntuModule = "$PSScriptRoot\linuxnode.ubuntu.module.psm1"
    $linuxNodeUbuntuModuleName = (Import-Module $linuxNodeUbuntuModule -PassThru -Force).Name
}

Describe 'ExistingUbuntuComputerAsMasterNodeInstaller.ps1' -Tag 'unit', 'linuxnode' {
    BeforeAll {
        $scriptFile = "$PSScriptRoot\ExistingUbuntuComputerAsMasterNodeInstaller.ps1"
    }
    BeforeEach {
        $DefaultParameterValues = @{
            UserName = 'myUserName'
            UserPwd = 'myUserPwd'
            IpAddress = 'myIpAddress'
            Proxy = 'myProxy'
        }
    }
    Context "parameter's existence" {
        It 'UserName' {
            # arrange
            Mock Get-IsValidIPv4Address { $true }
            $DefaultParameterValues.Remove('UserName')

            # act + assert
            { Invoke-Expression -Command "$scriptFile @DefaultParameterValues" } | Get-ExceptionMessage | Should -BeLike '*UserName*'
        }
        It 'UserPwd' {
            # arrange
            Mock Get-IsValidIPv4Address { $true }
            $DefaultParameterValues.Remove('UserPwd')
            
            # act + assert
            { Invoke-Expression -Command "$scriptFile @DefaultParameterValues" } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
        }
        It 'IpAddress' {
              # arrange
              Mock Get-IsValidIPv4Address { $true }
              $DefaultParameterValues.Remove('IpAddress')

             # act + assert
             { Invoke-Expression -Command "$scriptFile @DefaultParameterValues" } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            # arrange
            if ($nameToUse -eq 'null') {
                $nameToUse = $null
            }
            Mock Get-IsValidIPv4Address { $true }
            $DefaultParameterValues['UserName'] = $nameToUse

            # act + assert
            { Invoke-Expression -Command "$scriptFile @DefaultParameterValues" } | Get-ExceptionMessage | Should -BeLike '*UserName*'
        }
    }
    Context 'execution' {
        It "performs set-up using proxy '<proxyToUse>'" -ForEach @(
            @{ proxyToUse = 'useDefaultValue' }
            @{ proxyToUse = '' }
            @{ proxyToUse = 'anyValue' }
        ) {
            # arrange
            if ($proxyToUse -eq 'useDefaultValue') {
                $DefaultParameterValues.Remove('Proxy')
                $expectedProxy = ''
            } else {
                $DefaultParameterValues['Proxy'] = $proxyToUse
                $expectedProxy = $proxyToUse
            }
            $expectedNewUserName = 'remote'
            $expectedNewUserPwd = 'admin'
            $expectedK8sVersion = 'v1.25.13'
            $expectedCrioVersion = '1.25.2'
            $expectedDnsIpAddresses = 'myDnsIpAddress1,myDnsIpAddress2'
            $expectedPrefixLength = '24'
            $expectedLocalIpAddress = '172.19.1.1'
            $expectedRemoteIpAddress = '172.19.1.100'
            $expectedRemoteIpAddressGateway = '172.19.1.1'
            $expectedNetworkInterfaceName = 'eth0'
            $expectedClusterCIDR = '172.20.0.0/16'
            $expectedClusterCIDR_Services = '172.21.0.0/16'
            $expectedKubeDnsServiceIP = '172.21.0.10'
            $expectedIP_NextHop = '172.19.1.1'
            $expectedNetworkInterfaceCni0IP_Master = '172.20.0.1'
            $expectedHook = { }
            $expectedPrivateKeyPath = $global:LinuxVMKey
            $expectedPublicKeyPath = "$expectedPrivateKeyPath.pub"
            $expectedHostname = 'myHostname'

            $expectedRemoteUser = "$($DefaultParameterValues.UserName)@$($DefaultParameterValues.IpAddress)"
            $expectedNewRemoteUser = "$expectedNewUserName@$expectedRemoteIpAddress"
            $global:actualMethodCallSequence = @()
            Mock Get-IsValidIPv4Address { $true }
            Mock Write-Log { }
            Mock Wait-ForSshPossible { $global:actualMethodCallSequence += 'Wait-ForSshPossible' } -ParameterFilter { $RemoteUser -eq $expectedRemoteUser -and $RemotePwd -eq $($DefaultParameterValues.UserPwd) -and $SshTestCommand -eq 'which ls' -and $ExpectedSshTestCommandResult -eq '/usr/bin/ls' }
            Mock New-User { $global:actualMethodCallSequence += 'New-User' } -ParameterFilter { $UserName -eq $($DefaultParameterValues.UserName) -and $UserPwd -eq $($DefaultParameterValues.UserPwd) -and $IpAddress -eq $($DefaultParameterValues.IpAddress) -and $NewUserName -eq $expectedNewUserName -and $NewUserPwd -eq $expectedNewUserPwd }
            Mock New-KubernetesNode { $global:actualMethodCallSequence += 'New-KubernetesNode' } -ParameterFilter { $UserName -eq $expectedNewUserName -and $UserPwd -eq $expectedNewUserPwd -and $IpAddress -eq $($DefaultParameterValues.IpAddress) -and $K8sVersion -eq $expectedK8sVersion -and $CrioVersion -eq $expectedCrioVersion -and $Proxy -eq $expectedProxy }
            Mock Install-Tools { $global:actualMethodCallSequence += 'Install-Tools' } -ParameterFilter { $UserName -eq $expectedNewUserName -and $UserPwd -eq $expectedNewUserPwd -and $IpAddress -eq $($DefaultParameterValues.IpAddress) -and $Proxy -eq $expectedProxy }
            Mock Find-DnsIpAddress { $global:actualMethodCallSequence += 'Find-DnsIpAddress'; $expectedDnsIpAddresses } 
            Mock Add-LocalIPAddress {  $global:actualMethodCallSequence += 'Add-LocalIPAddress' } -ParameterFilter { $UserName -eq $expectedNewUserName -and $UserPwd -eq $expectedNewUserPwd -and $IpAddress -eq $($DefaultParameterValues.IpAddress) -and $LocalIpAddress -eq $expectedLocalIpAddress -and $PrefixLength -eq $expectedPrefixLength }
            Mock Add-RemoteIPAddress {  $global:actualMethodCallSequence += 'Add-RemoteIPAddress' } -ParameterFilter { $UserName -eq $expectedNewUserName -and $UserPwd -eq $expectedNewUserPwd -and $IpAddress -eq $($DefaultParameterValues.IpAddress) -and $RemoteIpAddress -eq $expectedRemoteIpAddress -and $PrefixLength -eq $expectedPrefixLength -and $RemoteIpAddressGateway -eq $expectedRemoteIpAddressGateway -and $DnsEntries -eq $expectedDnsIpAddresses -and $NetworkInterfaceName -eq $expectedNetworkInterfaceName }
            Mock Wait-ForSSHConnectionToLinuxVMViaPwd { $global:actualMethodCallSequence += 'Wait-ForSSHConnectionToLinuxVMViaPwd' }
            Mock Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode { $global:actualMethodCallSequence += 'Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode' } -ParameterFilter { $UserName -eq $expectedNewUserName -and $UserPwd -eq $expectedNewUserPwd -and $IpAddress -eq $($DefaultParameterValues.IpAddress) -and $DnsEntries -eq $expectedDnsIpAddresses }
            Mock Set-UpMasterNode { $global:actualMethodCallSequence += 'Set-UpMasterNode' } -ParameterFilter { $UserName -eq $expectedNewUserName -and $UserPwd -eq $expectedNewUserPwd -and $IpAddress -eq $($DefaultParameterValues.IpAddress) -and $K8sVersion -eq $expectedK8sVersion -and $ClusterCIDR -eq $expectedClusterCIDR -and $ClusterCIDR_Services -eq $expectedClusterCIDR_Services -and $KubeDnsServiceIP -eq $expectedKubeDnsServiceIP -and $IP_NextHop -eq $expectedIP_NextHop -and $NetworkInterfaceName -eq $expectedNetworkInterfaceName -and $NetworkInterfaceCni0IP_Master -eq $expectedNetworkInterfaceCni0IP_Master }
            Mock Remove-SshKeyFromKnownHostsFile { $global:actualMethodCallSequence += 'Remove-SshKeyFromKnownHostsFile' } -ParameterFilter { $IpAddress -eq $expectedRemoteIpAddress}
            Mock New-SshKeyPair { $global:actualMethodCallSequence += 'New-SshKeyPair' } -ParameterFilter { $PrivateKeyPath -eq $expectedPrivateKeyPath }
            Mock Copy-LocalPublicSshKeyToRemoteComputer { $global:actualMethodCallSequence += 'Copy-LocalPublicSshKeyToRemoteComputer' } -ParameterFilter { $UserName -eq $expectedNewUserName -and $UserPwd -eq $expectedNewUserPwd -and $IpAddress -eq $expectedRemoteIpAddress -and $LocalPublicKeyPath -eq $expectedPublicKeyPath }
            Mock Wait-ForSSHConnectionToLinuxVMViaSshKey { $global:actualMethodCallSequence += 'Wait-ForSSHConnectionToLinuxVMViaSshKey' }
            Mock ExecCmdMaster { $global:actualMethodCallSequence += 'ExecCmdMaster 1'; $expectedHostname } -ParameterFilter { $CmdToExecute -eq 'hostname' -and $NoLog -eq $true }
            Mock Save-ControlPlaneNodeHostname { $global:actualMethodCallSequence += 'Save-ControlPlaneNodeHostname'}
            Mock ExecCmdMaster { $global:actualMethodCallSequence += 'ExecCmdMaster 2' } -ParameterFilter { $CmdToExecute -eq 'echo reboot still pending | tee /tmp/rebootPending' }
            Mock ExecCmdMaster { $global:actualMethodCallSequence += 'ExecCmdMaster 3' } -ParameterFilter { $CmdToExecute -eq 'sudo reboot' }
            Mock Wait-ForSshPossible { $global:actualMethodCallSequence += 'Wait-ForSshPossible' } -ParameterFilter { $RemoteUser -eq $expectedNewRemoteUser -and $RemotePwd -eq $expectedNewUserPwd -and $SshTestCommand -eq 'cat /tmp/rebootPending' -and $ExpectedSshTestCommandResult -eq 'cat: /tmp/rebootPending: No such file or directory'}

            # act
            Invoke-Expression -Command "$scriptFile @DefaultParameterValues"

            # assert
            $expectedMethodCallSequence = @(
                'Wait-ForSshPossible'
                'New-User'
                'New-KubernetesNode'
                'Install-Tools'
                'Find-DnsIpAddress'
                'Add-LocalIPAddress'
                'Add-RemoteIPAddress'
                'Wait-ForSSHConnectionToLinuxVMViaPwd'
                'Set-UpComputerWithSpecificOsBeforeConfiguringAsMasterNode'
                'Set-UpMasterNode'
                'Remove-SshKeyFromKnownHostsFile'
                'New-SshKeyPair' 
                'Copy-LocalPublicSshKeyToRemoteComputer'
                'Wait-ForSSHConnectionToLinuxVMViaSshKey'
                'ExecCmdMaster 1'
                'Save-ControlPlaneNodeHostname'
                'ExecCmdMaster 2' 
                'ExecCmdMaster 3' 
                'Wait-ForSshPossible'
                )
            $global:actualMethodCallSequence | Should -Be $expectedMethodCallSequence

        }
    }
}    