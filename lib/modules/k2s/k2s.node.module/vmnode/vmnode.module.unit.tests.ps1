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
            # Return exactly one VM so the count check (Measure-Object) passes
            Mock -ModuleName $moduleName Get-VM {
                [PSCustomObject]@{ Name = 'test-vm'; State = 'Off' }
            }

            # Always throw to trigger the catch block on every retry iteration
            Mock -ModuleName $moduleName Start-VM { throw 'Hyper-V start error (mocked)' }

            # The migrated CIM calls - return a PSCustomObject with the expected properties.
            # LIMITATION: ParameterFilter only checks -ClassName; the non-Win32_OperatingSystem
            # Get-CimInstance calls (e.g. Win32_OperatingSystem BuildNumber, Msvm_ namespace)
            # are NOT exercised by this test path, so a single filter is sufficient here.
            Mock -ModuleName $moduleName Get-CimInstance {
                [PSCustomObject]@{
                    FreePhysicalMemory = 1024000
                    FreeVirtualMemory  = 2048000
                }
            } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }

            # Suppress all file/console logging
            Mock -ModuleName $moduleName Write-Log { }

            # Avoid the 20-second per-retry sleep (maxRetries = 4, retryDelay = 20s)
            Mock -ModuleName $moduleName Start-Sleep { }
        }

        It 'invokes Get-CimInstance Win32_OperatingSystem on each failed retry' {
            # After 4 failed retries the function throws "Failed to start VM ..."
            # That terminal throw is expected and caught here.
            InModuleScope $moduleName {
                { Start-VirtualMachine -VmName 'test-vm' } | Should -Throw

                # maxRetries = 4; each retry calls Get-CimInstance twice (FreePhysicalMemory + FreeVirtualMemory)
                Should -Invoke Get-CimInstance -Times 8 -Exactly -ParameterFilter {
                    $ClassName -eq 'Win32_OperatingSystem'
                }
            }
        }

        It 'throws only the retry-exhausted message, not a CimInstance property error' {
            # Ensures the Get-CimInstance mock returns the required properties so that
            # the string-interpolation in Write-Log does not itself raise an exception.
            InModuleScope $moduleName {
                $caught = $null
                try {
                    Start-VirtualMachine -VmName 'test-vm'
                }
                catch {
                    $caught = $_
                }

                # Must have thrown (retries exhausted)
                $caught | Should -Not -BeNullOrEmpty

                # The exception must be the expected retry-exhausted message
                $caught.Exception.Message | Should -BeLike '*Failed to start VM*'

                # Must NOT be a Get-CimInstance or property-access failure
                $caught.Exception.Message | Should -Not -BeLike '*Get-CimInstance*'
                $caught.Exception.Message | Should -Not -BeLike '*FreePhysicalMemory*'
                $caught.Exception.Message | Should -Not -BeLike '*FreeVirtualMemory*'
            }
        }
    }
}
