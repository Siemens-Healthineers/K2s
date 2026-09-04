# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $modulePath = "$PSScriptRoot\common-setup.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe 'Get-KubenodeNoProxy' -Tag 'unit', 'ci', 'proxy' {
    It 'derives K2s network entries from configured values' {
        InModuleScope $moduleName {
            Mock Get-ConfiguredIPControlPlane { '172.19.1.100' }
            Mock Get-ConfiguredKubeSwitchIP { '172.19.1.1' }
            Mock Get-ConfiguredClusterCIDR { '10.20.0.0/16' }
            Mock Get-ConfiguredClusterCIDRServices { '10.21.0.0/16' }
            Mock Get-ConfiguredKubeDnsServiceIP { '10.21.0.10' }

            $entries = (Get-KubenodeNoProxy) -split ','

            $entries | Should -Contain '172.19.1.100'
            $entries | Should -Contain '172.19.1.1'
            $entries | Should -Contain '10.20.0.0/16'
            $entries | Should -Contain '10.21.0.0/16'
            $entries | Should -Contain '10.21.0.10'
            $entries | Should -Contain '.cluster.local'
            $entries | Should -Contain '.svc'
        }
    }
}