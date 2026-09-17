# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

BeforeAll {
    $modulePath = "$PSScriptRoot/windows-worker-node.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $routeFunction = $moduleAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Set-RoutesToKubemaster'
    }, $false)
    . ([scriptblock]::Create($routeFunction.Extent.Text))

    function Get-ConfiguredControlPlaneCIDR { '172.19.1.0/24' }
    function Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
    function Write-Log { param($Message) }
    function Get-NetIPAddress { [CmdletBinding()] param($IPAddress, $AddressFamily) }
    function Get-NetRoute { [CmdletBinding()] param($AddressFamily, $PolicyStore) }
    function New-NetRoute { [CmdletBinding()] param($DestinationPrefix, $InterfaceIndex, $NextHop, $RouteMetric, $PolicyStore) }
    function Remove-NetRoute { [CmdletBinding(SupportsShouldProcess)] param([Parameter(ValueFromPipeline)]$InputObject) }
}

Describe 'Set-RoutesToKubemaster' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-NetIPAddress { [pscustomobject]@{ InterfaceIndex = 27 } }
        Mock Get-NetRoute {}
        Mock New-NetRoute {}
        Mock Remove-NetRoute {}
    }

    It 'creates a missing on-link route on the configured host IP interface' {
        Set-RoutesToKubemaster

        Should -Invoke Get-NetIPAddress -Times 1 -Exactly -ParameterFilter { $IPAddress -eq '172.19.1.1' -and $AddressFamily -eq 'IPv4' }
        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '172.19.1.0/24' -and $InterfaceIndex -eq 27 -and
            $NextHop -eq '0.0.0.0' -and $PolicyStore -eq 'ActiveStore'
        }
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'preserves the connected route and removes only legacy routes from both stores' {
        Mock Get-NetRoute {
            [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
            [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 9; NextHop = '172.19.1.1'; Store = $PolicyStore }
            [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 9; NextHop = '172.22.7.1' }
            [pscustomobject]@{ DestinationPrefix = '172.19.1.100/32'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
            [pscustomobject]@{ DestinationPrefix = '172.22.0.0/16'; InterfaceIndex = 9; NextHop = '172.19.1.1' }
        }

        Set-RoutesToKubemaster

        Should -Invoke New-NetRoute -Times 0 -Exactly
        Should -Invoke Remove-NetRoute -Times 2 -Exactly
        Should -Invoke Remove-NetRoute -Times 1 -Exactly -ParameterFilter {
            $InputObject.DestinationPrefix -eq '172.19.1.0/24' -and $InputObject.NextHop -eq '172.19.1.1' -and $InputObject.Store -eq 'PersistentStore'
        }
        Should -Invoke Remove-NetRoute -Times 1 -Exactly -ParameterFilter {
            $InputObject.DestinationPrefix -eq '172.19.1.0/24' -and $InputObject.NextHop -eq '172.19.1.1' -and $InputObject.Store -eq 'ActiveStore'
        }
    }

    It 'accepts an empty persistent store during Windows-hosted Linux-only startup' {
        Mock Get-NetRoute {
            if ($AddressFamily) {
                throw "No MSFT_NetRoute objects found with property 'AddressFamily' equal to 'IPv4'"
            }
            if ($PolicyStore -eq 'ActiveStore') {
                [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
            }
        }

        Set-RoutesToKubemaster

        Should -Invoke Get-NetRoute -Times 1 -Exactly -ParameterFilter { $PolicyStore -eq 'PersistentStore' -and -not $AddressFamily }
        Should -Invoke Get-NetRoute -Times 0 -Exactly -ParameterFilter { $AddressFamily }
        Should -Invoke New-NetRoute -Times 0 -Exactly
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'restores the on-link route when stores contain only unrelated IPv6 routes' {
        Mock Get-NetRoute {
            if ($AddressFamily) {
                throw "No MSFT_NetRoute objects found with property 'AddressFamily' equal to 'IPv4'"
            }
            [pscustomobject]@{ DestinationPrefix = 'fe80::/64'; InterfaceIndex = 27; NextHop = '::' }
        }

        Set-RoutesToKubemaster

        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter {
            $DestinationPrefix -eq '172.19.1.0/24' -and $InterfaceIndex -eq 27 -and $NextHop -eq '0.0.0.0'
        }
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'propagates genuine persistent-store query failures' {
        Mock Get-NetRoute {
            if ($PolicyStore -eq 'PersistentStore') {
                throw 'Access denied reading route store'
            }
            [pscustomobject]@{ DestinationPrefix = '172.19.1.0/24'; InterfaceIndex = 27; NextHop = '0.0.0.0' }
        }

        { Set-RoutesToKubemaster } | Should -Throw '*Access denied reading route store*'

        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'uses the current interface index after switch recreation or for WSL' {
        Mock Get-NetIPAddress { [pscustomobject]@{ InterfaceIndex = 42 } }

        Set-RoutesToKubemaster

        Should -Invoke New-NetRoute -Times 1 -Exactly -ParameterFilter { $InterfaceIndex -eq 42 }
    }

    It 'does not mutate routes when the switch address is missing' {
        Mock Get-NetIPAddress {}

        { Set-RoutesToKubemaster } | Should -Throw '*unique control-plane switch interface*'

        Should -Invoke New-NetRoute -Times 0 -Exactly
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'does not mutate routes when the switch address is ambiguous' {
        Mock Get-NetIPAddress {
            [pscustomobject]@{ InterfaceIndex = 27 }
            [pscustomobject]@{ InterfaceIndex = 42 }
        }

        { Set-RoutesToKubemaster } | Should -Throw '*unique control-plane switch interface*'

        Should -Invoke New-NetRoute -Times 0 -Exactly
        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }

    It 'does not remove routes if restoring the connected route fails' {
        Mock New-NetRoute { throw 'route creation failed' }

        { Set-RoutesToKubemaster } | Should -Throw '*route creation failed*'

        Should -Invoke Remove-NetRoute -Times 0 -Exactly
    }
}