# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $modulePath = "$PSScriptRoot\httpproxy.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe 'Get-RegistryMirrorHosts' -Tag 'unit', 'ci', 'proxy' {
    It 'returns configured mirror addresses without ports or paths' {
        InModuleScope $moduleName {
            Mock Get-MirrorRegistries {
                @(
                    [pscustomobject]@{ mirror = '10.81.79.18' },
                    [pscustomobject]@{ mirror = 'https://registry.internal.example:5000/v2' }
                )
            }

            $result = Get-RegistryMirrorHosts

            $result | Should -Contain '10.81.79.18'
            $result | Should -Contain 'registry.internal.example'
        }
    }
}