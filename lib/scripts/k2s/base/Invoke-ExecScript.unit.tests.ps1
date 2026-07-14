# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'Invoke-ExecScript.ps1'
    $scriptContent = Get-Content -LiteralPath $scriptPath -Raw
}

Describe 'Invoke-ExecScript wrapper hardening' -Tag 'unit', 'ci', 'script', 'k2s' {
    Context 'core module preload guardrails' {
        It 'includes both required core modules in the preload list' {
            $scriptContent | Should -Match "(?s)\$coreModules\s*=\s*@\("
            $scriptContent | Should -Match "'Microsoft\.PowerShell\.Utility'"
            $scriptContent | Should -Match "'Microsoft\.PowerShell\.Management'"
        }

        It 'imports preloaded modules with ErrorAction Stop' {
            $scriptContent | Should -Match 'Import-Module\s+-Name\s+\$coreModule\s+-ErrorAction\s+Stop'
        }

        It 'writes preload failure diagnostics including PSVersion and PSEdition' {
            $scriptContent | Should -Match "Failed to import module '\$coreModule'"
            $scriptContent | Should -Match 'PSVersion=\$\(\$PSVersionTable\.PSVersion\)'
            $scriptContent | Should -Match 'PSEdition=\$\(\$PSVersionTable\.PSEdition\)'
        }
    }

    Context 'infra module import hardening' {
        It 'wraps infra module import in deterministic try/catch with ErrorAction Stop' {
            $scriptContent | Should -Match '(?s)try\s*\{\s*Import-Module\s+\$infraModule\s+-ErrorAction\s+Stop\s*\}\s*catch\s*\{'
            $scriptContent | Should -Match "Failed to import infra module '\$infraModule'"
            $scriptContent | Should -Match '(?s)catch\s*\{[^}]*exit\s+1'
        }
    }

    Context 'ShowLogs guardrail' {
        It 'performs a null-safe Script check before calling Contains' {
            $scriptContent | Should -Match '-not\s*\[string\]::IsNullOrWhiteSpace\(\$Script\)\s*-and\s*\$Script\.Contains\("-ShowLogs"\)'
        }
    }
}