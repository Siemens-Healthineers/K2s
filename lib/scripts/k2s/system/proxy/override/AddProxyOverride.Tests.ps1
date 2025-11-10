# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $scriptPath = "$PSScriptRoot\AddProxyOverride.ps1"
    
    function global:Initialize-Logging { }
    function global:Add-NoProxyEntry { param($Entry) }
    function global:Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1', '*.example.com')
        }
    }
    function global:Get-K2sHosts { return @('172.19.1.100', '172.19.1.1', '.local', '.cluster.local') }
    function global:Stop-WinHttpProxy { }
    function global:Start-WinHttpProxy { }
    function global:Set-ProxyConfigInHttpProxy { param($HttpProxy) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param($Message, $Error) }
    
    # Now mock them for assertion tracking
    Mock Import-Module { }
    Mock Initialize-Logging { }
    Mock Add-NoProxyEntry { }
    Mock Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1', '*.example.com')
        }
    }
    Mock Get-K2sHosts { return @('172.19.1.100', '172.19.1.1', '.local', '.cluster.local') }
    Mock Stop-WinHttpProxy { }
    Mock Start-WinHttpProxy { }
    Mock Set-ProxyConfigInHttpProxy { }
    Mock Send-ToCli { }
    Mock Write-Log { }
}

Describe 'AddProxyOverride.ps1' -Tag 'unit', 'ci', 'proxy' {
    
    Context 'Parameter validation' {
        It 'requires Overrides parameter' {
            { & $scriptPath } | Should -Throw
        }

        It 'accepts single override entry' {
            { & $scriptPath -Overrides '*.internal.com' } | Should -Not -Throw
        }

        It 'accepts multiple override entries as array' {
            { & $scriptPath -Overrides @('*.internal.com', '192.168.1.0/24', 'intranet.local') } | Should -Not -Throw
        }

        It 'accepts ShowLogs switch parameter' {
            { & $scriptPath -Overrides '*.test.com' -ShowLogs } | Should -Not -Throw
        }

        It 'accepts EncodeStructuredOutput switch parameter' {
            { & $scriptPath -Overrides '*.test.com' -EncodeStructuredOutput -MessageType 'Test' } | Should -Not -Throw
        }
    }

    Context 'Module imports' {
        It 'imports infra module' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.infra.module.psm1'
            }
        }

        It 'imports node module' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.node.module.psm1'
            }
        }

        It 'initializes logging' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Initialize-Logging -Exactly 1
        }
    }

    Context 'Adding proxy overrides' {
        It 'calls Add-NoProxyEntry with single override' {
            $override = '*.company.com'
            
            & $scriptPath -Overrides $override
            
            Should -Invoke Add-NoProxyEntry -Exactly 1 -ParameterFilter {
                $Entries.Count -eq 1 -and
                $Entries[0] -eq $override
            }
        }

        It 'calls Add-NoProxyEntry with multiple overrides' {
            $overrides = @('*.internal.com', '10.0.0.0/8', 'localhost')
            
            & $scriptPath -Overrides $overrides
            
            Should -Invoke Add-NoProxyEntry -Exactly 1 -ParameterFilter {
                $Entries.Count -eq 3 -and
                $Entries -contains '*.internal.com' -and
                $Entries -contains '10.0.0.0/8' -and
                $Entries -contains 'localhost'
            }
        }

        It 'stops WinHttpProxy before updating configuration' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Stop-WinHttpProxy -Exactly 1
        }

        It 'retrieves updated proxy configuration after adding overrides' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'retrieves K2s hosts for NoProxy merging' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Get-K2sHosts -Exactly 1
        }
    }

    Context 'NoProxy hosts merging after override addition' {
        It 'merges updated NoProxy with K2s hosts' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', '*.example.com', '*.newly-added.com')
                }
            }
            Mock Get-K2sHosts { return @('172.19.1.100', '.local') }
            
            & $scriptPath -Overrides '*.newly-added.com'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverride -contains 'localhost' -and
                $ProxyOverride -contains '*.example.com' -and
                $ProxyOverride -contains '*.newly-added.com' -and
                $ProxyOverride -contains '172.19.1.100' -and
                $ProxyOverride -contains '.local'
            }
        }

        It 'removes duplicate entries from merged NoProxy list' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', '*.example.com')
                }
            }
            Mock Get-K2sHosts { return @('localhost', '.local') }
            
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                ($ProxyOverride | Where-Object { $_ -eq 'localhost' } | Measure-Object).Count -eq 1
            }
        }

        It 'handles empty NoProxy after override addition' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @()
                }
            }
            Mock Get-K2sHosts { return @('172.19.1.100', '.local') }
            
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverride -contains '172.19.1.100' -and
                $ProxyOverride -contains '.local'
            }
        }
    }

    Context 'WinHttpProxy configuration' {
        It 'configures WinHttpProxy with updated proxy and merged NoProxy' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $Proxy -eq 'http://proxy.example.com:8080'
            }
        }

        It 'starts WinHttpProxy service after configuration' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Start-WinHttpProxy -Exactly 1
        }
    }

    Context 'Execution order' {
        BeforeEach {
            $script:executionOrder = @()
            
            Mock Add-NoProxyEntry { $script:executionOrder += 'Add-NoProxyEntry' }
            Mock Stop-WinHttpProxy { $script:executionOrder += 'Stop-WinHttpProxy' }
            Mock Get-ProxyConfig { 
                $script:executionOrder += 'Get-ProxyConfig'
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @() }
            }
            Mock Get-K2sHosts { 
                $script:executionOrder += 'Get-K2sHosts'
                return @('localhost')
            }
            Mock Set-ProxyConfigInHttpProxy { $script:executionOrder += 'Set-ProxyConfigInHttpProxy' }
            Mock Start-WinHttpProxy { $script:executionOrder += 'Start-WinHttpProxy' }
        }

        It 'executes operations in correct order' {
            & $scriptPath -Overrides '*.test.com'
            
            $script:executionOrder[0] | Should -Be 'Add-NoProxyEntry'
            $script:executionOrder[1] | Should -Be 'Stop-WinHttpProxy'
            $script:executionOrder[2] | Should -Be 'Get-ProxyConfig'
            $script:executionOrder[3] | Should -Be 'Get-K2sHosts'
            $script:executionOrder[4] | Should -Be 'Set-ProxyConfigInHttpProxy'
            $script:executionOrder[5] | Should -Be 'Start-WinHttpProxy'
        }
    }

    Context 'Structured output' {
        It 'sends structured output when EncodeStructuredOutput is set' {
            & $scriptPath -Overrides '*.test.com' -EncodeStructuredOutput -MessageType 'AddOverrideResult'
            
            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'AddOverrideResult' -and
                $Message.Error -eq $null
            }
        }

        It 'does not send structured output by default' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Send-ToCli -Exactly 0
        }
    }

    Context 'Logging' {
        It 'logs completion message' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Write-Log -ParameterFilter {
                $Message -like '*finished*'
            }
        }

        It 'logs errors when exception occurs' {
            Mock Add-NoProxyEntry { throw 'Failed to add override' }
            
            { & $scriptPath -Overrides '*.test.com' } | Should -Throw
            
            Should -Invoke Write-Log -ParameterFilter {
                $Error -eq $true -and
                $Message -like '*Failed to add override*'
            }
        }
    }

    Context 'Error handling' {
        It 'throws exception when Add-NoProxyEntry fails' {
            Mock Add-NoProxyEntry { throw 'Entry addition failed' }
            
            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Entry addition failed*'
        }

        It 'throws exception when Stop-WinHttpProxy fails' {
            Mock Stop-WinHttpProxy { throw 'Service stop failed' }
            
            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Service stop failed*'
        }

        It 'throws exception when Get-ProxyConfig fails' {
            Mock Get-ProxyConfig { throw 'Failed to read config' }
            
            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Failed to read config*'
        }

        It 'throws exception when Set-ProxyConfigInHttpProxy fails' {
            Mock Set-ProxyConfigInHttpProxy { throw 'Configuration update failed' }
            
            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Configuration update failed*'
        }

        It 'throws exception when Start-WinHttpProxy fails' {
            Mock Start-WinHttpProxy { throw 'Service start failed' }
            
            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Service start failed*'
        }
    }
}
