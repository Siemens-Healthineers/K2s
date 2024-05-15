# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    . "$PSScriptRoot\..\common\GlobalFunctions.ps1"

    # $validationModule = "$PSScriptRoot\..\..\lib\modules\k2s\k2s.infra.module\validation\validation.module.psm1"
    # $validationModuleName = (Import-Module $validationModule -PassThru -Force).Name

    $linuxNodeModule = "$PSScriptRoot\linuxnode.module.psm1"
    $linuxNodeModuleName = (Import-Module $linuxNodeModule -PassThru -Force).Name
}

Describe 'Assert-GeneralComputerPrequisites' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { Assert-GeneralComputerPrequisites } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { Assert-GeneralComputerPrequisites -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { Assert-GeneralComputerPrequisites -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { Assert-GeneralComputerPrequisites -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { Assert-GeneralComputerPrequisites -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
    }
    Context 'hostname value' {
        It "with value '<retrievedHostname>' throws? <shouldThrow>" -ForEach @(
            @{ retrievedHostname = 'thenameofthehost'; shouldThrow = $false }
            @{ retrievedHostname = 'thenaMEofthehost'; shouldThrow = $true }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ retrievedHostname = $retrievedHostname; shouldThrow = $shouldThrow } {
                $expectedUserName = 'theUser'
                $expectedUserPwd = 'thePwd'
                $expectedIpAddress = 'myIpAddress'
                $expectedUser = "$expectedUserName@$expectedIpAddress"
                $expectedCommand = 'hostname'
                Mock Get-IsValidIPv4Address { $true }
                Mock ExecCmdMaster { return $retrievedHostname } -ParameterFilter { $CmdToExecute -eq $expectedCommand -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true -and $NoLog -eq $true }
                Mock Write-Log { }

                if ($shouldThrow) {
                    { Assert-GeneralComputerPrequisites -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress } | Get-ExceptionMessage | Should -BeLike "*The hostname '$retrievedHostname'*"
                }
                else {
                    { Assert-GeneralComputerPrequisites -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress } | Should -Not -Throw
                }
            }
        }
        It "with value '<retrievedHostname>' throws" -ForEach @(
            @{ retrievedHostname = '' }
            @{ retrievedHostname = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ retrievedHostname = $retrievedHostname } {
                $expectedIpAddress = 'myIpAddress'
                Mock Get-IsValidIPv4Address { $true }
                Mock ExecCmdMaster { $retrievedHostname }
                Mock Write-Log { }

                { Assert-GeneralComputerPrequisites -UserName 'theUser' -UserPwd 'thePwd' -IpAddress $expectedIpAddress } | Get-ExceptionMessage | Should -BeLike "*The hostname of the computer with IP '$expectedIpAddress'*"
            }
        }
    }
}

Describe 'Assert-MasterNodeComputerPrequisites' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { Assert-MasterNodeComputerPrequisites } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { Assert-MasterNodeComputerPrequisites -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { Assert-MasterNodeComputerPrequisites -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { Assert-MasterNodeComputerPrequisites -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { Assert-MasterNodeComputerPrequisites -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
    }
    Context 'number of cores' {
        It "equals '<numberOfCores>' throws? <shouldThrow>" -ForEach @(
            @{ numberOfCores = 1; shouldThrow = $true }
            @{ numberOfCores = 2; shouldThrow = $false }
            @{ numberOfCores = 3; shouldThrow = $false }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ numberOfCores = $numberOfCores; shouldThrow = $shouldThrow } {
                $expectedUserName = 'theUser'
                $expectedUserPwd = 'thePwd'
                $expectedIpAddress = 'myIpAddress'
                $expectedUser = "$expectedUserName@$expectedIpAddress"
                Mock Get-IsValidIPv4Address { $true }
                Mock ExecCmdMaster { return $numberOfCores } -ParameterFilter { $CmdToExecute -eq 'nproc' -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true -and $NoLog -eq $true }
                Mock Write-Log { }

                if ($shouldThrow) {
                    { Assert-MasterNodeComputerPrequisites -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress } | Get-ExceptionMessage | Should -BeLike "*The computer reachable on IP '$expectedIpAddress' does not has at least 2 cores*"
                }
                else {
                    { Assert-MasterNodeComputerPrequisites -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress } | Should -Not -Throw
                }
            }
        }
    }
}

Describe 'Set-UpComputerBeforeProvisioning' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { Set-UpComputerBeforeProvisioning } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { Set-UpComputerBeforeProvisioning -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { Set-UpComputerBeforeProvisioning -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { Set-UpComputerBeforeProvisioning -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { Set-UpComputerBeforeProvisioning -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
    }
    Context 'proxy value' {
        It "'<proxyValue>' is applied? <shouldApply>" -ForEach @(
            @{ proxyValue = ''; shouldApply = $false }
            @{ proxyValue = 'aProxyValue'; shouldApply = $true }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ proxyValue = $proxyValue; shouldApply = $shouldApply } {
                $expectedUserName = 'theUser'
                $expectedUserPwd = 'thePwd'
                $expectedIpAddress = 'myIpAddress'
                $expectedUser = "$expectedUserName@$expectedIpAddress"
                $global:callOrder = @()
                Mock Get-IsValidIPv4Address { $true }
                Mock ExecCmdMaster { $global:callorder += '1' } -ParameterFilter { $CmdToExecute -eq 'sudo touch /etc/apt/apt.conf.d/proxy.conf' -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }
                if ($PSVersionTable.PSVersion.Major -gt 5) {
                    Mock ExecCmdMaster { $global:callorder += '2-PSversion>5' } -ParameterFilter { $CmdToExecute -eq "echo Acquire::http::Proxy \""$proxyValue\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }
                }
                else {
                    Mock ExecCmdMaster { $global:callorder += '2-PSversion<=5' } -ParameterFilter { $CmdToExecute -eq "echo Acquire::http::Proxy \\\""$proxyValue\\\""\; | sudo tee -a /etc/apt/apt.conf.d/proxy.conf" -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }
                }
                Mock Write-Log { }

                Set-UpComputerBeforeProvisioning -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress -Proxy $proxyValue 

                if ($shouldApply) {
                    $expectedCallOrder = @('1')
                    if ($PSVersionTable.PSVersion.Major -gt 5) {
                        $expectedCallOrder += @('2-PSversion>5')
                    }
                    else {
                        $expectedCallOrder += @('2-PSversion<=5')
                    }
                    $global:callOrder | Should -Be $expectedCallOrder
                }
                else {
                    Should -Invoke -CommandName ExecCmdMaster -Times 0
                }
            }
        }
        It 'not specified in command then no proxy is set' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }
                Mock ExecCmdMaster { } 
                Mock Write-Log { }

                Set-UpComputerBeforeProvisioning -UserName 'theUser' -UserPwd 'thePwd' -IpAddress 'myIpAddress'

                Should -Invoke -CommandName ExecCmdMaster -Times 0
            }
        }
    }
}

Describe 'Set-UpComputerAfterProvisioning' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { Set-UpComputerAfterProvisioning } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { Set-UpComputerAfterProvisioning -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { Set-UpComputerAfterProvisioning -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { Set-UpComputerAfterProvisioning -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { Set-UpComputerAfterProvisioning -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
    }
    Context 'execution' {
        BeforeAll {
            $expectedUserName = 'theUser'
            $expectedUserPwd = 'thePwd'
            $expectedIpAddress = 'myIpAddress'
            Mock -ModuleName $linuxNodeModuleName Get-IsValidIPv4Address { $true }
            Mock -ModuleName $linuxNodeModuleName ExecCmdMaster { }
            Mock -ModuleName $linuxNodeModuleName CopyDotFile { }
            Mock -ModuleName $linuxNodeModuleName Write-Log { }
        }
        It 'copies dot files' {
            InModuleScope $linuxNodeModuleName -Parameters @{ expectedUserName = $expectedUserName; expectedUserPwd = $expectedUserPwd; expectedIpAddress = $expectedIpAddress } {
                $expectedUser = "$expectedUserName@$expectedIpAddress"
                $expectedDotFileLocation = "$global:KubernetesPath\smallsetup\linuxnode\..\common\dotfiles\"
                $expectedDotFiles = @('.inputrc', '.bash_kubectl', '.bash_docker', '.bash_aliases')

                Set-UpComputerAfterProvisioning -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress

                foreach ($expectedDotFile in $expectedDotFiles) {
                    Should -Invoke -CommandName CopyDotFile -Times 1 -ParameterFilter { $SourcePath -eq $expectedDotFileLocation -and $DotFile -eq $expectedDotFile -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd }
                }
            }
        }
        It 'sets local time zone' {
            InModuleScope $linuxNodeModuleName -Parameters @{ expectedUserName = $expectedUserName; expectedUserPwd = $expectedUserPwd; expectedIpAddress = $expectedIpAddress } {
                $expectedUser = "$expectedUserName@$expectedIpAddress"

                Set-UpComputerAfterProvisioning -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress
                
                Should -Invoke -CommandName ExecCmdMaster -Times 1 -ParameterFilter { $CmdToExecute -eq 'sudo timedatectl set-timezone Europe/Berlin' -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd }
            }
        }
        It 'enables hushlogin' {
            InModuleScope $linuxNodeModuleName -Parameters @{ expectedUserName = $expectedUserName; expectedUserPwd = $expectedUserPwd; expectedIpAddress = $expectedIpAddress } {
                $expectedUser = "$expectedUserName@$expectedIpAddress"

                Set-UpComputerAfterProvisioning -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress
                
                Should -Invoke -CommandName ExecCmdMaster -Times 1 -ParameterFilter { $CmdToExecute -eq 'touch ~/.hushlogin' -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd }
            }
        }
    }
}

Describe 'Install-KubernetesArtifacts' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { Install-KubernetesArtifacts } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { Install-KubernetesArtifacts -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { Install-KubernetesArtifacts -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'K8sVersion' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Install-KubernetesArtifacts -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*K8sVersion*'
            }
        }
        It 'CrioVersion' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Install-KubernetesArtifacts -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyK8sVersion' } | Get-ExceptionMessage | Should -BeLike '*CrioVersion*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { Install-KubernetesArtifacts -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { Install-KubernetesArtifacts -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
        It "K8sVersion '<k8sVersionToUse>'" -ForEach @(
            @{ k8sVersionToUse = 'null' }
            @{ k8sVersionToUse = '' }
            @{ k8sVersionToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ k8sVersionToUse = $k8sVersionToUse } {
                if ($k8sVersionToUse -eq 'null') {
                    $k8sVersionToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }

                { Install-KubernetesArtifacts -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion $k8sVersionToUse } | Get-ExceptionMessage | Should -BeLike '*K8sVersion*'
            }
        }
        It "CrioVersion '<crioVersionToUse>'" -ForEach @(
            @{ crioVersionToUse = 'null' }
            @{ crioVersionToUse = '' }
            @{ crioVersionToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ crioVersionToUse = $crioVersionToUse } {
                if ($crioVersionToUse -eq 'null') {
                    $crioVersionToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                
                { Install-KubernetesArtifacts -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyK8sVersion' -CrioVersion $crioVersionToUse } | Get-ExceptionMessage | Should -BeLike '*CrioVersion*'
            }
        }
    }
    Context 'perfoms installation' {
        It "with proxy '<proxyToUse>'" -ForEach @(
            @{ proxyToUse = '' }
            @{ proxyToUse = 'myProxy' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ proxyToUse = $proxyToUse } {
                $expectedCrioVersion = 'myCrioVersion'
                $expectedK8sVersion = 'vK8sMajorNumber.K8sMinorNumber.K8sBuildNumber'
                $expectedPackageShortK8sVersion = 'vK8sMajorNumber.K8sMinorNumber'
                $expectedShortK8sVersion = 'K8sMajorNumber.K8sMinorNumber.K8sBuildNumber-1.1'
                $expectedUserName = 'theUser'
                $expectedUserPwd = 'thePwd'
                $expectedIpAddress = 'myIpAddress'
                Mock Get-IsValidIPv4Address { $true }
                Mock InstallAptPackages { }
                Mock Write-Log { }
                class ActualRemoteCommand {
                    [string]$Command
                    [bool]$IgnoreErrors
                }
                if ($proxyToUse -ne '') {
                    $curlProxy = " --proxy $proxyToUse"
                }
                else {
                    $curlProxy = ''
                }

                $expectedExecutedRemoteCommands = @()
                $expectedExecutedRemoteCommands += @{Command = 'echo overlay | sudo tee /etc/modules-load.d/k8s.conf'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'echo br_netfilter | sudo tee /etc/modules-load.d/k8s.conf'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'sudo modprobe overlay'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'sudo modprobe br_netfilter'; IgnoreErrors = $false }

                $expectedExecutedRemoteCommands += @{Command = 'echo net.bridge.bridge-nf-call-ip6tables = 1 | sudo tee -a /etc/sysctl.d/k8s.conf'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'echo net.bridge.bridge-nf-call-iptables = 1 | sudo tee -a /etc/sysctl.d/k8s.conf'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'echo net.ipv4.ip_forward = 1 | sudo tee -a /etc/sysctl.d/k8s.conf'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'sudo sysctl --system'; IgnoreErrors = $false }

                $expectedExecutedRemoteCommands += @{Command = 'echo @reboot root mount --make-rshared / | sudo tee /etc/cron.d/sharedmount'; IgnoreErrors = $false }

                $expectedExecutedRemoteCommands += @{Command = 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes --allow-releaseinfo-change'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gpg'; IgnoreErrors = $false }

                $expectedExecutedRemoteCommands += @{Command = "sudo curl --retry 3 --retry-all-errors -so cri-o.v$expectedCrioVersion.tar.gz https://storage.googleapis.com/cri-o/artifacts/cri-o.amd64.v$expectedCrioVersion.tar.gz$curlProxy"; IgnoreErrors = $true }
                $expectedExecutedRemoteCommands += @{Command = 'sudo mkdir -p /usr/cri-o'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "sudo tar -xf cri-o.v$expectedCrioVersion.tar.gz -C /usr/cri-o --strip-components=1"; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'cd /usr/cri-o/ && sudo ./install 2>&1'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "sudo rm cri-o.v$expectedCrioVersion.tar.gz"; IgnoreErrors = $false }

                $expectedExecutedRemoteCommands += @{Command = "grep timeout.* /etc/crictl.yaml | sudo sed -i 's/timeout.*/timeout: 30/g' /etc/crictl.yaml"; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "grep timeout.* /etc/crictl.yaml || echo timeout: 30 | sudo tee -a /etc/crictl.yaml"; IgnoreErrors = $false }
                
                if ($proxyToUse -ne '') {
                    $expectedExecutedRemoteCommands += @{Command = 'sudo mkdir -p /etc/systemd/system/crio.service.d'; IgnoreErrors = $false } 
                    $expectedExecutedRemoteCommands += @{Command = 'sudo touch /etc/systemd/system/crio.service.d/http-proxy.conf' ; IgnoreErrors = $false } 
                    $expectedExecutedRemoteCommands += @{Command = 'echo [Service] | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf' ; IgnoreErrors = $false } 
                    $expectedExecutedRemoteCommands += @{Command = "echo Environment=\'HTTP_PROXY=$proxyToUse\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" ; IgnoreErrors = $false } 
                    $expectedExecutedRemoteCommands += @{Command = "echo Environment=\'HTTPS_PROXY=$proxyToUse\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" ; IgnoreErrors = $false } 
                    $expectedExecutedRemoteCommands += @{Command = "echo Environment=\'http_proxy=$proxyToUse\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" ; IgnoreErrors = $false } 
                    $expectedExecutedRemoteCommands += @{Command = "echo Environment=\'https_proxy=$proxyToUse\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf" ; IgnoreErrors = $false } 
                    $expectedExecutedRemoteCommands += @{Command = "echo Environment=\'no_proxy=.local\' | sudo tee -a /etc/systemd/system/crio.service.d/http-proxy.conf"; IgnoreErrors = $false } 
                }
                $token = Get-RegistryToken
                if ($PSVersionTable.PSVersion.Major -gt 5) {
                    $jsonConfig = @{
                        'auths' = @{
                            'shsk2s.azurecr.io' = @{
                                'auth' = "$token"
                            }
                        }
                    }
                }
                else {
                    $jsonConfig = @{
                        '"auths"' = @{
                            '"shsk2s.azurecr.io"' = @{
                                '"auth"' = """$token"""
                            }
                        }
                    }
                }
                
                $jsonString = ConvertTo-Json -InputObject $jsonConfig
                $expectedExecutedRemoteCommands += @{Command = "echo -e '$jsonString' | sudo tee /tmp/auth.json"; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = 'sudo mkdir -p /root/.config/containers'; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = 'sudo mv /tmp/auth.json /root/.config/containers/auth.json'; IgnoreErrors = $false }  

                $expectedCRIO_CNI_FILE = '/etc/cni/net.d/10-crio-bridge.conf'
                $expectedExecutedRemoteCommands += @{Command = "[ -f $expectedCRIO_CNI_FILE ] && sudo mv $expectedCRIO_CNI_FILE /etc/cni/net.d/100-crio-bridge.conf || echo File does not exist, no renaming of cni file $expectedCRIO_CNI_FILE.." ; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = 'sudo echo unqualified-search-registries = [\\\"docker.io\\\"] | sudo tee -a /etc/containers/registries.conf'; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = 'sudo apt-get update'; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes apt-transport-https ca-certificates curl'; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = "sudo curl --retry 3 --retry-all-errors -fsSL https://pkgs.k8s.io/core:/stable:/$expectedPackageShortK8sVersion/deb/Release.key$curlProxy | sudo gpg --dearmor -o /usr/share/keyrings/kubernetes-apt-keyring.gpg"; IgnoreErrors = $true } 
                $expectedExecutedRemoteCommands += @{Command = "echo 'deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$expectedPackageShortK8sVersion/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list"; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = 'sudo apt-get update'; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = 'sudo apt-mark hold kubelet kubeadm kubectl'; IgnoreErrors = $false } 
                if ($PSVersionTable.PSVersion.Major -gt 5) {
                    $expectedExecutedRemoteCommands += @{Command = "pauseImageToUse=`"`$(kubeadm config images list --kubernetes-version $expectedK8sVersion | grep `"pause`")`" && newTextLine=`$(echo pause_image = '`"'`$pauseImageToUse'`"') && sudo sed -i `"s#.*pause_image[ ]*=.*pause.*#`$newTextLine#`" /etc/crio/crio.conf"; IgnoreErrors = $false } 
                }
                else {
                    $expectedExecutedRemoteCommands += @{Command = "pauseImageToUse=`"`$(kubeadm config images list --kubernetes-version $expectedK8sVersion | grep \`"pause\`")`" && newTextLine=`$(echo pause_image = '\`"'`$pauseImageToUse'\`"') && sudo sed -i \`"s#.*pause_image[ ]*=.*pause.*#`$newTextLine#\`" /etc/crio/crio.conf"; IgnoreErrors = $false } 
                }
                $expectedExecutedRemoteCommands += @{Command = 'sudo systemctl daemon-reload'; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = 'sudo systemctl enable crio'; IgnoreErrors = $true } 
                $expectedExecutedRemoteCommands += @{Command = 'sudo systemctl start crio'; IgnoreErrors = $false } 
                $expectedExecutedRemoteCommands += @{Command = "sudo kubeadm config images pull --kubernetes-version $expectedK8sVersion" ; IgnoreErrors = $false } 

                $expectedUser = "$expectedUserName@$expectedIpAddress"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += (New-Object ActualRemoteCommand -Property @{Command = $CmdToExecute; IgnoreErrors = $IgnoreErrors }) } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }

                Install-KubernetesArtifacts -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress -Proxy $proxyToUse -K8sVersion $expectedK8sVersion -CrioVersion $expectedCrioVersion 

                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count

                for ($i = 0; $i -lt $global:actualExecutedRemoteCommands.Count; $i++) {
                    $global:actualExecutedRemoteCommands[$i].Command | Should -Be $expectedExecutedRemoteCommands[$i].Command
                    $global:actualExecutedRemoteCommands[$i].IgnoreErrors | Should -Be $expectedExecutedRemoteCommands[$i].IgnoreErrors
                }

                Should -Invoke -CommandName InstallAptPackages -Times 1 -ParameterFilter { $FriendlyName -eq 'kubernetes' -and $Packages -eq "kubelet=$expectedShortK8sVersion kubeadm=$expectedShortK8sVersion kubectl=$expectedShortK8sVersion" -and $TestExecutable -eq 'kubectl' -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd }
            }
        }
    }
}

Describe 'Install-Tools' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { Install-Tools } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { Install-Tools -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { Install-Tools -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { Install-Tools -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { Install-Tools -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
    }
    Context 'perfoms tools installation' {
        It "with proxy '<proxyToUse>'" -ForEach @(
            @{ proxyToUse = '' }
            @{ proxyToUse = 'myProxy' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ proxyToUse = $proxyToUse } {
                # Arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock AddAptRepo { }
                Mock Write-Log { }
                $expectedExecutedRemoteCommands = @()
                $expectedExecutedRemoteCommands += 'sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Options::="--force-confnew" install buildah --yes'
                $expectedExecutedRemoteCommands += 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -qq --yes software-properties-common'
                $expectedExecutedRemoteCommands += 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes'
                $expectedExecutedRemoteCommands += 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -t bookworm --no-install-recommends --no-install-suggests buildah --yes' 
                $expectedExecutedRemoteCommands += 'sudo buildah -v' 
                $expectedExecutedRemoteCommands += 'sudo DEBIAN_FRONTEND=noninteractive apt-get autoremove -qq --yes'
                $expectedExecutedRemoteCommands += "sudo apt-add-repository 'deb http://deb.debian.org/debian bookworm main' -r"
                $expectedExecutedRemoteCommands += "sudo apt-add-repository 'deb http://deb.debian.org/debian-security/ bookworm-security main' -r"
                $expectedExecutedRemoteCommands += 'sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq --yes' 
                if ($proxyToUse -ne '') {
                    $expectedExecutedRemoteCommands += 'echo [engine] | sudo tee -a /etc/containers/containers.conf'
                    if ($PSVersionTable.PSVersion.Major -gt 5) {
                        $expectedExecutedRemoteCommands += "echo env = [\""https_proxy=$proxyToUse\""] | sudo tee -a /etc/containers/containers.conf"
                    }
                    else {
                        $expectedExecutedRemoteCommands += "echo env = [\\\""https_proxy=$proxyToUse\\\""] | sudo tee -a /etc/containers/containers.conf"
                    }
                }

                $token = Get-RegistryToken
                if ($PSVersionTable.PSVersion.Major -gt 5) {
                    $jsonConfig = @{
                        'auths' = @{
                            'shsk2s.azurecr.io' = @{
                                'auth' = "$token"
                            }
                        }
                    }
                }
                else {
                    $jsonConfig = @{
                        '"auths"' = @{
                            '"shsk2s.azurecr.io"' = @{
                                '"auth"' = """$token"""
                            }
                        }
                    }
                }
                
                $jsonString = ConvertTo-Json -InputObject $jsonConfig
                $expectedExecutedRemoteCommands += "echo -e '$jsonString' | sudo tee /tmp/auth.json"
                $expectedExecutedRemoteCommands += 'sudo mkdir -p /root/.config/containers'
                $expectedExecutedRemoteCommands += 'sudo mv /tmp/auth.json /root/.config/containers/auth.json' 

                if ($PSVersionTable.PSVersion.Major -gt 5) {
                    $expectedExecutedRemoteCommands += 'sudo echo unqualified-search-registries = [\"docker.io\", \"quay.io\"] | sudo tee -a /etc/containers/registries.conf'
                }
                else {
                    $expectedExecutedRemoteCommands += 'sudo echo unqualified-search-registries = [\\\"docker.io\\\", \\\"quay.io\\\"] | sudo tee -a /etc/containers/registries.conf'
                }
                $expectedExecutedRemoteCommands += 'sudo systemctl daemon-reload'
                $expectedExecutedRemoteCommands += 'sudo systemctl restart crio'

                $expectedUserName = 'theUser'
                $expectedUserPwd = 'thePwd'
                $expectedIpAddress = 'myIpAddress'
                $expectedUser = "$expectedUserName@$expectedIpAddress"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += $CmdToExecute } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }

                # Act
                Install-Tools -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress -Proxy $proxyToUse

                # Assert
                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count

                for ($i = 0; $i -lt $global:actualExecutedRemoteCommands.Count; $i++) {
                    $global:actualExecutedRemoteCommands[$i] | Should -Be $expectedExecutedRemoteCommands[$i]
                }

                Should -Invoke -CommandName AddAptRepo -Times 1 -ParameterFilter { $RepoDebString -eq 'deb http://deb.debian.org/debian bookworm main' -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd }
                Should -Invoke -CommandName AddAptRepo -Times 1 -ParameterFilter { $RepoDebString -eq 'deb http://deb.debian.org/debian-security/ bookworm-security main' -and $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd }
            }
        }
    }
}

Describe 'Add-SupportForWSL' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { Add-SupportForWSL } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { Add-SupportForWSL -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { Add-SupportForWSL -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'NetworkInterfaceName' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Add-SupportForWSL -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceName*'
            }
        }
        It 'GatewayIP' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Add-SupportForWSL -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -NetworkInterfaceName 'anyNetworkInterfaceName' } | Get-ExceptionMessage | Should -BeLike '*GatewayIP*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { Add-SupportForWSL -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { Add-SupportForWSL -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
        It "NetworkInterfaceName '<networkInterfaceNameToUse>'" -ForEach @(
            @{ networkInterfaceNameToUse = 'null' }
            @{ networkInterfaceNameToUse = '' }
            @{ networkInterfaceNameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ networkInterfaceNameToUse = $networkInterfaceNameToUse } {
                if ($networkInterfaceNameToUse -eq 'null') {
                    $networkInterfaceNameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }

                { Add-SupportForWSL -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -NetworkInterfaceName $networkInterfaceNameToUse } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceName*'
            }
        }
        It 'GatewayIP' {
            InModuleScope $linuxNodeModuleName {
                $expectedIpAddress = 'anyIpAddress'
                $expectedGatewayIP = 'anyGatewayIP'
                Mock Get-IsValidIPv4Address { $true } -ParameterFilter { $Value -eq $expectedIpAddress }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $expectedGatewayIP }
                { Add-SupportForWSL -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress $expectedIpAddress -NetworkInterfaceName 'anyNetworkInterfaceName' -GatewayIP $expectedGatewayIP } | Get-ExceptionMessage | Should -BeLike '*GatewayIP*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $expectedGatewayIP }
            }
        }
    }
    Context 'execution' {
        It 'performs configuration' {
            InModuleScope $linuxNodeModuleName {
                # Arrange
                $expectedUserName = 'theUser'
                $expectedUserPwd = 'thePwd'
                $expectedIpAddress = 'myIpAddress'
                $expectedNetworkInterfaceName = 'myNetworkInterfaceName'
                $expectedGatewayIp = 'myGatewayIp'
                Mock Get-IsValidIPv4Address { $true }
                Mock Write-Log { }
                $expectedExecutedRemoteCommands = @()
                $expectedExecutedRemoteCommands += 'sudo touch /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += 'echo [automount] | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += 'echo enabled = false | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += "echo -e 'mountFsTab = false\n' | sudo tee -a /etc/wsl.conf" 

                $expectedExecutedRemoteCommands += 'echo [interop] | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += 'echo enabled = false | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += "echo -e 'appendWindowsPath = false\n' | sudo tee -a /etc/wsl.conf" 

                $expectedExecutedRemoteCommands += 'echo [user] | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += "echo -e 'default = $expectedUserName\n' | sudo tee -a /etc/wsl.conf" 

                $expectedExecutedRemoteCommands += 'echo [network] | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += 'echo generateHosts = false | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += 'echo generateResolvConf = false | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += "echo hostname = `$(hostname) | sudo tee -a /etc/wsl.conf"
                $expectedExecutedRemoteCommands += 'echo | sudo tee -a /etc/wsl.conf'

                $expectedExecutedRemoteCommands += 'echo [boot] | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += 'echo systemd = true | sudo tee -a /etc/wsl.conf' 
                $expectedExecutedRemoteCommands += "echo 'command = ""sudo ifconfig $expectedNetworkInterfaceName $expectedIpAddress && sudo ifconfig $expectedNetworkInterfaceName netmask 255.255.255.0"" && sudo route add default gw $expectedGatewayIp' | sudo tee -a /etc/wsl.conf" 

                
                $expectedUser = "$expectedUserName@$expectedIpAddress"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += $CmdToExecute } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }

                # Act
                Add-SupportForWSL -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress -NetworkInterfaceName $expectedNetworkInterfaceName -GatewayIP $expectedGatewayIp

                # Assert
                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count

                for ($i = 0; $i -lt $global:actualExecutedRemoteCommands.Count; $i++) {
                    $global:actualExecutedRemoteCommands[$i] | Should -Be $expectedExecutedRemoteCommands[$i]
                }
            }
        }
    }
}

