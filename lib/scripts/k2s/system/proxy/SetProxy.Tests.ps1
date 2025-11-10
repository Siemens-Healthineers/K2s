# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $scriptPath = "$PSScriptRoot\SetProxy.ps1"
    
    function global:Initialize-Logging { }
    function global:Set-ProxyServer { param($HttpProxy, $HttpsProxy, $NoProxy) }
    function global:Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1')
        }
    }
    function global:Get-K2sHosts { return @('172.19.1.100', '172.19.1.1', '.local', '.cluster.local') }
    function global:Stop-WinHttpProxy { }
    function global:Start-WinHttpProxy { }
    function global:Set-ProxyConfigInHttpProxy { param($HttpProxy) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param($Message, $Error) }
    
    Mock Import-Module { }
    Mock Initialize-Logging { }
    Mock Set-ProxyServer { }
    Mock Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1')
        }
    }
    Mock Get-K2sHosts { return @('172.19.1.100', '172.19.1.1', '.local', '.cluster.local') }
    Mock Stop-WinHttpProxy { }
    Mock Start-WinHttpProxy { }
    Mock Set-ProxyConfigInHttpProxy { }
    Mock Send-ToCli { }
    Mock Write-Log { }
}

Describe 'SetProxy.ps1' -Tag 'unit', 'ci', 'proxy' {
    
    Context 'Parameter validation' {
        It 'requires Uri parameter' {
            { & $scriptPath } | Should -Throw
        }

        It 'accepts valid Uri parameter' {
            { & $scriptPath -Uri 'http://proxy.test.com:8080' } | Should -Not -Throw
        }

        It 'accepts ShowLogs switch parameter' {
            { & $scriptPath -Uri 'http://proxy.test.com:8080' -ShowLogs } | Should -Not -Throw
        }

        It 'accepts EncodeStructuredOutput switch parameter' {
            { & $scriptPath -Uri 'http://proxy.test.com:8080' -EncodeStructuredOutput -MessageType 'Test' } | Should -Not -Throw
        }
    }

    Context 'Module imports' {
        It 'imports infra module' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.infra.module.psm1'
            }
        }

        It 'imports node module' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.node.module.psm1'
            }
        }

        It 'initializes logging' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Initialize-Logging -Exactly 1
        }
    }

    Context 'Proxy configuration' {
        It 'calls Set-ProxyServer with provided Uri' {
            $testUri = 'http://custom.proxy.com:9090'
            
            & $scriptPath -Uri $testUri
            
            Should -Invoke Set-ProxyServer -Exactly 1 -ParameterFilter {
                $Proxy -eq $testUri
            }
        }

        It 'stops WinHttpProxy service' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Stop-WinHttpProxy -Exactly 1
        }

        It 'retrieves updated proxy configuration' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'retrieves K2s hosts for NoProxy' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Get-K2sHosts -Exactly 1
        }
    }

    Context 'NoProxy hosts merging' {
        It 'merges existing NoProxy with K2s hosts' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('example.com', 'test.local')
                }
            }
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1') }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverride -contains 'example.com' -and
                $ProxyOverride -contains 'test.local' -and
                $ProxyOverride -contains 'localhost' -and
                $ProxyOverride -contains '127.0.0.1'
            }
        }

        It 'removes duplicate entries from NoProxy list' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', 'example.com')
                }
            }
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1') }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                # Count occurrences of 'localhost' - should be only 1
                ($ProxyOverride | Where-Object { $_ -eq 'localhost' } | Measure-Object).Count -eq 1
            }
        }

        It 'handles empty NoProxy from config' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @()
                }
            }
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1') }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverride -contains 'localhost' -and
                $ProxyOverride -contains '127.0.0.1'
            }
        }
    }

    Context 'WinHttpProxy configuration' {
        It 'configures WinHttpProxy with merged NoProxy hosts' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1
        }

        It 'starts WinHttpProxy service after configuration' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Start-WinHttpProxy -Exactly 1
        }
    }

    Context 'Structured output' {
        It 'sends structured output when EncodeStructuredOutput is set' {
            & $scriptPath -Uri 'http://proxy.test.com:8080' -EncodeStructuredOutput -MessageType 'ProxyResult'
            
            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'ProxyResult' -and
                $Message.Error -eq $null
            }
        }

        It 'does not send structured output by default' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Send-ToCli -Exactly 0
        }
    }

    Context 'Logging' {
        It 'logs completion message' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Write-Log -ParameterFilter {
                $Message -like '*finished*'
            }
        }

        It 'logs errors when exception occurs' {
            Mock Set-ProxyServer { throw 'Test error' }
            
            { & $scriptPath -Uri 'http://proxy.test.com:8080' } | Should -Throw
            
            Should -Invoke Write-Log -ParameterFilter {
                $Error -eq $true -and
                $Message -like '*Test error*'
            }
        }
    }

    Context 'Error handling' {
        It 'throws exception when Set-ProxyServer fails' {
            Mock Set-ProxyServer { throw 'Proxy configuration failed' }
            
            { & $scriptPath -Uri 'http://proxy.test.com:8080' } | Should -Throw '*Proxy configuration failed*'
        }

        It 'throws exception when Get-ProxyConfig fails' {
            Mock Get-ProxyConfig { throw 'Failed to read config' }
            
            { & $scriptPath -Uri 'http://proxy.test.com:8080' } | Should -Throw '*Failed to read config*'
        }

        It 'throws exception when WinHttpProxy operations fail' {
            Mock Stop-WinHttpProxy { throw 'Service stop failed' }
            
            { & $scriptPath -Uri 'http://proxy.test.com:8080' } | Should -Throw '*Service stop failed*'
        }
    }
}
