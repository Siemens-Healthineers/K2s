# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

BeforeAll {
    $module = "$PSScriptRoot\Smb-posix.module.psm1"

    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('UseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester Test')]
    $moduleName = (Import-Module $module -PassThru -Force).Name
}

Describe 'Test-SambaPosixNegotiation' -Tag 'unit', 'ci', 'addon', 'storage smb' {
    # The posix module does not import the infra module, so
    # Invoke-CmdOnControlPlaneViaSSHKey is unresolved in its scope. Each test
    # injects a stub of that command inside the module scope to return canned
    # testparm output, then exercises the validator against it.

    Context 'POSIX settings present in testparm output' {
        It 'returns true when streams_xattr and store dos attributes = no are configured' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    return [pscustomobject]@{
                        Output = @('vfs objects = streams_xattr', 'store dos attributes = no')
                    }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeTrue
            }
        }
    }

    Context 'POSIX settings missing' {
        It 'returns false when streams_xattr is absent' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    return [pscustomobject]@{ Output = @('store dos attributes = no') }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeFalse
            }
        }

        It 'returns false when store dos attributes setting is absent' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    return [pscustomobject]@{ Output = @('vfs objects = streams_xattr') }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeFalse
            }
        }
    }

    Context 'Section query returns nothing' {
        It 'falls back to a full configuration dump and still detects POSIX settings' {
            InModuleScope -ModuleName $moduleName {
                function Invoke-CmdOnControlPlaneViaSSHKey {
                    param([string]$CmdToExecute, [int]$Timeout, [switch]$NoLog)
                    if ($CmdToExecute -match '--section-name') {
                        return [pscustomobject]@{ Output = @() }
                    }
                    return [pscustomobject]@{
                        Output = @('vfs objects = streams_xattr', 'store dos attributes = no')
                    }
                }

                Test-SambaPosixNegotiation -ShareName 'k2s-smb-share' | Should -BeTrue
            }
        }
    }
}
