# SPDX-FileCopyrightText: © 2026 The K2s Authors
# SPDX-License-Identifier: Apache-2.0

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

Describe 'Remove-K2sAppLockerRules' -Tag 'unit', 'ci', 'cleanup' {
    BeforeAll {
        $modulePath = "$PSScriptRoot/system.module.psm1"
        $parseErrors = $null
        $moduleAst = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$parseErrors)
        if ($parseErrors) { throw ($parseErrors | Out-String) }
        $appLockerFunction = $moduleAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-K2sAppLockerRules'
        }, $false)
        . ([scriptblock]::Create($appLockerFunction.Extent.Text))

        function Write-Log { param($Message) }
        function Get-AppLockerPolicy { [CmdletBinding()] param([switch]$Xml, [switch]$Local) }
        function Set-AppLockerPolicy { [CmdletBinding()] param($XmlPolicy) }
    }
    BeforeEach {
        Mock Write-Log {}
        Mock Set-AppLockerPolicy {}
    }

    It 'safely returns when AppLocker returns null' {
        Mock Get-AppLockerPolicy { $null }

        { Remove-K2sAppLockerRules } | Should -Not -Throw
        Should -Invoke Set-AppLockerPolicy -Times 0 -Exactly
    }

    It 'safely returns when AppLocker returns empty string' {
        Mock Get-AppLockerPolicy { '' }

        { Remove-K2sAppLockerRules } | Should -Not -Throw
        Should -Invoke Set-AppLockerPolicy -Times 0 -Exactly
    }

    It 'removes the rule when present in policy' {
        $script:xmlPolicy = @"
<AppLockerPolicy Version="1">
    <RuleCollection Type="Exe">
        <FilePathRule Id="0bf9e8e6-42cf-41cc-8737-68c788984e0d" Name="k2s rule" Action="Allow">
        </FilePathRule>
    </RuleCollection>
</AppLockerPolicy>
"@
        Mock Get-AppLockerPolicy { $script:xmlPolicy }

        { Remove-K2sAppLockerRules } | Should -Not -Throw
        Should -Invoke Set-AppLockerPolicy -Times 1 -Exactly
    }
}