Describe 'Set-UpMasterNode' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { Set-UpMasterNode } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'K8sVersion' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*K8sVersion*'
            }
        }
        It 'ClusterCIDR' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyVersion' } | Get-ExceptionMessage | Should -BeLike '*ClusterCIDR*'
            }
        }
        It 'ClusterCIDR_Services' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' } | Get-ExceptionMessage | Should -BeLike '*ClusterCIDR_Services*'
            }
        }
        It 'KubeDnsServiceIP' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' -ClusterCIDR_Services 'anyValue' } | Get-ExceptionMessage | Should -BeLike '*KubeDnsServiceIP*'
            }
        }
        It 'IP_NextHop' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' -ClusterCIDR_Services 'anyValue' -KubeDnsServiceIP 'anyValue' } | Get-ExceptionMessage | Should -BeLike '*IP_NextHop*'
            }
        }
        It 'NetworkInterfaceName' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' -ClusterCIDR_Services 'anyValue' -KubeDnsServiceIP 'anyValue' -IP_NextHop 'anyValue' } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceName*'
            }
        }
        It 'NetworkInterfaceCni0IP_Master' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' -ClusterCIDR_Services 'anyValue' -KubeDnsServiceIP 'anyValue' -IP_NextHop 'anyValue' -NetworkInterfaceName 'anyName' } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceCni0IP_Master*'
            }
        }
        It 'Hook' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' -ClusterCIDR_Services 'anyValue' -KubeDnsServiceIP 'anyValue' -IP_NextHop 'anyValue' -NetworkInterfaceName 'anyName' -NetworkInterfaceCni0IP_Master 'anyValue' } | Get-ExceptionMessage | Should -BeLike '*Hook*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { Set-UpMasterNode -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
        It "K8sVersion '<k8sVersionToUse>'" -ForEach @(
            @{ k8sVersionToUse = 'null' }
            @{ k8sVersionToUse = '' }
            @{ k8sVersionToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ k8sVersionToUse = $k8sVersionToUse } {
                if ($k8sVersionToUse -eq 'null') {
                    $k8sVersionToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion $k8sVersionToUse } | Get-ExceptionMessage | Should -BeLike '*K8sVersion*'
            }
        }
        It "ClusterCIDR '<clusterCIDRToUse>'" -ForEach @(
            @{ clusterCIDRToUse = 'null' }
            @{ clusterCIDRToUse = '' }
            @{ clusterCIDRToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ clusterCIDRToUse = $clusterCIDRToUse } {
                if ($clusterCIDRToUse -eq 'null') {
                    $clusterCIDRToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyValue' -ClusterCIDR $clusterCIDRToUse } | Get-ExceptionMessage | Should -BeLike '*ClusterCIDR*'
            }
        }
        It "ClusterCIDR_Services '<clusterCIDR_ServicesToUse>'" -ForEach @(
            @{ clusterCIDR_ServicesToUse = 'null' }
            @{ clusterCIDR_ServicesToUse = '' }
            @{ clusterCIDR_ServicesToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ clusterCIDR_ServicesToUse = $clusterCIDR_ServicesToUse } {
                if ($clusterCIDR_ServicesToUse -eq 'null') {
                    $clusterCIDR_ServicesToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyValue' -ClusterCIDR 'anyValue' -ClusterCIDR_ServicesToUse $clusterCIDR_ServicesToUse } | Get-ExceptionMessage | Should -BeLike '*ClusterCIDR_Services*'
            }
        }
        It 'KubeDnsServiceIP' {
            InModuleScope $linuxNodeModuleName {
                $anyIpAddress = 'anyIpAddress'
                $expectedKubeDnsServiceIP = 'anyKubeDnsServiceIP'
                Mock Get-IsValidIPv4Address { $true } -ParameterFilter { $Value -eq $anyIpAddress }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $expectedKubeDnsServiceIP }
                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress $anyIpAddress -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' -ClusterCIDR_Services 'anyValue' -KubeDnsServiceIP $expectedKubeDnsServiceIP } | Get-ExceptionMessage | Should -BeLike '*KubeDnsServiceIP*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $expectedKubeDnsServiceIP }
            }
        }
        It 'IP_NextHop' {
            InModuleScope $linuxNodeModuleName {
                $anyIpAddress = 'anyIpAddress'
                $anyKubeDnsServiceIP = 'anyKubeDnsServiceIP'
                $expectedNextHopIP = 'anyNextHopIP'
                Mock Get-IsValidIPv4Address { $true } -ParameterFilter { $Value -eq $anyIpAddress }
                Mock Get-IsValidIPv4Address { $true } -ParameterFilter { $Value -eq $anyKubeDnsServiceIP }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $expectedNextHopIP }
                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress $anyIpAddress -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' -ClusterCIDR_Services 'anyValue' -KubeDnsServiceIP $anyKubeDnsServiceIP -IP_NextHop $expectedNextHopIP } | Get-ExceptionMessage | Should -BeLike '*IP_NextHop*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $expectedNextHopIP }
            }
        }
        It "NetworkInterfaceName '<networkInterfaceNameToUse>'" -ForEach @(
            @{ networkInterfaceNameToUse = 'null' }
            @{ networkInterfaceNameToUse = '' }
            @{ networkInterfaceNameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ networkInterfaceNameToUse = $networkInterfaceNameToUse } {
                if ($networkInterfaceNameToUse -eq 'null') {
                    $networkInterfaceNameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }

                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' -ClusterCIDR_Services 'anyValue' -KubeDnsServiceIP 'anyValue' -IP_NextHop 'anyValue' -NetworkInterfaceName $networkInterfaceNameToUse } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceName*'
            }
        }
        It 'NetworkInterfaceCni0IP_Master' {
            InModuleScope $linuxNodeModuleName {
                $anyIpAddress = 'anyIpAddress'
                $anyKubeDnsServiceIP = 'anyKubeDnsServiceIP'
                $anyNextHopIP = 'anyNextHopIP'
                $expectedNetworkInterfaceCni0IP = 'anyNetworkInterfaceCni0IP'
                Mock Get-IsValidIPv4Address { $true } -ParameterFilter { $Value -eq $anyIpAddress }
                Mock Get-IsValidIPv4Address { $true } -ParameterFilter { $Value -eq $anyKubeDnsServiceIP }
                Mock Get-IsValidIPv4Address { $true } -ParameterFilter { $Value -eq $anyNextHopIP }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $expectedNetworkInterfaceCni0IP }
                { Set-UpMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress $anyIpAddress -K8sVersion 'anyVersion' -ClusterCIDR 'anyValue' -ClusterCIDR_Services 'anyValue' -KubeDnsServiceIP $anyKubeDnsServiceIP -IP_NextHop $anyNextHopIP -NetworkInterfaceName 'anyName' -NetworkInterfaceCni0IP_Master $expectedNetworkInterfaceCni0IP } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceCni0IP_Master*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $expectedNetworkInterfaceCni0IP }
            }
        }
    }
    Context 'execution' {
        It 'performs set-up' {
            InModuleScope $linuxNodeModuleName {
                # Arrange
                $expectedUserName = 'theUser'
                $expectedUserPwd = 'thePwd'
                $expectedIpAddress = 'myIpAddress'
                $expectedK8sVersion = 'myK8sVersion'
                $expectedClusterCIDR = 'myClusterCIDR'
                $expectedClusterCIDR_Services = 'myClusterCIDR_Services'
                $expectedKubeDnsServiceIP = 'myKubeDnsServiceIP'
                $expectedIP_NextHop = 'myIP_NextHop'
                $expectedNetworkInterfaceName = 'myNetworkInterfaceName'
                $expectedNetworkInterfaceCni0IP_Master = 'myNetworkInterfaceCni0IP_Master'
                $expectedHook = { $global:HookExecuted = $true }
                Mock Get-IsValidIPv4Address { $true }
                Mock Write-Log { }
                Mock Add-FlannelPluginToMasterNode { }
                class ActualRemoteCommand {
                    [string]$Command
                    [bool]$IgnoreErrors
                }
                $expectedExecutedRemoteCommands = @()
                $expectedExecutedRemoteCommands += @{Command = "sudo kubeadm init --kubernetes-version $expectedK8sVersion --apiserver-advertise-address $expectedIpAddress --pod-network-cidr=$expectedClusterCIDR --service-cidr=$expectedClusterCIDR_Services"; IgnoreErrors = $true }
                $expectedExecutedRemoteCommands += @{Command = 'mkdir -p ~/.kube'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'chmod 755 ~/.kube'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'sudo cp /etc/kubernetes/admin.conf ~/.kube/config'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "sudo chown $expectedUserName ~/.kube/config" ; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'kubectl get nodes'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsutils --yes'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'sudo DEBIAN_FRONTEND=noninteractive apt-get install dnsmasq --yes' ; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "echo server=/cluster.local/$expectedKubeDnsServiceIP | sudo tee -a /etc/dnsmasq.conf"; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "echo server=$expectedIP_NextHop@$expectedNetworkInterfaceName | sudo tee -a /etc/dnsmasq.conf"; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "echo interface=$expectedNetworkInterfaceName | sudo tee -a /etc/dnsmasq.conf"; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'echo interface=cni0 | sudo tee -a /etc/dnsmasq.conf'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'echo interface=lo | sudo tee -a /etc/dnsmasq.conf'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = 'sudo systemctl restart dnsmasq'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "kubectl get configmap/coredns -n kube-system -o yaml | sed -e 's|forward . /etc/resolv.conf|forward . $expectedNetworkInterfaceCni0IP_Master|' | kubectl apply -f -"; IgnoreErrors = $true }
                $expectedExecutedRemoteCommands += @{Command = 'sudo chattr -i /etc/resolv.conf'; IgnoreErrors = $false }
                $expectedExecutedRemoteCommands += @{Command = "echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf"; IgnoreErrors = $false }
                
                $expectedUser = "$expectedUserName@$expectedIpAddress"
                $global:actualExecutedRemoteCommands = @()
                Mock ExecCmdMaster { $global:actualExecutedRemoteCommands += (New-Object ActualRemoteCommand -Property @{Command = $CmdToExecute; IgnoreErrors = $IgnoreErrors }) } -ParameterFilter { $RemoteUser -eq $expectedUser -and $RemoteUserPwd -eq $expectedUserPwd -and $UsePwd -eq $true }

                # Act
                Set-UpMasterNode -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress -K8sVersion $expectedK8sVersion -ClusterCIDR $expectedClusterCIDR -ClusterCIDR_Services $expectedClusterCIDR_Services -KubeDnsServiceIP $expectedKubeDnsServiceIP -IP_NextHop $expectedIP_NextHop -NetworkInterfaceName $expectedNetworkInterfaceName -NetworkInterfaceCni0IP_Master $expectedNetworkInterfaceCni0IP_Master -Hook $expectedHook

                # Assert
                $global:actualExecutedRemoteCommands.Count | Should -Be $expectedExecutedRemoteCommands.Count

                for ($i = 0; $i -lt $global:actualExecutedRemoteCommands.Count; $i++) {
                    $global:actualExecutedRemoteCommands[$i].Command | Should -Be $expectedExecutedRemoteCommands[$i].Command
                    $global:actualExecutedRemoteCommands[$i].IgnoreErrors | Should -Be $expectedExecutedRemoteCommands[$i].IgnoreErrors
                }

                Should -Invoke -CommandName Add-FlannelPluginToMasterNode -Times 1 -ParameterFilter { $IpAddress -eq $expectedIpAddress -and $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $PodNetworkCIDR -eq $expectedClusterCIDR }
                $global:HookExecuted | Should -Be $true
            }
        }
    }
}

