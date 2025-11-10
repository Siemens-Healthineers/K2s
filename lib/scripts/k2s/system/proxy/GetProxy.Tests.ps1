# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $scriptPath = "$PSScriptRoot\GetProxy.ps1"
    function global:Initialize-Logging { }
    function global:Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1')
        }
    }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param($Message, $Error) }
    
    Mock Import-Module { }
    Mock Initialize-Logging { }
    Mock Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1')
        }
    }
    Mock Send-ToCli { }
    Mock Write-Log { }
}

Describe 'GetProxy.ps1' -Tag 'unit', 'ci', 'proxy' {
    
    Context 'Parameter validation' {
        It 'runs without parameters' {
            { & $scriptPath } | Should -Not -Throw
        }

        It 'accepts ShowLogs switch parameter' {
            { & $scriptPath -ShowLogs } | Should -Not -Throw
        }

        It 'accepts EncodeStructuredOutput switch parameter' {
            { & $scriptPath -EncodeStructuredOutput -MessageType 'Test' } | Should -Not -Throw
        }
    }

    Context 'Module imports' {
        It 'imports infra module' {
            & $scriptPath
            
            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.infra.module.psm1'
            }
        }

        It 'imports node module' {
            & $scriptPath
            
            Should -Invoke Import-Module -ParameterFilter {
                $Name -like '*k2s.node.module.psm1'
            }
        }

        It 'initializes logging' {
            & $scriptPath
            
            Should -Invoke Initialize-Logging -Exactly 1
        }
    }

    Context 'Proxy retrieval' {
        It 'retrieves proxy configuration' {
            & $scriptPath
            
            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'returns result with Proxy property' {
            $result = & $scriptPath
            
            $result.Proxy | Should -Not -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }

        It 'returns HttpProxy value from configuration' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://custom.proxy.net:3128'
                }
            }
            
            $result = & $scriptPath
            
            $result.Proxy | Should -Be 'http://custom.proxy.net:3128'
        }

        It 'handles null proxy configuration' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = $null
                }
            }
            
            $result = & $scriptPath
            
            $result.Proxy | Should -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }
    }

    Context 'Structured output' {
        It 'sends structured output when EncodeStructuredOutput is set' {
            & $scriptPath -EncodeStructuredOutput -MessageType 'GetProxyResult'
            
            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'GetProxyResult' -and
                $Message.Proxy -eq 'http://proxy.example.com:8080' -and
                $Message.Error -eq $null
            }
        }

        It 'does not send structured output by default' {
            & $scriptPath
            
            Should -Invoke Send-ToCli -Exactly 0
        }

        It 'returns hashtable with Error and Proxy properties' {
            $result = & $scriptPath
            
            $result | Should -BeOfType [hashtable]
            $result.ContainsKey('Error') | Should -Be $true
            $result.ContainsKey('Proxy') | Should -Be $true
        }
    }

    Context 'Logging' {
        It 'logs completion message' {
            & $scriptPath
            
            Should -Invoke Write-Log -ParameterFilter {
                $Message -like '*finished*'
            }
        }

        It 'logs errors when exception occurs' {
            Mock Get-ProxyConfig { throw 'Configuration read failed' }
            
            { & $scriptPath } | Should -Throw
            
            Should -Invoke Write-Log -ParameterFilter {
                $Error -eq $true -and
                $Message -like '*Configuration read failed*'
            }
        }
    }

    Context 'Error handling' {
        It 'throws exception when Get-ProxyConfig fails' {
            Mock Get-ProxyConfig { throw 'Failed to read config' }
            
            { & $scriptPath } | Should -Throw '*Failed to read config*'
        }

        It 'logs error with stack trace on failure' {
            Mock Get-ProxyConfig { throw 'Test error' }
            
            { & $scriptPath } | Should -Throw
            
            Should -Invoke Write-Log -ParameterFilter {
                $Error -eq $true -and
                $Message -like '*Test error*' -and
                $Message -like '*ScriptStackTrace*'
            }
        }
    }
}
