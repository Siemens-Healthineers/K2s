# SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

BeforeAll {
    $modulePath = "$PSScriptRoot/vm.module.psm1"
    $moduleName = (Import-Module $modulePath -PassThru -Force).Name
}

Describe 'Invoke-ExeWithAsciiEncoding' -Tag 'unit','ci','vm'  {
    Context 'PipeInput provided' {
        It 'returns piped text when executing system more.com' -Skip:(
        -not (Test-Path "$env:SystemRoot\System32\more.com")
        ){
            InModuleScope $moduleName {
                $exe = "$env:SystemRoot\System32\more.com"
                $args = @('')
                $text = 'yes'
                $originalIn = [Console]::InputEncoding.WebName
                $originalOut = [Console]::OutputEncoding.WebName
                $result = Invoke-ExeWithAsciiEncoding -ExePath $exe -Arguments $args -PipeInput $text
                ($result -join '').Trim() | Should -Be $text
                [Console]::InputEncoding.WebName | Should -Be $originalIn
                [Console]::OutputEncoding.WebName | Should -Be $originalOut
            }
        }
    }
    Context 'No PipeInput, arguments echo output'  {
        It 'captures output' -Skip:(
        -not (Test-Path "$env:SystemRoot\System32\cmd.exe")
        ){
            InModuleScope $moduleName {
                $exe = "$env:SystemRoot\System32\cmd.exe"
                $args = @('/c', 'echo', 'log-line')
                $result = Invoke-ExeWithAsciiEncoding -ExePath $exe -Arguments $args
                ($result -join '').Trim() | Should -Be 'log-line'
            }
        }
    }
}
