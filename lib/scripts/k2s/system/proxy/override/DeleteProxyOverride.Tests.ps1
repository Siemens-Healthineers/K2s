# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $scriptPath = "$PSScriptRoot\DeleteProxyOverride.ps1"
    
    function global:Initialize-Logging { }
    function global:Remove-NoProxyEntry { param($Entry) }
    function global:Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1')
        }
    }
    function global:Stop-WinHttpProxy { }
    function global:Start-WinHttpProxy { }
    function global:Set-ProxyConfigInHttpProxy { param($HttpProxy) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param($Message, $Error) }
    
    Mock Import-Module { }
    Mock Initialize-Logging { }
    Mock Remove-NoProxyEntry { }
    Mock Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1')
        }
    }
    Mock Stop-WinHttpProxy { }
    Mock Start-WinHttpProxy { }
    Mock Set-ProxyConfigInHttpProxy { }
    Mock Send-ToCli { }
    Mock Write-Log { }
}

Describe 'DeleteProxyOverride.ps1' -Tag 'unit', 'ci', 'proxy' {
    
    Context 'Parameter validation' {
        It 'requires Overrides parameter' {
            { & $scriptPath } | Should -Throw
        }

        It 'accepts single override entry to delete' {
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

    Context 'Deleting proxy overrides' {
        It 'calls Remove-NoProxyEntry with single override' {
            $override = '*.company.com'
            
            & $scriptPath -Overrides $override
            
            Should -Invoke Remove-NoProxyEntry -Exactly 1 -ParameterFilter {
                $Entries.Count -eq 1 -and
                $Entries[0] -eq $override
            }
        }

        It 'calls Remove-NoProxyEntry with multiple overrides' {
            $overrides = @('*.internal.com', '10.0.0.0/8', 'localhost')
            
            & $scriptPath -Overrides $overrides
            
            Should -Invoke Remove-NoProxyEntry -Exactly 1 -ParameterFilter {
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

        It 'retrieves updated proxy configuration after deleting overrides' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Get-ProxyConfig -Exactly 1
        }
    }

    Context 'WinHttpProxy configuration after deletion' {
        It 'configures WinHttpProxy with updated NoProxy list' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', '127.0.0.1')
                }
            }
            
            & $scriptPath -Overrides '*.removed.com'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $Proxy -eq 'http://proxy.example.com:8080' -and
                $ProxyOverride -contains 'localhost' -and
                $ProxyOverride -contains '127.0.0.1'
            }
        }

        It 'uses NoProxy directly from config without K2s hosts merging' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('example.com')
                }
            }
            
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                ($ProxyOverride | Measure-Object).Count -eq 1 -and
                $ProxyOverride[0] -eq 'example.com'
            }
        }

        It 'handles empty NoProxy after all overrides deleted' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @()
                }
            }
            
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverride.Count -eq 0
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
            
            Mock Remove-NoProxyEntry { $script:executionOrder += 'Remove-NoProxyEntry' }
            Mock Stop-WinHttpProxy { $script:executionOrder += 'Stop-WinHttpProxy' }
            Mock Get-ProxyConfig { 
                $script:executionOrder += 'Get-ProxyConfig'
                return [PSCustomObject]@{ HttpProxy = 'http://proxy.test:8080'; NoProxy = @('localhost') }
            }
            Mock Set-ProxyConfigInHttpProxy { $script:executionOrder += 'Set-ProxyConfigInHttpProxy' }
            Mock Start-WinHttpProxy { $script:executionOrder += 'Start-WinHttpProxy' }
        }

        It 'executes operations in correct order' {
            & $scriptPath -Overrides '*.test.com'
            
            $script:executionOrder[0] | Should -Be 'Remove-NoProxyEntry'
            $script:executionOrder[1] | Should -Be 'Stop-WinHttpProxy'
            $script:executionOrder[2] | Should -Be 'Get-ProxyConfig'
            $script:executionOrder[3] | Should -Be 'Set-ProxyConfigInHttpProxy'
            $script:executionOrder[4] | Should -Be 'Start-WinHttpProxy'
        }

        It 'does not call Get-K2sHosts during deletion' {
            & $scriptPath -Overrides '*.test.com'
            
            $script:executionOrder | Should -Not -Contain 'Get-K2sHosts'
        }
    }

    Context 'Structured output' {
        It 'sends structured output when EncodeStructuredOutput is set' {
            & $scriptPath -Overrides '*.test.com' -EncodeStructuredOutput -MessageType 'DeleteOverrideResult'
            
            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'DeleteOverrideResult' -and
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
            Mock Remove-NoProxyEntry { throw 'Failed to remove override' }
            
            { & $scriptPath -Overrides '*.test.com' } | Should -Throw
            
            Should -Invoke Write-Log -ParameterFilter {
                $Error -eq $true -and
                $Message -like '*Failed to remove override*'
            }
        }
    }

    Context 'Error handling' {
        It 'throws exception when Remove-NoProxyEntry fails' {
            Mock Remove-NoProxyEntry { throw 'Entry removal failed' }
            
            { & $scriptPath -Overrides '*.test.com' } | Should -Throw '*Entry removal failed*'
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

    Context 'Behavioral differences from Add' {
        It 'does not merge with K2s hosts unlike AddProxyOverride' {
            & $scriptPath -Overrides '*.test.com'
            
            Should -Not -Invoke Get-K2sHosts
        }

        It 'uses exact NoProxy from config without additional entries' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('entry1', 'entry2')
                }
            }
            
            & $scriptPath -Overrides '*.test.com'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                ($ProxyOverride | Measure-Object).Count -eq 2 -and
                $ProxyOverride -contains 'entry1' -and
                $ProxyOverride -contains 'entry2'
            }
        }
    }
}
