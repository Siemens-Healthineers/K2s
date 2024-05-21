# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\upgrade.module.psm1"

    $moduleName = (Import-Module $module -Force -PassThru).Name
}

Describe 'Assert-UpgradeVersionIsValid' -Tag 'unit', 'ci', 'upgrade' {
    BeforeAll {
        Mock -ModuleName $moduleName Write-Log {}
    }

    It "returns '<ExpectedResult>' when current version is '<Current>' and new version is'<New>'" -ForEach @(
        @{ ExpectedResult = $true; Current = '1.0.0'; New = '1.0.1' }
        @{ ExpectedResult = $true; Current = '1.0.0'; New = '1.0.11' }
        @{ ExpectedResult = $true; Current = '1.0.0'; New = '1.1.0' }
        @{ ExpectedResult = $true; Current = '1.0.0'; New = '1.1.11' }
        @{ ExpectedResult = $true; Current = '1.1.1'; New = '1.2.0' }
        @{ ExpectedResult = $true; Current = '1.2.3'; New = '1.3.444' }
        @{ ExpectedResult = $true; Current = '2.3.4'; New = '2.4.0' }

        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.2.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '2.0.0' }
        @{ ExpectedResult = $false; Current = '2.0.0'; New = '2.2.0' }
        
        @{ ExpectedResult = $false; Current = '1.1.0'; New = '1.0.0' }
        @{ ExpectedResult = $false; Current = '1.1.1'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '2.0.0'; New = '1.0.0' }

        @{ ExpectedResult = $false; Current = '1.0'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1' }

        @{ ExpectedResult = $false; Current = '1.o.o'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1.o' }

        @{ ExpectedResult = $false; Current = '1'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '2' }

        @{ ExpectedResult = $false; Current = '1.0.0.0'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1.0.0' }

        @{ ExpectedResult = $false; Current = '1.0.0-beta'; New = '1.1.0' }
        @{ ExpectedResult = $false; Current = '1.0.0'; New = '1.1.0-beta' }
    ) {
        InModuleScope $moduleName -Parameters @{ ExpectedResult = $ExpectedResult; Current = $Current; New = $New } {
            Assert-UpgradeVersionIsValid -VersionInstalled $Current -VersionToBeUsed $New | Should -Be $ExpectedResult
        }
    }
}