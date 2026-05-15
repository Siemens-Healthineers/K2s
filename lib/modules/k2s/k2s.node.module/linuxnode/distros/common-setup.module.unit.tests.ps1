# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $modulePath = "$PSScriptRoot\common-setup.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name

    Mock -ModuleName $moduleName Write-Log { }
}

Describe 'Get-NormalizedNoProxyHostFromMirrorEndpoint' -Tag 'unit', 'ci', 'proxy' {
    It 'extracts host from endpoint with scheme, path and port' {
        InModuleScope $moduleName {
            $result = Get-NormalizedNoProxyHostFromMirrorEndpoint -MirrorEndpoint 'https://Example.Internal:5000/v2/'
            $result | Should -Be 'example.internal'
        }
    }

    It 'extracts host from host:port endpoint without scheme' {
        InModuleScope $moduleName {
            $result = Get-NormalizedNoProxyHostFromMirrorEndpoint -MirrorEndpoint 'registry.local:30500'
            $result | Should -Be 'registry.local'
        }
    }

    It 'returns lowercase host for plain hostname endpoint' {
        InModuleScope $moduleName {
            $result = Get-NormalizedNoProxyHostFromMirrorEndpoint -MirrorEndpoint 'SHSK2S.Azurecr.io'
            $result | Should -Be 'shsk2s.azurecr.io'
        }
    }

    It 'returns null for empty endpoint' {
        InModuleScope $moduleName {
            $result = Get-NormalizedNoProxyHostFromMirrorEndpoint -MirrorEndpoint ''
            $result | Should -BeNullOrEmpty
        }
    }

    It 'returns null for invalid endpoint' {
        InModuleScope $moduleName {
            $result = Get-NormalizedNoProxyHostFromMirrorEndpoint -MirrorEndpoint 'http://[::1'
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Get-CrioNoProxySettings' -Tag 'unit', 'ci', 'proxy' {
    BeforeEach {
        Mock -ModuleName $moduleName Get-ConfiguredIPControlPlane { return '172.19.1.100' }
        Mock -ModuleName $moduleName Get-ConfiguredKubeSwitchIP { return '172.19.1.1' }
        Mock -ModuleName $moduleName Get-ConfiguredClusterCIDR { return '172.20.0.0/16' }
        Mock -ModuleName $moduleName Get-ConfiguredClusterCIDRServices { return '172.21.0.0/16' }
    }

    It 'builds no_proxy list from base entries and mirror hosts' {
        Mock -ModuleName $moduleName Get-MirrorRegistries {
            return @(
                [PSCustomObject]@{ mirror = 'https://mirror.internal:5000/v2/' },
                [PSCustomObject]@{ mirror = 'registry.local:30500' }
            )
        }

        InModuleScope $moduleName {
            $entries = (Get-CrioNoProxySettings) -split ','

            $entries | Should -Contain 'localhost'
            $entries | Should -Contain '127.0.0.1'
            $entries | Should -Contain '::1'
            $entries | Should -Contain '.local'
            $entries | Should -Contain '.cluster.local'
            $entries | Should -Contain '172.19.1.100'
            $entries | Should -Contain '172.19.1.1'
            $entries | Should -Contain '172.20.0.0/16'
            $entries | Should -Contain '172.21.0.0/16'
            $entries | Should -Contain 'mirror.internal'
            $entries | Should -Contain 'registry.local'
            $entries | Should -Not -Contain 'https://mirror.internal:5000/v2/'
            $entries | Should -Not -Contain 'registry.local:30500'
        }
    }

    It 'de-duplicates entries and skips invalid mirror endpoints' {
        Mock -ModuleName $moduleName Get-MirrorRegistries {
            return @(
                [PSCustomObject]@{ mirror = 'MIRROR.INTERNAL:5000' },
                [PSCustomObject]@{ mirror = 'https://mirror.internal/v2' },
                [PSCustomObject]@{ mirror = '' },
                [PSCustomObject]@{ mirror = 'http://[::1' }
            )
        }

        InModuleScope $moduleName {
            $entries = (Get-CrioNoProxySettings) -split ','

            ($entries | Where-Object { $_ -eq 'mirror.internal' } | Measure-Object).Count | Should -Be 1
            $entries | Where-Object { [string]::IsNullOrWhiteSpace($_) } | Should -BeNullOrEmpty
        }
    }

    It 'returns base entries when mirror list is empty' {
        Mock -ModuleName $moduleName Get-MirrorRegistries { return @() }

        InModuleScope $moduleName {
            $entries = (Get-CrioNoProxySettings) -split ','

            $entries | Should -Contain 'localhost'
            $entries | Should -Contain '172.19.1.100'
            $entries | Should -Contain '172.19.1.1'
            $entries | Should -Contain '172.20.0.0/16'
            $entries | Should -Contain '172.21.0.0/16'
        }
    }
}