Describe 'Add-FlannelPluginToMasterNode' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { Add-FlannelPluginToMasterNode } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { Add-FlannelPluginToMasterNode -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { Add-FlannelPluginToMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'PodNetworkCIDR' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { Add-FlannelPluginToMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*PodNetworkCIDR*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { Add-FlannelPluginToMasterNode -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { Add-FlannelPluginToMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
        It "PodNetworkCIDR '<podNetworkCIDRToUse>'" -ForEach @(
            @{ podNetworkCIDRToUse = 'null' }
            @{ podNetworkCIDRToUse = '' }
            @{ podNetworkCIDRToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ podNetworkCIDRToUse = $podNetworkCIDRToUse } {
                if ($podNetworkCIDRToUse -eq 'null') {
                    $podNetworkCIDRToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }

                { Add-FlannelPluginToMasterNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -PodNetworkCIDR $podNetworkCIDRToUse } | Get-ExceptionMessage | Should -BeLike '*PodNetworkCIDR*'
            }
        }
    }
}

Describe 'New-KubernetesNode' -Tag 'unit', 'ci', 'linuxnode' {
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName {
                { New-KubernetesNode } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName {
                { New-KubernetesNode -UserName 'anyNonEmptyOrNullValue' } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                { New-KubernetesNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'K8sVersion' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { New-KubernetesNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*K8sVersion*'
            }
        }
        It 'CrioVersion' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $true }

                { New-KubernetesNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyK8sVersion' } | Get-ExceptionMessage | Should -BeLike '*CrioVersion*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ nameToUse = $nameToUse } {
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                { New-KubernetesNode -UserName $nameToUse } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName {
                Mock Get-IsValidIPv4Address { $false }
                { New-KubernetesNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'

                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq 'anyIpAddress' }
            }
        }
        It "K8sVersion '<k8sVersionToUse>'" -ForEach @(
            @{ k8sVersionToUse = 'null' }
            @{ k8sVersionToUse = '' }
            @{ k8sVersionToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ k8sVersionToUse = $k8sVersionToUse } {
                if ($k8sVersionToUse -eq 'null') {
                    $k8sVersionToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }

                { New-KubernetesNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion $k8sVersionToUse } | Get-ExceptionMessage | Should -BeLike '*K8sVersion*'
            }
        }
        It "CrioVersion '<crioVersionToUse>'" -ForEach @(
            @{ crioVersionToUse = 'null' }
            @{ crioVersionToUse = '' }
            @{ crioVersionToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ crioVersionToUse = $crioVersionToUse } {
                if ($crioVersionToUse -eq 'null') {
                    $crioVersionToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                
                { New-KubernetesNode -UserName 'anyNonEmptyOrNullValue' -UserPwd 'anyPwd' -IpAddress 'anyIpAddress' -K8sVersion 'anyK8sVersion' -CrioVersion $crioVersionToUse } | Get-ExceptionMessage | Should -BeLike '*CrioVersion*'
            }
        }
    }
    Context 'execution' {
        It "calls creation methods in right order using proxy '<proxyToUse>'" -ForEach @(
            @{ proxyToUse = '' }
            @{ proxyToUse = 'myProxy' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ proxyToUse = $proxyToUse } {
                # arrange
                $expectedUserName = 'myUserName'
                $expectedUserPwd = 'myUserPwd'
                $expectedIpAddress = 'myIpAddress'
                $expectedK8sVersion = 'myK8sVersion'
                $expectedCrioVersion = 'myCrioVersion'
                function Set-UpComputerWithSpecificOsBeforeProvisioning {}
                function Set-UpComputerWithSpecificOsAfterProvisioning {}
                $global:actualMethodsCallOrder = @()
                Mock Get-IsValidIPv4Address { $true }
                Mock Write-Log { }
                Mock Assert-GeneralComputerPrequisites { $global:actualMethodsCallOrder += 'Assert-GeneralComputerPrequisites' } -ParameterFilter { $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $IpAddress -eq $expectedIpAddress }
                Mock Set-UpComputerBeforeProvisioning { $global:actualMethodsCallOrder += 'Set-UpComputerBeforeProvisioning' } -ParameterFilter { $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $IpAddress -eq $expectedIpAddress -and $Proxy -eq $proxyToUse }
                Mock Set-UpComputerWithSpecificOsBeforeProvisioning { $global:actualMethodsCallOrder += 'Set-UpComputerWithSpecificOsBeforeProvisioning' } -ParameterFilter { $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $IpAddress -eq $expectedIpAddress }
                Mock Install-KubernetesArtifacts { $global:actualMethodsCallOrder += 'Install-KubernetesArtifacts' } -ParameterFilter { $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $IpAddress -eq $expectedIpAddress -and $Proxy -eq $proxyToUse -and $K8sVersion -eq $expectedK8sVersion -and $CrioVersion -eq $expectedCrioVersion }
                Mock Set-UpComputerWithSpecificOsAfterProvisioning { $global:actualMethodsCallOrder += 'Set-UpComputerWithSpecificOsAfterProvisioning' } -ParameterFilter { $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $IpAddress -eq $expectedIpAddress }
                Mock Set-UpComputerAfterProvisioning { $global:actualMethodsCallOrder += 'Set-UpComputerAfterProvisioning' } -ParameterFilter { $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $IpAddress -eq $expectedIpAddress }

                # act
                New-KubernetesNode -UserName $expectedUserName -UserPwd $expectedUserPwd -IpAddress $expectedIpAddress -K8sVersion $expectedK8sVersion -CrioVersion $expectedCrioVersion -Proxy $proxyToUse

                # assert
                $expectedMethodsCallOrder = @(
                    'Assert-GeneralComputerPrequisites',
                    'Set-UpComputerBeforeProvisioning',
                    'Set-UpComputerWithSpecificOsBeforeProvisioning',
                    'Install-KubernetesArtifacts',
                    'Set-UpComputerWithSpecificOsAfterProvisioning',
                    'Set-UpComputerAfterProvisioning'
                )

                $global:actualMethodsCallOrder | Should -Be $expectedMethodsCallOrder
            }
        }
    }
}

Describe 'New-MasterNode' -Tag 'unit', 'ci', 'linuxnode' {
    BeforeEach {
        $DefaultParameterValues = @{
            UserName                      = 'myUserName'
            UserPwd                       = 'myUserPwd'
            IpAddress                     = 'myIpAddress'
            K8sVersion                    = 'myK8sVersion'
            CrioVersion                   = 'myCrioVersion'
            ClusterCIDR                   = 'myClusterCIDR'
            ClusterCIDR_Services          = 'myClusterCIDR_Services'
            KubeDnsServiceIP              = 'myKubeDnsServiceIP'
            GatewayIP                     = 'myGatewayIP'
            NetworkInterfaceName          = 'myNetworkInterfaceName'
            NetworkInterfaceCni0IP_Master = 'myNetworkInterfaceCni0IP_Master'
            Proxy                         = 'myProxy'
            Hook                          = { }
        }
    }
    Context "parameter's existence" {
        It 'UserName' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserName')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'UserPwd' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('UserPwd')
 
                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserPwd*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('IpAddress')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
            }
        }
        It 'K8sVersion' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('K8sVersion')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*K8sVersion*'
            }
        }
        It 'CrioVersion' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('CrioVersion')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*CrioVersion*'
            }
        }
        It 'ClusterCIDR' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('ClusterCIDR')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*ClusterCIDR*'
            }
        }
        It 'ClusterCIDR_Services' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('ClusterCIDR_Services')
 
                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*ClusterCIDR_Services*'
            }
        }
        It 'KubeDnsServiceIP' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('KubeDnsServiceIP')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*KubeDnsServiceIP*'
            }
        }
        It 'GatewayIP' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('GatewayIP')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*GatewayIP*'
            }
        }
        It 'NetworkInterfaceName' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('NetworkInterfaceName')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceName*'
            }
        }
        It 'NetworkInterfaceCni0IP_Master' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('NetworkInterfaceCni0IP_Master')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceCni0IP_Master*'
            }
        }
        It 'Hook' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues.Remove('Hook')

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*Hook*'
            }
        }
    }
    Context "parameter's value validation" {
        It "UserName '<nameToUse>'" -ForEach @(
            @{ nameToUse = 'null' }
            @{ nameToUse = '' }
            @{ nameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; nameToUse = $nameToUse } {
                # arrange
                if ($nameToUse -eq 'null') {
                    $nameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['UserName'] = $nameToUse

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*UserName*'
            }
        }
        It 'IpAddress' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*IpAddress*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.IpAddress }
            }
        }
        It "K8sVersion '<k8sVersionToUse>'" -ForEach @(
            @{ k8sVersionToUse = 'null' }
            @{ k8sVersionToUse = '' }
            @{ k8sVersionToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; k8sVersionToUse = $k8sVersionToUse } {
                # arrange
                if ($k8sVersionToUse -eq 'null') {
                    $k8sVersionToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['K8sVersion'] = $k8sVersionToUse

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*K8sVersion*'
            }
        }
        It "CrioVersion '<crioVersionToUse>'" -ForEach @(
            @{ crioVersionToUse = 'null' }
            @{ crioVersionToUse = '' }
            @{ crioVersionToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; crioVersionToUse = $crioVersionToUse } {
                # arrange
                if ($crioVersionToUse -eq 'null') {
                    $crioVersionToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['CrioVersion'] = $crioVersionToUse

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*CrioVersion*'
            }
        }
        It "ClusterCIDR '<clusterCIDRToUse>'" -ForEach @(
            @{ clusterCIDRToUse = 'null' }
            @{ clusterCIDRToUse = '' }
            @{ clusterCIDRToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; clusterCIDRToUse = $clusterCIDRToUse } {
                # arrange
                if ($clusterCIDRToUse -eq 'null') {
                    $clusterCIDRToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['ClusterCIDR'] = $clusterCIDRToUse

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*ClusterCIDR*'
            }
        }
        It "ClusterCIDR_Services '<clusterCIDR_ServicesToUse>'" -ForEach @(
            @{ clusterCIDR_ServicesToUse = 'null' }
            @{ clusterCIDR_ServicesToUse = '' }
            @{ clusterCIDR_ServicesToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; clusterCIDR_ServicesToUse = $clusterCIDR_ServicesToUse } {
                # arrange
                if ($clusterCIDR_ServicesToUse -eq 'null') {
                    $clusterCIDR_ServicesToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['ClusterCIDR_Services'] = $clusterCIDR_ServicesToUse

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*ClusterCIDR_Services*'
            }
        }
        It 'KubeDnsServiceIP' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true }
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.KubeDnsServiceIP }
                
                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*KubeDnsServiceIP*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.KubeDnsServiceIP }
            }
        }
        It 'GatewayIP' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true } 
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.GatewayIP }

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*GatewayIP*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.GatewayIP }
            }
        }
        It "NetworkInterfaceName '<networkInterfaceNameToUse>'" -ForEach @(
            @{ networkInterfaceNameToUse = 'null' }
            @{ networkInterfaceNameToUse = '' }
            @{ networkInterfaceNameToUse = '  ' }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; networkInterfaceNameToUse = $networkInterfaceNameToUse } {
                # arrange
                if ($networkInterfaceNameToUse -eq 'null') {
                    $networkInterfaceNameToUse = $null
                }
                Mock Get-IsValidIPv4Address { $true }
                $DefaultParameterValues['NetworkInterfaceName'] = $networkInterfaceNameToUse

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceName*'
            }
        }
        It 'NetworkInterfaceCni0IP_Master' {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues } {
                # arrange
                Mock Get-IsValidIPv4Address { $true } 
                Mock Get-IsValidIPv4Address { $false } -ParameterFilter { $Value -eq $DefaultParameterValues.NetworkInterfaceCni0IP_Master }

                # act + assert
                { New-MasterNode @DefaultParameterValues } | Get-ExceptionMessage | Should -BeLike '*NetworkInterfaceCni0IP_Master*'
                Should -Invoke -CommandName Get-IsValidIPv4Address -Times 1 -ParameterFilter { $Value -eq $DefaultParameterValues.NetworkInterfaceCni0IP_Master }
            }
        }
    }
    Context 'execution' {
        It 'calls methods in right order (use default proxy value? <useDefaultProxyValue>)' -ForEach @(
            @{ useDefaultProxyValue = $true }
            @{ useDefaultProxyValue = $false }
        ) {
            InModuleScope $linuxNodeModuleName -Parameters @{ DefaultParameterValues = $DefaultParameterValues; useDefaultProxyValue = $useDefaultProxyValue } {
                if ($useDefaultProxyValue) {
                    $expectedProxy = ''
                    $DefaultParameterValues.Remove('Proxy')
                }
                else {
                    $expectedProxy = $DefaultParameterValues.Proxy
                }
                # arrange
                $expectedUserName = $DefaultParameterValues.UserName
                $expectedUserPwd = $DefaultParameterValues.UserPwd
                $expectedIpAddress = $DefaultParameterValues.IpAddress
                $expectedK8sVersion = $DefaultParameterValues.K8sVersion
                $expectedCrioVersion = $DefaultParameterValues.CrioVersion
                $expectedClusterCIDR = $DefaultParameterValues.ClusterCIDR
                $expectedClusterCIDR_Services = $DefaultParameterValues.ClusterCIDR_Services
                $expectedKubeDnsServiceIP = $DefaultParameterValues.KubeDnsServiceIP
                $expectedGatewayIP = $DefaultParameterValues.GatewayIP
                $expectedNetworkInterfaceName = $DefaultParameterValues.NetworkInterfaceName
                $expectedNetworkInterfaceCni0IP_Master = $DefaultParameterValues.NetworkInterfaceCni0IP_Master
                $expectedHook = $DefaultParameterValues.Hook

                $global:actualMethodsCallOrder = @()
                Mock Assert-MasterNodeComputerPrequisites { $global:actualMethodsCallOrder += 'Assert-MasterNodeComputerPrequisites' } -ParameterFilter { $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $IpAddress -eq $expectedIpAddress }
                Mock New-KubernetesNode { $global:actualMethodsCallOrder += 'New-KubernetesNode' } -ParameterFilter { $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $IpAddress -eq $expectedIpAddress -and $K8sVersion -eq $expectedK8sVersion -and $CrioVersion -eq $expectedCrioVersion -and $Proxy -eq $expectedProxy }
                Mock Set-UpMasterNode { $global:actualMethodsCallOrder += 'Set-UpMasterNode' } -ParameterFilter { $UserName -eq $expectedUserName -and $UserPwd -eq $expectedUserPwd -and $IpAddress -eq $expectedIpAddress -and $K8sVersion -eq $expectedK8sVersion -and $ClusterCIDR -eq $expectedClusterCIDR -and $ClusterCIDR_Services -eq $expectedClusterCIDR_Services -and $KubeDnsServiceIP -eq $expectedKubeDnsServiceIP -and $IP_NextHop -eq $expectedGatewayIP -and $NetworkInterfaceName -eq $expectedNetworkInterfaceName -and $NetworkInterfaceCni0IP_Master -eq $expectedNetworkInterfaceCni0IP_Master -and $Hook -eq $expectedHook }
                Mock Get-IsValidIPv4Address { $true }

                # act
                New-MasterNode @DefaultParameterValues

                # assert
                $expectedMethodsCallOrder = @(
                    'Assert-MasterNodeComputerPrequisites',
                    'New-KubernetesNode',
                    'Set-UpMasterNode'
                )
                $global:actualMethodsCallOrder | Should -Be $expectedMethodsCallOrder
            }
        }
    }
}





