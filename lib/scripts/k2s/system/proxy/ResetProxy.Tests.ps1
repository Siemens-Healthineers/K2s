# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $scriptPath = "$PSScriptRoot\ResetProxy.ps1"
    
    function global:Initialize-Logging { }
    function global:Reset-ProxyConfig { }
    function global:Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = ''
            HttpsProxy = ''
            NoProxy = @()
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
    Mock Reset-ProxyConfig { }
    Mock Get-ProxyConfig { 
        return [PSCustomObject]@{
            HttpProxy = ''
            HttpsProxy = ''
            NoProxy = @()
        }
    }
    Mock Get-K2sHosts { return @('172.19.1.100', '172.19.1.1', '.local', '.cluster.local') }
    Mock Stop-WinHttpProxy { }
    Mock Start-WinHttpProxy { }
    Mock Set-ProxyConfigInHttpProxy { }
    Mock Send-ToCli { }
    Mock Write-Log { }
}

Describe 'ResetProxy.ps1' -Tag 'unit', 'ci', 'proxy' {
    
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

    Context 'Proxy reset operations' {
        It 'calls Reset-ProxyConfig' {
            & $scriptPath
            
            Should -Invoke Reset-ProxyConfig -Exactly 1
        }

        It 'stops WinHttpProxy service' {
            & $scriptPath
            
            Should -Invoke Stop-WinHttpProxy -Exactly 1
        }

        It 'retrieves updated proxy configuration after reset' {
            & $scriptPath
            
            Should -Invoke Get-ProxyConfig -Exactly 1
        }

        It 'retrieves K2s hosts for NoProxy configuration' {
            & $scriptPath
            
            Should -Invoke Get-K2sHosts -Exactly 1
        }
    }

    Context 'WinHttpProxy configuration after reset' {
        It 'configures WinHttpProxy with empty proxy and K2s hosts only' {
            Mock Get-K2sHosts { return @('localhost', '127.0.0.1', '.local') }
            
            & $scriptPath
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                $Proxy -eq '' -and
                $ProxyOverride -contains 'localhost' -and
                $ProxyOverride -contains '127.0.0.1' -and
                $ProxyOverride -contains '.local'
            }
        }

        It 'starts WinHttpProxy service after configuration' {
            & $scriptPath
            
            Should -Invoke Start-WinHttpProxy -Exactly 1
        }

        It 'uses only K2s hosts as ProxyOverride after reset' {
            Mock Get-K2sHosts { return @('172.19.1.100', '172.19.1.1') }
            
            & $scriptPath
            
            Should -Invoke Set-ProxyConfigInHttpProxy -Exactly 1 -ParameterFilter {
                ($ProxyOverride | Measure-Object).Count -eq 2 -and
                $ProxyOverride -contains '172.19.1.100' -and
                $ProxyOverride -contains '172.19.1.1'
            }
        }
    }

    Context 'Execution order' {
        BeforeEach {
            $script:executionOrder = @()
            
            Mock Reset-ProxyConfig { $script:executionOrder += 'Reset-ProxyConfig' }
            Mock Stop-WinHttpProxy { $script:executionOrder += 'Stop-WinHttpProxy' }
            Mock Get-ProxyConfig { 
                $script:executionOrder += 'Get-ProxyConfig'
                return [PSCustomObject]@{ HttpProxy = ''; NoProxy = @() }
            }
            Mock Get-K2sHosts { 
                $script:executionOrder += 'Get-K2sHosts'
                return @('localhost')
            }
            Mock Set-ProxyConfigInHttpProxy { $script:executionOrder += 'Set-ProxyConfigInHttpProxy' }
            Mock Start-WinHttpProxy { $script:executionOrder += 'Start-WinHttpProxy' }
        }

        It 'executes operations in correct order' {
            & $scriptPath
            
            $script:executionOrder[0] | Should -Be 'Reset-ProxyConfig'
            $script:executionOrder[1] | Should -Be 'Stop-WinHttpProxy'
            $script:executionOrder[2] | Should -Be 'Get-ProxyConfig'
            $script:executionOrder[3] | Should -Be 'Get-K2sHosts'
            $script:executionOrder[4] | Should -Be 'Set-ProxyConfigInHttpProxy'
            $script:executionOrder[5] | Should -Be 'Start-WinHttpProxy'
        }
    }

    Context 'Structured output' {
        It 'sends structured output when EncodeStructuredOutput is set' {
            & $scriptPath -EncodeStructuredOutput -MessageType 'ResetProxyResult'
            
            Should -Invoke Send-ToCli -Exactly 1 -ParameterFilter {
                $MessageType -eq 'ResetProxyResult' -and
                $Message.Error -eq $null
            }
        }

        It 'does not send structured output by default' {
            & $scriptPath
            
            Should -Invoke Send-ToCli -Exactly 0
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
            Mock Reset-ProxyConfig { throw 'Reset failed' }
            
            { & $scriptPath } | Should -Throw
            
            Should -Invoke Write-Log -ParameterFilter {
                $Error -eq $true -and
                $Message -like '*Reset failed*'
            }
        }
    }

    Context 'Error handling' {
        It 'throws exception when Reset-ProxyConfig fails' {
            Mock Reset-ProxyConfig { throw 'Configuration reset failed' }
            
            { & $scriptPath } | Should -Throw '*Configuration reset failed*'
        }

        It 'throws exception when Stop-WinHttpProxy fails' {
            Mock Stop-WinHttpProxy { throw 'Service stop failed' }
            
            { & $scriptPath } | Should -Throw '*Service stop failed*'
        }

        It 'throws exception when Get-ProxyConfig fails' {
            Mock Get-ProxyConfig { throw 'Failed to read config' }
            
            { & $scriptPath } | Should -Throw '*Failed to read config*'
        }

        It 'throws exception when Set-ProxyConfigInHttpProxy fails' {
            Mock Set-ProxyConfigInHttpProxy { throw 'Configuration update failed' }
            
            { & $scriptPath } | Should -Throw '*Configuration update failed*'
        }

        It 'throws exception when Start-WinHttpProxy fails' {
            Mock Start-WinHttpProxy { throw 'Service start failed' }
            
            { & $scriptPath } | Should -Throw '*Service start failed*'
        }
    }
}
