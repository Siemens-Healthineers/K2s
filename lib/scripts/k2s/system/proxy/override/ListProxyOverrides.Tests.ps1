# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $scriptPath = "$PSScriptRoot\ListProxyOverrides.ps1"
    
    function global:Initialize-Logging { }
    function global:Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = 'http://proxy.example.com:8080'
            HttpsProxy = 'http://proxy.example.com:8080'
            NoProxy = @('localhost', '127.0.0.1', '*.example.com', '.local')
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
            NoProxy = @('localhost', '127.0.0.1', '*.example.com', '.local')
        }
    }
    Mock Send-ToCli { }
    Mock Write-Log { }
}

Describe 'ListProxyOverrides.ps1' -Tag 'unit', 'ci', 'proxy' {
    
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

    Context 'Listing proxy overrides' {
        It 'retrieves proxy configuration' {
            & $scriptPath
            
            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'returns result with ProxyOverrides property' {
            $result = & $scriptPath
            
            $result.ProxyOverrides | Should -Not -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }

        It 'returns NoProxy list from configuration' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    NoProxy = @('override1', 'override2', 'override3')
                }
            }
            
            $result = & $scriptPath
            
            $result.ProxyOverrides | Should -HaveCount 3
            $result.ProxyOverrides | Should -Contain 'override1'
            $result.ProxyOverrides | Should -Contain 'override2'
            $result.ProxyOverrides | Should -Contain 'override3'
        }

        It 'handles empty NoProxy list' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    NoProxy = @()
                }
            }
            
            $result = & $scriptPath
            
            $result.ProxyOverrides | Should -BeNullOrEmpty
            $result.Error | Should -BeNullOrEmpty
        }

        It 'handles null NoProxy' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    NoProxy = $null
                }
            }
            
            $result = & $scriptPath
            
            $result.ProxyOverrides | Should -BeNullOrEmpty
        }

        It 'returns all types of override entries' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    NoProxy = @('localhost', '*.domain.com', '192.168.1.0/24', '.local')
                }
            }
            
            $result = & $scriptPath
            
            $result.ProxyOverrides | Should -Contain 'localhost'
            $result.ProxyOverrides | Should -Contain '*.domain.com'
            $result.ProxyOverrides | Should -Contain '192.168.1.0/24'
            $result.ProxyOverrides | Should -Contain '.local'
        }
    }

    Context 'Structured output' {
        It 'sends structured output when EncodeStructuredOutput is set' {
            & $scriptPath -EncodeStructuredOutput -MessageType 'ListOverridesResult'
            
            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'ListOverridesResult' -and
                $Message.ProxyOverrides -ne $null -and
                $Message.Error -eq $null
            }
        }

        It 'sends correct ProxyOverrides in structured output' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    NoProxy = @('entry1', 'entry2')
                }
            }
            
            & $scriptPath -EncodeStructuredOutput -MessageType 'ListOverridesResult'
            
            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $Message.ProxyOverrides.Count -eq 2 -and
                $Message.ProxyOverrides -contains 'entry1' -and
                $Message.ProxyOverrides -contains 'entry2'
            }
        }

        It 'returns result directly when not encoding' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    NoProxy = @('test1', 'test2')
                }
            }
            
            $result = & $scriptPath
            
            $result | Should -BeOfType [hashtable]
            $result.ProxyOverrides | Should -HaveCount 2
        }

        It 'does not send structured output by default' {
            & $scriptPath
            
            Should -Invoke Send-ToCli -Exactly 0
        }
    }

    Context 'Return value structure' {
        It 'returns hashtable with Error and ProxyOverrides properties' {
            $result = & $scriptPath
            
            $result | Should -BeOfType [hashtable]
            $result.ContainsKey('Error') | Should -Be $true
            $result.ContainsKey('ProxyOverrides') | Should -Be $true
        }

        It 'sets Error to null on success' {
            $result = & $scriptPath
            
            $result.Error | Should -BeNullOrEmpty
        }

        It 'includes all NoProxy entries in ProxyOverrides' {
            Mock Get-ProxyConfig { 
                return [PSCustomObject]@{
                    NoProxy = @('a', 'b', 'c', 'd', 'e')
                }
            }
            
            $result = & $scriptPath
            
            $result.ProxyOverrides | Should -HaveCount 5
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

    Context 'No service operations' {
        It 'does not stop WinHttpProxy' {
            & $scriptPath
            
            Should -Not -Invoke Stop-WinHttpProxy
        }

        It 'does not start WinHttpProxy' {
            & $scriptPath
            
            Should -Not -Invoke Start-WinHttpProxy
        }

        It 'does not modify proxy configuration' {
            & $scriptPath
            
            Should -Not -Invoke Set-ProxyConfigInHttpProxy
        }

        It 'only reads configuration without modifications' {
            & $scriptPath
            
            Should -Invoke Get-ProxyConfig -Exactly 1
            Should -Not -Invoke Add-NoProxyEntry
            Should -Not -Invoke Remove-NoProxyEntry
            Should -Not -Invoke Set-ProxyServer
        }
    }
}
