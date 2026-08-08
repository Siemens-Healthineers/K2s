# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

BeforeAll {
    $script:OriginalPSModulePath = $env:PSModulePath

    # Inline copy of the normalization block from Invoke-ExecScript.ps1.
    # The block runs at script scope in the real script (not inside a function),
    # so we replicate it here as a helper to keep tests in-process and side-effect-free.
    # Kept in sync manually; update here when the source block changes.
    function global:Invoke-NormalizationBlock {
        if ($env:PSModulePath -match 'PowerShell[/\\]7') {
            $env:PSModulePath = @(
                "$env:USERPROFILE\Documents\WindowsPowerShell\Modules",
                "$env:ProgramFiles\WindowsPowerShell\Modules",
                "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
            ) -join ';'
        }
    }
}

AfterAll {
    $env:PSModulePath = $script:OriginalPSModulePath
    Remove-Item -Path Function:\Invoke-NormalizationBlock -ErrorAction SilentlyContinue
}

Describe 'Invoke-ExecScript PSModulePath normalization' -Tag 'unit', 'ci', 'ps7-compat', 'k2s' {

    BeforeEach {
        $env:PSModulePath = $script:OriginalPSModulePath
    }

    Context 'when PSModulePath contains a PowerShell 7 path (pollution detected)' {

        It 'replaces the path so it no longer matches the pwsh 7 pattern' {
            $env:PSModulePath = 'C:\Program Files\PowerShell\7\Modules;C:\Users\user\Documents\PowerShell\Modules'

            Invoke-NormalizationBlock

            $env:PSModulePath | Should -Not -Match 'PowerShell[/\\]7'
        }

        It 'contains the WindowsPowerShell user-level Modules path' {
            $env:PSModulePath = 'C:\Program Files\PowerShell\7\Modules'

            Invoke-NormalizationBlock

            $env:PSModulePath | Should -BeLike "*$env:USERPROFILE\Documents\WindowsPowerShell\Modules*"
        }

        It 'contains the ProgramFiles WindowsPowerShell\Modules path' {
            $env:PSModulePath = 'C:\Program Files\PowerShell\7\Modules'

            Invoke-NormalizationBlock

            $env:PSModulePath | Should -BeLike "*$env:ProgramFiles\WindowsPowerShell\Modules*"
        }

        It 'contains the System32 WindowsPowerShell\v1.0\Modules path' {
            $env:PSModulePath = 'C:\Program Files\PowerShell\7\Modules'

            Invoke-NormalizationBlock

            $env:PSModulePath | Should -BeLike "*$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules*"
        }

        It 'handles a forward-slash variant of the pwsh 7 marker' {
            $env:PSModulePath = 'C:\Program Files\PowerShell/7/Modules'

            Invoke-NormalizationBlock

            $env:PSModulePath | Should -Not -Match 'PowerShell[/\\]7'
        }
    }

    Context 'when PSModulePath is already a clean WinPS 5.1 path (no pollution)' {

        It 'leaves PSModulePath unchanged when all three canonical paths are present' {
            $cleanPath = "$env:USERPROFILE\Documents\WindowsPowerShell\Modules;$env:ProgramFiles\WindowsPowerShell\Modules;$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules"
            $env:PSModulePath = $cleanPath

            Invoke-NormalizationBlock

            $env:PSModulePath | Should -Be $cleanPath
        }

        It 'leaves PSModulePath unchanged when no 7-related segment is present' {
            $cleanPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\Modules'
            $env:PSModulePath = $cleanPath

            Invoke-NormalizationBlock

            $env:PSModulePath | Should -Be $cleanPath
        }
    }
}
