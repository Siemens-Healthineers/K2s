# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

<#
.SYNOPSIS
    Unit tests for Start-VirtualMachine WMI-to-CIM migration.
.DESCRIPTION
    Verifies that the error/retry logging branch in Start-VirtualMachine
    calls Get-CimInstance (not the deprecated Get-WmiObject) when Start-VM
    throws, and that the logging lines themselves do not propagate exceptions.
#>

BeforeAll {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module "$PSScriptRoot\vmnode.module.psm1" -PassThru -Force).Name
}

Describe 'Start-VirtualMachine - WMI to CIM migration' -Tag 'unit', 'ci', 'vmnode', 'k2s' {
    Context 'When Start-VM throws on every retry' {
        BeforeEach {
            Mock -ModuleName $moduleName Get-VM {
                [PSCustomObject]@{ Name = 'test-vm'; State = 'Off' }
            }

            Mock -ModuleName $moduleName Start-VM { throw 'Hyper-V start error (mocked)' }

            Mock -ModuleName $moduleName Get-CimInstance {
                [PSCustomObject]@{
                    FreePhysicalMemory = 1024000
                    FreeVirtualMemory  = 2048000
                }
            } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }

            Mock -ModuleName $moduleName Write-Log { }

            Mock -ModuleName $moduleName Start-Sleep { }
        }

        It 'invokes Get-CimInstance Win32_OperatingSystem on each failed retry' {
            InModuleScope $moduleName {
                { Start-VirtualMachine -VmName 'test-vm' } | Should -Throw

                Should -Invoke Get-CimInstance -Times 8 -Exactly -ParameterFilter {
                    $ClassName -eq 'Win32_OperatingSystem'
                }
            }
        }

        It 'throws only the retry-exhausted message, not a CimInstance property error' {
            InModuleScope $moduleName {
                $caught = $null
                try {
                    Start-VirtualMachine -VmName 'test-vm'
                }
                catch {
                    $caught = $_
                }

                $caught | Should -Not -BeNullOrEmpty

                $caught.Exception.Message | Should -BeLike '*Failed to start VM*'

                $caught.Exception.Message | Should -Not -BeLike '*Get-CimInstance*'
                $caught.Exception.Message | Should -Not -BeLike '*FreePhysicalMemory*'
                $caught.Exception.Message | Should -Not -BeLike '*FreeVirtualMemory*'
            }
        }
    }
}
