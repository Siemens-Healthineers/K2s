# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    function Get-HnsNetwork {}
    function Remove-HnsNetwork {}
    function Get-VMSwitch {}
    function Remove-VMSwitch {}

    $modulePath = Join-Path $PSScriptRoot 'windows-host-network.module.psm1'
    Import-Module $modulePath -Force
}

Describe 'Test-DefaultSwitch' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log -ModuleName windows-host-network.module
        Mock Get-ConfiguredK2sSubnets -ModuleName windows-host-network.module {
            @(
                @{ Name = 'masterNetworkCIDR'; Value = '172.19.1.0/24' },
                @{ Name = 'podNetworkCIDR'; Value = '172.20.0.0/16' },
                @{ Name = 'servicesCIDR'; Value = '172.21.0.0/16' },
                @{ Name = 'loopbackAdapterCIDR'; Value = '172.22.1.0/24' }
            )
        }
        Mock Remove-K2sDefaultSwitch -ModuleName windows-host-network.module
        Mock Start-Sleep -ModuleName windows-host-network.module
    }

    It 'returns without removal when the Default Switch does not conflict' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            [pscustomobject]@{ IPAddress = '192.168.128.1'; PrefixLength = 20 }
        }

        Test-DefaultSwitch -ResolveConflict

        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'throws without removal when recovery is not requested' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            [pscustomobject]@{ IPAddress = '172.21.16.1'; PrefixLength = 20 }
        }

        { Test-DefaultSwitch } | Should -Throw '*collides with K2s network configuration servicesCIDR*'

        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'removes a conflicting switch and succeeds after revalidation' {
        $global:defaultSwitchRemovedForTest = $false
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            if (-not $global:defaultSwitchRemovedForTest) {
                [pscustomobject]@{ IPAddress = '172.21.160.1'; PrefixLength = 20 }
            }
        }
        Mock Remove-K2sDefaultSwitch -ModuleName windows-host-network.module {
            $global:defaultSwitchRemovedForTest = $true
        }

        try {
            Test-DefaultSwitch -ResolveConflict -RetryDelaySeconds 0
        }
        finally {
            Remove-Variable -Name defaultSwitchRemovedForTest -Scope Global -ErrorAction SilentlyContinue
        }

        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Get-NetIPAddress -ModuleName windows-host-network.module -Times 2 -Exactly
    }

    It 'throws after bounded recovery attempts keep finding a conflict' {
        Mock Get-NetIPAddress -ModuleName windows-host-network.module {
            [pscustomobject]@{ IPAddress = '172.21.16.1'; PrefixLength = 20 }
        }

        { Test-DefaultSwitch -ResolveConflict -MaxAttempts 2 -RetryDelaySeconds 0 } |
            Should -Throw '*Automatic recovery failed after 2 attempts*'

        Assert-MockCalled Remove-K2sDefaultSwitch -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Get-NetIPAddress -ModuleName windows-host-network.module -Times 2 -Exactly
    }
}

Describe 'Remove-K2sDefaultSwitch' -Tag 'unit', 'ci', 'network' {
    BeforeEach {
        Mock Write-Log -ModuleName windows-host-network.module
        Mock Import-K2sHnsModule -ModuleName windows-host-network.module
        Mock Get-HnsNetwork -ModuleName windows-host-network.module
        Mock Remove-HnsNetwork -ModuleName windows-host-network.module
        Mock Get-VMSwitch -ModuleName windows-host-network.module
        Mock Remove-VMSwitch -ModuleName windows-host-network.module
    }

    It 'removes the Default Switch through HNS' {
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'Default Switch'; Id = 'default-switch-id' }
        }

        & (Get-Module windows-host-network.module) { Remove-K2sDefaultSwitch }

        Assert-MockCalled Import-K2sHnsModule -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Remove-HnsNetwork -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            $InputObjects.Id -eq 'default-switch-id'
        }
        Assert-MockCalled Remove-VMSwitch -ModuleName windows-host-network.module -Times 0
    }

    It 'uses Hyper-V removal when no HNS Default Switch exists' {
        Mock Get-VMSwitch -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'Default Switch' }
        }

        & (Get-Module windows-host-network.module) { Remove-K2sDefaultSwitch }

        Assert-MockCalled Remove-HnsNetwork -ModuleName windows-host-network.module -Times 0
        Assert-MockCalled Remove-VMSwitch -ModuleName windows-host-network.module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Default Switch' -and $Force
        }
    }

    It 'throws when the conflicting switch cannot be found for removal' {
        { & (Get-Module windows-host-network.module) { Remove-K2sDefaultSwitch } } |
            Should -Throw '*could not be found through HNS or Hyper-V*'
    }

    It 'continues to revalidation when HNS removal succeeds but Hyper-V reports a stale switch' {
        Mock Get-HnsNetwork -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'Default Switch'; Id = 'default-switch-id' }
        }
        Mock Get-VMSwitch -ModuleName windows-host-network.module {
            [pscustomobject]@{ Name = 'Default Switch' }
        }
        Mock Remove-VMSwitch -ModuleName windows-host-network.module {
            throw 'Default Switch is managed by Windows'
        }

        { & (Get-Module windows-host-network.module) { Remove-K2sDefaultSwitch } } | Should -Not -Throw

        Assert-MockCalled Remove-HnsNetwork -ModuleName windows-host-network.module -Times 1 -Exactly
        Assert-MockCalled Remove-VMSwitch -ModuleName windows-host-network.module -Times 1 -Exactly
    }
}
