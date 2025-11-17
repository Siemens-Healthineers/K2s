# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $scriptPath = "$PSScriptRoot\SetProxy.ps1"
    
    function global:Initialize-Logging { }
    
    function global:Set-ProxyServer { param($Proxy) }
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
    function global:Set-ProxyConfigInHttpProxy { param($Proxy, $ProxyOverrides) }
    function global:Send-ToCli { param($MessageType, $Message) }
    function global:Write-Log { param([string]$Message, [switch]$Error) }
    
    Mock -CommandName Import-Module { }
    Mock -CommandName Initialize-Logging { }
}

Describe 'SetProxy.ps1' -Tag 'unit', 'ci', 'proxy' {
    
    Context 'Parameter validation' {
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
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
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig { 
                return [PSCustomObject]@{ HttpProxy = 'http://test.proxy:8080'; NoProxy = @() }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }
        
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
        BeforeEach {
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }
        
        It 'calls Set-ProxyServer with provided Uri' {
            Mock -CommandName Set-ProxyServer { }
            $testUri = 'http://custom.proxy.com:9090'
            
            & $scriptPath -Uri $testUri
            
            Should -Invoke Set-ProxyServer -Exactly 1 -ParameterFilter {
                $Proxy -eq $testUri
            }
        }

        It 'stops WinHttpProxy service' {
            Mock -CommandName Set-ProxyServer { }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Stop-WinHttpProxy -Exactly 1
        }

        It 'retrieves updated proxy configuration' {
            Mock -CommandName Set-ProxyServer { }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'retrieves K2s hosts for NoProxy' {
            Mock -CommandName Set-ProxyServer { }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Get-K2sHosts -Exactly 1
        }
    }

    Context 'NoProxy hosts merging' {
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }
        
        It 'merges existing NoProxy with K2s hosts' {
            Mock -CommandName Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('example.com', 'test.local')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost', '127.0.0.1') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverrides -contains 'example.com' -and
                $ProxyOverrides -contains 'test.local' -and
                $ProxyOverrides -contains 'localhost' -and
                $ProxyOverrides -contains '127.0.0.1'
            }
        }

        It 'removes duplicate entries from NoProxy list' {
            Mock -CommandName Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost', 'example.com')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost', '127.0.0.1') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                # Count occurrences of 'localhost' - should be only 1
                ($ProxyOverrides | Where-Object { $_ -eq 'localhost' } | Measure-Object).Count -eq 1
            }
        }

        It 'handles empty NoProxy from config' {
            Mock -CommandName Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @()
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost', '127.0.0.1') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $ProxyOverrides -contains 'localhost' -and
                $ProxyOverrides -contains '127.0.0.1'
            }
        }
    }

    Context 'WinHttpProxy configuration' {
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }
        
        It 'configures WinHttpProxy with merged NoProxy hosts' {
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1
        }

        It 'starts WinHttpProxy service after configuration' {
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Start-WinHttpProxy -Exactly 1
        }
    }

    Context 'Structured output' {
        BeforeEach {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Write-Log { }
        }
        
        It 'sends structured output when EncodeStructuredOutput is set' {
            Mock -CommandName Send-ToCli { }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080' -EncodeStructuredOutput -MessageType 'ProxyResult'
            
            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'ProxyResult' -and
                $Message.Error -eq $null
            }
        }

        It 'does not send structured output by default' {
            Mock -CommandName Send-ToCli { }
            
            & $scriptPath -Uri 'http://proxy.test.com:8080'
            
            Should -Invoke Send-ToCli -Exactly 0
        }
    }

    Context 'Error handling' {
        BeforeEach {
            Mock -CommandName Stop-WinHttpProxy { }
            Mock -CommandName Get-ProxyConfig { 
                return [PSCustomObject]@{
                    HttpProxy = 'http://proxy.example.com:8080'
                    NoProxy = @('localhost')
                }
            }
            Mock -CommandName Get-K2sHosts { return @('localhost') }
            Mock -CommandName Set-ProxyConfigInHttpProxy { }
            Mock -CommandName Start-WinHttpProxy { }
            Mock -CommandName Send-ToCli { }
            Mock -CommandName Write-Log { }
        }
        
        It 'throws exception when Set-ProxyServer fails' {
            Mock -CommandName Set-ProxyServer { throw 'Proxy configuration failed' }
            
            { & $scriptPath -Uri 'http://proxy.test.com:8080' } | Should -Throw '*Proxy configuration failed*'
        }

        It 'throws exception when Get-ProxyConfig fails' {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Get-ProxyConfig { throw 'Failed to read config' }
            
            { & $scriptPath -Uri 'http://proxy.test.com:8080' } | Should -Throw '*Failed to read config*'
        }

        It 'throws exception when WinHttpProxy operations fail' {
            Mock -CommandName Set-ProxyServer { }
            Mock -CommandName Stop-WinHttpProxy { throw 'Service stop failed' }
            
            { & $scriptPath -Uri 'http://proxy.test.com:8080' } | Should -Throw '*Service stop failed*'
        }
    }
}

