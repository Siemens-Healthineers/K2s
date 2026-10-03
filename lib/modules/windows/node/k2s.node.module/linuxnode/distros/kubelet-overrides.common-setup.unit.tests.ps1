# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot 'common-setup.module.psm1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Failed to parse '$modulePath': $($parseErrors[0].Message)"
    }

    $functionAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Set-K2sLinuxKubeletOverride'
    }, $true)
    if ($null -eq $functionAst) {
        throw "Set-K2sLinuxKubeletOverride was not found in '$modulePath'"
    }

    $testModuleName = 'K2sLinuxKubeletOverrideTestModule_' + [guid]::NewGuid().ToString('N')
    $script:moduleName = (New-Module -Name $testModuleName -ScriptBlock ([scriptblock]::Create($functionAst.Extent.Text)) | Import-Module -PassThru -Force).Name
}

Describe 'Set-K2sLinuxKubeletOverride' -Tag 'unit', 'ci', 'kubelet-overrides' {
    BeforeEach {
        $env:TEMP = $TestDrive
    }

    It 'recognizes the managed header with LF and CRLF line endings' {
        $managedHeader = '# This file is managed by K2s. Do not edit.'
        $expected = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($managedHeader))

        foreach ($lineEnding in "`n", "`r`n") {
            $lineBytes = [Text.Encoding]::UTF8.GetBytes($managedHeader + $lineEnding) |
                Where-Object { $_ -ne 10 -and $_ -ne 13 }
            [Convert]::ToBase64String($lineBytes) | Should -BeExactly $expected
        }
    }

    It 'creates the drop-in directory and removes only a regular managed file when overrides are absent' {
        InModuleScope $moduleName {
            function Get-K2sKubeletOverrideContent { param([Parameter(ValueFromRemainingArguments)]$Rest) }
            function Invoke-CmdOnVmViaSSHKey { param([string]$CmdToExecute, [string]$UserName, [string]$IpAddress, [switch]$NoLog) }

            Mock Get-K2sKubeletOverrideContent { $null }
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $true; Output = '' } }

            Set-K2sLinuxKubeletOverride -EffectiveInstallConfigPath 'C:\config\effective.json' -UserName 'remote' -IpAddress '172.19.1.100'

            Should -Invoke Invoke-CmdOnVmViaSSHKey -Exactly 1 -ParameterFilter {
                $CmdToExecute -match '^set -e; sudo mkdir -p /etc/kubernetes/kubelet\.conf\.d;' -and
                $CmdToExecute -match 'test -e \$target \|\| sudo test -L \$target' -and
                $CmdToExecute -match '! sudo test -f \$target \|\| sudo test -L \$target' -and
                $CmdToExecute -match "firstLineEncoded=\`$\(sudo head -n 1 \`$target \| tr -d '\\r\\n' \| base64 -w0\)" -and
                $CmdToExecute -match 'if \[ x\$firstLineEncoded != xIyBUaGlzIGZpbGUgaXMgbWFuYWdlZCBieSBLMnMuIERvIG5vdCBlZGl0Lg== \]' -and
                $CmdToExecute -match 'sudo rm -f -- \$target' -and
                $CmdToExecute -match 'sudo systemctl restart kubelet'
            }
        }
    }

    It 'copies and atomically replaces managed content with collision checks' {
        InModuleScope $moduleName {
            function Get-K2sKubeletOverrideContent { param([Parameter(ValueFromRemainingArguments)]$Rest) }
            function Copy-ToRemoteComputerViaSshKey { param([string]$Source, [string]$Target, [string]$UserName, [string]$IpAddress) }
            function Invoke-CmdOnVmViaSSHKey { param([string]$CmdToExecute, [string]$UserName, [string]$IpAddress, [switch]$NoLog) }

            Mock Get-K2sKubeletOverrideContent { "# This file is managed by K2s. Do not edit.`nmaxPods: 42`n" }
            Mock Copy-ToRemoteComputerViaSshKey {}
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $true; Output = '' } }

            Set-K2sLinuxKubeletOverride -EffectiveInstallConfigPath 'C:\config\effective.json' -UserName 'remote' -IpAddress '172.19.1.100'

            Should -Invoke Copy-ToRemoteComputerViaSshKey -Exactly 1 -ParameterFilter {
                $Target -match '^/tmp/20-k2s-install-config\.[a-f0-9]{32}\.conf$'
            }
            Should -Invoke Invoke-CmdOnVmViaSSHKey -Exactly 1 -ParameterFilter {
                $CmdToExecute -match '^set -e;' -and
                $CmdToExecute -match "trap 'sudo rm -f --" -and
                $CmdToExecute -match '\$source.*\$targetTemp' -and
                $CmdToExecute -match 'Refusing to replace non-regular kubelet drop-in collision' -and
                $CmdToExecute -match "firstLineEncoded=\`$\(sudo head -n 1 \`$target \| tr -d '\\r\\n' \| base64 -w0\)" -and
                $CmdToExecute -match 'if \[ x\$firstLineEncoded != xIyBUaGlzIGZpbGUgaXMgbWFuYWdlZCBieSBLMnMuIERvIG5vdCBlZGl0Lg== \]' -and
                $CmdToExecute -match 'sudo cp \$source \$targetTemp' -and
                $CmdToExecute -match 'sudo mv -f \$targetTemp \$target' -and
                $CmdToExecute -match 'sudo systemctl restart kubelet'
            }
        }
    }

    It 'uses the password copy path when credentials are supplied' {
        InModuleScope $moduleName {
            function Get-K2sKubeletOverrideContent { param([Parameter(ValueFromRemainingArguments)]$Rest) }
            function Copy-ToRemoteComputerViaUserAndPwd { param([string]$Source, [string]$Target, [string]$UserName, [string]$UserPwd, [string]$IpAddress) }
            function Invoke-CmdOnVmViaSSHKey { param([string]$CmdToExecute, [string]$UserName, [string]$IpAddress, [switch]$NoLog) }

            Mock Get-K2sKubeletOverrideContent { "# This file is managed by K2s. Do not edit.`nmaxPods: 42`n" }
            Mock Copy-ToRemoteComputerViaUserAndPwd {}
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $true; Output = '' } }

            Set-K2sLinuxKubeletOverride -EffectiveInstallConfigPath 'C:\config\effective.json' -UserName 'remote' -UserPwd 'pwd' -IpAddress '172.19.1.100'

            Should -Invoke Copy-ToRemoteComputerViaUserAndPwd -Exactly 1 -ParameterFilter {
                $UserName -eq 'remote' -and $UserPwd -eq 'pwd' -and $IpAddress -eq '172.19.1.100'
            }
        }
    }

    It 'reports non-regular removal collisions returned by the remote transaction' {
        InModuleScope $moduleName {
            function Get-K2sKubeletOverrideContent { param([Parameter(ValueFromRemainingArguments)]$Rest) }
            function Invoke-CmdOnVmViaSSHKey { param([string]$CmdToExecute, [string]$UserName, [string]$IpAddress, [switch]$NoLog) }

            Mock Get-K2sKubeletOverrideContent { $null }
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; Output = 'Refusing to remove non-regular kubelet drop-in collision' } }

            { Set-K2sLinuxKubeletOverride -EffectiveInstallConfigPath 'C:\config\effective.json' -UserName 'remote' -IpAddress '172.19.1.100' } |
                Should -Throw '*Failed to remove Linux control-plane kubelet override*non-regular kubelet drop-in collision*'
        }
    }

    It 'propagates replacement or restart failures from the remote transaction' {
        InModuleScope $moduleName {
            function Get-K2sKubeletOverrideContent { param([Parameter(ValueFromRemainingArguments)]$Rest) }
            function Copy-ToRemoteComputerViaSshKey { param([string]$Source, [string]$Target, [string]$UserName, [string]$IpAddress) }
            function Invoke-CmdOnVmViaSSHKey { param([string]$CmdToExecute, [string]$UserName, [string]$IpAddress, [switch]$NoLog) }

            Mock Get-K2sKubeletOverrideContent { "# This file is managed by K2s. Do not edit.`nmaxPods: 42`n" }
            Mock Copy-ToRemoteComputerViaSshKey {}
            Mock Invoke-CmdOnVmViaSSHKey { [pscustomobject]@{ Success = $false; Output = 'kubelet restart failed' } }

            { Set-K2sLinuxKubeletOverride -EffectiveInstallConfigPath 'C:\config\effective.json' -UserName 'remote' -IpAddress '172.19.1.100' } |
                Should -Throw '*Failed to apply Linux control-plane kubelet override*kubelet restart failed*'
        }
    }
}
