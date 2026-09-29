# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

Describe 'Enable-MissingFeature' -Tag 'unit', 'ci', 'prerequisites' {
BeforeAll {
    $modulePath = "$PSScriptRoot/system.module.psm1"
    $parseErrors = $null
    $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw ($parseErrors | Out-String) }
    $featureFunction = $moduleAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Enable-MissingFeature'
    }, $false)
    . ([scriptblock]::Create($featureFunction.Extent.Text))

    function Write-Log { param($Message) }
    function Get-WindowsOptionalFeature { [CmdletBinding()] param([switch]$Online, $FeatureName) }
    function Enable-WindowsOptionalFeature {
        [CmdletBinding()]
        param([switch]$Online, $FeatureName, [switch]$All, [switch]$NoRestart)
    }
}

    BeforeEach {
        Mock Write-Log {}
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Disabled' } }
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $false } }
    }

    It 'returns the restart requirement reported by DISM' {
        Mock Enable-WindowsOptionalFeature { [pscustomobject]@{ RestartNeeded = $true } }

        Enable-MissingFeature -Name 'Containers' | Should -BeTrue
    }

    It 'does not request a restart when DISM reports none is needed' {
        Enable-MissingFeature -Name 'Containers' | Should -BeFalse
    }

    It 'fails when DISM does not return feature state' {
        Mock Enable-WindowsOptionalFeature {}

        { Enable-MissingFeature -Name 'Containers' } | Should -Throw '*returned no result*'
    }

    It 'does not enable or request a restart for an enabled feature' {
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }

        Enable-MissingFeature -Name 'Containers' | Should -BeFalse

        Should -Invoke Enable-WindowsOptionalFeature -Times 0 -Exactly
    }
}
